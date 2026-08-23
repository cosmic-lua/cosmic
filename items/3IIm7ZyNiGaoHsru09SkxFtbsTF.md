## Evidence

A module on the boot surface (`_make/stamp.tl`'s `BOOT_MODULES`) cannot
gain a call to a NEW function in a module that is not on it: a cold
`--make build` fails in the generate step, and the failure is
unrecoverable because it happens before the build can produce the
binary that would resolve it.

Measured 2026-08-23 at main `d01ea6ac` in a detached worktree, cold
(`--make clean && --make fetch && --make build`), against the
`2026-08-15-c497c04` pin.

**The failing shape.** Add `to_integer` to `cosmic/string.tl` (a new
function, new `StringModule` field, new `M` entry) and call it from
`cosmic/instrument.tl`, which IS in `BOOT_MODULES`
(`_make/stamp.tl:66`). `bin/cosmic --make build` on a cold tree ends:

```
generate _types/tlast_gen.tl
o/bootstrap/cosmic: /zip/main.lua:43: .../_cli/main_handlers.tl:3: error loading
module 'cosmic.instrument' from '.../cosmic/instrument.tl':
.../cosmic/instrument.tl:163:16: error: invalid key 'to_integer' in record 'str'
of type record StringModule
make: _types/tlast_gen.tl failed
build: FAIL (generate failed)
```

`cosmic.instrument` resolves from the TREE (the error names the `.tl`
path), while `cosmic.string`'s TYPE resolves to a `StringModule`
without the new field — the copy the running binary carries. The
fallback to the pinned release fails identically, so there is no
second generation that recovers: `--make ci` converges because it
re-execs into a binary that already has the function, but a cold
`--make build` never gets one.

**The passing shape, same function.** Reverting `instrument.tl` and
instead calling the same new `str.to_integer` from `_tool/testrun.tl`
(not on the boot surface), cold from the same clean state:
`build: PASS (511 files, 1 binary)`, and
`--make test _make/stamp_test.tl _tool/testrun_test.tl cosmic/instrument_test.tl`
ends `test: PASS (3 files)` — so requiring `cosmic.string` from
`_tool/` does not drag it onto the boot surface either.

So the boundary is exactly "the caller is on the boot surface", not
"the callee is new" and not "`cosmic.string` in particular".

## Why this matters beyond one item

This bit board item 3I7Otbvg (cast wave 4) at implementation time and
bounced it; the bounce recorded the symptom as a
generation-1-vs-generation-2 ordering, which the measurement above
corrects — both the tree bootstrap and the pinned release fail, and the
cold build cannot converge out of it. Nothing in AGENTS.md, in the
`work` skill, or in any gate warns a session that a boot-surface module
has a smaller stdlib available to it than the rest of the tree, and
`--make ci`'s convergence hides it: the gate a session is told to run
is exactly the one that cannot see this failure.

The deliverable is (a) the mechanism, named precisely — which
resolution layer supplies `cosmic.string`'s type to a boot module
compiled during generate, in `cosmic/searcher.tl`'s layering and
`cosmic.teal`'s include dirs — and (b) the strongest available
countermeasure, in `enable.md`'s preference order: a gate that fails
loudly at `--make ci` time rather than only on a cold tree would be
core; an AGENTS.md convention naming the boot surface as a restricted
stdlib would be docs. The `repro` CI lane builds a fresh container and
is the existing place a cold-tree regression would surface.
