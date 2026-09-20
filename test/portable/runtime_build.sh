#!/bin/sh
# Build real new-format Cosmic artifacts for retained-descriptor integration.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=${1:?usage: runtime_build.sh OUTPUT_DIRECTORY}
mkdir -p "$out"
"$root/bin/zig" build cores -Dportable-startup-test-hooks=true \
  --prefix "$out/hooked-build"
"$root/bin/zig" build sanitized --prefix "$out/sanitized-build"
cp "$root/o/cosmic.portable.db" "$out/old.db"
cp "$root/o/cosmic.portable.db" "$out/new.db"
cp "$root/o/cosmic.portable.db" "$out/basis.db"
cp "$root/o/cosmic.portable.db" "$out/missing.db"
python3 - "$out/old.db" "$out/new.db" "$out/basis.db" "$out/missing.db" <<'PY'
import hashlib
import sqlite3
import sys
for path, marker in zip(sys.argv[1:], ("old", "new", "basis", "missing")):
    db = sqlite3.connect(path)
    db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
               ("retained_fixture", marker))
    if marker == "basis":
        db.execute("UPDATE meta SET value = ? WHERE key = 'runtime_basis'",
                   (hashlib.sha256(b"portable fixture basis variant").hexdigest(),))
    elif marker == "missing":
        db.execute("DELETE FROM meta WHERE key = 'runtime_basis'")
    db.commit()
    db.close()
PY

python3 - "$out/old.db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
keys = {row[0] for row in db.execute("SELECT key FROM meta")}
images = db.execute("SELECT count(*) FROM images").fetchone()[0]
db.close()
for forbidden in ("host", "host_image", "runtime"):
    if forbidden in keys:
        raise SystemExit("portable runtime build: per-host metadata survived: " + forbidden)
if "runtime_basis" not in keys or images != 0:
    raise SystemExit("portable runtime build: projection lacks basis or carries images")
PY

"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$root/o/core" "$out/old.db" "$out/runtime.release"
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/old.db" \
  "$out/runtime.old" test
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/new.db" \
  "$out/runtime.new" test
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/basis.db" \
  "$out/runtime.basis" test
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$root/o/targets.tsv" "$out/hooked-build/core" "$out/missing.db" \
  "$out/runtime.missing" test

# A fixture-only fourth manifest entry binds the real host sanitized core. Its
# synthetic uname tuple is deliberately unreachable from the launcher; the
# identity test executes that raw core with descriptors 8 and 9 populated from
# this manifest entry, exercising the production startup contract without
# making sanitized the ordinary shell selection.
host_system=$(uname -s)
host_arch=$(uname -m)
tab=$(printf '\t')
host_record=$(awk -F "$tab" -v sysname="$host_system" -v arch="$host_arch" \
  '$5 == sysname && $6 == arch { print; exit }' "$root/o/targets.tsv")
[ -n "$host_record" ]
target_id=$(printf '%s\n' "$host_record" | awk -F "$tab" '{ print $1 }')
target=$(printf '%s\n' "$host_record" | awk -F "$tab" '{ print $4 }')
sanitized_name="sanitized-$target"
cat "$root/o/targets.tsv" > "$out/sanitized-targets.tsv"
printf '%s\t2\tsanitized\t%s\tFixture\tSanitized\n' \
  "$target_id" "$sanitized_name" >> "$out/sanitized-targets.tsv"
mkdir -p "$out/sanitized-cores"
while IFS="$tab" read -r _ _ _ release_target _ _; do
  mkdir -p "$out/sanitized-cores/$release_target"
  cp "$out/hooked-build/core/$release_target/cosmic-core" \
    "$out/sanitized-cores/$release_target/cosmic-core"
done < "$root/o/targets.tsv"
mkdir -p "$out/sanitized-cores/$sanitized_name"
cp "$out/sanitized-build/sanitized/cosmic-core" \
  "$out/sanitized-cores/$sanitized_name/cosmic-core"
"$root/o/bin/cosmic" "$root/test/portable/write_runtime_fixture.tl" \
  "$out/sanitized-targets.tsv" "$out/sanitized-cores" "$out/old.db" \
  "$out/runtime.sanitized" test
printf '%s\n' "$target_id" > "$out/sanitized-target-id"
printf '%s\n' "$target" > "$out/sanitized-target"
printf '%s\n' "$sanitized_name" > "$out/sanitized-core-name"

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
for name in ("runtime.release", "runtime.old", "runtime.new", "runtime.basis",
             "runtime.missing", "runtime.sanitized"):
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
cp "$root/test/portable/fixture/runtime_test.tl.in" "$out/runtime_test.tl.in"
cp "$root/test/portable/fixture/cmd/hello/main.tl.in" "$out/hello_main.tl.in"
chmod 755 "$out/runtime.release" "$out/runtime.old" "$out/runtime.new" \
  "$out/runtime.basis" "$out/runtime.missing" "$out/runtime.sanitized" \
  "$out/runtime.incompatible"
printf 'portable runtime build: PASS (host-independent projection, real release/sanitized cores, distinct complete artifacts)\n'
