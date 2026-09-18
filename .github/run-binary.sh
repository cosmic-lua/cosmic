#!/bin/bash
# Runs a downloaded cosmic binary: the help surface, then a project of
# one file built and run from its own database.
#
#   run-binary.sh <download dir> <target> <lane name>
set -euo pipefail

downloaded=$1
target=$2
lane=$3

PY=$(command -v python3 || command -v python)
for zip in $(find "$downloaded" -type f -name '*.zip'); do
  "$PY" -m zipfile -e "$zip" "$downloaded/"
done

cosmic=$(find "$downloaded" -type f -name "cosmic-$target" | head -1)
if [ -z "$cosmic" ]; then
  echo "no cosmic-$target in $downloaded" >&2
  find "$downloaded" >&2
  exit 1
fi
cosmic=$(cd "$(dirname "$cosmic")" && pwd)/$(basename "$cosmic")
chmod +x "$cosmic"

"$cosmic" help

project=${RUNNER_TEMP:-/tmp}/cosmic-project
rm -rf "$project"
mkdir -p "$project"
cp hello.tl "$project/"
cd "$project"

got=$("$cosmic" hello.tl)
test "$got" = "hello from the database"

# Again, with the database already built: the second run must not
# rebuild what has not changed, and must still print the same line.
got=$("$cosmic" hello.tl)
test "$got" = "hello from the database"

echo "ci: PASS ($lane)"
