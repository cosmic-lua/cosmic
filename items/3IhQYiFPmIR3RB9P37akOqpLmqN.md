## Question

`_make/artifact.tl`'s `build()` needs a correct definition of "expected
entry count" for a verify-before-install check (item `3I29nhZC`, handle
«PxMM_mVMH»). What is the right source of truth for that count?

## Evidence

Measured 2026-08-31 against this repo's own `cosmic` binary, in a clean
worktree, via a one-line instrumentation probe in `build()` (reverted
before this write-up; `git status --porcelain` empty after):

- `cosmic/embed/init.tl:480`'s `embedc.write` returns `count =
  #files_to_embed` — the count of files staged from the caller's `dir`
  (`_make/artifact.tl`'s `plan()`/`stage()` output) — **572** for this
  repo's `cosmic` binary.
- The actually-built `o/bin/cosmic`, listed via `cosmic.zip`
  (`open` + `a:list()`), has **687** entries and does contain
  `main.lua`.
- The 115-entry gap is exactly the base-runtime floor
  (`cosmic/embed/floor.tl`'s `FLOOR` table: `usr/*` — TLS roots and
  zoneinfo, 114 entries — plus `.cosmo`, 1 entry) that survives the
  strip pass but is never part of `files_to_embed`/`embedc.write`'s
  count: `572 + 115 = 687`, exact.

`PxMM_mVMH`'s spec (`## Change` step 2) states `verify_payload`'s
`expected` is `embedc.write`'s returned `count`, checked as `#entries ==
expected` against the built artifact. Implemented literally, this fails
every real `--make build` whose base is a cosmos-provided runtime
(`687 != 572` here), which would sink `bin/cosmic --make ci`'s own
`ci: PASS` acceptance bar permanently — not just catch the race the
item exists to catch.

## What needs deciding

A correct `expected` has to account for the base-floor entries a real
build keeps. Candidate shapes, not evaluated here:

- sum `embedc.write`'s `count` plus the base-floor entries the strip
  pass is expected to keep (would need `floor.tl`'s kept-entry count
  exposed alongside the strip, and re-verified against a
  `provides`-varying build, not just this repo's own default build);
- derive `expected` from a second, independent `list()` on the
  just-staged artifact taken before `replace_if_changed` swaps it in
  (self-referential — verifies internal consistency between two reads
  of the same write, not staged-content-matches-intent, so it may not
  catch the actual race `PxMM_mVMH`'s Evidence describes: a
  concurrent process clearing the staging directory mid-write. Needs
  checking against that race's actual sequence.);
- some other reconciliation of `files_to_embed` and `floor.tl`'s kept
  set that a planning pass should measure rather than assume.

Resolving this unblocks `3I29nhZC` (handle «PxMM_mVMH»,
"concurrent --make in one tree yields a payload-less o/bin/cosmic that
exits 0 as bare Lua") to build against a correct `expected` definition.
