## Goal

G3 — an honest type layer, no escape hatches. A carried tl patch entry is
only worth what the probe that proved it is worth, and the probe written
the obvious way reports the opposite answer in silence.

`_make/patch.tl` now carries `patch.reverse` and a `Probing an entry`
paragraph that states the trap. Measured 2026-08-28 against that file as
it stands: the paragraph is the only place in the tree that says it, and
a session probing an entry is editing `3p/tl/tl_patch/*.tl` and
`cosmic/teal_narrowing_test.tl` — neither of which mentions it, and
neither of which forces `_make/patch.tl` open.

The wrong form is still silent. Reproduced 2026-08-28 on a build of
PR #1479 merged onto main, both probes in one process against the same
snippet, `narrow-truthiness` reversed out of a re-derived `tl.lua`:

    searchpath('tl')      = <scratch>/wrongpath/tl.lua
    WRONG (package.path)    chunk=@/zip/tl.lua                    errors=0
    RIGHT (patch.reverse)   chunk=@/tmp/patch-reverse-XXXXXX/tl.lua  errors=1
          cannot index key 'x' in variable 'r' of type R | nil

`package.searchpath` names the de-patched copy first; `require` loads the
binary's own `/zip/tl.lua` regardless and reports zero errors, which
reads as "stock tl already narrows this" — the opposite of the truth,
with nothing logged.

## Change

Put the pointer where the session already is. The candidates, in the
order they are worth measuring:

- a header comment line in each `3p/tl/tl_patch/*.tl` naming
  `_make.patch.reverse` as the probe and `package.path` as the form that
  measures the shipped checker;
- the same line in `cosmic/teal_narrowing_test.tl`'s header, the file
  whose tests guard the entries.

Both were non-goaled in 3IVenbbU because PRs #1477 and #1478 held
`3p/tl/tl_patch/**` at the time. Both have landed (main is 835c874d), so
the directory is free.

Refine before building: decide which of the two locations carries it,
whether one line or a `note` field, and whether the wording belongs in
`docs/guides/**` instead so `cosmic --docs` serves it. Do NOT add a
runtime warning to `cosmic/searcher.tl` — its precedence is deliberate
and `wc -l cosmic/searcher.tl` is 498 against the 500-line cap.

## Non-goals

- No change to `_make/patch.tl`'s `reverse` or its header paragraph.
- No `cosmic/searcher.tl` change.
- No new patch entry, and no edit to any entry's `find`/`replace`.

## Acceptance

To be set at refinement. At minimum: `bin/cosmic --make ci` ends
`ci: PASS`, and a grep names the file(s) that gained the pointer.
