#!/bin/sh
# Run after bin/zig build boot -Dportable-probe=true. No network or host
# sqlite command: the projection helper uses the same vendored SQLite.
set -eu
mkdir -p o/portable
bin/zig cc -O2 -DSQLITE_ENABLE_FTS5 -I o/vendor/sqlite \
  experiments/portable/pack.c o/vendor/sqlite/sqlite3.c -lm -o o/portable/project
cp o/cosmic.db o/portable/shared.db
o/portable/project o/portable/shared.db
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1";
  else shasum -a 256 "$1"; fi | cut -d ' ' -f1
}
# A fixed-size shell header followed by block-aligned raw cores and one DB.
block=1
: > o/portable/targets
for target in x86_64-linux-musl aarch64-linux-musl aarch64-macos; do
  case $target in
    x86_64-linux-musl) host=Linux:x86_64;;
    aarch64-linux-musl) host=Linux:aarch64;;
    aarch64-macos) host=Darwin:arm64;;
  esac
  core=o/core/$target/cosmic-core
  length=$(wc -c < "$core" | tr -d ' ')
  blocks=$(( (length + 16383) / 16384 ))
  printf '  %s) block=%s; blocks=%s; length=%s; digest=%s;;\n' \
    "$host" "$block" "$blocks" "$length" "$(sha "$core")" >> o/portable/targets
  block=$((block + blocks))
done
awk 'FILENAME == ARGV[1] { arms = arms $0 "\n"; next }
     $0 == "@TARGETS@" { printf "%s", arms; next } { print }' \
  o/portable/targets experiments/portable/launcher.sh > o/portable/cosmic
header=$(wc -c < o/portable/cosmic)
[ "$header" -lt 16384 ]
dd if=/dev/zero bs=1 count=$((16384 - header)) 2>/dev/null >> o/portable/cosmic
for target in x86_64-linux-musl aarch64-linux-musl aarch64-macos; do
  dd if="o/core/$target/cosmic-core" bs=16384 conv=sync 2>/dev/null >> o/portable/cosmic
done
cat o/portable/shared.db >> o/portable/cosmic
# The existing locator expects its 17-byte marker, then an eight-byte
# big-endian absolute offset. Offsets fit in 32 bits here.
printf 'Start-Of-Cosmic--\000\000\000\000' >> o/portable/cosmic
offset=$((block * 16384))
for shift in 24 16 8 0; do
  octal=$(printf '%03o' "$(( (offset >> shift) & 255 ))")
  printf "\\$octal" >> o/portable/cosmic
done
chmod 755 o/portable/cosmic
printf 'portable: %s bytes, database at %s; sha256 %s\n' \
  "$(wc -c < o/portable/cosmic)" "$offset" "$(sha o/portable/cosmic)"
