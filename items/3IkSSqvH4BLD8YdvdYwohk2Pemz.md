## Goal

A cosmos pin bump that changes a `cosmo.*` binding's return SHAPE
cannot land a wrapper fix for any `cosmic/*.tl` module that is
transitively `require`d during the build's own GENERATION phase (which
runs under `bin/cosmic.pin`'s stale, pre-bump embedded `cosmo.*` type
declarations, not the tree's freshly regenerated ones) or that
`_cli/main_handlers.tl` pulls in on every cold invocation. Until this is
resolved, any binding-contract-changing pin bump must permanently
exclude these modules' internal fixes from its own PR — which is a real,
recurring cost to every future census-driven pin bump, not a one-off.

## Evidence

Found live while building board item `3IkMf7BY1UOxBTAIwbNFQwRZJDA` (the
`2026.08.31-6dfa6728a` → `2026.09.01-0f64e8e6c` cosmos pin bump).
`_types/tlast_gen.tl` and `_make/bytecode.tl` both `require`
`cosmic.child`/`cosmic.fs` (and `_types/tlast_gen.tl` also
`cosmic.proc`) to spawn a subprocess as part of the build's generation
step, which runs BEFORE the tree's own `_types/types_gen.tl` output
exists — so these modules compile under `bin/cosmic.pin`'s embedded,
not-yet-bumped types. `_cli/main_handlers.tl` is loaded on every cold
`bin/cosmic` invocation for the same structural reason.

Modules transitively reachable this way, confirmed by repeated clean
(`rm -rf o`) `bin/cosmic --make fetch && bin/cosmic --make build`
attempts with the post-bump `unix.pipe`/`unix.mkstemp`/
`unix.getrlimit`/`unix.gmtime`/`unix.localtime`/`unix.nanosleep`
contract fixes applied to their destructuring:

- `cosmic/fd.tl` (pipe) — via `cosmic.fs`
- `cosmic/fs/ops.tl`, `cosmic/fs/file.tl` (mkstemp/mkdtemp) — via `cosmic.fs`
- `cosmic/embed/init.tl` (mkstemp) — via `cosmic.fs`
- `cosmic/child/init.tl` (pipe) — via `cosmic.child`
- `cosmic/proc/rusage.tl` (getrlimit) — via `cosmic.proc`
- `cosmic/time.tl` (nanosleep, gmtime, localtime) — via `cosmic.child.io` → `cosmic.time`
- `_cli/main_handlers.tl` (mkstemp) — loaded directly on every invocation

With the NEW (post-bump-correct) destructuring in these files, the
generation step itself fails to compile (`_types/tlast_gen.tl`'s own
generation run), because `bin/cosmic.pin`'s embedded checker rejects
the new shape:

```
_cli/main_handlers.tl:98:28: error: argument 1: got MkstempPath, expected string
cosmic/fd.tl:253:32: error: argument 1: got Pipe (inferred at cosmic/fd.tl:248:3), expected integer
cosmic/time.tl:127:26: error: assignment in declaration did not produce an initial value for variable 'hour'
```

With the OLD destructuring left in place, generation succeeds (it runs
under the stale pinned checker, which still expects the old shape),
but the LATER `compile-batch o/.groups/cosmic.compiled`/`_cli.compiled`
step — which correctly uses the tree's fresh, post-bump types — then
fails on the exact same files for the opposite reason. There is no
single source text for these files that satisfies both compile passes
under the current `bin/cosmic.pin`.

This generalizes AGENTS.md's documented cold-build staging rule ("a
source that needs the tree's own checker... stages behind a release
and pin bump: land the checker first, bump `bin/cosmic.pin` to a
release carrying it, then land the code that needs it") from a checker
FEATURE to a runtime BINDING CONTRACT. `_build/coldbuild_test.tl`
does not catch this today because it exercises generation-1's type
check against the target build states, not this specific
generation-time execution path through `cosmic.child`/`cosmic.fs`/
`cosmic.proc`.

## The decision needed

One of, chosen by whoever has standing to make this call (not this
capture's job):

(a) Stage every binding-contract pin bump behind a `cosmic-lua`
    release + `bin/cosmic.pin` bump carrying the new cosmos shape
    FIRST (mirroring the existing checker-feature staging rule
    exactly), landing the affected wrapper's fix only after that pin
    bump is live — i.e., these specific wrappers permanently trail
    every other wrapper by one `bin/cosmic.pin` release cycle.

(b) Decouple `_types/tlast_gen.tl`'s and `_make/bytecode.tl`'s
    subprocess-spawning from `cosmic.child`/`cosmic.fs`/`cosmic.proc`
    (e.g. a minimal, contract-independent internal spawn helper those
    two generators use instead), and/or restructure
    `_cli/main_handlers.tl`'s cold-invocation path to not force
    `mkstemp`'s wrapper to compile before generation — removing the
    generation-phase dependency entirely so these wrappers are no
    different from any other one-PR pin-bump fix.

## Non-goals

- Does not itself fix any of the listed wrappers — that is deferred
  work once this decision lands, tracked as its own follow-up item(s)
  once the direction is chosen.
- Does not relitigate the pin bump itself (board item
  `3IkMf7BY1UOxBTAIwbNFQwRZJDA`), which is landing separately, narrowed
  to the wrappers this hazard does NOT affect.
