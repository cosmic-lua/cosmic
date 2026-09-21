#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: bootstrap-driver.sh PIN CACHE_DIR PROJECT_DIR RUNNER_PATH" >&2
  exit 2
fi
pin=$1
cache=$2
project=$3
runner=$4
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd -P)
case "$cache:$project:$runner" in /*:/*:/*) ;; *) exit 1;; esac
for destination in "$cache" "$project" "$runner"; do
  case "$destination/" in "$root/"*) exit 1;; esac
done

test -f "$pin"
test "$(wc -l < "$pin" | tr -d ' ')" = 3
commit=$(sed -n '1p' "$pin")
url=$(sed -n '2p' "$pin")
digest=$(sed -n '3p' "$pin")
case "$commit" in *[!0-9a-f]*|'') exit 1;; esac
test "${#commit}" -eq 40
case "$digest" in *[!0-9a-f]*|'') exit 1;; esac
test "${#digest}" -eq 64
test "$url" = "https://github.com/cosmic-lua/cosmic/releases/download/next-$commit/cosmic"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
verify() { test "$(sha256_file "$1")" = "$digest"; }

mkdir -p "$cache" "$(dirname "$runner")" "$project"
cache=$(CDPATH= cd -- "$cache" && pwd -P)
project=$(CDPATH= cd -- "$project" && pwd -P)
runner_parent=$(CDPATH= cd -- "$(dirname "$runner")" && pwd -P)
runner="$runner_parent/$(basename "$runner")"
inside_candidate() {
  case "$1/" in "$root/"*) return 0;; *) return 1;; esac
}
! inside_candidate "$cache"
! inside_candidate "$project"
! inside_candidate "$runner"
test ! -e "$project/driver.tl" && test ! -L "$project/driver.tl"
test ! -e "$runner" && test ! -L "$runner"
cached="$cache/cosmic-$digest"
if [ -f "$cached" ] && ! verify "$cached"; then rm -f "$cached"; fi
if [ ! -f "$cached" ]; then
  partial="$cache/.cosmic-$digest.$$"
  trap 'rm -f "$partial"' EXIT
  trap 'rm -f "$partial"; exit 1' HUP INT TERM
  curl --fail --location --proto '=https' --tlsv1.2 --output "$partial" "$url"
  verify "$partial"
  chmod 755 "$partial"
  mv "$partial" "$cached"
  trap - EXIT HUP INT TERM
fi
verify "$cached"
cp "$cached" "$runner"
verify "$runner"
chmod 755 "$runner"
for template in "$(dirname "$0")"/driver/*.tl.in; do
  name=$(basename "$template" .in)
  test ! -e "$project/$name" && test ! -L "$project/$name"
  cp "$template" "$project/$name"
done
