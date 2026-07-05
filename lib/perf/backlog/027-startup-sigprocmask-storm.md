# 27. startup issues ~195 rt_sigprocmask and ~115 mmap kernel calls

- status: open
- layer: cosmopolitan
- scenario: startup_run_lua (and every startup_*/child_* scenario)

- evidence: a real-kernel trace (`strace -c -f sh -c 'o/bin/cosmic -e
  "print(1)"'`, 2026-07-05 — cosmo's own `--strace` shows the
  userspace view; this is the kernel view) counts 572 syscalls for a
  trivial run, dominated by:
  - 195 rt_sigprocmask (~11% of traced syscall time)
  - 115 mmap + 33 munmap
  - 38 fcntl, 52 close
  (numbers include a `sh -c` wrapper's own footprint — re-measure
  bare via binfmt or subtract a `sh -c true` baseline when working
  this; the sigprocmask count is far beyond what a shell adds.)
- hypothesis: the sigprocmask storm is cosmopolitan libc wrapping
  hot operations in block/unblock-signals pairs (allocator, zipos,
  or stdio critical sections — find the exact callers first, e.g.
  by breakpointing rt_sigprocmask in gdb on lua.dbg or reading
  BLOCK_SIGNALS users under libc/). Batching or eliding redundant
  mask flips on paths that run dozens of times per boot, and
  consolidating the mmap churn (115 maps for a hello-world), would
  shave fixed startup cost that no cosmic-side change can reach.
- how to work it: `lib/perf/optimize/cosmopolitan.md` loop; this is
  pure C-internals (no binding contract involved), so gates are
  upstream tests + the startup scenarios. `perf record -g` on
  `o//tool/lua/lua.dbg` and `--strace` before/after are the right
  instruments.
- relation to entry 4: entry 4 tracks the startup floor as a whole
  and its decomposition; this entry is one concrete, measured slice
  of it (syscall overhead), workable independently of the zipos/
  payload questions (entry 24 covers the inflate slice).
- risk: medium — signal-mask correctness around fork/threads is
  easy to get wrong; lean on upstream's test suite and keep diffs
  surgical per the fork-hygiene guardrail.
