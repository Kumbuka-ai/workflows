#!/usr/bin/env bash
# Decide, per Trivy database, whether the copy preloaded into the runner image
# may be used instead of a download — and never let a stale one be used silently.
#
#   db-seed.sh SEED_DIR CACHE_DIR MAX_AGE_HOURS [NOW_EPOCH]
#
# SEED_DIR   where the runner image keeps the databases its nightly build
#            downloaded (layout of Trivy's own cache dir: db/, java-db/).
# CACHE_DIR  the cache dir this scan mounts into the Trivy container.
# NOW_EPOCH  for the test only; defaults to the clock.
#
# Prints the Trivy flags to add on stdout (possibly nothing) and explains each
# decision on stderr. A database is used from the seed ONLY when its metadata is
# readable and its `UpdatedAt` — the time the database content was built, not the
# time it was copied anywhere — is younger than MAX_AGE_HOURS. It is then copied
# into CACHE_DIR and Trivy is told not to update it.
#
# EVERY OTHER CASE DOWNLOADS, AS BEFORE THIS SCRIPT EXISTED, and none of them is
# silent:
#   - no seed at all (every hosted runner, or a runner image built before the
#     seed existed): a notice — nothing is wrong, the scan downloads.
#   - a seed that is older than the limit, or whose metadata cannot be read: a
#     warning annotation naming the database and its age, then the download.
#     A scan against a stale database must never happen quietly, and a nightly
#     build that stopped refreshing the seed must be visible in every job.
# Nothing here changes which scanners run, which severities block, or how a
# finding is judged; it only decides where the database comes from.
set -euo pipefail

seed=${1:?seed dir}
cache=${2:?cache dir}
max_hours=${3:?max age in hours}
now=${4:-$(date +%s)}

flags=()
mkdir -p "$cache"

for db in db java-db; do
  case $db in
    db)      flag=--skip-db-update;      label="vulnerability database" ;;
    java-db) flag=--skip-java-db-update; label="Java database" ;;
  esac
  meta="$seed/$db/metadata.json"

  if [ ! -d "$seed/$db" ]; then
    echo "::notice::Trivy $label: no preloaded copy at $seed/$db — downloading it, as without a seed" >&2
    continue
  fi

  # `UpdatedAt` carries nanoseconds; fromdateiso8601 accepts whole seconds only.
  updated=$(jq -r '.UpdatedAt // empty | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' "$meta" 2>/dev/null || true)
  if ! [[ "$updated" =~ ^[0-9]+$ ]]; then
    echo "::warning::Trivy $label: the preloaded copy at $seed/$db has no readable UpdatedAt in $meta — not used, downloading instead" >&2
    continue
  fi

  age=$(( now - updated ))
  hours=$(( age / 3600 ))
  if [ "$age" -ge $(( max_hours * 3600 )) ]; then
    echo "::warning::Trivy $label: the preloaded copy is ${hours}h old (UpdatedAt $(jq -r .UpdatedAt "$meta")), over the ${max_hours}h limit — not used, downloading a fresh one. The runner image's nightly build has not refreshed it." >&2
    continue
  fi

  rm -rf "${cache:?}/$db"
  cp -a "$seed/$db" "$cache/$db"
  echo "Trivy $label: preloaded copy used, ${hours}h old (UpdatedAt $(jq -r .UpdatedAt "$meta")), limit ${max_hours}h" >&2
  flags+=("$flag")
done

echo "${flags[*]:-}"
