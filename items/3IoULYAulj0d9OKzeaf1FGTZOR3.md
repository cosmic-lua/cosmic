## Question

`A3HK_gamw`'s adaptation pass (updating cosmic's call sites for
cosmopolitan PRs #308-#362's binding-contract-shape rewrite, then
bumping `3p/cosmos/cosmos_pin.tl`) hits a structural cold-build
deadlock that the item's own doctrine (AGENTS.md's cold-build rule)
does not have a ready answer for. How should the adaptation land,
given this?

## Evidence

Found by the builder of `A3HK_gamw`, working from a clean worktree
with every confirmed call site adapted to the new `cosmo.unix`/`cosmo.re`
table-return shapes and `3p/cosmos/cosmos_pin.tl` bumped to
`2026.09.03-903f9e59a` (verified against the release's own
`SHA256SUMS`). A truly cold build (`rm -rf o && bin/cosmic --make check`)
fails before reaching the main compile graph:

```
generate _types/tlast_gen.tl
cosmic/child/init.tl:165:15: error: cannot index key 'pid' in variable 'result' of type integer (inferred at cosmic/child/init.tl:162:5)
cosmic/child/init.tl:170:59: error: cannot index key 'wstatus' in variable 'result' of type integer (inferred at cosmic/child/init.tl:162:5)
cosmic/child/init.tl:247:28: error: cannot index key 'reader' in variable 'p' of type integer (inferred at cosmic/child/init.tl:244:5)
...
make: _types/tlast_gen.tl: cannot build o/cosmic/child/init.lua
build: FAIL (generate failed)
```

Root cause, as the builder traced it: `_types/tlast_gen.tl` sorts
alphabetically before `_types/types_gen.tl`, and `_make/generate.tl`
documents that a generator's own dependency closure — here,
`tlast_gen`'s closure reaches `cosmic/child/init.tl` via
`_types/tlast.tl`'s `dump_via_base`, which spawns a subprocess
through `cosmic.child` — strict-compiles with `o/_types/types_gen/`
absent, falling back to the type declarations bundled in the
**pinned trust-root release** (`bin/cosmic.pin`), not the
freshly-fetched `3p/cosmos` pin the same build is generating from.

The builder confirmed `bin/cosmic.pin` (`2026-08-31-a5b36f4`) and the
latest available cosmic-lua release (`2026-09-02-c60dcf1`) both still
pin cosmos at `6dfa6728a` — no released `cosmic-lua` binary anywhere
yet carries the new `cosmo.unix` shapes. So in one cold build:

- `cosmic/child/init.tl` (needed transitively by `tlast_gen`, which
  runs before `types_gen`) gets type-checked against the OLD bundled
  declarations — and fails, because the builder's adaptation
  correctly targets the NEW shapes.
- Reverting `cosmic/child/init.tl` (and whatever else shares its
  generator-closure exposure) to the OLD shape would then fail
  type-checking later, in the MAIN graph, against the freshly
  generated NEW declarations (from the bumped `3p/cosmos` pin).

No single shape for the affected files satisfies both compile passes
in one cold build — a structural deadlock, not a missed call site.
AGENTS.md's cold-build rule ("land the checker first, bump
`bin/cosmic.pin` to a release carrying it, then land the code that
needs it") is the project's answer to this SHAPE of problem for
checker/patch-set changes, but doesn't transfer directly here: that
staging needs an intermediate released `cosmic-lua` binary that
already carries the adapted-but-not-yet-cosmos-bumped call sites,
and no such release exists (nor can one be produced mid-session).

Repro: from a clean worktree with the pin bumped and the confirmed
call sites adapted, `rm -rf o && bin/cosmic --make check` (or
`--make build`/`ci`) fails as above, both via `o/bin/cosmic` and
after removing it (forcing the `bin/cosmic.pin` fallback).

Also confirmed during this pass: the PR range #308-#362 undercounts
the true adaptation surface. `git log --oneline 6dfa6728a..903f9e59a`
in `cosmic-lua/cosmopolitan` lists 75 commits (#298-#372); the
binding-contract-shape subset is #308, #309, #315-#322, #324, #326,
#328, #329, #331, #332 (bugfix only), #334, #338, #340 — beyond the
item's confirmed-start list, `unix.getrlimit`, `raise`,
`sigprocmask`, `getpgrp`, `isatty`, `openpty`, `Dir:read`,
`lsqlite3.open`/`config`/`prepare`/`wal_checkpoint`/`serialize` are
also affected. The builder adapted all of these before hitting the
deadlock above; `cosmic/sqlite/*` call sites were not exhaustively
confirmed (the shape changes there appeared to only add discarded
error-message slots, but the builder stopped before finishing that
check).

## Decision needed

How should this land, given no intermediate release exists to stage
through? Candidates, not exhaustive:

a. Make the affected generator-closure files (at minimum
   `cosmic/child/init.tl`, whatever else `tlast_gen`'s closure
   reaches) tolerate BOTH the old and new `cosmo.*` shapes at
   runtime — a real, permanent dual-shape compatibility burden in
   public library modules, which the item's own Non-goals currently
   rule out ("no new features riding along... purely absorbing
   already-landed contract changes"); revisit that wall or accept
   the cost.
b. Reorder generator execution so `types_gen` runs before
   `tlast_gen` regardless of alphabetical sort — a `_make/generate.tl`
   change, itself possibly needing its own cold-build staging if it
   changes what the checker sees generator-to-generator.
c. Break `tlast_gen`'s dependency on `cosmic.child` (hence on
   cosmo's process/pipe shapes) so the early generator pass no longer
   needs the changing bindings at all.
d. Cut a cosmic-lua release carrying ONLY the adapted call sites
   against the OLD `3p/cosmos` pin first (a no-op-shape-wise
   intermediate), bump `bin/cosmic.pin` to it, then land the
   `3p/cosmos` pin bump as a second, now-unblocked change — mirrors
   the checker cold-build rule literally, at the cost of two PRs and
   a release cut in between.
e. Something else the refiner sees that this evidence-gathering pass
   didn't.

## Non-goals

- Not itself the adaptation pass — `A3HK_gamw` stays the item that
  does the call-site work and the pin bump, once this question names
  how the cold-build deadlock is resolved.
- Not re-verifying the PR-range recount above; treat it as
  established (it superset-contains the original list).
