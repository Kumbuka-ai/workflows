#!/usr/bin/env bash
#
# One table for every repository's security gates.
#
# For a single repository, red is the overview: the run failed, the summary says
# why. Across two dozen it stops being one — which is the same argument that
# replaced the code-scanning view in the first place, arriving one order of
# magnitude later. This collects what the gates found and sorts it into the only
# three buckets that lead anywhere:
#
#   FIX      a fix exists and can be adopted here      -> do it
#   IGNORE   a finding that is not one, or not ours    -> register it, with a reason
#   WAIT     no fix upstream                           -> blocks nothing, returns by itself
#
# The third bucket is the one that needs no decision: an unfixed CVE does not
# block, and the moment upstream publishes a fix it blocks on its own. It is
# listed so nobody is surprised, not so anybody acts.
#
# Usage:
#   scripts/security-overview.sh                 # markdown to stdout
#   scripts/security-overview.sh --json          # raw data
#   ORG=Kumbuka-ai scripts/security-overview.sh
#
# Needs: gh (authenticated), jq. Read access to the repositories it reports on —
# which is why this is a script and not only a workflow: the token a workflow
# gets is scoped to its own repository and cannot see the others.

set -euo pipefail

ORG="${ORG:-Kumbuka-ai}"
WORKFLOW="${WORKFLOW:-security.yml}"
FORMAT="markdown"
[ "${1:-}" = "--json" ] && FORMAT="json"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Repositories that actually carry the gates. Asking the repository rather than
# keeping a list here: a list would be wrong the first time someone adds one.
mapfile -t repos < <(
  gh repo list "$ORG" --limit 200 --json name,isArchived \
    --jq '.[] | select(.isArchived == false) | .name' | sort
)

echo '[]' > "$tmp/all.json"

for repo in "${repos[@]}"; do
  gh api "repos/$ORG/$repo/contents/.github/workflows/$WORKFLOW" >/dev/null 2>&1 || continue

  run=$(gh api "repos/$ORG/$repo/actions/workflows/$WORKFLOW/runs?per_page=1&status=completed" \
        --jq '.workflow_runs[0] // empty' 2>/dev/null) || true
  [ -z "$run" ] && continue

  run_id=$(jq -r '.id'          <<<"$run")
  concl=$( jq -r '.conclusion'  <<<"$run")
  when=$(  jq -r '.updated_at'  <<<"$run")
  url=$(   jq -r '.html_url'    <<<"$run")

  jobs=$(gh api "repos/$ORG/$repo/actions/runs/$run_id/jobs" --jq '.jobs' 2>/dev/null) || jobs='[]'

  # The findings live in the job logs. They would be cleaner as artefacts, and
  # the shared workflow uploads them as such — but logs are what exists for runs
  # that predate that, so both are read and the logs are the fallback.
  findings="[]"
  while read -r job_id job_name; do
    [ -z "$job_id" ] && continue
    # --allow-escape-sequences is required: without it gh refuses to emit the
    # log at all ("the response contains terminal escape sequences") and returns
    # nothing, which looks exactly like a job with no findings. The codes are
    # then stripped, because every pattern below would otherwise miss.
    log=$(gh api "repos/$ORG/$repo/actions/jobs/$job_id/logs" --allow-escape-sequences 2>/dev/null \
          | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g') || continue
    [ -z "$log" ] && continue

    # Trivy, blocking: severity, package@version, CVE, fixed version
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      findings=$(jq --arg t "trivy" --arg j "$job_name" --arg l "$line" \
        '. + [{tool:$t, job:$j, bucket:"FIX", detail:$l}]' <<<"$findings")
    done < <(grep -oE '(CRITICAL|HIGH)[[:space:]]+[^[:space:]]+@[^[:space:]]+[[:space:]]+CVE-[0-9-]+[[:space:]]+fixed:[^[:space:]-][^[:space:]]*' <<<"$log" | sort -u || true)

    # Trivy, no fix upstream
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      findings=$(jq --arg t "trivy" --arg j "$job_name" --arg l "$line" \
        '. + [{tool:$t, job:$j, bucket:"WAIT", detail:$l}]' <<<"$findings")
    done < <(grep -oE 'UNFIXED[[:space:]]+(CRITICAL|HIGH)[[:space:]]+[^[:space:]]+[[:space:]]+CVE-[0-9-]+' <<<"$log" | sort -u || true)

    # Semgrep: path:line rule
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      findings=$(jq --arg t "semgrep" --arg j "$job_name" --arg l "$line" \
        '. + [{tool:$t, job:$j, bucket:"DECIDE", detail:$l}]' <<<"$findings")
    done < <(grep -oE '[a-zA-Z0-9_./-]+:[0-9]+[[:space:]]+[a-z]+\.[a-z0-9_.-]+' <<<"$log" | sort -u | head -40 || true)

    # Gitleaks: path:line rule-id
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      findings=$(jq --arg t "gitleaks" --arg j "$job_name" --arg l "$line" \
        '. + [{tool:$t, job:$j, bucket:"DECIDE", detail:$l}]' <<<"$findings")
    done < <(grep -oE '/src/[^[:space:]]+:[0-9]+[[:space:]]+[a-z-]+$' <<<"$log" | sort -u || true)
  done < <(jq -r '.[] | select(.conclusion == "failure") | "\(.id) \(.name)"' <<<"$jobs")

  jq --arg r "$repo" --arg c "$concl" --arg w "$when" --arg u "$url" \
     --argjson jobs "$jobs" --argjson f "$findings" \
     '. + [{repo:$r, conclusion:$c, when:$w, url:$u,
            jobs: ($jobs | map({name, conclusion})),
            findings: $f}]' "$tmp/all.json" > "$tmp/next.json"
  mv "$tmp/next.json" "$tmp/all.json"
done

if [ "$FORMAT" = "json" ]; then
  cat "$tmp/all.json"
  exit 0
fi

cat <<'HEAD'
# Security gates — state of every repository

Generated by `scripts/security-overview.sh`. Each row is the most recent
completed run of that repository's `security` workflow.

**FIX** a fix exists and can be adopted · **DECIDE** needs a human call: real
finding or documented exception · **WAIT** no fix upstream, blocks nothing and
returns by itself once one is published.

HEAD

printf '## Summary\n\n| repository | run | failing jobs |\n|---|---|---|\n'
jq -r '.[] |
  "| `\(.repo)` | \(if .conclusion == "success" then "green" else "**red**" end) | " +
  ((.jobs | map(select(.conclusion == "failure") | .name) | join(", ")) // "-" |
   if . == "" then "—" else . end) + " |"' "$tmp/all.json"

printf '\n## Triage\n\n'
jq -r '
  .[] | select(.findings | length > 0) |
  "### `\(.repo)`\n\n" +
  "[run](\(.url))\n\n" +
  "| bucket | tool | finding |\n|---|---|---|\n" +
  (.findings
   | group_by(.bucket) | sort_by(.[0].bucket)
   | map(.[] | "| \(.bucket) | \(.tool) | `\(.detail)` |")
   | join("\n")) + "\n"
' "$tmp/all.json"

printf '\n## Nothing to decide\n\n'
jq -r '[.[] | select(.conclusion == "success") | .repo] as $g |
  if ($g | length) == 0 then "None yet."
  else "Green: " + ($g | map("`" + . + "`") | join(", ")) end' "$tmp/all.json"
