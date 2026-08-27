## Goal

G3, under the tl-patch gaps container (3ISJI4Lg): the carried-patch
mechanism stops being capacity-bound at one 500-line file, so the four
stuck patch items (3ISSFrCO, 3ISSGDIN, 3ISSGm9B, 3IPXRRd2) have a
place for their entries. The decision this item settles: a pin's patch
may be a `<stem>_patch/` DIRECTORY of entry files, resolved and merged
by the mechanism — capacity by splitting, never by relaxing the
500-line cap.

## Evidence

Measured 2026-08-27 at main `d8584916`, from the repo root.

- **The bind.** `wc -l 3p/tl/tl_patch.tl` → **499** against the
  500-line `file-length` cap (`.d.tl` the only exemption,
  `_cli/lint.tl:335`), and the landed pack-n slice already spent the
  header slack (28 → 22 lines). An anchored entry runs 13–30 lines
  (`narrow-or-fallback` 13, `narrow-truthiness` 30), so nothing more
  fits.
- **One file per pin, by string surgery.** `_make/patch.tl:56-61`
  (`of_pin`) derives `<stem>_patch.tl` from `<stem>_pin.tl` and
  returns one path or nil. Its two callers are both in
  `_make/fetch.tl`: `patch_of` (`:107`) and `repair` (`:265`).
  `patch.read` (`_make/patch.tl:71-108`) parses ONE file with
  `cosmic.literal`, sorts entry names, validates the four string
  fields, and refuses an empty patch.
- **The groups are already two.** `grep -n '^\  \["' 3p/tl/tl_patch.tl`
  → 20 entries: 5 `ast-cache-*` at lines 24–172, 15 `narrow-*` at
  173–499. Split at that seam, each side plus a short header is ~165
  and ~345 lines — both under the cap, with ~150 lines of growth room
  on the narrow side where the four pending items land.
- **Patch files are ordinary tree files to the graph.** The role
  conventions name `*_pin.tl` (`_make/artifact.tl:40`,
  `_make/check.tl:45`) but not `*_patch.tl`; `3p/tl/tl_patch.tl`
  type-checks and lints like any module today, so files under
  `3p/tl/tl_patch/` need no model change — they are modules whose
  return value `patch.read` parses as literal data, same as now.
- **Headroom for the mechanism edit.** `wc -l _make/patch.tl` → 190,
  `_make/patch_test.tl` → 95; both have hundreds of lines of room.
- **The byte-identity oracle.** With the patch set applied,
  `sha256sum o/3p/tl/tl.lua` →
  `77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`
  and `o/3p/tl/tl.tl` → `d4e7e075d3f2710deccb30fa14cf8c7191f9b43b1f2d4b76629b4dd024406f88`.
  A pure mechanism-plus-split change must reproduce both digests
  exactly after a clean re-fetch.
- **Cold-build note.** `_make/patch.tl` is compiled by the PINNED
  binary in a cold build's first generation. The current pin
  (`2026-08-27-afad5b5`) carries the full narrowing patch set, so no
  special spelling care is needed — but keep the edit plain Teal
  regardless; the mechanism is boot-path code.

## Change

Three parts: the mechanism, the split, the tests.

### `_make/patch.tl` — a patch is one file or a directory of them

1. `of_pin` becomes `paths_of_pin(pin_source): {string} | nil` (rename
   both fetch.tl call sites): when `<stem>_patch.tl` is a file, return
   `{that path}`; else when `<stem>_patch/` is a directory, return its
   `*.tl` files sorted by name (via `cosmic.fs` listing); else nil.
   When BOTH exist, this is an error the caller must surface: return
   the list with the single file first is WRONG — instead add a second
   return, `paths_of_pin(): {string} | nil, string`, and make the
   both-forms case `nil, "<stem>_patch.tl and <stem>_patch/ both
   exist; keep exactly one"`. An empty directory returns
   `nil, "<dir>: a patch directory with no *.tl entries is one to
   delete"`.
2. `read` keeps its one-file signature. Add
   `read_all(paths: {string}): {Edit} | nil, string`: call `read` on
   each path, concatenate, and refuse a duplicate entry NAME across
   files naming both paths — one namespace, whatever the file layout.
   Keep the merged list in sorted-name order across the whole set, as
   `read` sorts today, so apply order is unchanged by the split.
3. Update the module header: the patch beside a pin is
   `<stem>_patch.tl`, or, when the entry set outgrows the 500-line
   cap, a `<stem>_patch/` directory whose `*.tl` files hold the
   entries — same format per file, one shared entry namespace,
   capacity by splitting rather than by a cap exemption.

### `_make/fetch.tl` — the two callers

`patch_of` (`:107`) and `repair` (`:265`) call `paths_of_pin` and
`read_all`, propagating the new error return. The archive-pin guard
(`:111-114`) is unchanged and applies to the whole set.

### The split

Create `3p/tl/tl_patch/ast_cache.tl` (the five `ast-cache-*` entries,
today's lines 24–172, byte-identical) and `3p/tl/tl_patch/narrow.tl`
(the fifteen `narrow-*` entries, lines 173–499, byte-identical), each
opening with the header lines that describe its own group plus the
shared two: the pointer to `_make/patch.tl` as the mechanism and the
carried-not-forked paragraph (anchor must match exactly once; a pin
bump that moves the code fails the fetch loudly). Delete
`3p/tl/tl_patch.tl`. Entry text is MOVED, never edited: find/replace
bodies byte-identical, which the oracle below checks better than any
diff read.

### `_make/patch_test.tl` — the new seams

Following the file's existing fixture style: a directory patch
resolves and merges (two files, entries from both applied); file and
directory together is refused with the message above; an empty
directory is refused; a duplicate entry name across two files is
refused naming both; a single-file patch still resolves exactly as
before (the regression pin for every other pin in every project).

### Ratchets

`bin/cosmic --make coverage --baseline` if the coverage gate asks
(two new tree files under `3p/tl/tl_patch/`, one deleted); any other
ratchet, run exactly the regen command its failure message prints and
commit the result.

## Non-goals

- **The 500-line cap does not move** — no `file-length` exemption for
  patch data; the rejected alternative is recorded here: an exemption
  relaxes a convention the work system's hard rules say is never
  relaxed to make work fit, and splitting is the enablement the same
  rules prescribe.
- **No entry is edited, added, or removed.** Twenty entries in, twenty
  out, byte-identical bodies; the four pending patch items land their
  entries AFTER this, in `3p/tl/tl_patch/narrow.tl`.
- **No pin change, no `o/3p/**` expectation change**: the applied
  output must be byte-identical (the oracle).
- **`patch.read`'s per-file validation and the Edit record are
  untouched**; only resolution and aggregation grow.
- **No model/convention change**: `*_patch/` files are ordinary tree
  files, and nothing new is excluded from any gate.
- **Frozen**: the anchor contract (find matches exactly once, per
  file it names), `cosmic.literal` as the reader, the archive-pin
  guard in fetch.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _make/patch_test.tl` passes, including the
   directory, both-forms, empty-dir, duplicate-name and
   single-file-regression tests.
3. `ls 3p/tl/tl_patch.tl` fails (the file is gone);
   `wc -l < 3p/tl/tl_patch/ast_cache.tl` and
   `wc -l < 3p/tl/tl_patch/narrow.tl` each print at most `500`.
4. `grep -c '^\  \["' 3p/tl/tl_patch/ast_cache.tl` prints `5` and
   `grep -c '^\  \["' 3p/tl/tl_patch/narrow.tl` prints `15` — twenty
   entries, none lost, none gained.
5. **The oracle**: after `rm -rf o/3p/tl && bin/cosmic --make fetch`,
   `sha256sum o/3p/tl/tl.lua` prints
   `77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`
   and `sha256sum o/3p/tl/tl.tl` prints
   `d4e7e075d3f2710deccb30fa14cf8c7191f9b43b1f2d4b76629b4dd024406f88`
   — the split changed no applied byte. (Re-measure the two digests at
   pull if a tl pin bump landed since 2026-08-27; the CLAIM is
   before/after identity, the constants are today's.)
6. `git diff --name-only origin/main` prints exactly, in any order:
   `_make/patch.tl`, `_make/fetch.tl`, `_make/patch_test.tl`,
   `3p/tl/tl_patch/ast_cache.tl`, `3p/tl/tl_patch/narrow.tl`, the
   deleted `3p/tl/tl_patch.tl`, plus `.cosmic-coverage` if and only
   if the coverage ratchet asked for it.

## Enablement

none needed. The mechanism, its two callers, the group seam, the
entry counts and the byte-identity oracle are all measured above with
their commands; the split is a move, not a rewrite; and the four
items this unblocks each get one line of their `Change` corrected
(`3p/tl/tl_patch.tl` → `3p/tl/tl_patch/narrow.tl`) at their own
refinement, not here.
