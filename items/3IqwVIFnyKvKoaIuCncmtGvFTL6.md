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
