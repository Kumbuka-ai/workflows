#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Exports the views of a fragment's workspace as C4-PlantUML, one file per view:
#
#   export-plantuml.sh --fragment <fragment.json> --out <plantuml dir>
#
# Reads nothing but fragment.json, so the views can never say more than the
# workspace does. Container views are exported, which is every view the
# generator writes; a view of another kind is reported and not exported. A
# fragment without any exportable view is an error: an empty plantuml/ would
# read like a module without views rather than like a broken export.
#
# The C4 macros come from PlantUML's standard library (`!include <C4/...>`), so
# rendering needs no network.
set -euo pipefail

usage() {
  echo "usage: $0 --fragment <fragment.json> --out <plantuml dir>" >&2
  exit 2
}

fragment='' out=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --fragment) fragment=$2 ;;
    --out)      out=$2 ;;
    *)          usage ;;
  esac
  shift 2
done
if [ -z "$fragment" ] || [ -z "$out" ]; then usage; fi

other=$(jq -r '.workspace.views // {} | to_entries[]
               | select(.key != "containerViews" and .key != "configuration" and (.value | type) == "array" and (.value | length) > 0)
               | .key' "$fragment")
if [ -n "$other" ]; then
  echo "::warning title=docs-fragment::views not exported (only container views are): $(tr '\n' ' ' <<<"$other")"
fi

keys=$(jq -r '.workspace.views.containerViews // [] | .[].key' "$fragment")
if [ -z "$keys" ]; then
  echo "::error title=docs-fragment::$fragment has no container view; nothing to export" >&2
  exit 1
fi

mkdir -p "$out"
written=0
while IFS= read -r key; do
  # The key becomes a file name: nothing that could leave the directory.
  if ! [[ $key =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "::error title=docs-fragment::view key '$key' is not usable as a file name" >&2
    exit 1
  fi
  jq -r --arg key "$key" '
    def q: tostring | gsub("[\"\n\r]"; " ");
    def alias: "e" + (tostring | gsub("[^A-Za-z0-9]"; "_"));
    .workspace as $ws
    | ($ws.views.containerViews[] | select(.key == $key)) as $view
    | ($ws.model.softwareSystems[] | select(.id == $view.softwareSystemId)) as $system
    | ([$view.elements[]?.id]) as $ids
    | "@startuml " + $key,
      "!include <C4/C4_Container>",
      "",
      "title " + (($view.title // $key) | q),
      "",
      "System_Boundary(" + ($system.id | alias) + ", \"" + ($system.name | q) + "\") {",
      ( $system.containers[]? | select(.id as $id | $ids | index($id))
        | "  Container(" + (.id | alias) + ", \"" + (.name | q) + "\", \""
          + ((.technology // "") | q) + "\", \"" + ((.description // "") | q) + "\")" ),
      "}",
      "@enduml"
  ' "$fragment" > "$out/$key.puml"
  written=$((written + 1))
done <<<"$keys"

echo "plantuml: $written view(s) written to $out"
