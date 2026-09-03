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

## Recommendation

Option (c) as written — cutting `_types/tlast_gen.tl`'s `cosmic.child`
dependency — is necessary for the failure the builder saw but NOT
sufficient, and (b) and (d) do not work at all. Measured:

```
$ cd /home/user/cosmic && git rev-parse --short origin/main        # 96afd807 (== HEAD)
$ python3 - <<'PY'   # transitive require() walk from each generator, cosmo.* excluded
import re,os
def path_of(m):
  p=m.replace(".","/")
  return next((c for c in (p+".tl",p+"/init.tl") if os.path.exists(c)),None)
def walk(f,seen):
  if f in seen: return seen
  seen.add(f)
  for m in re.findall(r'require\("([^"]+)"\)',open(f).read()):
    if not m.startswith("cosmo") and path_of(m): walk(path_of(m),seen)
  return seen
for g in ("_types/tlast_gen.tl","_types/types_gen.tl"): print(g,sorted(walk(g,set())))
PY
== _types/tlast_gen.tl: 24 files; changed-binding members: ['cosmic/child/init.tl',
   'cosmic/child/io.tl', 'cosmic/fd.tl', 'cosmic/fs/dir.tl', 'cosmic/fs/file.tl',
   'cosmic/fs/ops.tl', 'cosmic/proc/init.tl', 'cosmic/proc/rusage.tl', 'cosmic/time.tl']
== _types/types_gen.tl: 26 files; changed-binding members: ['cosmic/fd.tl',
   'cosmic/fs/dir.tl', 'cosmic/fs/file.tl', 'cosmic/fs/ops.tl', 'cosmic/proc/init.tl',
   'cosmic/proc/rusage.tl']
```

The mechanism, file by file: `_make/project.tl:368` sorts `proj.files`
by path, so `_types/tlast_gen.tl` precedes `_types/types_gen.tl`;
`_make/generate.tl:374-381` runs every `kind == "gen"` file in that
order; `run_generator` (generate.tl:218) clears the generator's own
output dir and then `closure_argv` (generate.tl:145-217) strict-compiles
the generator's whole import closure with `--include-dir .`; with
`o/_types/types_gen/` absent, `cosmic/_teal_engine.tl:76-86` falls
through to `/zip/.types` of the RUNNING binary (generate.tl:136-138
documents this as deliberate), i.e. `bin/cosmic.pin`'s
`2026-08-31-a5b36f4`, which carries the OLD shapes. `tlast_gen.tl:14 →
_types/tlast.tl:20 → cosmic.child → cosmic/child/init.tl:161
(unix.wait, #340) / :243 (unix.pipe, #328)` is the first adapted site
hit — but `types_gen`'s OWN closure reaches `cosmic/fs/ops.tl:381`
(mkstemp, #329), `fs/dir.tl:27` (Dir:read, #326), `fd.tl:247` (pipe),
`proc/init.tl:252` (wait) and `proc/rusage.tl:41` (getrlimit, #324), so
after (c) the same error moves one generator later. `run_generator`
clears `o/_types/types_gen` BEFORE compiling `types_gen`'s closure, so
even a warm tree cannot help that pass.

- (a) dual-shape runtime code in nine public modules: works, permanent
  debt, and every future shape change repeats it. Reject.
- (b) reorder generators: `types_gen`'s own closure is exposed; no order
  helps.
- (c) alone: see above — moves the failure, does not remove it.
- (d) intermediate release: an adapted tree against the OLD pin fails
  its own main-graph check, so no such release can be built.

Adopt (e): `_make/generate.tl` seeds declarations from the fetched pin
before any closure compile — spec `generate-seed-types` (blocks this
item). It is engine code the PINNED binary runs at generation 1, so it
lands first, `bin/cosmic.pin` is bumped to a release carrying it, and
only then can `A3HK_gamw`'s adaptation + `3p/cosmos` bump cold-build
(`_build/coldbuild_test.tl` enforces exactly this order). Tradeoff: one
engine PR plus one daily-release wait before the adaptation can merge,
against the lasting property that a pin bump never again depends on the
trust root's bundled types. (c) becomes optional hygiene, not a gate.

The `A3HK_gamw` worktree is GONE — `ls /tmp/claude-0/-home-user/15925051-9a03-506a-af49-a6b214eeb796/scratchpad/worktrees/A3HK_gamw`
→ `No such file or directory`; `ls /home/user/cosmic/.git/worktrees` →
`board` only; no branch, stash or dangling object matches. The adaptation
must be redone from the PR list in `A3HK_gamw`'s refreshed spec.

## Decision

Adopted: option (e), the seed pass — `_make/generate.tl` generates the
cosmo declarations from the FETCHED `3p/cosmos` pin before any
generator closure compiles, and hands that seed to every closure
compile ahead of the running binary's bundled `/zip/.types`. The
project owner confirmed this in conversation after reading the
Recommendation above, on the grounds that (a) needs casts that fight
G3 permanently, (b) leaves `types_gen`'s own closure exposed, (c)
alone moves the failure one generator later, and (d) cannot be built
because an adapted tree fails its own check against the old pin.

Consequences recorded as items:
- the seed pass itself is `pawY_zI7x` (this item's `done` unblocks it);
- the cold-build rule in CLAUDE.md changes meaning — generation 1
  still uses the pinned CHECKER, but its cosmo types now come from the
  tree's own pin — and that is a decision record plus a CLAUDE.md
  paragraph, filed as its own item beside the seed;
- `A3HK_gamw` (the adaptation + `3p/cosmos` bump) waits on the seed
  shipping in a release and a `bin/cosmic.pin` bump, which its
  blockers already say;
- `tlast_gen` dropping `cosmic.child` stays filed as optional hygiene,
  not a gate.

Accepted cost: one engine PR and one release cycle before the
adaptation can merge, and a new staging constraint of the same shape
as the checker's — a change to the annotation FORMAT upstream must
land in `_types/gentype.tl` and ship in a release before the cosmos
pin that relies on it.
