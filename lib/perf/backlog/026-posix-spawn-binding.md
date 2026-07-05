# 26. child.spawn pays full fork(); vfork-backed posix_spawn is unexposed

- status: open
- layer: cosmopolitan (new binding) + cosmic (wrapper fast path)
- scenario: child_spawn_true

- evidence: `child_spawn_true` costs 1.71ms/op at cpu/wall 0.14 —
  almost all kernel time — to spawn `/bin/true` from the ~20MB cosmic
  process. `cosmic.child.spawn` (lib/cosmic/child.tl) uses
  `unix.fork()` + dup2 + `unix.execve()`; fork of a large process
  pays page-table copy proportional to the parent's memory.
  Meanwhile cosmopolitan's `posix_spawn()`
  (libc/proc/posix_spawn.c) explicitly uses vfork on the hot path —
  its own doc comment: "Cosmopolitan Libc's posix_spawn() uses
  vfork() under the hood ... because vfork() creates a child process
  without needing to copy [the parent's page tables], which is
  awesome for large processes" — with file-actions support for the
  dup2/pipe plumbing spawn needs. There is NO Lua binding for it:
  `grep posix_spawn tool/lua/lcosmo.c tool/net/lfuncs.c` comes back
  empty (checked 2026-07-05).
- hypothesis: expose posix_spawn (+ file actions for the
  stdin/stdout/stderr pipe setup) as a `unix.*` binding upstream,
  then give `child.spawn` a fast path that uses it when the caller's
  options map onto file actions (the common capture-stdout shape
  does). Given fork dominates the 1.71ms, expect a large cut — this
  also feeds every `startup_*` scenario, which spawn the cosmic
  binary via `child.spawn`.
- how to work it: this is a binding-surface addition, so it follows
  the contract rules in `lib/perf/optimize/cosmopolitan.md` — new
  annotations in tool/net/definitions.lua, upstream tests
  (tool/lua/test_unix_proc.lua is the precedent), a cosmic
  `regen-types` + wrapper change landed together with the pin bump.
  Measure locally first via `perf-bin` with a modified checkout.
- cross-reference: entry 12 gathered the original evidence and found
  no cosmic-layer fix; this entry is its concrete C-side successor.
- risk: medium-high — new C binding surface (vfork semantics are
  subtle; posix_spawn encapsulates them, which is exactly why it's
  the right vehicle), plus a two-repo landing. The win size justifies
  it.
