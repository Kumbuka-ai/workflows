#!/usr/bin/env bash
# The Trivy image scan, run inside the job that built the image (action.yml next
# to this file). Moved here verbatim from reusable-security-image.yml; what
# changed is only the input: the image is named by the caller instead of being
# built under a fixed tag, the scanned image's id is printed, and the databases
# may come from the runner image (db-seed.sh). Scanners, severities, the database
# sources and every line of the blocking logic below are the ones the template
# had.
#
# Environment: IMAGE_REF, IMAGE_NAME, SEVERITY, TRIVY_IMAGE, DB_SEED_DIR,
# DB_MAX_AGE_HOURS, ACTION_PATH, plus the runner's own RUNNER_TEMP,
# GITHUB_WORKSPACE and GITHUB_STEP_SUMMARY.
set -euo pipefail
mkdir -p "$RUNNER_TEMP/trivy-cache"

started=$(date +%s)
# Same register as the filesystem scan. It has to be mounted explicitly
# here: this job talks to the docker socket, not to the checkout.
IGNORE_ARG=""
IGNORE_MOUNT=""
if [ -f "$GITHUB_WORKSPACE/.trivyignore.yaml" ]; then
  IGNORE_ARG="--ignorefile /ignore/.trivyignore.yaml"
  IGNORE_MOUNT="-v $GITHUB_WORKSPACE/.trivyignore.yaml:/ignore/.trivyignore.yaml:ro"
  echo "Risk register in use:"
  cat "$GITHUB_WORKSPACE/.trivyignore.yaml"
fi

# The socket this runner actually talks to. A hosted runner has it at
# /var/run/docker.sock and DOCKER_HOST is unset; a rootless daemon has
# it under $XDG_RUNTIME_DIR and says so in DOCKER_HOST. Mounting the
# fixed path on a rootless machine mounts nothing, and Trivy then
# reports the image as not found -- "Cannot connect to the Docker
# daemon at unix:///var/run/docker.sock" -- after the build step has
# already succeeded, which reads like a broken image rather than a
# missing mount. Measured on apollo 2026-09-26 across five
# repositories. Inside the container it stays at the default path,
# because that is where Trivy looks; only the host side moves.
#
# The expansion takes two steps because DOCKER_HOST may not be set
# at all, and that is a case the line has to survive rather than the
# exception it looks like: a hosted runner leaves it unset, while an
# apollo slot sets it to unix:///var/run/docker.sock. Measured
# 2026-09-28 on both. Under `set -u` a bare `${DOCKER_HOST#unix://}`
# does not yield the empty string where the variable is unset -- it
# aborts the step with "DOCKER_HOST: unbound variable" before the
# fallback on the line below is ever reached, so the one case the
# fallback exists for is the one that never gets there.
# `${DOCKER_HOST:-}` turns unset into an empty string first; only
# then is the prefix stripped.
DOCKER_SOCK="${DOCKER_HOST:-}"
DOCKER_SOCK="${DOCKER_SOCK#unix://}"
[ -S "${DOCKER_SOCK:-}" ] || DOCKER_SOCK=/var/run/docker.sock
echo "docker socket: $DOCKER_SOCK"

# shellcheck disable=SC2086
# TRIVY'S OWN TIMEOUT, RAISED FROM ITS 5-MINUTE DEFAULT (satellite/29.17).
# The scan fails as `context deadline exceeded` when the five minutes run
# out, and on this build host they run out under load rather than because
# anything is wrong with the image: measured 2026-09-29, the same scan that
# fails with thirteen jobs on the machine passes on an idle one. A deadline
# that is a function of how busy the neighbours are is not a finding about
# the code under test.
#
# THIS RAISES THE PATIENCE, NOT THE BAR. No scanner is skipped, no analyser
# is switched off, no severity is downgraded, and `--exit-code`/the
# blocking logic below are untouched: a vulnerability that was blocking
# before this line is blocking after it. The only thing that changes is how
# long Trivy waits before giving up on itself.
#
# WHERE THE DATABASES COME FROM FIRST: a copy the runner image preloaded, if
# there is one and it is younger than the limit (db-seed.sh, next to this file,
# decides per database and says why). Otherwise the download below, as always —
# and a preloaded copy that is too old is never used quietly: it is a warning
# annotation in the job, then the download.
# THE CANONICAL DATABASE FIRST, AND THE ORDER IS THE WHOLE POINT
# (satellite/29.17). Trivy's default is the list
# [mirror.gcr.io/aquasec/trivy-db:2, ghcr.io/aquasecurity/trivy-db:2], and
# on 2026-09-28 and 2026-09-29 the Google mirror answered a layer download
# with `404 Not Found` — twice, in infra and ee-memory, and the job died
# with `failed to download vulnerability DB` rather than trying the second
# entry.
#
# THAT IS NOT A FALLBACK CHAIN, measured 2026-09-29 in a job container:
#
#   --db-repository kumbuka.invalid/x:1                      rc=1
#   --db-repository kumbuka.invalid/x:1,ghcr.io/…/trivy-db:2 rc=1  ← still
#   --db-repository ghcr.io/…/trivy-db:2,mirror.gcr.io/…:2   rc=0
#
# A download failure on the FIRST entry ends the attempt; the second entry
# does not rescue it. So the list is a priority order and nothing else, and
# which repository is first is the only decision it expresses. Put the one
# Aqua Security publishes itself first — it is where the mirror mirrors
# from, and it is not the one that produced the 404. The mirror stays as
# the second entry: it costs nothing and covers the failure classes where
# the fallback does work.
#
# This changes where the database comes from, not what it contains. No
# scanner, analyser or severity is touched.
# THE IMAGE THIS SCAN LOOKS AT, by its content-addressed id. The step that
# built it prints the same id, so the log shows that what was scanned is what
# was built — and, in a release, what is pushed.
echo "scanned image: $IMAGE_REF $(docker image inspect "$IMAGE_REF" --format '{{.Id}}')"

DB_ARGS=$(bash "$ACTION_PATH/db-seed.sh" "$DB_SEED_DIR" "$RUNNER_TEMP/trivy-cache" "$DB_MAX_AGE_HOURS")

# shellcheck disable=SC2086
docker run --rm \
  -v "$DOCKER_SOCK":/var/run/docker.sock \
  -v "$RUNNER_TEMP/trivy-cache":/root/.cache/trivy \
  $IGNORE_MOUNT \
  "$TRIVY_IMAGE" image "$IMAGE_REF" $IGNORE_ARG $DB_ARGS \
  --scanners vuln \
  --timeout 15m \
  --db-repository ghcr.io/aquasecurity/trivy-db:2,mirror.gcr.io/aquasec/trivy-db:2 \
  --java-db-repository ghcr.io/aquasecurity/trivy-java-db:1,mirror.gcr.io/aquasec/trivy-java-db:1 \
  --list-all-pkgs \
  --format json --quiet \
  > "$RUNNER_TEMP/trivy-image.json"
elapsed=$(( $(date +%s) - started ))

cp "$RUNNER_TEMP/trivy-image.json" "$GITHUB_WORKSPACE/trivy-image-$IMAGE_NAME-report.json"

pkgs=$(jq '[.Results[]?.Packages[]?] | length'         "$RUNNER_TEMP/trivy-image.json")
targets=$(jq '[.Results[]?] | length'                  "$RUNNER_TEMP/trivy-image.json")
vulns=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$RUNNER_TEMP/trivy-image.json")

{
  echo "### Trivy — image \`$IMAGE_NAME\`"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| targets | $targets |"
  echo "| packages in image | $pkgs |"
  echo "| vulnerabilities (all severities) | $vulns |"
  echo "| runtime (scan only) | ${elapsed}s |"
  echo "| blocking severities | $SEVERITY |"
  echo "| image | \`$TRIVY_IMAGE\` |"
  echo
  echo "| severity | count |"
  echo "|---|---|"
  jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.)
         | map({s: .[0], n: length}) | sort_by(-.n)[]
         | "| \(.s) | \(.n) |"' "$RUNNER_TEMP/trivy-image.json"
} >> "$GITHUB_STEP_SUMMARY"

echo "targets=$targets packages=$pkgs vulns=$vulns"

# An image with no packages means the scan looked at nothing — which is
# exactly what a green verdict would otherwise hide.
if [ "$pkgs" -eq 0 ]; then
  echo "::error::Trivy found 0 packages in $IMAGE_NAME — the check had no search space, so its green verdict means nothing"
  exit 1
fi

echo "--- all findings (reported; only $SEVERITY block) ---"
jq -r '.Results[]? | .Target as $t | (.Vulnerabilities // [])[]
       | "\($t)  \(.Severity)  \(.PkgName)@\(.InstalledVersion)  \(.VulnerabilityID)  fixed:\(.FixedVersion // "-")"' \
       "$RUNNER_TEMP/trivy-image.json" | sort || true

# Only a fixable vulnerability blocks — see the filesystem job for the
# reasoning. It matters most here: a base image carries OS packages
# whose CVEs are routinely unfixed for months — a RedHat 9.8 layer
# carrying pcre2 with `fixed:-` is the worked example. Blocking on
# those would make this job permanently red without a single action
# anyone could take.
blocking=$(jq --arg sev "$SEVERITY" \
  '($sev | split(",")) as $s
   | [ .Results[]?.Vulnerabilities[]?
       | select(.Severity as $x | $s | index($x))
       | select((.FixedVersion // "") != "") ] | length' \
  "$RUNNER_TEMP/trivy-image.json")

unfixed=$(jq --arg sev "$SEVERITY" \
  '($sev | split(",")) as $s
   | [ .Results[]?.Vulnerabilities[]?
       | select(.Severity as $x | $s | index($x))
       | select((.FixedVersion // "") == "") ] | length' \
  "$RUNNER_TEMP/trivy-image.json")

{
  echo
  echo "| at $SEVERITY | count |"
  echo "|---|---|"
  echo "| with a fix available (blocking) | $blocking |"
  echo "| without a fix upstream (reported, not blocking) | $unfixed |"
} >> "$GITHUB_STEP_SUMMARY"

# WHAT IS BLOCKING, NAMED, AT THE TOP OF THE SUMMARY. A count answers
# "is it red"; it does not answer the only question anyone has when it
# is, which is what to upgrade. Until this table existed the CVE was in
# the job log and nowhere else: the annotation said "1 fixable
# vulnerability", the summary said "1", and a reader had to open the
# job and scroll to find out that it was jackson-databind.
if [ "$blocking" -gt 0 ]; then
  {
    echo
    echo "#### What blocks this build"
    echo
    echo "| severity | package | installed | fixed in | advisory | target |"
    echo "|---|---|---|---|---|---|"
    jq -r --arg sev "$SEVERITY" '
      ($sev | split(",")) as $s
      | [ .Results[]? | .Target as $t | (.Vulnerabilities // [])[]
          | select(.Severity as $x | $s | index($x))
          | select((.FixedVersion // "") != "")
          | {t:$t, sev:.Severity, pkg:.PkgName, cur:.InstalledVersion,
             fix:.FixedVersion, id:.VulnerabilityID} ]
      | unique_by([.pkg, .id]) | sort_by(.sev, .pkg) | .[]
      | "| \(.sev) | `\(.pkg)` | `\(.cur)` | **\(.fix)** | [\(.id)](https://nvd.nist.gov/vuln/detail/\(.id)) | \(.t) |"' \
      "$RUNNER_TEMP/trivy-image.json"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$unfixed" -gt 0 ]; then
  echo "::warning::$unfixed vulnerability/ies at $SEVERITY in $IMAGE_NAME have no fix upstream — reported, not blocking. They will block automatically once a fix is published."
  jq -r '.Results[]? | (.Vulnerabilities // [])[]
         | select((.FixedVersion // "") == "")
         | "  UNFIXED \(.Severity)  \(.PkgName)@\(.InstalledVersion)  \(.VulnerabilityID)"' \
         "$RUNNER_TEMP/trivy-image.json" | sort -u || true
fi

if [ "$blocking" -gt 0 ]; then
  # ONE ANNOTATION PER FINDING, AND EACH ONE NAMES THE UPGRADE.
  # Annotations are what a reader sees first — in the checks list, on
  # the PR, in the run's header — and until now the only one said
  # "Trivy found N fixable vulnerability/ies", which is a number, not
  # a thing to do. Now the first screen carries the package, the
  # version in the image and the versions that carry the fix.
  #
  # EVERY FIXED VERSION IS PRINTED, NOT THE FIRST. Trivy lists one per
  # release line — jackson-databind 2.21.4 reports
  # `2.18.10, 2.21.6, 2.22.2` — and the first entry is frequently
  # BELOW the installed version. An annotation reading "upgrade to
  # 2.18.10" would be advice to downgrade, which is worse than no
  # advice. Which line to follow is the caller's decision; this says
  # where the fixes are.
  jq -r --arg sev "$SEVERITY" --arg img "$IMAGE_NAME" '
    ($sev | split(",")) as $s
    | [ .Results[]? | (.Vulnerabilities // [])[]
        | select(.Severity as $x | $s | index($x))
        | select((.FixedVersion // "") != "")
        | {sev:.Severity, pkg:.PkgName, cur:.InstalledVersion,
           fix:.FixedVersion, id:.VulnerabilityID} ]
    | unique_by([.pkg, .id]) | sort_by(.sev, .pkg) | .[]
    | "::error::\($img): \(.id) \(.sev) — \(.pkg) \(.cur), fixed in \(.fix)"' \
    "$RUNNER_TEMP/trivy-image.json"
  # THE TWO NUMBERS ARE NOT THE SAME NUMBER, and saying so is cheaper
  # than letting a reader find the discrepancy. $blocking counts
  # findings as Trivy reports them — the same CVE in the same package
  # appears once per target it was found in — while the annotations
  # above are one per (package, CVE). A summary line claiming "each of
  # 3 is annotated" above two annotations would read as a bug in the
  # gate.
  distinct=$(jq --arg sev "$SEVERITY" \
    '($sev | split(",")) as $s
     | [ .Results[]?.Vulnerabilities[]?
         | select(.Severity as $x | $s | index($x))
         | select((.FixedVersion // "") != "")
         | {pkg:.PkgName, id:.VulnerabilityID} ] | unique | length' \
    "$RUNNER_TEMP/trivy-image.json")
  if [ "$distinct" = "$blocking" ]; then
    echo "::error::Trivy found $blocking fixable vulnerability/ies at $SEVERITY in $IMAGE_NAME — each one is annotated above, and the job summary lists them with links"
  else
    echo "::error::Trivy found $blocking fixable finding(s) at $SEVERITY in $IMAGE_NAME, $distinct distinct package/CVE pair(s) — each pair is annotated above, and the job summary lists them with links"
  fi
  exit 1
fi

echo "Trivy image $IMAGE_NAME: $pkgs packages, nothing at $SEVERITY."
