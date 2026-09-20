#!/bin/sh
set -eu

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
  echo "usage: $0 DIAGNOSTICS-DIRECTORY LABEL [COSMIC]" >&2
  exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
checkout=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
diagnostics=$1
label=$2
cosmic=${3-}

canonical_directory_path() {
  path=$1
  suffix=
  while [ ! -e "$path" ]; do
    component=${path##*/}
    [ -n "$component" ] || return 1
    suffix="/$component$suffix"
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  ancestor=$(CDPATH= cd -- "$path" && pwd -P) || return 1
  if [ "$ancestor" = / ]; then
    printf '%s\n' "$ancestor${suffix#/}"
  else
    printf '%s\n' "$ancestor$suffix"
  fi
}

case "$diagnostics" in
  /*) ;;
  *)
    echo "diagnostics directory must be an absolute path: $diagnostics" >&2
    exit 2
    ;;
esac
case "/${diagnostics#/}/" in
  *//*|*/./*|*/../*)
    echo "diagnostics directory must be a normalized path: $diagnostics" >&2
    exit 2
    ;;
esac
diagnostics=$(canonical_directory_path "$diagnostics") || {
  echo "diagnostics path cannot be resolved: $diagnostics" >&2
  exit 2
}
case "$diagnostics/" in
  "$checkout/"*)
    echo "diagnostics directory must be outside the checkout: $diagnostics" >&2
    exit 2
    ;;
esac
mkdir -p "$diagnostics"
diagnostics=$(CDPATH= cd -- "$diagnostics" && pwd -P)
case "$diagnostics/" in
  "$checkout/"*)
    echo "diagnostics directory must be outside the checkout: $diagnostics" >&2
    exit 2
    ;;
esac
case "$label" in
  ""|*/*|.|..)
    echo "snapshot label must be one nonempty path component" >&2
    exit 2
    ;;
esac

database="$checkout/o/build.db"
if [ -z "$cosmic" ]; then cosmic=$checkout/o/bin/cosmic; fi
case $cosmic in /*) ;; *) cosmic=$PWD/$cosmic ;; esac
source_helper="$checkout/test/portable/work_db_integrity.tl.in"
snapshot="$diagnostics/$label"

if [ ! -f "$database" ]; then
  echo "working database does not exist: $database" >&2
  exit 1
fi
if [ ! -x "$cosmic" ]; then
  echo "Cosmic executable does not exist: $cosmic" >&2
  exit 1
fi
if ! mkdir "$snapshot"; then
  echo "snapshot already exists or cannot be created: $snapshot" >&2
  exit 1
fi

cp "$database" "$snapshot/build.db"
if [ -e "$database-journal" ]; then
  cp "$database-journal" "$snapshot/build.db-journal"
fi

hash_value() {
  if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum "$1") || return
  else value=$(shasum -a 256 "$1") || return; fi
  printf '%s\n' "${value%% *}"
}

# Record the untouched bytes before SQLite opens any copy. Opening a database
# with a journal may recover it, so the integrity probe below gets another,
# disposable copy of both files.
wc -c < "$snapshot/build.db" > "$snapshot/build.db.bytes"
{
  database_hash=$(hash_value "$snapshot/build.db") || exit
  printf '%s  build.db\n' "$database_hash"
  if [ -e "$snapshot/build.db-journal" ]; then
    journal_hash=$(hash_value "$snapshot/build.db-journal") || exit
    printf '%s  build.db-journal\n' "$journal_hash"
  fi
} > "$snapshot/hashes.sha256"
if [ -e "$snapshot/build.db-journal" ]; then
  wc -c < "$snapshot/build.db-journal" > \
    "$snapshot/build.db-journal.bytes"
fi

inspection=$(mktemp -d "$diagnostics/.work-db-inspection.XXXXXX")
cleanup() {
  rm -rf "$inspection"
}
trap cleanup EXIT HUP INT TERM
cp "$snapshot/build.db" "$inspection/build.db"
if [ -e "$snapshot/build.db-journal" ]; then
  cp "$snapshot/build.db-journal" "$inspection/build.db-journal"
fi
cp "$source_helper" "$inspection/work_db_integrity.tl"

set +e
(
  cd "$inspection"
  "$cosmic" work_db_integrity.tl build.db
) > "$snapshot/integrity.out" 2> "$snapshot/integrity.err"
status=$?
set -e
cat "$snapshot/integrity.out"
cat "$snapshot/integrity.err" >&2
exit "$status"
