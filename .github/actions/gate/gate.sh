#!/usr/bin/env bash
# One required check per workflow: red unless every job before it ended well.
#
#   NEEDS_JSON='${{ toJSON(needs) }}' gate.sh
#
# NEEDS_JSON  the calling job's `toJSON(needs)`: an object keyed by job id, each
#             value carrying at least `result`
#
# GREEN when every job reports `success` or `skipped`. A job behind a paths
# filter or an `if:` that did not apply is skipped, and that is not a defect.
# RED when any job reports `failure` or `cancelled` — and also for any other or
# missing result, because a value this script does not know is not a success.
# RED when the set is empty or not an object: a gate that waits for nothing
# would be green forever, which is the failure it exists to prevent.
#
# Every red job is printed with its id and result, as an error annotation and in
# the job summary, so a red gate says what it hangs on without a search.
set -euo pipefail

needs=${NEEDS_JSON-}

summary() { # <markdown line>
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; fi
}

if ! count=$(jq -er 'if type == "object" then length else error("not an object") end' <<<"$needs" 2>/dev/null); then
  echo "::error title=gate::gate RED: the input is not a JSON object of jobs — pass toJSON(needs)"
  summary "**gate RED**: the input is not a JSON object of jobs — pass \`toJSON(needs)\`"
  exit 1
fi

if [ "$count" -eq 0 ]; then
  echo "::error title=gate::gate RED: no jobs given — needs: of the gate job lists no job, so it would check nothing"
  summary "**gate RED**: no jobs given — \`needs:\` of the gate job lists no job"
  exit 1
fi

red=0
rows=""
while IFS=$'\t' read -r job result; do
  case "$result" in
    success|skipped)
      echo "ok   $job: $result" ;;
    *)
      echo "::error title=gate::job '$job' ended $result"
      red=$((red + 1)) ;;
  esac
  rows="${rows}| \`${job}\` | ${result} |"$'\n'
done < <(jq -r 'to_entries[] | [.key, ((.value.result // "missing") | tostring)] | @tsv' <<<"$needs")

if [ "$red" -gt 0 ]; then
  echo "gate RED: $red of $count job(s) did not end in success or skipped"
  summary "**gate RED**: $red of $count job(s) did not end in success or skipped"
else
  echo "gate GREEN: all $count job(s) ended in success or skipped"
  summary "**gate GREEN**: all $count job(s) ended in success or skipped"
fi
summary ""
summary "| job | result |"
summary "|---|---|"
summary "${rows%$'\n'}"

[ "$red" -eq 0 ]
