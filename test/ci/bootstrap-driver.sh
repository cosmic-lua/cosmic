#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
  echo "usage: bootstrap-driver.sh PIN SOURCE_ROOT CACHE_DIR PROJECT_DIR RUNNER_PATH" >&2
  exit 2
fi
pin=$1
root=$2
cache=$3
project=$4
runner=$5
case "$root" in /*) ;; *) exit 1;; esac
root=$(CDPATH= cd -- "$root" && pwd -P)
test -d "$root/test/ci/driver/cosmic_ci"
test -d "$root/test/ci/driver/testdata"
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
if [ -e "$project/cosmic_ci" ] || [ -L "$project/cosmic_ci" ] ||
   [ -e "$project/testdata" ] || [ -L "$project/testdata" ] ||
   [ -e "$runner" ] || [ -L "$runner" ]; then
  exit 1
fi
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
source_root=$root/test/ci/driver
partial_project="$project/.cosmic-ci-copy.$$"
if [ -e "$partial_project" ] || [ -L "$partial_project" ]; then exit 1; fi
trap 'rm -rf "$partial_project" "$project/cosmic_ci" "$project/testdata"' EXIT HUP INT TERM
mkdir "$partial_project"
cp -R "$source_root/cosmic_ci" "$source_root/testdata" "$partial_project/"
for tree in cosmic_ci testdata; do
  test "$(find "$source_root/$tree" -type f | wc -l | tr -d ' ')" = \
       "$(find "$partial_project/$tree" -type f | wc -l | tr -d ' ')"
  (cd "$source_root" && find "$tree" -type f -print) | while IFS= read -r file; do
    cmp "$source_root/$file" "$partial_project/$file"
  done
  mv "$partial_project/$tree" "$project/$tree"
done
rmdir "$partial_project"
trap - EXIT HUP INT TERM
