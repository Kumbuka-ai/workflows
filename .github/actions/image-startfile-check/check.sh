#!/usr/bin/env bash
# An image without its application must never be green.
#
#   check.sh IMAGE PATH_REGEX
#
# IMAGE       the image as the local daemon knows it (tag or id)
# PATH_REGEX  extended regex for the start file's path inside the image,
#             without the leading slash, anchored on both ends by this script
#             (e.g. 'app/quarkus-run\.jar')
#
# Passes only when at least one regular file matching PATH_REGEX exists in the
# image AND is not empty. Prints the image id, so the log ties this check to the
# build, the scan and the push of the same image.
#
# WHY NOT `docker run ... test -f`: that needs a shell and an entrypoint override
# in the image, and a distroless or shell-less image would turn the check into a
# failure about the image's tooling rather than about its content. The image is
# instead created (never started) and its filesystem listed with `docker export`,
# which needs nothing from the image.
#
# WHAT IT GUARDS AGAINST: a build that silently copies nothing — a .dockerignore
# that excludes the build output, a named context pointing at an empty or wrong
# directory, a COPY whose glob matches nothing in a stage that tolerates it. The
# image still builds, starts a JVM or node and dies, or worse, passes a scan that
# looked at a base image only.
set -euo pipefail

image=${1:?image}
regex=${2:?path regex}

id=$(docker image inspect "$image" --format '{{.Id}}')
echo "checked image: $image $id"

cid=$(docker create "$image" true)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

# Names only (`tar -tf`), because the verbose column layout differs between GNU
# tar and bsdtar; type and size are then read from a copy of each candidate, so
# a directory or an empty file of that name does not pass.
names=$(docker export "$cid" | tar -tf - | sed -e 's#^\./##' -e 's#^/##' | grep -E "^(${regex})\$" || true)

if [ -z "$names" ]; then
  echo "::error::start file check RED: no file matching /${regex} in ${image} (${id}) — the image carries no application"
  exit 1
fi

tmp=$(mktemp -d)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
good=""
while IFS= read -r n; do
  out="$tmp/$(printf '%s' "$n" | tr '/' '_')"
  docker cp -L "$cid:/$n" "$out" >/dev/null 2>&1 || continue
  if [ -f "$out" ] && [ -s "$out" ]; then
    good="${good}  /${n} ($(wc -c < "$out" | tr -d ' ') bytes)"$'\n'
  fi
done <<< "$names"

if [ -z "$good" ]; then
  echo "::error::start file check RED: /${regex} exists in ${image} (${id}) but not as a non-empty regular file"
  printf '%s\n' "$names"
  exit 1
fi

echo "start file check GREEN:"
printf '%s' "$good"
