#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Produces fragment.json, the documentation fragment of a module, from a
# checked-out tree. The contract is docs/docs-fragment.md.
#
#   generate.sh --module <name> --version <release tag> --source <checkout> --out <dir>
#
# The workspace holds only what the tree gives without an assumption: name,
# version, commit and the build structure (the build manifests git tracks). No
# components: which parts of a module are C4 components is not something a file
# list says, and a guessed component is worse than a missing one.
#
# Reproducible: two productions from the same commit differ only in produced_at.
# Keys are sorted, element ids are fixed, the manifest list is sorted bytewise,
# and only tracked files count, so a build directory left in the checkout
# changes nothing.
set -euo pipefail

usage() {
  echo "usage: $0 --module <name> --version <release tag> --source <checkout> --out <dir>" >&2
  exit 2
}

module='' version='' source='' out=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --module)  module=$2 ;;
    --version) version=$2 ;;
    --source)  source=$2 ;;
    --out)     out=$2 ;;
    *)         usage ;;
  esac
  shift 2
done
if [ -z "$module" ] || [ -z "$version" ] || [ -z "$source" ] || [ -z "$out" ]; then usage; fi

if ! commit=$(git -C "$source" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
  echo "::error title=docs-fragment::$source is not a git checkout with a commit; the fragment needs the commit it describes" >&2
  exit 1
fi

tracked=$(git -C "$source" -c core.quotePath=false ls-files)
manifests=$(printf '%s\n' "$tracked" \
  | grep -E '(^|/)(pom\.xml|package\.json|go\.mod|Cargo\.toml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|pyproject\.toml|Dockerfile|Containerfile)$' \
  | LC_ALL=C sort || true)

# The build systems at the root of the tree, in a fixed order. A manifest further
# down belongs to the build structure, not to the technology of the module.
systems=()
has_root() { printf '%s\n' "$manifests" | grep -qxE "$1"; }
if has_root 'pom\.xml'; then systems+=("Maven"); fi
if has_root '(build|settings)\.gradle(\.kts)?'; then systems+=("Gradle"); fi
if has_root 'package\.json'; then systems+=("Node.js"); fi
if has_root 'go\.mod'; then systems+=("Go"); fi
if has_root 'Cargo\.toml'; then systems+=("Rust"); fi
if has_root 'pyproject\.toml'; then systems+=("Python"); fi

manifests_json=$(printf '%s' "$manifests" | jq -R -s 'split("\n") | map(select(length > 0))')
if [ ${#systems[@]} -gt 0 ]; then
  systems_json=$(printf '%s\n' "${systems[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')
else
  systems_json='[]'
fi

produced_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$out"
jq -n -S --indent 2 \
  --arg module "$module" \
  --arg version "$version" \
  --arg commit "$commit" \
  --arg produced_at "$produced_at" \
  --argjson manifests "$manifests_json" \
  --argjson systems "$systems_json" '
  ($systems | join(", ")) as $technology
  | {
      schema_version: "1.0",
      module: $module,
      version: $version,
      commit: $commit,
      produced_at: $produced_at,
      workspace: {
        name: $module,
        description: ("Documentation fragment of the module " + $module + " at " + $version + ", produced from its build structure."),
        model: {
          softwareSystems: [{
            id: "1",
            name: $module,
            description: "Carrier only. The module is the container below; an aggregator places it under the container of the frame that names this module.",
            tags: "Element,Software System",
            containers: [(
              {
                id: "2",
                name: $module,
                description: ("Module " + $module + " at " + $version + ", commit " + $commit),
                tags: "Element,Container,Module",
                properties: {
                  module: $module,
                  version: $version,
                  commit: $commit,
                  "build.manifests": ($manifests | join(",")),
                  "build.systems": ($systems | join(","))
                }
              }
              + (if $technology == "" then {} else {technology: $technology} end)
            )]
          }]
        },
        views: {
          containerViews: [{
            key: ($module + "-container"),
            softwareSystemId: "1",
            title: ("Module " + $module + " " + $version),
            elements: [{id: "2"}]
          }],
          configuration: {}
        }
      }
    }' > "$out/fragment.json"

echo "fragment: module=$module version=$version commit=$commit manifests=$(jq length <<<"$manifests_json") technology=${systems[*]:-none}"
