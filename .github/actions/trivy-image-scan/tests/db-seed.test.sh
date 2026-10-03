#!/usr/bin/env bash
# Executable test of db-seed.sh. Every case builds its own seed and cache under a
# temp dir and asserts three things: the flags printed, the annotation printed,
# and whether the database was copied. A fixed NOW keeps the ages exact.
#
#   bash .github/actions/trivy-image-scan/tests/db-seed.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sut="$here/../db-seed.sh"
NOW=1790000000                                  # 2026-09-21T14:13:20Z
fails=0

iso() { jq -nr --argjson t "$1" '$t | todate | sub("Z$"; ".123456789Z")'; }

mkseed() { # <dir> <db> <updated-epoch | raw:<json>>
  mkdir -p "$1/$2"
  echo payload > "$1/$2/$2.payload"
  case $3 in
    raw:*) printf '%s' "${3#raw:}" > "$1/$2/metadata.json" ;;
    *)     printf '{"Version":2,"UpdatedAt":"%s","DownloadedAt":"%s"}' "$(iso "$3")" "$(iso "$3")" > "$1/$2/metadata.json" ;;
  esac
}

check() { # <description> <condition-result 0|1>
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi
}

run() { # sets OUT ERR RC for seed $1 cache $2
  OUT=$(bash "$sut" "$1" "$2" 24 "$NOW" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. Both fresh (1 h old): both used, both skip flags, copied, no warning.
s=$T/c1/seed; c=$T/c1/cache
mkseed "$s" db $((NOW-3600)); mkseed "$s" java-db $((NOW-3600))
run "$s" "$c"
check "fresh: exit 0"                          "$([ $RC -eq 0 ] && echo 0 || echo 1)"
check "fresh: both skip flags"                 "$([ "$OUT" = "--skip-db-update --skip-java-db-update" ] && echo 0 || echo 1)"
check "fresh: db copied into the cache"        "$([ -f "$c/db/db.payload" ] && echo 0 || echo 1)"
check "fresh: java-db copied into the cache"   "$([ -f "$c/java-db/java-db.payload" ] && echo 0 || echo 1)"
check "fresh: no warning"                      "$(grep -q '::warning::' <<<"$ERR" && echo 1 || echo 0)"

# 2. Both stale (25 h old): neither used, a warning per database, nothing copied.
s=$T/c2/seed; c=$T/c2/cache
mkseed "$s" db $((NOW-25*3600)); mkseed "$s" java-db $((NOW-25*3600))
run "$s" "$c"
check "stale: exit 0"                          "$([ $RC -eq 0 ] && echo 0 || echo 1)"
check "stale: no skip flag"                    "$([ -z "$OUT" ] && echo 0 || echo 1)"
check "stale: nothing copied"                  "$([ ! -e "$c/db" ] && [ ! -e "$c/java-db" ] && echo 0 || echo 1)"
check "stale: warning names the db and its age" "$(grep -q '::warning::Trivy vulnerability database: the preloaded copy is 25h old' <<<"$ERR" && echo 0 || echo 1)"
check "stale: warning for the java db too"     "$(grep -q '::warning::Trivy Java database: the preloaded copy is 25h old' <<<"$ERR" && echo 0 || echo 1)"

# 3. Exactly at the limit counts as stale: the limit is "younger than".
s=$T/c3/seed; c=$T/c3/cache
mkseed "$s" db $((NOW-24*3600)); mkseed "$s" java-db $((NOW-24*3600+1))
run "$s" "$c"
check "limit: 24h00 not used, 23h59 used"      "$([ "$OUT" = "--skip-java-db-update" ] && echo 0 || echo 1)"

# 4. No seed at all (a hosted runner): no flag, a notice, no warning.
run "$T/c4/none" "$T/c4/cache"
check "absent: exit 0"                         "$([ $RC -eq 0 ] && echo 0 || echo 1)"
check "absent: no skip flag"                   "$([ -z "$OUT" ] && echo 0 || echo 1)"
check "absent: notice, not warning"            "$(grep -q '::notice::' <<<"$ERR" && ! grep -q '::warning::' <<<"$ERR" && echo 0 || echo 1)"

# 5. Unreadable metadata: never trusted, warned, not used.
s=$T/c5/seed; c=$T/c5/cache
mkseed "$s" db 'raw:{"Version":2}'; mkseed "$s" java-db 'raw:not json'
run "$s" "$c"
check "broken: no skip flag"                   "$([ -z "$OUT" ] && echo 0 || echo 1)"
check "broken: warned for both"                "$([ "$(grep -c '::warning::.*no readable UpdatedAt' <<<"$ERR")" -eq 2 ] && echo 0 || echo 1)"
check "broken: nothing copied"                 "$([ ! -e "$c/db" ] && [ ! -e "$c/java-db" ] && echo 0 || echo 1)"

echo
if [ "$fails" -eq 0 ]; then echo "db-seed: all cases pass"; else echo "db-seed: $fails case(s) FAIL"; exit 1; fi
