#!/bin/sh
# What the build wrote under zig-build since the restore. `stamp` marks
# the moment right after the restore; `report` lists the files newer
# than it, so a run whose inputs match the entry it restored says what
# it added anyway (ci.yml's TODO on the zig build cache). Reports only;
# it fails nothing.
set -u

dir="$RUNNER_TEMP/zig-build"
stamp="$RUNNER_TEMP/zig-build.stamp"

case "${1:-}" in
stamp)
  touch "$stamp"
  ;;
report)
  [ -f "$stamp" ] && [ -d "$dir" ] || { echo "no stamp or no zig-build: nothing to report"; exit 0; }
  # The processor is what the likeliest cause varies with: zig builds its
  # maker and configurer for the one it detects.
  cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)
  [ -n "$cpu" ] || cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || :)
  echo "runner: $(uname -sm), cpu: ${cpu:-unknown}"
  echo "restored entry: ${RESTORED:-none}"
  out=$(mktemp)
  # `wc -c` prints "<bytes> <path>"; its "total" lines, one per batch, go.
  find "$dir" -type f -newer "$stamp" -exec wc -c {} + 2>/dev/null |
    awk '$2 != "total"' > "$out"
  echo "files written since the restore: $(wc -l < "$out" | tr -d ' ')"
  echo "bytes written, by directory (two levels under zig-build):"
  awk -v p="$dir/" '{ n = $1; sub(/^[ ]*[0-9]+ /, ""); sub("^" p, "");
        split($0, a, "/"); k = a[1] "/" a[2]; s[k] += n; c[k]++ }
      END { for (k in s) printf "%12d %6d files  %s\n", s[k], c[k], k }' "$out" |
    sort -rn
  echo "largest files written:"
  sort -rn "$out" | head -n 15 | sed "s|$dir/||"
  rm -f "$out"
  ;;
*)
  echo "usage: zig-build-writes.sh stamp|report" >&2
  exit 2
  ;;
esac
