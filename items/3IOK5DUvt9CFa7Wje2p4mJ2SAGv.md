## Goal

G3 — an honest type layer. The cast census is the instrument that tells
G3 whether the tree is shedding casts, and it currently counts things
that are not casts, so its number is not a measurement. This slice makes
`_build/casts.tl` count the same thing `--check lint` counts — `as`
tokens, token-exact — instead of grepping for the justification comment.

The linter is already right: `_cli/lint.tl:35`'s `cast_lines` lexes with
`tl.lex` and takes `t.tk == "as"`, precisely so "casts inside strings and
comments never count" (its own doc comment). Only the census grep is
wrong, and it is wrong in three shapes, all measured 2026-08-25 (see
`Change` for the command):

| site | what the grep counts | what it is |
| --- | --- | --- |
| `_build/casts_test.tl:67,68` | 2 | fixture text in a string literal |
| `_cli/lint.tl:84` | 1 | the lint's own diagnostic message, a string |
| `_build/casts.tl:6`, `_cli/lint.tl:65` | 2 | a `---` doc comment quoting the syntax |
| `cosmic/compress.tl:48,68` | 2 | orphaned reasons — those lines carry no `as` at all |

That is 7 phantom casts across 4 files: 363 counted, 356 real. The third
shape is the one that shows the grep is not merely over-counting quoted
examples — `cosmic/compress.tl` carries two `-- cast:` comments left
behind by a refactor that removed the casts, and the census has been
reporting them as debt ever since.

`_build/casts.tl`'s own header states the current behaviour as a
deliberate trade ("without a second cast lexer to keep in step with the
linter's", and "a quotation costs a baseline entry and nothing else").
This slice does not add a second lexer — it reuses the linter's — so that
trade no longer applies and the prose that records it is rewritten in the
same diff.

## Change

**1. `_cli/lint.tl` — export `cast_lines`.** The function already exists
at line 35 and is unchanged; only the module surface grows. Add to
`LintModule`, immediately before `check_cast_justification`:

```teal
  cast_lines: function(content: string, file: string): {integer}
```

and to the `M` table in the same position:

```teal
  cast_lines = cast_lines,
```

Measured: `wc -l < _cli/lint.tl` is 455, so 43 lines of headroom remain
under the 500-line cap after these two.

**2. `_build/casts.tl` — count `as` tokens, via the linter's scanner.**
Add `local lint = require("_cli.lint")` to the import block (alphabetical:
after `floor`, before `fs`). Delete `in_text` (lines 39–56, the doc
comment and the function) and replace the per-file body inside `count`

```teal
            local text = fs.read(path)
            local n = text and in_text(text) or 0
```

with

```teal
            local text = fs.read(path)
            local n = text and #lint.cast_lines(text, path) or 0
```

`cast_lines` returns each line at most once, so this is still a count of
cast LINES, which is what the floor's per-file numbers have always meant.
A file `tl.lex` cannot lex yields `{}`, i.e. 0 — the same treatment
`fs.read` failing already gets, and the same the linter gives.

Rewrite the two places that describe the old mechanism, and nothing else
in the file:
- the module header's third paragraph (lines 4–9): the reason each cast
  line is findable is still that `--make lint` demands a justification,
  but what this module counts is the `as` tokens themselves, through
  `_cli.lint`'s scanner — one lexer, shared with the gate that enforces
  the rule, so a cast quoted in a string or named in a doc comment is not
  counted.
- `count`'s doc comment, which must stop promising that "a quotation
  costs a baseline entry".

Measured: `wc -l < _build/casts.tl` is 157; this nets out shorter.

**3. `cosmic/compress.tl` — delete the two orphaned reasons.** Line 48
(`-- cast: same word set; the binding names its enum independently`, above
`local result, err = cosmo.Deflate(...)`) and line 68 (the identical
comment above `local result, err = cosmo.Inflate(...)`). Neither line
below them holds an `as`; verified 2026-08-25 by
`grep -n " as " cosmic/compress.tl`, which prints only prose matches
("as used inside ZIP files", "as inside ZIP files", "as nil, err"). Delete
only those two comment lines — the line above line 68
(`-- The binding reports truncated or corrupt input as nil, err.`) is a
real comment and stays.

**4. `_build/casts_test.tl` — reword the fixture test and add the case
that proves the fix.** Rename
`test_count_reads_justification_comments` to
`test_count_reads_as_tokens_not_their_justifications`, updating its
call line and its comment above. The existing `both.tl` fixture keeps
asserting 2 (both of its lines carry a real `as`; only the reason for the
number changes). Add one more fixture file, `cosmic/quoted.tl`, written
beside `both.tl` and `none.tl`:

```teal
  local quoted = table.concat({
      "local s = \"local a = x as {string} -- cast: from any\"",
      "-- cast: a reason with no cast under it",
      "local b = 1",
      "print(s, b)",
    }, "\n") .. "\n"
```

with the assertion

```teal
  assert(got["cosmic/quoted.tl"] == nil,
    "a cast quoted in a string, and a reason with no cast, are not counted")
```

Measured: `wc -l < _build/casts_test.tl` is 93 — 407 lines of headroom.

**5. `_build/casts_baseline.tl` — regenerate.** Run exactly the command
the gate's failure message prints,
`bin/cosmic --make run _build/casts.tl --baseline`, and commit the result.
Read the diff before committing: only the four rows in `Acceptance` may
move. This is a ratchet the change legitimately lowers; re-baseline it
with that command and never weaken the gate any other way. If the
coverage gate also asks on the day, run the command IT prints and commit
that too.

## Non-goals

- **No new lint for an orphaned justification.** `cosmic/compress.tl`'s
  two stale comments are deleted here, but nothing is added to stop the
  next one appearing — a `-- cast:` reason with no cast under it is a
  second, independent check with its own diagnostic and its own fixtures.
  Captured as board item `3IPFx8zM`; do not implement it in this diff.
- **`_cli/lint.tl`'s behaviour does not move.** `cast_lines`,
  `is_justified` and `check_cast_justification` are untouched; the only
  edit to that file is the two lines that export an existing local. No
  file's lint result may change.
- **The floor's format does not move.** `_build/casts_baseline.tl` stays
  one sorted `["path"] = count` entry per line, written and read through
  `_tool.floor`; `casts.baseline`, `casts.BASELINE` and `casts.TREES` keep
  their current signatures, because `_build/size.tl` requires this module.
- **Do not re-scope which trees are counted.** `TREES` and the
  `testdata/` skip stay exactly as they are; this slice changes what
  counts as a cast, not where the count looks.
- **Do not touch the sites the census now stops counting.** Beyond the
  two comment lines in `cosmic/compress.tl` named in `Change` 3, the
  quoted examples in `_build/casts_test.tl`, `_cli/lint.tl` and
  `_build/casts.tl`'s header are correct documentation and stay as they
  are.
- **Do not rewrite `docs/design/casts.md`.** It is a dated census against
  `d3e59de7`; correcting it is separate work, and this slice changes the
  instrument, not the record.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/casts_test.tl` ends `test: PASS (1 file)`
  and reports 3 test functions (today 2).
- `bin/cosmic --make run _build/casts.tl --baseline` prints
  `casts: wrote _build/casts_baseline.tl — 356 casts in 116 files`
  (today `363 casts in 119 files`).
- `grep -n '"_build/casts.tl"\|"_build/casts_test.tl"\|"_cli/lint.tl"\|"cosmic/compress.tl"' _build/casts_baseline.tl`
  shows `["_build/casts.tl"] = 1` and NO row for the other three
  (today all four are rows of `2`).
- `grep -c "cast_lines" _cli/lint.tl` reports `4` (today `2`).
- `grep -c "in_text" _build/casts.tl` reports `0` (today `3`).
- `grep -c -- "-- cast: " cosmic/compress.tl` reports `0` (today `2`).
- `wc -l _cli/lint.tl _build/casts.tl _build/casts_test.tl` reports each
  under the 500-line cap (today `455`, `157`, `93`).
- `bin/cosmic --check lint _build/casts.tl _build/casts_test.tl _cli/lint.tl cosmic/compress.tl`
  prints `Style check passed` for each — the census change must not move
  any file's lint result.

## Enablement

Blocked on `3IOK542Q` (PR #1373), mirrored in `blocked_by`. Both slices
regenerate `_build/casts_baseline.tl`, so landing them in parallel
guarantees a conflict in that generated file; landing this one second
makes its regen a clean rewrite. The four rows this slice moves are in
files `3IOK542Q` does not touch, so the per-row figures in `Acceptance`
hold either way — only the totals depend on `3IOK542Q` having landed.

Otherwise none needed. Every fact above was measured 2026-08-25 against
`1dc5aa14` plus `3IOK542Q`'s diff, with:

- the phantom-count census: a walk of `casts.TREES` counting
  `tl.lex` `as` tokens per file beside `casts.count(".")`, which
  reported `lex total=356 files=116 ; grep total=363 files=119` and named
  the four differing files
- `grep -n -- "-- cast: " <file>` on each of those four
- `wc -l` on each file named in `Change`

The mechanism the fix needs already exists and is already tested
(`cast_lines` is exercised through `check_cast_justification` on every
lint run), so this is a two-line export and a one-line call site, not new
machinery.
