#!/usr/bin/env bash
# Executable test of check.sh against real images built here: one carrying the
# start file, one without it (the .dockerignore case), one with it empty, one
# with a directory of that name, and a regex for a versioned jar.
#
#   bash .github/actions/image-startfile-check/tests/check.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sut="$here/../check.sh"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"; docker image rm -f $(cat "$T.images" 2>/dev/null) >/dev/null 2>&1; rm -f "$T.images"' EXIT

build() { # <tag> <dockerfile-body> [file:content ...]
  local tag=$1 body=$2; shift 2
  local d="$T/$tag"; mkdir -p "$d"
  printf '%s\n' "$body" > "$d/Dockerfile"
  for fc in "$@"; do mkdir -p "$d/$(dirname "${fc%%:*}")"; printf '%s' "${fc#*:}" > "$d/${fc%%:*}"; done
  docker build -q -t "startfile-test:$tag" "$d" >/dev/null || { echo "could not build $tag"; exit 2; }
  echo "startfile-test:$tag" >> "$T.images"
}

check() { # <description> <expected rc> <image> <regex>
  out=$(bash "$sut" "$3" "$4" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ] && grep -q "checked image: $3 sha256:" <<<"$out"; then echo "PASS  $1"
  else echo "FAIL  $1 (rc=$rc, expected $2)"; printf '%s\n' "${out//$'\n'/$'\n'      }"; fails=$((fails+1)); fi
}

build present 'FROM scratch
COPY app/ /app/' 'app/quarkus-run.jar:PK-not-empty'
build absent 'FROM scratch
COPY other/ /other/' 'other/readme.txt:x'
build empty 'FROM scratch
COPY app/ /app/' 'app/quarkus-run.jar:'
build isdir 'FROM scratch
COPY app/ /app/' 'app/quarkus-run.jar/inner:x'
build versioned 'FROM scratch
COPY providers/ /opt/keycloak/providers/' 'providers/cimd-grant-normalizer-1.4.0.jar:PK'

check "present: green"                          0 startfile-test:present   'app/quarkus-run\.jar'
check "absent (excluded build output): red"     1 startfile-test:absent    'app/quarkus-run\.jar'
check "empty start file: red"                   1 startfile-test:empty     'app/quarkus-run\.jar'
check "directory of that name: red"             1 startfile-test:isdir     'app/quarkus-run\.jar'
check "versioned jar by regex: green"           0 startfile-test:versioned 'opt/keycloak/providers/cimd-grant-normalizer-.*\.jar'
check "anchored: a prefix does not match"       1 startfile-test:present   'app/quarkus-run'

echo
if [ "$fails" -eq 0 ]; then echo "image-startfile-check: all cases pass"; else echo "image-startfile-check: $fails case(s) FAIL"; exit 1; fi
