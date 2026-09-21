#!/bin/sh
set -eu
cosmic=${1:?usage: orchestration-selfcheck.sh COSMIC CANDIDATE_ROOT WORK}
candidate=${2:?usage: orchestration-selfcheck.sh COSMIC CANDIDATE_ROOT WORK}
work=${3:?usage: orchestration-selfcheck.sh COSMIC CANDIDATE_ROOT WORK}
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
mkdir -p "$work/project" "$work/state" "$work/products"
for template in "$here"/*.tl.in; do
  cp "$template" "$work/project/$(basename "$template" .in)"
done
driver=$work/project/driver.tl

# Logical failures are durable, and corrupt/missing attestations fail.
for name in a b; do
  product=$work/products/portable-product-$name
  mkdir "$product"; printf bytes > "$product/cosmic"
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$product/cosmic" | cut -d' ' -f1)
  else
    digest=$(shasum -a 256 "$product/cosmic" | cut -d' ' -f1)
  fi
  printf '%s  cosmic\n' "$digest" > "$product/executed-cosmic.sha256"
  printf '2\n' > "$product/expected-platforms"
done
"$cosmic" "$driver" provenance "$work/state/good.db" worker run 1 \
  "$candidate" "$work/products"
printf changed >> "$work/products/portable-product-b/cosmic"
set +e
"$cosmic" "$driver" provenance "$work/state/bad.db" worker run 1 \
  "$candidate" "$work/products"
status=$?
set -e
test "$status" -ne 0
"$cosmic" "$driver" report "$work/state/bad.db" "$work/state/bad.md"
grep -F '| worker | run | 1 | provenance | error |' "$work/state/bad.md" >/dev/null

# WORK is rejected before creation when it aliases or sits under the candidate.
test ! -e "$candidate/orchestration-selfcheck-work"
set +e
"$cosmic" "$driver" platform build "$work/state/path.db" worker run 1 \
  "$candidate" x86_64-linux-musl "$candidate/orchestration-selfcheck-work"
status=$?
set -e
test "$status" -ne 0
test ! -e "$candidate/orchestration-selfcheck-work"

# Every entry point rejects a database inside either protected project.
set +e
"$cosmic" "$driver" provenance "$work/project/bad.db" worker run 1 \
  "$candidate" "$work/products" >/dev/null 2>&1
status=$?
set -e
test "$status" -ne 0
test ! -e "$work/project/bad.db"

# A fake candidate proves cache restore is restricted, large output stays in
# files, snapshot cleanup removes the candidate-created inspection o/, and a
# suite exit remains primary when its integrity snapshot also fails.
fake=$work/fake-candidate
seed=$work/seed
test ! -e "$work/platform" && test ! -e "$work/state/failure.db"
mkdir -p "$fake/bin" "$fake/test/portable" "$seed/zig-cache" \
  "$seed/zig-global" "$work/tmp"
printf fixture > "$fake/AGENTS.md"
cp "$candidate/test/portable/work_db_integrity.tl.in" "$fake/test/portable/"
printf poison > "$seed/build.db"
cat > "$fake/bin/zig" <<'EOF'
#!/bin/sh
set -eu
test ! -e o/build.db
mkdir -p o/bin
printf not-a-database > o/build.db
cat > o/bin/cosmic <<'INNER'
#!/bin/sh
if [ "${1-}" = work_db_integrity.tl ]; then mkdir -p o; exit 0; fi
i=0
while [ "$i" -lt 20000 ]; do printf 'large retained output %s\n' "$i"; i=$((i + 1)); done
exit 23
INNER
chmod 755 o/bin/cosmic
EOF
chmod 755 "$fake/bin/zig"
set +e
TMPDIR="$work/tmp" COSMIC_ZIG_CACHE_SEED="$seed" \
  COSMIC_CI_SELFTEST_REPLAY_FAILURE=true \
  "$cosmic" "$driver" platform build "$work/state/failure.db" worker run 1 \
    "$fake" x86_64-linux-musl "$work/platform"
status=$?
set -e
test "$status" -eq 23
test -d "$work/platform" && test -f "$work/state/failure.db"
test ! -e "$fake/o/build.db.build.db"
test ! -e "$fake/o/poison"
test -d "$fake/o/zig-cache" && test -d "$fake/o/zig-global"
test "$(wc -c < "$work/platform/local-diagnostics/local-test.out")" -gt 100000
test "$(find "$work/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 0
grep -F 23 "$work/platform/local-diagnostics/local-test.status" >/dev/null

echo 'ci orchestration contracts: PASS'
