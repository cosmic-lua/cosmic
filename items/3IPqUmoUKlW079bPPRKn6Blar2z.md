## Goal

G3 — an honest type layer, no escape hatches. The parent
(`3IOegofM`) holds the 38 decoded-data shaping `from any` casts in test
files; this slice takes the 21 of them whose test does NOT have the
dynamic decode as its subject, so `cosmic.shape` closes them outright.
The sibling slice under the same parent owns the other 17
(`cosmic/json_test.tl`, `cosmic/literal_test.tl`), where the decode
itself is what the test pins and the answer is a judgment per site
rather than a validator.

## Evidence

Re-measured 2026-08-26 against `whilp/cosmic` `fb2587ad` (`main`);
first measured 2026-08-25 at `cd87a765`, and every figure below is the
`fb2587ad` one.

The tree carries 97 `from any` casts of 301 total
(`git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l`
and the same with `-- cast:`) — down from 165 of 364 at `cd87a765`, as
the sibling slices under this epic have landed. The six files this
slice closes, with their site counts (`grep -c -- "-- cast:" <file>`,
which equals the `from any` count in each — these files carry no other
cast) and their lengths (`wc -l`, against the 500-line cap):

| file | sites | lines | headroom |
| --- | --- | --- | --- |
| `_eval/score_test.tl` | 12 | 293 | 207 |
| `_eval/stage_test.tl` | 3 | 147 | 353 |
| `_make/pin_test.tl` | 2 | 458 | **42** |
| `cosmic/teal_config_test.tl` | 2 | 102 | 398 |
| `_tool/doc/index_test.tl` | 1 | 432 | 68 |
| `cosmic/fetch/verbs_test.tl` | 1 | 251 | 249 |
| **total** | **21** | | |

None of the six site counts moved between `cd87a765` and `fb2587ad`;
only `_eval/score_test.tl`'s length did (279 → 293).

`_make/pin_test.tl` has the least room and needs the least: one
four-line Spec. Nothing here adds a Spec longer than the twelve-field
one in `_eval/score_test.tl`, whose file has 207 lines spare.

**The mechanism exists.** `cosmic/shape.tl` (318 lines, landed as
blocker `3IOefXSz`, PR #1370) validates a decoded value against a Spec
and hands it back typed. Its contract, from its module doc comment:
extra keys the Spec does not name are IGNORED; a missing key and a JSON
`null` are the same thing and `shape.optional` admits either; nothing
is coerced; the target type comes from the CALLER's annotation, and
`local m = check.must(shape.into(raw, SPEC))` is the one shape that
fails to infer — a helper declared `T | nil, string` returning
`shape.into(...)` directly is the shape that works.

**Probe-verified at refinement, and re-verified 2026-08-26 against a
`--make build` of `fb2587ad`.** A scratch file (written outside the
committed tree, type-checked with `o/bin/cosmic --check types`, then
deleted) established the three facts this slice turns on. `shape.tl`
gained `shape.integer_map` between the two runs (PR #1388); `into`'s
signature did not move, so all three facts stand unchanged:

- A helper declared `function(body: string): eval_types.EvalResults |
  nil, string` whose body ends `return shape.into(raw, RESULTS)`
  type-checks, and `check.must(read_results(...))` at the call site
  yields a plain `EvalResults` with no annotation and no cast.
- Under it, `by_task[row.task] = row` needs NO cast (`row.task` is
  `string`), `found.silent_bugs >= 1` compiles (it is `integer`), and
  `by_task["text-report"].attempts_first_build == nil` compiles.
- A Spec of `shape.map(shape.any)` validated into a record field
  declared `{string: any}` keeps a DYNAMIC index legal —
  `meta[field] ~= nil` where `field` is a loop variable — and
  `meta.leaked == false` and `row.silent_bugs == 0` compile, because
  `==` accepts `any` on one side. **`>=` does not**: the probe's first
  form failed with
  `error: cannot use operator '>=' for types <any type> and integer`.
  That one line is why `_eval/score_test.tl` needs two readers rather
  than one, and it is stated here so a session does not rediscover it.

**Two tests read fields by dynamic name, and that is their subject.**
`_eval/score_test.tl`'s `test_every_meta_field_is_present` (`:155`) and
`test_every_row_field_is_present` (`:174`), and `_eval/stage_test.tl`'s
`test_meta_json_has_all_ten_fields` (`:75`), each walk a `want` list of
field names and assert `meta[field] ~= nil`. Validating those into
`eval_types.ResultMeta` would make the presence walk uncompilable and
delete the assertion, which `Non-goals` forbids. The map-shaped reader
above is what keeps them exactly as they are while removing the cast.

**The target records already exist**, so no new record type is written
for the eval files: `eval_types.EvalResults` (`_eval/eval_types.tl:154`)
over `ResultMeta` (`:77`) and `Row` (`:99`), and `eval_types.Meta`
(`:46`). `Row`'s nullable fields — `checker_errors`, `cycles`,
`attempts_first_build`, `attempts_green_ci`, `gate_adopted`, `denials`,
`denial_recovery_steps`, `self_report_clean` — and `ResultMeta`'s
`cosmic_version` are `shape.optional`; the probe above used exactly
that Spec and passed.

**The other four sites' shapes**:

- `_make/pin_test.tl:51`–`:52` read `got.platforms` then `plat["*"]`
  then `star.sha`, where `got` comes from
  `ext(source): {string: any} | nil, string` (`:30`, wrapping
  `pin.extract`). Equality is the only use.
- `cosmic/teal_config_test.tl:15` casts `chunk()` from `loadfile("tlconfig.lua")`;
  `:30` reads `cfg.include_dir` and `ipairs`es it, so that field must
  come back `{string}`, not `any`.
- `_tool/doc/index_test.tl:38` already casts into a declared local
  record: `return (data as DecodedIndex).modules` inside
  `decoded_modules(data: any): {string: ModuleDoc}` (`:37`).
  `DecodedIndex` (`:28`) has one field, `modules: {string: ModuleDoc}`.
- `cosmic/fetch/verbs_test.tl:205` asserts
  `(v as {string: any}).answer == 42` on `r:json()`, one field, equality
  only.

**The ratchet.** `_build/casts.tl` counts every `as` token per file
through `_cli.lint`'s scanner and gates it against
`_build/casts_baseline.tl`. Today's rows for the six files are exactly
the site counts above (`grep -n '"_eval/score_test.tl"'
_build/casts_baseline.tl` and siblings: at `fb2587ad` they sit on
lines 6, 7, 12, 25, 49 and 103 — the file is alphabetical and every
landing shifts them, so find each row by name, never by line).
A file with no casts left drops OUT of the baseline rather than going
to zero — `_build/casts_test.tl:48` reports `"%s: no casts left
(baseline %d)"` and the regen command is the one the failure prints:
`bin/cosmic --make run _build/casts.tl --baseline`.

## Change

In each of the six files, replace the cast sites with one
`shape.into` call behind a helper whose declared return type is the
record being validated into. Add `local shape = require("cosmic.shape")`
to each file that does not already require it.

1. **`_eval/score_test.tl`** (12 sites) — two readers, because the file
   has both kinds of test.

   Declare two module-level `<const>` Specs and keep the existing
   `read_results` name for the strict one:

   - `RESULTS` = `shape.record({meta = META, rows = shape.list(ROW),
     verdict = shape.string})`, where `META` and `ROW` mirror
     `eval_types.ResultMeta` and `eval_types.Row` field for field, with
     the nine nullable fields named in `Evidence` wrapped in
     `shape.optional`. `read_results(path: string):
     eval_types.EvalResults | nil, string` reads the file, calls
     `json.decode_object`, and returns `shape.into(raw, RESULTS)`.
   - `RAW_RESULTS` = `shape.record({meta = shape.map(shape.any), rows =
     shape.list(shape.map(shape.any)), verdict = shape.string})`
     validated into a file-local `record RawResults` with fields
     `meta: {string: any}`, `rows: {{string: any}}`, `verdict: string`.
     `read_results_object(path: string): RawResults | nil, string` is
     the second reader.

   Callers become `local results = check.must(read_results(out))` — no
   annotation needed, per the probe. `read_results_object` is used by
   `test_every_meta_field_is_present` and
   `test_every_row_field_is_present` and by nothing else; every other
   test uses `read_results`. Then delete each cast: `results.rows`,
   `results.meta`, `row.silent_bugs`, `found.silent_bugs` and
   `row.task` are all typed reads under whichever reader that test
   holds, and `by_task` is declared `{string: eval_types.Row}`.

2. **`_eval/stage_test.tl`** (3 sites) — the same two-reader split, one
   test each. Add a `META` Spec mirroring `eval_types.Meta`'s ten
   fields (`cosmic_version` optional) and a
   `read_meta(path: string): eval_types.Meta | nil, string`, used by
   `test_bin_sha_matches_independent_digest` (`:92`) so `meta.bin_sha`
   is a `string` and `#sha` compiles; and a map-shaped
   `read_meta_object` for `test_meta_json_has_all_ten_fields` (`:75`),
   whose presence walk stays exactly as written.

3. **`_make/pin_test.tl`** (2 sites) — declare
   `record Platform sha: string end` and
   `record ExtractedPin platforms: {string: Platform} end` local to the
   file, with `PIN <const> = shape.record({platforms =
   shape.map(shape.record({sha = shape.string}))})`, and read
   `check.must(shape.into(got, PIN))` into a local declared
   `ExtractedPin | nil, string` in `test_extracts_a_literal`. The three
   assertions above it (`got.url`, `got.version`, ...) read
   `{string: any}` off `ext`'s own return and are untouched.

4. **`cosmic/teal_config_test.tl`** (2 sites) — declare
   `record TlConfig gen_target: string; gen_compat: string;
   include_dir: {string} end` and `CONFIG <const> =
   shape.record({gen_target = shape.string, gen_compat = shape.string,
   include_dir = shape.list(shape.string)})`. Bind `local raw = chunk()`
   first — `chunk` is `loadfile`'s `function(...: any): any...` and
   passing the call directly into `shape.into` would carry its whole
   return tuple — then validate. `cfg.include_dir` becomes a typed
   `{string}` and the `ipairs` below it is unchanged.

5. **`_tool/doc/index_test.tl`** (1 site) — `decoded_modules` keeps its
   signature and body becomes a `shape.into(data, INDEX)` where
   `INDEX <const> = shape.record({modules = shape.map(MODULE_DOC)})` and
   `MODULE_DOC` mirrors the existing `ModuleDoc` record. Reword the
   helper's doc comment: it no longer says the cast is kept "here so
   every test below reads a `{string: ModuleDoc}` without repeating it",
   because there is no cast.

6. **`cosmic/fetch/verbs_test.tl`** (1 site) — in `test_result_json`,
   declare `record JsonBody answer: integer end` and
   `BODY <const> = shape.record({answer = shape.integer})`, bind
   `local body, berr: JsonBody | nil, string = shape.into(v, BODY)`,
   assert on it, and delete the bare `-- cast: from any` comment line
   above the assertion.

Then run `bin/cosmic --make run _build/casts.tl --baseline` — the exact
command the gate's failure prints — and commit the rewritten
`_build/casts_baseline.tl`, in which all six rows are gone.

## Non-goals

- **Do not change what any test asserts.** Every existing `assert` keeps
  its condition and its message. The two presence-walk tests in
  `_eval/score_test.tl` and the one in `_eval/stage_test.tl` keep their
  `want` lists and their `meta[field] ~= nil` loops — that is what the
  map-shaped reader is for. A validator that makes an assertion
  redundant is not a licence to delete the assertion.
- **Do not touch `cosmic/json_test.tl` or `cosmic/literal_test.tl`.**
  Those 17 sites are the sibling slice's work.
- **Do not touch any non-test file.** In particular `_eval/score.tl`,
  `_eval/stage.tl`, `_eval/eval_types.tl` and `cosmic/shape.tl` are
  unmoved. `3IOeg86u` has since landed over the first two (PR #1378),
  so this is no longer a race — it is the slice boundary: the non-test
  half of the epic is done and this half touches only `*_test.tl`.
- **Do not change `cosmic.shape`'s contract or add a combinator.** If a
  site needs a shape `cosmic.shape` cannot express, leave that site's
  cast in place, say so in the PR, and file it — do not widen the
  module.
- **Do not add a cast.** This diff removes 21 and adds none. A site that
  will not close keeps its existing `-- cast:` line unedited.
- **Do not edit `_build/casts_baseline.tl` by hand.** Run the regen
  command the gate prints and commit its output.
- **Do not weaken a gate.** No `.cosmicignore` entry, no coverage
  exclusion, no lint suppression.
- **Do not touch `whilp/cosmopolitan`.**

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root and write
into no committed file.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The 21 sites are gone and no cast replaced them.**

  ```
  grep -c -- "-- cast:" _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl
  ```

  reports `0` for every one of the six. Today the same command reports
  12, 3, 2, 2, 1, 1 (re-measured 2026-08-26 at `fb2587ad`), so it
  discriminates.

- **The tree-wide `from any` count fell by exactly 21.**

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports **76**. It reports 97 at `fb2587ad`. `main` moves fast under
  this epic — the number was 165 on 2026-08-25 — so the check that
  survives is the DELTA: run the command at the branch's merge base and
  at its head, and the difference is 21. Do not treat 76 as the target
  if the merge base is not `fb2587ad`.

- **The ratchet floor was regenerated, not edited.**

  ```
  grep -c -E '"(_eval/score_test|_eval/stage_test|_make/pin_test|cosmic/teal_config_test|_tool/doc/index_test|cosmic/fetch/verbs_test)\.tl"' _build/casts_baseline.tl
  ```

  reports `0` — a file with no casts left drops out of the baseline
  entirely. Today it reports `6`.

- **The sibling slice's files are untouched.**

  ```
  git diff --name-only origin/main...HEAD
  ```

  names exactly the six test files above plus `_build/casts_baseline.tl`,
  and no other path — in particular neither `cosmic/json_test.tl`,
  `cosmic/literal_test.tl`, `cosmic/shape.tl`, nor anything under
  `_eval/` that is not `*_test.tl`.

- **The tests themselves still pass, named individually**, so a green
  `ci` cannot hide a file that stopped being run:

  ```
  bin/cosmic --make test _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl
  ```

  ends `test: PASS (6 files)`.

- **No assertion was dropped.**

  ```
  git diff origin/main...HEAD -- _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl | grep -c '^-.*assert('
  ```

  is `0` except for lines that reappear as `+` with the same condition
  — quote any such pair in the PR description with both sides, so the
  reviewer judges the rewrite rather than the count.

- **Every file stays under the cap.**

  ```
  wc -l _eval/score_test.tl _eval/stage_test.tl _make/pin_test.tl \
    cosmic/teal_config_test.tl _tool/doc/index_test.tl \
    cosmic/fetch/verbs_test.tl
  ```

  reports at most **500** for each. `_make/pin_test.tl` is the tight one
  at 458 today.

## Enablement

No blocker. `cosmic.shape` landed (`3IOefXSz`, PR #1370) and its
contract is stated in its own module doc comment; the three facts a
session would otherwise have to discover by trial — the inferring
helper shape, the dynamic index surviving a `{string: any}` field, and
`>=` refusing `any` — are probe-verified in `Evidence` above with the
exact error text. The records to validate into already exist in
`_eval/eval_types.tl` and in the two test files that declare their own.
Conventions are AGENTS.md; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.

`3IOeg86u` (the non-test half) has landed over `_eval/score.tl` and
`_eval/stage.tl` (PR #1378), so nothing is in flight against these
files. What remains shared with every other slice under this epic is
`_build/casts_baseline.tl`, and a conflict there is the mechanical
regen the landing rule already covers — run the regen command again
after merging `main` and commit the result.
