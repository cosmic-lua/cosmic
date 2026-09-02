## Goal

A cosmos pin bump that changes a `cosmo.*` binding's return SHAPE
cannot land in `cosmic-lua/cosmic` AT ALL — not narrowed, not
partial — while `bin/cosmic.pin` stays fixed, if ANY of a specific set
of `cosmic/*.tl` modules (reachable during the build's own generation
phase, or loaded by `_cli/main_handlers.tl` on every cold invocation)
would need their internal destructuring of an affected binding to
change. This is a full precondition on the pin bump itself, not a
"leave these wrappers on old code" workaround.

## Evidence

**Updated 2026-09-02, second builder pass.** The first pass (see
history below) proposed narrowing the pin-bump item
(`3IkMf7BY1UOxBTAIwbNFQwRZJDA`) to exclude the affected wrappers
(`cosmic/fd.tl`, `cosmic/fs/ops.tl`, `cosmic/fs/file.tl`,
`cosmic/embed/init.tl`, `cosmic/child/init.tl`,
`cosmic/proc/rusage.tl`, `cosmic/time.tl`, `_cli/main_handlers.tl`),
leaving them on their OLD (pre-bump) destructuring. That narrowing was
insufficient: a fresh clean-tree `bin/cosmic --make ci` with the pin
bumped, the narrowed-safe wrappers fixed, and the 8 excluded files left
UNCHANGED still fails — not during generation this time, but at the
LATER `compile-batch o/.groups/cosmic.compiled`/`_cli.compiled` step,
which correctly resolves the tree's fresh, post-bump `cosmo.unix`
types against the excluded files' still-old destructuring:

```
_cli/main_handlers.tl:98:28: error: argument 1: got MkstempPath, expected string
cosmic/fd.tl:253:32: error: argument 1: got Pipe (inferred at cosmic/fd.tl:248:3), expected integer
cosmic/time.tl:83:38: error: assignment in declaration did not produce an initial value for variable 'eintr_ns'
cosmic/time.tl:89:28: error: cannot use operator '*' for types SleepRemainder and integer
... (18 more time.tl errors, gmtime/localtime tuple fields)
cosmic -c: compile-batch: 2 of 140 failed
make: the converging build failed
ci: FAIL (build failed)
```

So each of the 8 files has exactly two states — old destructuring,
new destructuring — and BOTH fail one of the build's two compile
passes under the current `bin/cosmic.pin`:
- NEW destructuring → generation's own compile of
  `_types/tlast_gen.tl`/`_make/bytecode.tl` (which runs under
  `bin/cosmic.pin`'s stale, pre-bump embedded types) rejects it.
- OLD destructuring → the later `compile-batch` pass (which runs
  against the tree's fresh, post-bump regenerated types) rejects it.

There is no third option and no scope-narrowing that avoids it: as
long as the pin advances past a release these 8 files' bindings
change shape in, `--make ci` cannot go green, regardless of which of
the two destructuring styles those 8 files carry. The pin bump itself
is blocked, full stop, until this resolves.

(First-pass evidence, for the underlying mechanism: `_types/tlast_gen.tl`
and `_make/bytecode.tl` both `require("cosmic.child")`/`require("cosmic.fs")`
(and `_types/tlast_gen.tl` also `require("cosmic.proc")`) to spawn a
subprocess during generation, which runs BEFORE `_types/types_gen.tl`'s
own output exists; `_cli/main_handlers.tl` loads on every cold
`bin/cosmic` invocation for the same reason. This generalizes AGENTS.md's
documented cold-build staging rule — "a source that needs the tree's
own checker... stages behind a release and pin bump" — from a checker
FEATURE to a runtime BINDING CONTRACT. `_build/coldbuild_test.tl` does
not catch this: it exercises generation-1's type check against the
target build states, not this specific generation-time execution path.)

## The decision needed

One of, chosen by whoever has standing to make this call (not this
capture's job):

(a) Stage this specific pin bump (and every future one whose window
    touches one of these 8 files' bindings) behind a `cosmic-lua`
    release + `bin/cosmic.pin` bump carrying the new cosmos shape
    FIRST, so generation's own compile sees types already matching
    what the new destructuring needs — mirroring the existing
    checker-feature staging rule exactly, but for a runtime binding
    contract instead of a checker feature. This is a two-step
    sequence (pin the release engine first, THEN the pin bump that
    needed staging), not a single PR.

(b) Decouple `_types/tlast_gen.tl`'s and `_make/bytecode.tl`'s
    subprocess-spawning from `cosmic.child`/`cosmic.fs`/`cosmic.proc`
    (e.g. a minimal, contract-independent internal spawn helper those
    two generators use instead), and restructure
    `_cli/main_handlers.tl`'s cold-invocation path so it does not force
    `mkstemp`'s wrapper to compile before generation — removing the
    generation-phase dependency on these specific bindings entirely,
    so a pin bump touching them is no different from any other
    one-PR pin-bump fix ever again.

## Non-goals

- Does not itself fix any of the 8 listed files or land the pin bump
  — that is deferred work once this decision lands.
- Does not relitigate `3IkMf7BY1UOxBTAIwbNFQwRZJDA` (the pin-bump
  item), which is now itself blocked on this item in full — not
  narrowed, not partially landable — pending this decision.
