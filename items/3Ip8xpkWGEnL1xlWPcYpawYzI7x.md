## Evidence

A cold build compiles each `*_gen.tl`'s import closure before running
it (`_make/generate.tl:145-217`, `closure_argv`), strictly, with the
include path from `cosmic/_teal_engine.tl:76-86`:

```
$ sed -n '76,86p' cosmic/_teal_engine.tl
local function default_include_dirs(): {string}
  return {
    "o/_types/types_gen",
    "/zip/.types", -- Bundled cosmic types (in binary)
    "/zip/.tl", "/zip",
  }
end
```

On a cold tree `o/_types/types_gen` is absent, so every closure member
is checked against the RUNNING binary's `/zip/.types` — the trust root
`bin/cosmic.pin` (`2026-08-31-a5b36f4`) — not the `3p/cosmos` pin the
same build just fetched. Any closure member adapted to a new `cosmo.*`
shape therefore fails before the graph exists. Both generators are
exposed (the `require()` walk pasted in `3IoULYAu`'s Recommendation, run at `96afd807`):

```
== _types/tlast_gen.tl: 24 files; changed-binding members: child/init.tl child/io.tl
   fd.tl fs/dir.tl fs/file.tl fs/ops.tl proc/init.tl proc/rusage.tl time.tl
== _types/types_gen.tl: 26 files; changed-binding members: fd.tl fs/dir.tl
   fs/file.tl fs/ops.tl proc/init.tl proc/rusage.tl
```

`run_generator` (generate.tl:218-231) clears the generator's own output
dir BEFORE `closure_argv`, so `types_gen`'s closure never sees its own
previous output either. The generator itself resolves its helpers from
the running binary when no closure is handed to it (generate.tl:121-131),
and those helpers ship: `_types/gentype*.tl`, `_types/gentl.tl` are kind
`module`, and `_make/artifact.tl:51-55` ships `module`, `entry`,
`payload`; `_types/types_gen.tl` is kind `gen` and does NOT ship.

## Change

`_make/generate.tl`, in `sources()` (line 363), after `fetch.repair`
and before the generator loop: when `o/_types/types_gen/` is absent,
run a SEED pass — `child.run({cosmic, "_types/types_gen.tl",
"o/_types/types_seed"})` with no closure flags and no `LUA_PATH`, so
the generator's helpers come from the running binary and its input
(`o/3p/cosmos/lua`'s `/zip/.lua/definitions.lua`, `o/3p/tl/`) from the
tree. Clear `o/_types/types_seed` first the way `run_generator` clears
its dir. A seed failure is loud (`make: seed failed`), never a
fall-through.

`closure_argv`: when the seed dir exists, prepend `"--include-dir",
"o/_types/types_seed"` to the compile args at generate.tl:192.
Confirm explicit `--include-dir` entries are searched BEFORE
`default_include_dirs()` (read `_cli/build/work.tl:191-217`; if they
are appended after, reorder there — the seed must win over
`/zip/.types`). Delete the seed dir at the end of `sources()`, after
`stamp_types`, so `o/_types/types_gen` stays the only declaration set
the graph, the stamp digest (generate.tl:286-335) and
`cmd/cosmic/embed_gen.tl:139` ever read.

Update the comment block at generate.tl:133-139 ("does not deadlock on
itself … falls back to the bundled /zip/.types"): the fallback is now
the seed, and `/zip/.types` is reached only by a generator whose closure
compiles before the seed exists (none, after this change).

Test, in `_make/generate_test.tl` (or the existing generator test that
owns `sources()`): a cold fixture root (`_make/testdata/hello` copied,
`o/` absent) runs `sources()` and asserts `o/_types/types_seed` is gone
afterwards and `o/_types/types_gen/cosmo/unix.d.tl` exists; and a
second assertion that a closure compile with the seed present was
handed `--include-dir o/_types/types_seed` (capture `closure_argv`'s
returned flags).

Sequencing wall: this is engine code the PINNED binary runs at
generation 1 (`_build/coldbuild_test.tl`). It lands under the current
`3p/cosmos` pin (seed output equals final output, so nothing observable
changes), a release is cut, `bin/cosmic.pin` is bumped, and only then
can the adaptation + `3p/cosmos` bump (`A3HK_gamw`) cold-build.

## Non-goals

Not the adaptation itself, not any `_types/tlast_gen.tl` dependency
change, not a change to what `o/_types/types_gen` contains.
