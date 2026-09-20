#!/bin/sh
# Build one identical launcher fixture containing a native TEST payload for
# every generated target. The fixture verifies only the step-4 shell contract.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=${1:?usage: launcher_build.sh OUTPUT_DIRECTORY}
mkdir -p "$out/payloads"
tab=$(printf '\t')
while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
  [ "$configuration" = release ]
  "$root/bin/zig" cc -target "$target" -O2 -std=c11 -Wall -Wextra -Werror \
    "$root/test/portable/launcher_payload.c" -o "$out/payloads/payload-$target"
  "$root/bin/zig" cc -target "$target" -O2 -std=c11 -Wall -Wextra -Werror \
    "$root/test/portable/launcher_socket_fd.c" -o "$out/payloads/socket-$target"
done < "$root/o/targets.tsv"

"$root/o/bin/cosmic" "$root/test/portable/write_launcher_fixture.tl" \
  "$root/o/targets.tsv" "$out/payloads" "$out/launcher"
chmod 755 "$out/launcher.release" "$out/launcher.test"
for kind in release test; do
  dd if="$out/launcher.$kind" of="$out/launcher.$kind.header" \
    bs=16384 count=1 2>/dev/null
  /bin/sh -n "$out/launcher.$kind.header"
done
if grep -a -q 'COSMIC_PORTABLE_TEST_' "$out/launcher.release"; then
  echo 'release launcher contains fixture hook names' >&2
  exit 1
fi
grep -a -q 'COSMIC_PORTABLE_TEST_' "$out/launcher.test"
printf 'portable launcher build: PASS (three native TEST payloads, release shell has no hooks)\n'
