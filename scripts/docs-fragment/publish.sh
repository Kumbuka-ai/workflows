#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Pushes a checked fragment (fragment.json and plantuml/) as one OCI artefact:
#
#   publish.sh --dir <fragment dir> --version <release tag> --repository <registry/name> [--registry-config <file>]
#   publish.sh --dir <fragment dir> --version <release tag> --oci-layout <dir>
#
# The second form writes into a local OCI image layout instead of a registry.
# The self-test uses it, so the same push runs on every pull request without
# anything being written to a registry.
#
# Tags: the release tag as given and, when it reads vX.Y.Z..., also X.Y.Z, so
# the fragment is found under whichever form the module publishes its image.
# The artefact type is our own (ARTIFACT_TYPE below), never an image type, so a
# client that pulls images does not take a fragment for one.
set -euo pipefail

ARTIFACT_TYPE=application/vnd.kumbuka.docs-fragment.v1
FRAGMENT_MEDIA_TYPE=application/vnd.kumbuka.docs-fragment.fragment.v1+json
PLANTUML_MEDIA_TYPE=application/vnd.kumbuka.docs-fragment.plantuml.v1.tar+gzip

usage() {
  echo "usage: $0 --dir <fragment dir> --version <release tag> (--repository <registry/name> [--registry-config <file>] | --oci-layout <dir>) [--source-url <url>]" >&2
  exit 2
}

dir='' version='' repository='' layout='' registry_config='' source_url=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --dir)             dir=$2 ;;
    --version)         version=$2 ;;
    --repository)      repository=$2 ;;
    --oci-layout)      layout=$2 ;;
    --registry-config) registry_config=$2 ;;
    --source-url)      source_url=$2 ;;
    *)                 usage ;;
  esac
  shift 2
done
if [ -z "$dir" ] || [ -z "$version" ]; then usage; fi
# Exactly one target.
if [ -n "$repository" ] && [ -n "$layout" ]; then usage; fi
if [ -z "$repository" ] && [ -z "$layout" ]; then usage; fi

if [ ! -f "$dir/fragment.json" ]; then
  echo "::error title=docs-fragment::$dir/fragment.json is missing" >&2
  exit 1
fi
if ! compgen -G "$dir/plantuml/*.puml" >/dev/null; then
  echo "::error title=docs-fragment::$dir/plantuml/ holds no view" >&2
  exit 1
fi
fragment_version=$(jq -r '.version' "$dir/fragment.json")
if [ "$fragment_version" != "$version" ]; then
  echo "::error title=docs-fragment::fragment.json is for version '$fragment_version', not '$version'" >&2
  exit 1
fi
commit=$(jq -r '.commit' "$dir/fragment.json")

tags=("$version")
if [[ $version =~ ^v([0-9]+\.[0-9]+\.[0-9]+.*)$ ]]; then
  tags+=("${BASH_REMATCH[1]}")
fi

target_args=()
if [ -n "$layout" ]; then
  target_args+=(--oci-layout)
  base=$layout
else
  base=$repository
  if [ -n "$registry_config" ]; then target_args+=(--registry-config "$registry_config"); fi
fi

annotations=(--annotation "org.opencontainers.image.version=$version"
             --annotation "org.opencontainers.image.revision=$commit")
if [ -n "$source_url" ]; then
  # Links the package to the module's repository on GHCR.
  annotations+=(--annotation "org.opencontainers.image.source=$source_url")
fi

tag_list=$(IFS=,; echo "${tags[*]}")
echo "pushing $base:$tag_list"
# oras takes paths relative to the working directory.
(
  cd "$dir"
  oras push "${target_args[@]}" "$base:$tag_list" \
    --artifact-type "$ARTIFACT_TYPE" \
    "${annotations[@]}" \
    "fragment.json:$FRAGMENT_MEDIA_TYPE" \
    "plantuml:$PLANTUML_MEDIA_TYPE"
)

# Read back every tag: a push is only done when each tag resolves to an
# artefact of our type.
for tag in "${tags[@]}"; do
  type=$(oras manifest fetch "${target_args[@]}" "$base:$tag" | jq -r '.artifactType // .config.mediaType')
  if [ "$type" != "$ARTIFACT_TYPE" ]; then
    echo "::error title=docs-fragment::$base:$tag resolves to type '$type', not $ARTIFACT_TYPE" >&2
    exit 1
  fi
  echo "published $base:$tag ($type)"
done
