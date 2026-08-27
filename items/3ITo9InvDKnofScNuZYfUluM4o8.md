## Goal

G3, under the tl-patch gaps container (3ISJI4Lg): stage 2 of the
patch-capacity work — the actual split of `3p/tl/tl_patch.tl` into
the `3p/tl/tl_patch/` directory the landed mechanism (3ISnTFGe, PR
#1424, main `6b88a0db`) can read. It unblocks the three queued patch
items (3ISSFrCO, 3ISSGDIN, 3ISSGm9B) and, transitively, 3IPXRRd2.

## Evidence

Measured 2026-08-27; tree facts at main `6b88a0db`.

- **The wall, proven by run 33033225229** (PR #1424's first push):
  generation 1 of a cold build fetches with the PINNED binary, and a
  pin whose mechanism knows only the single-file layout applies no
  patches over the split tree — `tlast_gen` fails with `no ast_hooks;
  is the tl patch applied?`, on both the tree build and the pinned
  fallback. So this slice is workable only once `bin/cosmic.pin`
  names a release whose tag commit has PR #1424's merge (`6b88a0db`)
  as an ancestor. That is the PULL-TIME GATE below; the cold-build
  rule's third face (tree layout needing new build-mechanism code) is
  recorded on 3ISnTFGe.
- **The whole stage was already built and validated once**, as PR
  #1424's first push (`9ff72e9b`), refused only by the pin wall — so
  every shape below is observed, not predicted:
  - The seam: 20 entries — 5 `ast-cache-*` (file lines 24–172), 15
    `narrow-*` (173–499); split files landed at 168 and 344 lines.
  - The byte-identity oracle: with the patch set applied,
    `sha256sum o/3p/tl/tl.lua` →
    `77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`,
    `o/3p/tl/tl.tl` →
    `d4e7e075d3f2710deccb30fa14cf8c7191f9b43b1f2d4b76629b4dd024406f88`.
    A pure split reproduces both after a clean re-fetch. (Re-measure
    the two constants at pull if a tl pin bump landed since; the
    CLAIM is before/after identity.)
  - Eleven files' comments/prose name `3p/tl/tl_patch.tl` and follow
    the rename (list in `git show 9ff72e9b --stat`): AGENTS.md,
    `cosmic/teal_test.tl`, `cosmic/_teal_ast.tl`,
    `cosmic/_teal_hints.tl`, `_types/tlast.tl`, `_types/gentl.tl`,
    `docs/design/casts.md`, `docs/design/nil-flow.md`,
    `docs/guides/checking.md`, `docs/guides/gotchas.md`, and a
    "correct"-class path fix in
    `docs/decisions/d21-carried-tl-patch.md` (no claim moves).
    `_make/patch_test.tl`'s header sentence names the single file and
    flips to the directory wording.
- **The mechanism refuses both-forms layouts**, so the split commit
  must add the directory and delete the file in ONE commit — a tree
  with both fails every fetch with "keep exactly one".

## Change

One commit, reproducible from `git show 9ff72e9b` restricted to the
split's files (cherry-picking the relevant hunks is fine; entry text
byte-identical, never retyped):

1. Create `3p/tl/tl_patch/ast_cache.tl` (the five `ast-cache-*`
   entries) and `3p/tl/tl_patch/narrow.tl` (the fifteen `narrow-*`
   entries), each with its group header plus the shared
   mechanism-pointer and carried-not-forked paragraphs, exactly as
   `9ff72e9b` wrote them. Delete `3p/tl/tl_patch.tl` in the same
   commit.
2. Apply the eleven prose path renames from `9ff72e9b` (same hunks),
   plus `_make/patch_test.tl`'s header sentence.
3. `bin/cosmic --make coverage --baseline` if the coverage gate asks
   (two new tree files, one deleted); any other ratchet, run exactly
   the regen command its failure message prints and commit the
   result.

## Non-goals

- **No mechanism change** — `_make/patch.tl`, `_make/fetch.tl` and
  their tests landed in stage 1 and are untouched.
- **No entry edited, added, or removed** — twenty in, twenty out,
  byte-identical bodies; the queued patch items land their entries
  AFTER this, in `3p/tl/tl_patch/narrow.tl`.
- **No pin change in this slice** — the pin bump that ENABLES it is
  its own event (the gate below); this diff touches no pin.
- **Frozen**: the 500-line cap (capacity by splitting, decided on
  3ISnTFGe), the anchor contract, the applied-output bytes.

## Acceptance

**Pull-time gate, first**: in a whilp/cosmic checkout,
`git merge-base --is-ancestor 6b88a0db <sha of the tag bin/cosmic.pin names>`
must hold (resolve the tag's sha from the release). If it does not,
the pin has not caught up — bounce back to blocked rather than
building; do NOT dispatch a release to force it.

Then, run from the repo root:

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `ls 3p/tl/tl_patch.tl` fails; `wc -l < 3p/tl/tl_patch/ast_cache.tl`
   and `wc -l < 3p/tl/tl_patch/narrow.tl` each print at most `500`.
3. `grep -c '^\  \["' 3p/tl/tl_patch/ast_cache.tl` prints `5` and
   `grep -c '^\  \["' 3p/tl/tl_patch/narrow.tl` prints `15`.
4. **The oracle**: `rm -rf o/3p/tl && bin/cosmic --make fetch`, then
   `sha256sum o/3p/tl/tl.lua o/3p/tl/tl.tl` prints the two digests
   recorded in Evidence (or the pair re-measured at pull) — the split
   changed no applied byte.
5. **The cold proof**: the PINNED release binary's own `--make fetch`
   over a clean `o/3p/tl` applies the set from the directory —
   `grep -c "PackTable<any>" o/3p/tl/tl.lua` → `1`.
6. `grep -rn "tl_patch.tl" --include="*.tl" --include="*.md" .`
   (excluding `o/**`, the directory itself, and `_make/patch.tl`'s
   doc example) prints nothing.
7. `git diff --name-only origin/main` prints exactly the fifteen
   files of `9ff72e9b`'s split surface: the two new patch files, the
   deleted `3p/tl/tl_patch.tl`, `_make/patch_test.tl` (header
   sentence only), the eleven prose files — plus `.cosmic-coverage`
   if and only if the coverage ratchet asked.

## Enablement

Wall-clock gated on the pin cycle, exactly like 3ISVlHT6 was: the
next cosmic release (daily 06:00 UTC cron, or a dispatch a human
chooses to run) will carry `6b88a0db`, and the pin bump that follows
it opens this. Everything else is settled: the diff exists at
`9ff72e9b` and was validated end to end (ci green, oracle held)
before the pin wall refused it, and the gate above is the one check a
puller must run before building.
