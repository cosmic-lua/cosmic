#!/bin/sh
# What the build wrote under zig-build since the restore. `stamp` marks
# the moment right after the restore and lists the files then there;
# `report` lists the files newer than the mark, so a run whose inputs
# match the entry it restored says what it added anyway (ci.yml's TODO
# on the zig build cache). A diagnostic: the steps that run it are
# continue-on-error, and RUNNER_TEMP, which Actions always sets, is
# the one thing it insists on.
set -u

dir="${RUNNER_TEMP:?}/zig-build"
stamp="$RUNNER_TEMP/zig-build.stamp"
before="$RUNNER_TEMP/zig-build.before"

case "${1:-}" in
stamp)
  touch "$stamp"
  [ -d "$dir" ] && find "$dir" -type f | sort > "$before"
  ;;
report)
  [ -f "$stamp" ] && [ -d "$dir" ] || { echo "no stamp or no zig-build: nothing to report"; exit 0; }
  # The processor is what the likeliest cause varies with: zig builds its
  # maker and configurer for the one it detects.
  cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)
  [ -n "$cpu" ] || cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || :)
  echo "runner: $(uname -sm), cpu: ${cpu:-unknown}"
  echo "restored entry: ${RESTORED:-none}"
  all=$(mktemp)
  out=$(mktemp)
  now=$(mktemp)
  # `wc -c` prints "<bytes> <path>"; its "total" lines, one per batch, go.
  find "$dir" -type f -exec wc -c {} + 2>/dev/null | awk '$2 != "total"' > "$all"
  find "$dir" -type f -newer "$stamp" -exec wc -c {} + 2>/dev/null |
    awk '$2 != "total"' > "$out"
  echo "zig-build now: $(awk '{ n += $1 } END { print n + 0 }' "$all") bytes in $(wc -l < "$all" | tr -d ' ') files"
  # Newer than the stamp is new or rewritten in place (manifests that
  # zig_restat or a cache hit touches are the latter), so the files
  # that did not exist at the stamp are counted apart.
  if [ -f "$before" ]; then
    find "$dir" -type f | sort > "$now"
    echo "files that did not exist at the restore: $(comm -13 "$before" "$now" | wc -l | tr -d ' ')"
  fi
  echo "files newer than the restore (new or rewritten in place): $(wc -l < "$out" | tr -d ' '), $(awk '{ n += $1 } END { print n + 0 }' "$out") bytes"
  echo "by directory (two levels under zig-build):"
  awk -v p="$dir/" '{ n = $1; sub(/^[ ]*[0-9]+ /, ""); sub("^" p, "");
        m = split($0, a, "/"); k = (m > 2) ? a[1] "/" a[2] : a[1];
        s[k] += n; c[k]++ }
      END { for (k in s) printf "%12d %6d files  %s\n", s[k], c[k], k }' "$out" |
    sort -rn
  echo "largest files newer than the restore:"
  sort -rn "$out" | head -n 15 | sed "s|$dir/||"
  rm -f "$all" "$out" "$now"
  ;;
*)
  echo "usage: zig-build-writes.sh stamp|report" >&2
  exit 2
  ;;
esac
