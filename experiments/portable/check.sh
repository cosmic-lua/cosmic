#!/bin/sh
# Run from any cwd. Only the downloaded artifact and an explicit private cache
# are required; no native cosmic installation or repository database is used.
set -eu
artifact=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/cache" "$work/program space"
cp "$artifact" "$work/program space/cosmic"
artifact=$work/program\ space/cosmic
chmod 755 "$artifact"
export COSMIC_PORTABLE_CACHE=$work/cache
cd "$work"
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1";
  else shasum -a 256 "$1"; fi | cut -d ' ' -f1
}
before=$(sha "$artifact")
# First launches race to publish the SAME core, then each reads the same DB.
"$artifact" help > a & a=$!
"$artifact" help > b & b=$!
wait "$a"
wait "$b"
cmp a b
[ "$(find "$work/cache" -type f | wc -l | tr -d ' ')" = 1 ]
core=$(find "$work/cache" -type f)
core_hash=$(sha "$core")
printf 'native core: %s\n' "$core"
file "$core"
if [ "$(uname -s)" = Darwin ]; then
  codesign --verify --strict --verbose=2 "$core"
fi
# Real module loading and FTS/doc reads from the ONE shared database.
"$artifact" docs Fs.read > docs
[ -s docs ]
# A warm start must work without write permission to the cache.
chmod 500 "$work/cache"
"$artifact" help > warm
cmp a warm
[ "$(sha "$core")" = "$core_hash" ]
[ "$(sha "$artifact")" = "$before" ]
chmod 700 "$work/cache"
# A different artifact pathname still reuses that core.
cp "$artifact" "$work/renamed"
"$work/renamed" help > renamed.out
cmp a renamed.out
[ "$(find "$work/cache" -type f | wc -l | tr -d ' ')" = 1 ]
# Compile and run actual user code, preserving arguments, stdin, and exit code.
cat > smoke.tl <<'TEAL'
local Fs = require("cosmic.fs")
return function(argv: {integer:string}): integer
  assert(argv[1] == "a b" and argv[2] == "" and argv[3] == "--literal")
  local input, trouble = Fs.read("/dev/stdin")
  assert(input == "input stays intact\n", trouble)
  print("user code ran")
  return 23
end
TEAL
set +e
printf 'input stays intact\n' | "$artifact" smoke.tl 'a b' '' --literal > script.out
status=$?
set -e
[ "$status" = 23 ]
grep -q '^user code ran$' script.out
printf 'portable: PASS (cold race, shared DB/docs, warm read-only cache, rename, unchanged artifact, user code/argv/stdin/exit)\n'
