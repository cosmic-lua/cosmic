# 12. subprocess execution (fork/exec/wait)

- status: open (evidence-gathering, 2026-07-04)
- layer: cosmic or cosmopolitan (undetermined — see finding)
- scenario: child_spawn_true

- evidence: `child_spawn_true` (new, `lib/perf/bench/child_bench.tl`):
  1.32ms/op, cpu/wall 0.14 (mostly not CPU — kernel fork/exec/wait
  time, as expected)
- why a new scenario: the existing `startup_*` scenarios
  (`lib/perf/bench/startup_bench.tl`) already spawn a child process
  (`cosmic.child.spawn`), but the target is the `cosmic` binary
  itself, so those numbers conflate raw spawn overhead with booting
  a Lua/Teal runtime. `child_spawn_true` spawns `/bin/true` — about
  as cheap an exec target as exists — isolating `spawn()`'s own
  pipe-setup/fork/wait cost from what gets `exec`'d.
- finding: read through `cosmic.child`'s `spawn()`
  (lib/cosmic/child.tl) and its I/O pump (`lib/cosmic/child_io.tl`).
  Both already call `unix.*` C bindings directly for every operation
  (pipe, fork, dup2, poll, read, write) — there's no pure-Lua
  reimplementation of syscall-level work to delegate, unlike the
  other entries in this backlog. No concrete fix identified this
  round; this entry exists to track the scenario for future passes.
- remaining angles:
  - cosmic layer: `spawn()` always allocates 3 pipes even when a
    caller doesn't need stdin/stderr capture — is a fast path worth
    it?
  - cosmopolitan layer: where does the non-CPU 86% actually go?
    cosmopolitan's `fork()` does userspace work beyond the raw
    syscall (e.g. reconstituting runtime state for portability);
    whether any of it is avoidable on the Linux hot path is a
    C-side question — work it with
    `lib/perf/optimize/cosmopolitan.md`.
- risk: unknown until a concrete hypothesis is found.
