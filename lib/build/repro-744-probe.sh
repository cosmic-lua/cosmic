#!/bin/sh
# repro-744-probe.sh — COMPILE_WRAP instrumentation for whilp/cosmic#744.
#
# The decisive question #744 leaves open: when a sandbox-enforced compile
# fails `module not found`, is the required module actually UNREADABLE
# (EACCES) by that exact child at that instant — while the child's own
# prerequisites stay readable? That distinguishes the working hypothesis
#   "the bled ruleset dropped the global r:lib grant; per-target
#    prerequisite grants survived"  (=> the require-closure-prereq fix works)
# from every other cause (kernel ENOENT, whole-ruleset loss, a real teal
# bug) — under which that fix would be useless.
#
# It can only be answered from INSIDE the failing child, under the exact
# Landlock ruleset landlock-make gave it. This wrapper is that instrument.
# The compile rule invokes it as its COMPILE_WRAP prefix, so it runs as the
# recipe process (sharing the child's inherited, immutable ruleset), execs
# the real compile, and — only when the compile fails with `module not
# found` — probes readability of the require-closure and the prerequisites
# and records the errno class for each.
#
# Invocation (from the compile recipe, via `sh`):
#   sh <this> <diagdir> <bootstrap-cosmic> <compile args...> <src.tl>
# stdout is the compiled Lua (the recipe redirects it to $@.tmp) and must
# pass through untouched; only stderr is inspected. Exit status is the
# compile's own, so a hit still fails the build exactly as today.
#
# On a host without Landlock the probe simply always records READABLE (the
# sandbox is a no-op), which is itself the control: no EACCES, no fault.
set -u

diagdir="$1"
shift

# Capture the compile's stderr for inspection; let stdout flow through to
# the recipe's `> $@.tmp`. errf lives under diagdir (in $(o), which the
# compile rule grants rwc) so the write survives even a dropped r:lib.
mkdir -p "$diagdir" 2>/dev/null || true
errf="$diagdir/.stderr.$$"
"$@" 2>"$errf"
rc=$?

# Re-emit the compiler's stderr so the build output is unchanged.
cat "$errf" >&2 2>/dev/null

if [ "$rc" -ne 0 ] && grep -q "module not found" "$errf" 2>/dev/null; then
  # The source being compiled is the last argument.
  src=""
  for a in "$@"; do src="$a"; done
  safe=$(printf '%s' "$src" | tr '/ .' '___')
  diag="$diagdir/$safe.diag"

  # classify(path): open it and reduce the outcome to an errno class, using
  # the same read `io.open`/`cat` performs. A directory that opens is
  # reported READABLE (traversable); EACCES is the smoking gun.
  classify() {
    msg=$(cat "$1" 2>&1 >/dev/null)
    case "$msg" in
      "")                       echo READABLE ;;
      *[Pp]ermission" "denied*) echo EACCES ;;
      *[Nn]o" "such*)           echo ENOENT ;;
      *[Ii]s" "a" "directory*)  echo READABLE_DIR ;;
      *)                        echo "OTHER:$msg" ;;
    esac
  }

  {
    echo "# repro-744 HIT  pid=$$  rc=$rc"
    echo "# src (a prerequisite — should be READABLE): $src"
    echo "# compiler stderr:"
    sed 's/^/#   /' "$errf"
    echo "# in-child readability probe (this process's inherited ruleset):"
    # prerequisites the compile rule grants per-target (expect READABLE),
    # then the require-closure reachable only via the global r:lib grant
    # (EACCES here == the bled-grant mechanism confirmed).
    for f in \
      "$src" \
      tlconfig.lua \
      lib \
      lib/cosmic \
      lib/cosmic/fs/init.tl \
      lib/cosmic/check.tl \
      lib/cosmic/net/init.tl \
      lib/docs/publish.tl \
      3p; do
      printf '#   %-26s %s\n' "$f" "$(classify "$f")"
    done
  } > "$diag" 2>/dev/null
fi

rm -f "$errf" 2>/dev/null
exit "$rc"
