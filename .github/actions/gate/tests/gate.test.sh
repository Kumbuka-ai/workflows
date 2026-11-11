#!/usr/bin/env bash
# Executable test of gate.sh against inputs shaped like toJSON(needs). The
# expected exit status of each case is written here, not derived from gate.sh.
#
#   bash .github/actions/gate/tests/gate.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sut="$here/../gate.sh"
fails=0

check() { # <description> <expected rc> <needs json> [text the output must contain]
  out=$(NEEDS_JSON=$3 GITHUB_STEP_SUMMARY='' bash "$sut" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then echo "PASS  $1"
  else echo "FAIL  $1 (rc=$rc, expected $2${4:+, output must contain: $4})"; printf '      %s\n' "${out//$'\n'/$'\n'      }"; fails=$((fails+1)); fi
}

check "all success: green"            0 '{"build":{"result":"success","outputs":{}},"test":{"result":"success","outputs":{}}}'
check "one skipped among them: green" 0 '{"build":{"result":"success","outputs":{}},"migrations":{"result":"skipped","outputs":{}},"test":{"result":"success","outputs":{}}}'
check "one failure: red, named"       1 '{"build":{"result":"success","outputs":{}},"test":{"result":"failure","outputs":{}}}' "job 'test' ended failure"
check "one cancelled: red, named"     1 '{"build":{"result":"cancelled","outputs":{}},"test":{"result":"success","outputs":{}}}' "job 'build' ended cancelled"
check "empty set: red"                1 '{}' "no jobs given"
check "all skipped: green"            0 '{"a":{"result":"skipped","outputs":{}}}'
check "every red job is named"        1 '{"a":{"result":"failure"},"b":{"result":"cancelled"},"c":{"result":"success"}}' "2 of 3 job(s)"
check "unknown result: red"           1 '{"a":{"result":"neutral"}}' "job 'a' ended neutral"
check "missing result: red"           1 '{"a":{}}' "job 'a' ended missing"
check "empty input: red"              1 ''
check "not an object: red"            1 '[]'
check "not JSON: red"                 1 'needs'

echo
if [ "$fails" -eq 0 ]; then echo "gate: all cases pass"; else echo "gate: $fails case(s) FAIL"; exit 1; fi
