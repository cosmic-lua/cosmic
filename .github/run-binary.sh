#!/bin/bash
# Runs a downloaded cosmic binary on its own real target: the help
# surface, then a trivial one-file script with no project of its own,
# proving cross-compilation produced something that actually boots and
# runs on this hardware. It never builds anything -- the native-build
# lanes prove the whole tree, including o/types/'s generated
# declarations, compiles and every test passes on that real platform.
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
cat > "$project/smoke.tl" <<'EOF'
local function hi(_argv: {integer:string}): integer
  print("hello from the database")
  return 0
end
return hi
EOF
cd "$project"

got=$("$cosmic" smoke.tl)
test "$got" = "hello from the database"

# Again, with the database already built: the second run must not
# rebuild what has not changed, and must still print the same line.
got=$("$cosmic" smoke.tl)
test "$got" = "hello from the database"

echo "ci: PASS ($lane)"
