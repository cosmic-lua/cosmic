#!/bin/sh
# Build real new-format Cosmic artifacts for retained-descriptor integration.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=${1:?usage: runtime_build.sh OUTPUT_DIRECTORY}
mkdir -p "$out"
"$root/bin/zig" build cores -Dportable-startup-test-hooks=true \
  --prefix "$out/hooked-build"
cp "$root/o/cosmic.db" "$out/old.db"
cp "$root/o/cosmic.db" "$out/new.db"
python3 - "$out/old.db" "$out/new.db" <<'PY'
import sqlite3
import sys
for path, marker in zip(sys.argv[1:], ("old", "new")):
    db = sqlite3.connect(path)
    db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
               ("retained_fixture", marker))
    db.commit()
    db.close()
PY

"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$root/o/core" "$out/old.db" "$out/runtime.release"
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/old.db" \
  "$out/runtime.old" test
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/new.db" \
  "$out/runtime.new" test

mkdir -p "$out/incompatible-cores"
tab=$(printf '\t')
while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
  mkdir -p "$out/incompatible-cores/$target"
  cp "$out/hooked-build/core/$target/cosmic-core" \
    "$out/incompatible-cores/$target/cosmic-core"
  printf X | dd of="$out/incompatible-cores/$target/cosmic-core" \
    bs=1 seek=128 conv=notrunc 2>/dev/null
done < "$root/o/targets.tsv"
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/incompatible-cores" "$out/new.db" \
  "$out/runtime.incompatible" test

# Make the second complete artifact's prefix observably different without
# changing its valid launcher or manifest. This byte is padding in the final
# shell comment, outside all core ranges.
python3 - "$out/runtime.new" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as artifact:
    artifact.seek(16370)
    if artifact.read(1) != b" ":
        raise SystemExit("runtime fixture: expected shell comment padding")
    artifact.seek(16370)
    artifact.write(b"X")
PY

python3 - "$out" <<'PY'
import hashlib
import os
import struct
import sys
root = sys.argv[1]
for name in ("runtime.release", "runtime.old", "runtime.new"):
    path = os.path.join(root, name)
    with open(path, "rb") as source:
        data = source.read()
    trailer = data[-48:]
    if trailer[:8] != b"CosmicT1":
        raise SystemExit("runtime fixture: trailer is missing")
    prefix = struct.unpack(">Q", trailer[32:40])[0]
    with open(path + ".prefix-sha256", "w") as output:
        output.write(hashlib.sha256(data[:prefix]).hexdigest() + "\n")
PY

cp "$root/test/portable/fixture/retained_probe.tl.in" "$out/probe.tl"
chmod 755 "$out/runtime.release" "$out/runtime.old" "$out/runtime.new" \
  "$out/runtime.incompatible"
printf 'portable runtime build: PASS (real cores, Cosmic database, distinct complete artifacts)\n'
