#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Executable test of publish.sh, pushing into a local OCI image layout: the same
# push the release makes to GHCR, without a registry. Every expected value is
# written here, from docs/docs-fragment.md. Needs git, jq and oras on PATH
# (scripts/docs-fragment/install-tools.sh).
#
#   bash scripts/docs-fragment/tests/publish.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scripts=$(cd "$here/.." && pwd)
fails=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
expect() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

if ! command -v oras >/dev/null; then
  echo "FAIL  oras is not on PATH; run scripts/docs-fragment/install-tools.sh first"
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

src="$tmp/src"
cp -R "$here/fixture" "$src"
git -C "$src" init -q
git -C "$src" add .
git -C "$src" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
  commit -q -m fixture
fixture_commit=$(git -C "$src" rev-parse HEAD)

fragment() { # <version> <out dir>
  bash "$scripts/generate.sh" --module fixture-module --version "$1" --source "$src" --out "$2" >/dev/null &&
    bash "$scripts/export-plantuml.sh" --fragment "$2/fragment.json" --out "$2/plantuml" >/dev/null
}

type_expected=application/vnd.kumbuka.docs-fragment.v1

# --- a v-prefixed release tag: both forms --------------------------------------

fragment v1.2.3 "$tmp/v" || fail "setup: fragment for v1.2.3"
if bash "$scripts/publish.sh" --dir "$tmp/v" --version v1.2.3 --oci-layout "$tmp/layout-v" >"$tmp/pv.log" 2>&1; then
  pass "publish: v1.2.3 into an OCI layout"
else fail "publish: v1.2.3 into an OCI layout"; cat "$tmp/pv.log"; fi

oras manifest fetch --oci-layout "$tmp/layout-v:v1.2.3" >"$tmp/m-v.json" 2>/dev/null
oras manifest fetch --oci-layout "$tmp/layout-v:1.2.3" >"$tmp/m-plain.json" 2>/dev/null
expect "publish: tag v1.2.3 is our artefact type" "$type_expected" "$(jq -r '.artifactType' "$tmp/m-v.json" 2>/dev/null)"
expect "publish: tag 1.2.3 is our artefact type"  "$type_expected" "$(jq -r '.artifactType' "$tmp/m-plain.json" 2>/dev/null)"
if [ -s "$tmp/m-v.json" ] && cmp -s "$tmp/m-v.json" "$tmp/m-plain.json"; then
  pass "publish: both forms are one manifest"
else fail "publish: both forms are one manifest"; fi
expect "publish: the layers are fragment.json and plantuml" "fragment.json,plantuml" \
  "$(jq -r '[.layers[].annotations["org.opencontainers.image.title"]] | sort | join(",")' "$tmp/m-v.json" 2>/dev/null)"
expect "publish: fragment.json has its own media type" "application/vnd.kumbuka.docs-fragment.fragment.v1+json" \
  "$(jq -r '.layers[] | select(.annotations["org.opencontainers.image.title"] == "fragment.json") | .mediaType' "$tmp/m-v.json" 2>/dev/null)"
expect "publish: the revision is the commit" "$fixture_commit" \
  "$(jq -r '.annotations["org.opencontainers.image.revision"]' "$tmp/m-v.json" 2>/dev/null)"

if oras pull --oci-layout "$tmp/layout-v:1.2.3" -o "$tmp/pulled" >/dev/null 2>&1 \
   && cmp -s "$tmp/v/fragment.json" "$tmp/pulled/fragment.json" \
   && diff -r "$tmp/v/plantuml" "$tmp/pulled/plantuml" >/dev/null; then
  pass "publish: what is pulled is what was produced"
else fail "publish: what is pulled is what was produced"; fi

# --- a release tag without v: that form only -------------------------------------

fragment 1.2.3 "$tmp/p" || fail "setup: fragment for 1.2.3"
if bash "$scripts/publish.sh" --dir "$tmp/p" --version 1.2.3 --oci-layout "$tmp/layout-p" >"$tmp/pp.log" 2>&1; then
  pass "publish: 1.2.3 into an OCI layout"
else fail "publish: 1.2.3 into an OCI layout"; cat "$tmp/pp.log"; fi
expect "publish: tag 1.2.3 is our artefact type" "$type_expected" \
  "$(oras manifest fetch --oci-layout "$tmp/layout-p:1.2.3" 2>/dev/null | jq -r '.artifactType' 2>/dev/null)"
if oras manifest fetch --oci-layout "$tmp/layout-p:v1.2.3" >/dev/null 2>&1; then
  fail "publish: no v-form is invented for 1.2.3"
else pass "publish: no v-form is invented for 1.2.3"; fi

# --- refusals ------------------------------------------------------------------

bash "$scripts/publish.sh" --dir "$tmp/v" --version v9.9.9 --oci-layout "$tmp/layout-x" >/dev/null 2>&1
expect "publish: a version other than the fragment's fails" "1" "$?"
bash "$scripts/publish.sh" --dir "$tmp/v" --version v1.2.3 --oci-layout "$tmp/layout-x" --repository ghcr.io/example/x >/dev/null 2>&1
expect "publish: two targets are a usage error" "2" "$?"
bash "$scripts/publish.sh" --dir "$tmp/v" --version v1.2.3 >/dev/null 2>&1
expect "publish: no target is a usage error" "2" "$?"
mkdir -p "$tmp/noviews"
cp "$tmp/v/fragment.json" "$tmp/noviews/"
bash "$scripts/publish.sh" --dir "$tmp/noviews" --version v1.2.3 --oci-layout "$tmp/layout-x" >/dev/null 2>&1
expect "publish: a fragment without views fails" "1" "$?"

echo
if [ "$fails" -eq 0 ]; then echo "docs-fragment publish: all cases pass"; else echo "docs-fragment publish: $fails case(s) FAIL"; exit 1; fi
