#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Executable test of generate.sh, the schema and export-plantuml.sh, on the
# fixture next to this file. Every expected value is written here, from
# docs/docs-fragment.md, not taken from the scripts. Needs git, jq and yajsv on
# PATH (scripts/docs-fragment/install-tools.sh).
#
#   bash scripts/docs-fragment/tests/generate.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scripts=$(cd "$here/.." && pwd)
schema=$(cd "$here/../../../docs" && pwd)/docs-fragment.schema.json
fails=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
expect() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
validates() { yajsv -q -s "$schema" "$1" >/dev/null 2>&1; }

if ! command -v yajsv >/dev/null; then
  echo "FAIL  yajsv is not on PATH; run scripts/docs-fragment/install-tools.sh first"
  exit 1
fi
if [ ! -f "$schema" ]; then
  echo "FAIL  no schema at $schema"
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The fixture as a checkout with one commit, as a caller's job has it.
src="$tmp/src"
cp -R "$here/fixture" "$src"
git -C "$src" init -q
git -C "$src" add .
git -C "$src" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
  commit -q -m fixture
fixture_commit=$(git -C "$src" rev-parse HEAD)
# Build output left in the checkout is not tracked and must not count.
mkdir -p "$src/target"
cp "$src/pom.xml" "$src/target/pom.xml"

gen() { # <out dir>
  bash "$scripts/generate.sh" --module fixture-module --version v1.2.3 --source "$src" --out "$1"
}

# --- production and schema -------------------------------------------------

if gen "$tmp/a" >"$tmp/a.log" 2>&1; then pass "generate: the fixture produces a fragment"
else fail "generate: the fixture produces a fragment"; cat "$tmp/a.log"; fi
f="$tmp/a/fragment.json"

if validates "$f"; then pass "schema: the fixture's fragment.json passes"
else fail "schema: the fixture's fragment.json passes"; yajsv -s "$schema" "$f"; fi

c='.workspace.model.softwareSystems[0].containers[0]'
expect "fragment: schema_version"            "1.0"            "$(jq -r '.schema_version' "$f")"
expect "fragment: module"                    "fixture-module" "$(jq -r '.module' "$f")"
expect "fragment: version is the release tag" "v1.2.3"        "$(jq -r '.version' "$f")"
expect "fragment: commit of the checkout"    "$fixture_commit" "$(jq -r '.commit' "$f")"
expect "fragment: produced_at in UTC"        "true" \
  "$(jq -r '.produced_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$f")"
expect "workspace: one software system"      "1"              "$(jq -r '.workspace.model.softwareSystems | length' "$f")"
expect "workspace: one container, the module" "fixture-module" "$(jq -r "$c.name" "$f")"
expect "container: version"                  "v1.2.3"         "$(jq -r "$c.properties.version" "$f")"
expect "container: commit"                   "$fixture_commit" "$(jq -r "$c.properties.commit" "$f")"
expect "container: tracked manifests, sorted" "Dockerfile,app/pom.xml,pom.xml" \
  "$(jq -r "$c.properties[\"build.manifests\"]" "$f")"
expect "container: technology from the root build" "Maven"    "$(jq -r "$c.technology" "$f")"
expect "container: no components assumed"    "null"           "$(jq -c "$c.components" "$f")"
expect "workspace: one container view"       "fixture-module-container" \
  "$(jq -r '.workspace.views.containerViews[0].key' "$f")"

# --- the schema rejects what the contract forbids --------------------------

for field in schema_version module version commit produced_at workspace; do
  jq "del(.$field)" "$f" >"$tmp/missing-$field.json"
  if validates "$tmp/missing-$field.json"; then fail "schema: a fragment without $field must fail"
  else pass "schema: a fragment without $field fails"; fi
done

rejects() { # <description> <jq filter>
  jq "$2" "$f" >"$tmp/bad.json"
  if validates "$tmp/bad.json"; then fail "schema: $1 must fail"; else pass "schema: $1 fails"; fi
}
rejects "a short commit"                    '.commit = "abc1234"'
rejects "a module name with spaces"         '.module = "Not A Module"'
rejects "a version that is no OCI tag"      '.version = "v1.2.3+build.1"'
rejects "a produced_at with an offset"      '.produced_at = "2026-11-14T21:20:21+01:00"'
rejects "schema major 2"                    '.schema_version = "2.0"'
rejects "a workspace without a model"       'del(.workspace.model)'
rejects "a software system without a container" '.workspace.model.softwareSystems[0].containers = []'
rejects "a container without its commit"    "del($c.properties.commit)"

# A reader skips fields it does not know; the schema lets them through, so a
# later optional prose part under 1.x does not break anyone.
jq '.schema_version = "1.1" | .prose = {"notes": ["later"]}' "$f" >"$tmp/later.json"
if validates "$tmp/later.json"; then pass "schema: an unknown field under 1.1 passes"
else fail "schema: an unknown field under 1.1 passes"; fi

# --- reproducibility --------------------------------------------------------

# A second later, so produced_at differs as it does between two real runs.
sleep 1
if gen "$tmp/b" >"$tmp/b.log" 2>&1; then pass "generate: a second production"
else fail "generate: a second production"; cat "$tmp/b.log"; fi
g="$tmp/b/fragment.json"
expect "fragment: produced_at is one line"   "1" "$(grep -c '"produced_at":' "$f")"
grep -v '"produced_at":' "$f" >"$tmp/a.stripped"
grep -v '"produced_at":' "$g" >"$tmp/b.stripped"
if cmp -s "$tmp/a.stripped" "$tmp/b.stripped"; then
  pass "reproducible: two productions are byte-identical except produced_at"
else
  fail "reproducible: two productions are byte-identical except produced_at"
  diff "$tmp/a.stripped" "$tmp/b.stripped"
fi

# --- C4-PlantUML -------------------------------------------------------------

if bash "$scripts/export-plantuml.sh" --fragment "$f" --out "$tmp/a/plantuml" >"$tmp/ea.log" 2>&1; then
  pass "export: the fragment's views are exported"
else fail "export: the fragment's views are exported"; cat "$tmp/ea.log"; fi
puml="$tmp/a/plantuml/fixture-module-container.puml"
expect "export: one file per view"           "fixture-module-container.puml" "$(find "$tmp/a/plantuml" -type f -printf '%f\n' 2>/dev/null)"
expect "export: starts the diagram"          "@startuml fixture-module-container" "$(head -n 1 "$puml" 2>/dev/null)"
expect "export: ends the diagram"            "@enduml" "$(tail -n 1 "$puml" 2>/dev/null)"
if grep -qxF '!include <C4/C4_Container>' "$puml" 2>/dev/null; then pass "export: C4 container macros from the standard library"
else fail "export: C4 container macros from the standard library"; fi
if grep -qF "Container(e2, \"fixture-module\", \"Maven\", \"Module fixture-module at v1.2.3, commit $fixture_commit\")" "$puml" 2>/dev/null; then
  pass "export: the module is a container with technology and commit"
else fail "export: the module is a container with technology and commit"; cat "$puml"; fi

bash "$scripts/export-plantuml.sh" --fragment "$g" --out "$tmp/b/plantuml" >/dev/null 2>&1
if diff -r "$tmp/a/plantuml" "$tmp/b/plantuml" >/dev/null 2>&1; then
  pass "reproducible: the views of two productions are byte-identical"
else fail "reproducible: the views of two productions are byte-identical"; fi

jq '.workspace.views = {}' "$f" >"$tmp/noviews.json"
if bash "$scripts/export-plantuml.sh" --fragment "$tmp/noviews.json" --out "$tmp/noviews" >/dev/null 2>&1; then
  fail "export: a fragment without a view must fail"
else pass "export: a fragment without a view fails"; fi

# --- refusals ------------------------------------------------------------------

bash "$scripts/generate.sh" --module fixture-module --version v1.2.3 >/dev/null 2>&1
expect "generate: missing arguments are a usage error" "2" "$?"
mkdir -p "$tmp/not-a-checkout"
# The ceiling keeps git from finding a repository above the temp directory.
GIT_CEILING_DIRECTORIES=$tmp bash "$scripts/generate.sh" --module fixture-module --version v1.2.3 \
  --source "$tmp/not-a-checkout" --out "$tmp/x" >/dev/null 2>&1
expect "generate: a tree without a commit fails" "1" "$?"

echo
if [ "$fails" -eq 0 ]; then echo "docs-fragment generate: all cases pass"; else echo "docs-fragment generate: $fails case(s) FAIL"; exit 1; fi
