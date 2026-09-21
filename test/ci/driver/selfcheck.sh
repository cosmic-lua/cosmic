#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: selfcheck.sh COSMIC CANDIDATE_ROOT [WORK_DIR]" >&2
  exit 2
fi
cosmic=$1
candidate=$2
here=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
if [ "$#" -eq 3 ]; then
  work=$3
  mkdir -p "$work"
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-driver-check.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
fi
project="$work/driver project"
state="$work/worker state"
mkdir -p "$project" "$state"
cp "$here/driver/driver.tl.in" "$project/driver.tl"
cp "$here/driver/orchestration.tl.in" "$project/orchestration.tl"
cp "$here/driver/state.tl.in" "$project/state.tl"
driver="$project/driver.tl"
db="$state/operations.db"

(cd "$project" && "$cosmic" fix driver.tl)

"$cosmic" "$driver" run "$db" worker run-1 1 success "$candidate" 1000 \
  /bin/sh -c 'test "$PWD" = "$1"; printf ok > "$2"' sh \
  "$candidate" "$state/path with spaces"
test "$(cat "$state/path with spaces")" = ok

set +e
"$cosmic" "$driver" run "$db" worker run-1 1 nonzero "$candidate" 1000 \
  /bin/sh -c 'exit 23'
code=$?
set -e
test "$code" -eq 23

set +e
"$cosmic" "$driver" run "$db" worker run-1 1 start-failure "$candidate" 1000 \
  /definitely/not/a/cosmic-command
code=$?
set -e
test "$code" -eq 1

set +e
"$cosmic" "$driver" run "$db" worker run-1 1 timeout "$candidate" 20 \
  /bin/sh -c 'sleep 30'
code=$?
set -e
test "$code" -eq 124

"$cosmic" "$driver" run "$db" worker run-1 1 interrupted "$candidate" 30000 \
  /bin/sh -c 'printf ready > "$1"; sleep 30' sh "$state/ready" &
driver_pid=$!
i=0
while [ ! -f "$state/ready" ] && [ "$i" -lt 200 ]; do
  sleep 0.01
  i=$((i + 1))
done
test -f "$state/ready"
kill -TERM "$driver_pid"
set +e
wait "$driver_pid"
code=$?
set -e
test "$code" -eq 143

report="$state/report.md"
"$cosmic" "$driver" report "$db" "$report"
grep -F '| worker | run-1 | 1 | success | success |' "$report" >/dev/null
grep -F '| worker | run-1 | 1 | nonzero | exit |' "$report" >/dev/null
grep -F '| worker | run-1 | 1 | start-failure | start-error |' "$report" >/dev/null
grep -F '| worker | run-1 | 1 | timeout | timeout |' "$report" >/dev/null
grep -F '| worker | run-1 | 1 | interrupted | incomplete |' "$report" >/dev/null

cp "$db" "$project/sentinel.db"
if command -v sha256sum >/dev/null 2>&1; then
  sentinel_before=$(sha256sum "$project/sentinel.db" | cut -d' ' -f1)
else
  sentinel_before=$(shasum -a 256 "$project/sentinel.db" | cut -d' ' -f1)
fi
ln -s "$project/sentinel.db" "$state/database-link"
set +e
"$cosmic" "$driver" run "$state/database-link" worker run-1 1 symlink-db \
  "$candidate" 1000 /bin/true >/dev/null 2>&1
code=$?
set -e
test "$code" -ne 0
if command -v sha256sum >/dev/null 2>&1; then
  sentinel_after=$(sha256sum "$project/sentinel.db" | cut -d' ' -f1)
else
  sentinel_after=$(shasum -a 256 "$project/sentinel.db" | cut -d' ' -f1)
fi
test "$sentinel_after" = "$sentinel_before"

# A bad cache entry is discarded, and a bad replacement download is rejected.
# The curl fixture is deliberately offline; bootstrap still validates the exact
# immutable release URL before invoking it.
fakebin="$work/fake bin"
cache="$work/cache"
mkdir -p "$fakebin" "$cache"
cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
cp "$DOWNLOAD_SOURCE" "$output"
EOF
chmod 755 "$fakebin/curl"
commit=0123456789abcdef0123456789abcdef01234567
digest=0000000000000000000000000000000000000000000000000000000000000000
pin="$work/bad.pin"
printf '%s\n%s\n%s\n' "$commit" \
  "https://github.com/cosmic-lua/cosmic/releases/download/next-$commit/cosmic" \
  "$digest" > "$pin"
printf bad > "$cache/cosmic-$digest"
printf bad-download > "$work/download"
set +e
PATH="$fakebin:$PATH" DOWNLOAD_SOURCE="$work/download" \
  sh "$here/bootstrap-driver.sh" "$pin" "$cache" "$work/bootstrap project" \
  "$work/bootstrap runner/cosmic"
code=$?
set -e
test "$code" -ne 0
test ! -e "$work/bootstrap runner/cosmic"

echo "ci driver: PASS (success, nonzero, start failure, timeout, interruption, spaces, pin rejection)"
