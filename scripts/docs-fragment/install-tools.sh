#!/usr/bin/env bash
# Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
# All rights reserved. Copying, reproduction, distribution or any other
# use of this file, in whole or in part, without the prior written
# permission of the copyright holder is prohibited.

# Installs the two tools the documentation fragment needs and the runner does
# not bring, into a directory of the job's own:
#
#   install-tools.sh <bin dir>
#
# yajsv checks fragment.json against the schema, oras pushes the artefact.
# Pinned by version AND by the SHA-256 of the download: a release asset can be
# replaced, and a validator that silently changes changes the verdict. Into the
# given directory, never system-wide: the runner user has no sudo.
set -euo pipefail

YAJSV_VERSION=v1.4.0
YAJSV_SHA256=41095e099a04ec480bda537655c1d10999dbda51819d31735f0a0c55fffcccc0
ORAS_VERSION=1.2.3
ORAS_SHA256=b4efc97a91f471f323f193ea4b4d63d8ff443ca3aab514151a30751330852827

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <bin dir>" >&2
  exit 2
fi
bin=$1
mkdir -p "$bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { # <url> <file> <expected sha256>
  curl -sSfL --retry 3 -o "$2" "$1"
  actual=$(sha256sum "$2" | cut -d' ' -f1)
  if [ "$actual" != "$3" ]; then
    echo "::error title=docs-fragment::$1 has SHA-256 $actual, pinned is $3" >&2
    exit 1
  fi
}

fetch "https://github.com/neilpa/yajsv/releases/download/${YAJSV_VERSION}/yajsv.linux.amd64" \
  "$work/yajsv" "$YAJSV_SHA256"
install -m 0755 "$work/yajsv" "$bin/yajsv"

fetch "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
  "$work/oras.tar.gz" "$ORAS_SHA256"
tar -xzf "$work/oras.tar.gz" -C "$work" oras
install -m 0755 "$work/oras" "$bin/oras"

"$bin/yajsv" -v
"$bin/oras" version
