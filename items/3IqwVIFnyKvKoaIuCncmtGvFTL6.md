## Access

read access to `cosmic-lua/cosmic` (measured against the tree at
`cosmic-pin-bump-3IkMf7BY`, pushed to `origin/cosmic-pin-bump-3IkMf7BY`).

## Goal

`3IkSSqvH4BLD8YdvdYwohk2Pemz`'s Resolution (D43 / PR #1656, seeding
`o/_types/types_seed` before a generator's own import closure compiles)
does not close the whole "cold build sees stale `cosmo.*` declarations"
class — it closes exactly the piece it measured: the two generators'
(`_types/tlast_gen.tl`, `_make/bytecode.tl`) own declared `require`
closure. A SEPARATE path — the interpreted searcher resolving an
arbitrary `cosmic/*.tl` file's `require`, triggered from inside a
generator script's own execution rather than from its static import
closure — does not inherit the seed and still resolves `cosmo.*`
against the pinned release's bundled (pre-bump) declarations. This
blocks a cold build of `3IkMf7BY1UOxBTAIwbNFQwRZJDA`'s otherwise-complete
pin-bump adaptation.

## Evidence

Measured 2026-09-04 against `cosmic-pin-bump-3IkMf7BY`
(`3p/cosmos/cosmos_pin.tl` bumped to `2026.09.04-65bc139fc`, sha256
`9f3cb4bada574951f04bd46e79933e087d3594c1c94ee35d77ca7102d6488886`,
independently verified against the release's `SHA256SUMS`), with all
~23 files the bumped pin's binding-shape changes touch already adapted
— confirmed by a WARM build: `bin/cosmic --make build` then
`o/bin/cosmic --make ci` ends `ci: PASS (5 stages)`, 3285/3285 tests,
coverage ratchet holds.

A genuinely COLD build fails:

```
$ rm -rf o && bin/cosmic --make fetch && bin/cosmic --make ci
...
generate _types/tlast_gen.tl
/home/user/cosmic/o/pinbump/o/bootstrap/cosmic: /zip/main.lua:45: error loading module '_cli.main_handlers' from '.../\_cli/main_handlers.tl':
.../_cli/main_handlers.tl:102:28: error: invalid key 'path' in record 'tmp_res' of type string (inferred at .../_cli/main_handlers.tl:97:3)
...
	/home/user/cosmic/o/pinbump/_cli/require_hints.tl:231: in global 'require'
	/zip/main.lua:45: in main chunk
```

`main_handlers.tl:97` is `local tmp_fd, tmp_res = unix.mkstemp(...)`,
adapted to the NEW `unix.MkstempPath|string` shape — the checker at
this point infers `tmp_res` as bare `string`, the OLD (pre-bump) shape.

**Isolating the direction**: with `_cli/main_handlers.tl` reverted to
its OLD (pre-bump) destructuring, keeping every other file adapted, the
SAME cold build instead fails on a DIFFERENT file:

```
generate _types/tlast_gen.tl
/home/user/cosmic/o/pinbump/o/bootstrap/cosmic: /zip/main.lua:343: error loading module 'cosmic.tty' from '.../cosmic/tty.tl':
.../cosmic/tty.tl:91:3: error: cannot resolve a type for sfd here
.../cosmic/tty.tl:91:10: error: sfd (of type integer) can never be a string
```

`cosmic/tty.tl:91` is the NEW `if sfd is string then` narrowing this
item's sibling PR added — here the checker infers `sfd` as bare
`integer`, again the OLD shape (`unix.openpty`'s NEW declared shape is
`integer|nil mfd, integer|string sfd, string|unix.Errno name`).

So EITHER destructuring style fails, depending on which file the
interpreted searcher happens to reach first while `cmd/cosmic/main.tl`
boots — this is the identical "no third option" dual-wall
`3IkSSqvH` originally described, now proven to also cover files
reachable ONLY through the searcher's on-demand interpreted compile,
not through either generator's static import closure.

**Standalone, minimal reproduction** (no `--make`, no generate step at
all):

```
$ o/bootstrap/cosmic --check types cosmic/tty.tl
cosmic/tty.tl:91:10: warning: sfd (of type integer) can never be a string
cosmic/tty.tl:91:3: error: cannot resolve a type for sfd here
cosmic/tty.tl:91:10: error: sfd (of type integer) can never be a string
cosmic/tty.tl:136:3: error: cannot resolve a type for cols here
cosmic/tty.tl:136:11: error: cols (of type integer) can never be a string
```

The bootstrap engine's `--check types`, invoked bare against a tree
source file, resolves `cosmo.*` through its own bundled `/zip/.types`
— exactly `_make/seed.tl`'s own documented fallback ("the RUNNING
binary's bundled `/zip/.types`, from whatever release built this
tree") — unless something passes an `--include-dir` naming fresher
declarations.

**Root cause, read from source**: `_make/closure.tl:146-158` builds
the compile argv for exactly ONE thing — the generator SCRIPT's own
top-level compile:

```teal
local seeded = fs.is_present(seed.SEED_DIR)
...
  or seeded and {cosmic, src, path, "--include-dir", seed.SEED_DIR, "--include-dir", "."}
  or {cosmic, src, path, "--include-dir", "."}
```

`_make/generate.tl`'s `run_generator` (lines ~74-86) then runs the
generator as a SCRIPT through the bootstrap engine:

```teal
local argv: {string} = {cosmic}
for _, a in ipairs(flag) do argv[#argv + 1] = a end
argv[#argv + 1] = gen
argv[#argv + 1] = dest
local r, rerr = child.run(argv, {stdout = "inherit", stderr = "inherit"})
```

i.e. `cosmic --include-dir o/_types/types_seed --include-dir . _types/tlast_gen.tl <dest>`.
That `--include-dir` pair is consumed by the ONE compile step that
checks `_types/tlast_gen.tl` itself before running it. But invoking
`cosmic` with a script argument boots `cmd/cosmic/main.tl` first —
which unconditionally `require("_cli.main_handlers")` at its own
module top level, before it ever dispatches to the script argument —
and that require, along with anything else the interpreted searcher
loads while the generator script subsequently runs (`cosmic/tty.tl`
in the isolated case above), goes through the ordinary searcher path
with `_teal_engine`'s DEFAULT include dirs, which do not carry the
`--include-dir o/_types/types_seed` flag forward. `default_include_dirs()`
hardcodes `o/_types/types_gen` — the REAL directory `run_generator`
clears and repopulates only later, on the actual (non-seed) run — so
at this exact moment neither the seed's location nor the real one is
on the default path, and the fallback to the bundled bootstrap types
fires.

## Non-goals

- Does not itself propose a fix — staging behind an
  `--include-dir`-propagation change (env var, a wider default,
  changing what `main.tl` requires unconditionally, or something else)
  is a real design decision for whoever picks this up, not this
  capture's job.
- Does not re-verify `3IkSSqvH`'s own closure-compile fix, which this
  item's own Evidence confirms still holds (`cosmic/fd.tl`,
  `cosmic/fs/dir.tl` compile cleanly in the closure pass on this same
  tree).
- Does not itself adapt or revert any wrapper; `3IkMf7BY`'s branch
  (`cosmic-pin-bump-3IkMf7BY`, pushed) carries the complete, warm-CI-green
  adaptation as-is, blocked on this item.

## Change

`_make/seed.tl`'s `run` now promotes the staged seed directly into the
one path every compile channel already consults with no flag at all.

Previously `run` left the generator's unclosed output sitting at
`SEED_DIR` (`o/_types/types_seed`) — a location only `_make/closure.tl`'s
`--include-dir` flag, attached to the ONE explicit compile of a
generator SCRIPT's own top-level closure, ever names. Everything else
this Evidence traced — `main.tl`'s own unconditional
`require("_cli.main_handlers")`, and any `cosmic/*.tl` a generator's
subsequent execution reaches through the interpreted searcher — never
receives that flag, so it falls through `_teal_engine`'s
`default_include_dirs()` to the fallback: the RUNNING (pinned, pre-bump)
binary's bundled `/zip/.types`.

`default_include_dirs()` already hardcodes `o/_types/types_gen` FIRST,
unconditionally, on every project's compile path — that's the one
directory every consumer this item found (explicit-flag or searcher
alike) already looks at with nothing extra to wire up. So instead of
teaching more call sites about the seed's separate location, `run` now
does one `fs.move` of the complete, successfully-seeded `SEED_DIR`
straight onto `TYPES_GEN_DIR` (`o/_types/types_gen`) itself, atomically,
once the seed generator succeeds. `should_seed` already only calls
`run` when `TYPES_GEN_DIR` is absent (or a prior run's `SEED_DIR` was
left dangling), so there is never a real directory here for the rename
to clobber — and the later real run of `_types/types_gen.tl` in
`generate.sources`'s own generator loop still unconditionally clears
and repopulates `TYPES_GEN_DIR` with the complete, closure-checked
output, exactly as it always has; the promoted seed is only ever the
bridge that gets every OTHER compile in between past the gap.

`_make/seed_test.tl`'s `test_run_populates_and_cleanup_removes_the_seed_dir`
is renamed `test_run_populates_and_promotes_to_types_gen_dir` and
rewritten to match: after `run`, `SEED_DIR` is gone (promoted away, not
left behind) and the generator's own output lives at the newly-exported
`seed.TYPES_GEN_DIR` instead; `cleanup` afterward is asserted as the
no-op it now is on that path.

**Why this can't be proven against a genuinely cold build on the
CURRENT pin, and what was proven instead**: `_make/*.tl` is embedded,
precompiled, in the pinned bootstrap binary and frozen for generation 1
— confirmed directly: `o/bootstrap/cosmic -e 'require("_make.seed")...'`
silently returns the OLD code with no trace of a tree-source debug print
added for the check, and a genuinely cold `rm -rf o` build never emits
it either. This is the identical situation `3IkSSqvH`'s own D43 fix
was already in (AGENTS.md's cold-build rule: "Such a change stages
behind a release and pin bump: land the checker first, bump
`bin/cosmic.pin` to a release carrying it, then land the code that
needs it") — a tree-source change to `_make/*.tl` cannot alter what
generation 1 of THIS pin does; it only takes effect once a release built
from a tree carrying it becomes the new pin.

Validated instead the way that constraint allows: built `o/bin/cosmic`
(generation 2, compiled from tree source, which DOES embed this fix) via
a completely cold `rm -rf o && bin/cosmic --make fetch && bin/cosmic
--make build` against this branch's UNCHANGED, un-bumped `3p/cosmos`
pin — `build: PASS (605 files, 1 binary)`, converging in the normal two
generations with no manual intervention. Then, to specifically exercise
the promote-on-seed path itself (which the current, un-bumped pin has no
occasion to trigger — `o/_types/types_gen` is already fresh once
generation 2 exists), removed only `o/_types` and reran `o/bin/cosmic
--make build` alone: it reseeded, promoted, and rebuilt cleanly with no
stale-type failure and no manual step — the exact self-heal this fix is
for, proven on the one binary available to prove it on before the next
pin bump embeds it for real. `o/bin/cosmic --make ci` afterward:
`ci: PASS (5 stages)`, 3286/3286 tests, coverage ratchet holds,
including `_build/coldbuild_test.tl` — the gate that specifically
re-checks generation 1's exact type-check behavior with the pinned
checker and tree module resolution.

Does not itself unblock `3IkMf7BY1UOxBTAIwbNFQwRZJDA`: that item's
cold build, against the ACTUAL bumped `3p/cosmos` pin, still needs a
new cosmic release cut from a tree carrying this fix, and
`bin/cosmic.pin` bumped to it, before ITS generation 1 sees any of
this — same staging `3IkSSqvH` went through. This item only lands the
mechanism.
