## Goal

G3 — an honest type layer. The parent (`3IOK2K7z`) closes the
decoded-data shaping `from any` bucket; the non-test half is
`3IOeg86u`. This is the test half's larger, mechanical part: **21 sites
in 6 files where the test already knows the shape it decoded**, so the
cast is either redundant, a wrong-call-choice, or a validating decode
waiting to happen. The 17 sites whose SUBJECT is the dynamic decode are
the sibling slice, and this one must not touch them.

## Evidence

Measured 2026-08-25 against `e7ac1580`, with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`. The
counts are unchanged from the parent's `5cd43b78` measurement.

| file | sites | lines |
| --- | --- | --- |
| `_eval/score_test.tl` | 12 | 39, 91, 99, 111, 135, 139, 147, 161, 180, 193, 206, 218 |
| `_eval/stage_test.tl` | 3 | 77, 95, 96 |
| `_make/pin_test.tl` | 2 | 51, 52 |
| `cosmic/teal_config_test.tl` | 2 | 15, 30 |
| `_tool/doc/index_test.tl` | 1 | 38 |
| `cosmic/fetch/verbs_test.tl` | 1 | 205 |
| **total** | **21** | |

**The decode entry points.** `cosmic/json.tl:188-190` declares:

```text
  decode: function(str: string, opts?: DecodeOptions): any, string
  decode_object: function(str: string): {string: any} | nil, string
  decode_array: function(str: string): {any} | nil, string
```

so `check.must(json.decode_object(body))` is already `{string: any}` and
needs no cast, while `check.must(json.decode(body))` is `any` and does.
That is the whole of the two smallest fixes:

- `_eval/score_test.tl:39` — `return check.must(json.decode_object(body))
  as {string: any}` casts what `check.must` already yields. The cast
  deletes with no other change.
- `_eval/stage_test.tl:77` and `:95` — `local meta =
  check.must(json.decode(body)) as {string: any}` becomes
  `check.must(json.decode_object(body))`, and the cast deletes.

**`_eval/score_test.tl`'s other 11 sites are one fix, not eleven.**
They are all downstream reads off the `{string: any}` that
`read_results` (`:37-40`) returns — `results.rows as {{string: any}}`,
`row.silent_bugs as number`, `results.meta as {string: any}`,
`row.task as string`. The record they should be reading already exists:
`eval_types.EvalResults` (`_eval/eval_types.tl:154-163`) declares
`meta: ResultMeta`, `rows: {Row}` and `verdict: string`, over `Row`
(`:99-147`) and `ResultMeta` (`:77-96`). Give `read_results` that
return type, validate into it once, and every downstream read is an
ordinary typed read.

`Row`'s journal-derived fields are documented NULLABLE in v1 —
`checker_errors`, `cycles`, `gate_adopted`, `denials`,
`denial_recovery_steps`, `self_report_clean` are "left nil rather than
guessed" — so a Spec that demands them would reject the results.json
score.tl actually writes.

**`cosmic.shape`'s call shapes** (`cosmic/shape.tl:9-19`): three infer
`T` and one does not. In a test the working shape is an ANNOTATED
local — `local m: Meta = check.must(shape.into(raw, SPEC))`. Bare
`local m = check.must(shape.into(...))` fails with "cannot infer
declaration type".

**The remaining four sites**, each a small known shape:
`_eval/stage_test.tl:96` (`meta.bin_sha as string`),
`_make/pin_test.tl:51-52` (`got.platforms`, then `plat["*"]`),
`cosmic/teal_config_test.tl:15` (a `chunk()` result) and `:30`
(`cfg.include_dir as {string}`), `_tool/doc/index_test.tl:38`
(`(data as DecodedIndex).modules`, inside a `decoded_modules` helper
every test below it uses), and `cosmic/fetch/verbs_test.tl:205`
(`(v as {string: any}).answer` off `r:json()`).

**`is` narrows a decoded `any`** — probe-verified 2026-08-25, type-checks
clean and runs: `assert(d is {string: any})` then `d.a`;
`assert(d is {number})` then `d[1] + 1`; `assert(d is {any})` then `#d`;
`assert(d is string)` then `d:upper()`. Note the first case yields
`any` for the field, so a NESTED read needs a second step — which is
why the multi-level sites want a validating decode rather than a chain
of `is`.

**Headroom** (`wc -l`, 500-line cap): `_eval/score_test.tl` 279,
`_eval/stage_test.tl` 147, `_make/pin_test.tl` 458,
`cosmic/teal_config_test.tl` 102, `_tool/doc/index_test.tl` 432,
`cosmic/fetch/verbs_test.tl` 251. `_make/pin_test.tl` and
`_tool/doc/index_test.tl` are the tight ones: 42 and 68 lines of
headroom, so a Spec added to either must be compact or the fix there
must be `is` narrowing instead.

**The ratchet.** `_build/casts.tl` counts every `as` token per file and
gates it against `_build/casts_baseline.tl`. Today's rows for these six
files: `_eval/score_test.tl` 12, `_eval/stage_test.tl` 3,
`_make/pin_test.tl` 2, `cosmic/teal_config_test.tl` 2,
`_tool/doc/index_test.tl` 1, `cosmic/fetch/verbs_test.tl` 1.

## Change

Per site, in this order of preference: delete a redundant cast, change
the call so the type arrives typed, validate into a declared record, or
narrow with `is`. Never leave a cast whose reason is still `from any`.

1. **`_eval/score_test.tl`** — declare a `RESULTS_SPEC` in the test
   mirroring `eval_types.EvalResults`, with every field `Row` documents
   as nullable in v1 marked `shape.optional`. Change `read_results`
   (`:37-40`) to return `eval_types.EvalResults`:

   ```text
   local results: eval_types.EvalResults =
     check.must(shape.into(check.must(json.decode_object(body)), RESULTS_SPEC))
   ```

   Then delete all 12 casts: the downstream `results.rows`,
   `results.meta`, `row.task` and `row.silent_bugs` reads become
   ordinary typed reads. Put the Spec in the TEST, not in
   `_eval/eval_types.tl`: that module is types-only, score.tl
   constructs the record rather than parsing it, and nothing else in
   the tree reads results.json.

2. **`_eval/stage_test.tl`** — `:77` and `:95` switch to
   `json.decode_object`; `:96` (`meta.bin_sha as string`) copies the
   field to a local and narrows it with `assert(sha is string, …)`.

3. **`_make/pin_test.tl`**, **`cosmic/teal_config_test.tl`**,
   **`_tool/doc/index_test.tl`**, **`cosmic/fetch/verbs_test.tl`** — one
   or two sites each. Use `is` narrowing where the read is one level
   deep, and a compact Spec where it is not. `_tool/doc/index_test.tl`'s
   `decoded_modules` helper is the single funnel for that file, so
   whatever it becomes fixes the file.

Then rewrite the ratchet floor with exactly the command the gate
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and
commit the result. Never hand-edit `_build/casts_baseline.tl`.

## Non-goals

- **Do not touch `cosmic/json_test.tl` or `cosmic/literal_test.tl`.**
  Their 17 sites are the sibling slice: there the decode is the
  SUBJECT, and replacing `decode` with `decode_object` or validating
  into a record changes what is under test.
- **Do not touch a non-test file.** `3IOeg86u` owns those.
- **Do not change what any of these tests assert.** A narrowing
  `assert(d is …)` may be ADDED — it makes the test stricter — but no
  existing assertion is weakened, reworded to fit a type, or deleted.
- **Do not change `cosmic/shape.tl`**, its test or its example.
- **Do not add a field to `eval_types.Row` or `EvalResults`**, and do
  not make a nullable field non-nullable to simplify a Spec.
- **No new `as` cast and no new `-- cast:` line anywhere in the diff.**

## Acceptance

All commands run verbatim from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The 21 sites are gone.**

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports exactly **21 fewer** than it did at pull. Re-measure at pull
  and quote both numbers: the bucket is 165 at `e7ac1580`, so this
  slice ends at 144 if it lands before `3IOeg86u` (PR #1378, which
  removes a disjoint 21) and at 123 if it lands after. And

  ```
  grep -c -- "-- cast: " _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl
  ```

  reports `0` for each of the six.

- **The sibling's files are untouched.**

  ```
  grep -c -- "-- cast: .*from any" cosmic/json_test.tl cosmic/literal_test.tl
  ```

  still reports **10** and **7**, and
  `git diff --name-only origin/main...HEAD` names neither.

- **The floor was regenerated, not edited.** After
  `bin/cosmic --make run _build/casts.tl --baseline`,
  `bin/cosmic --make test _build/casts_test.tl` ends `test: PASS`, and
  the six rows above are gone from `_build/casts_baseline.tl` (a file
  missing from the floor reads as having had none).

- **The tests still test what they tested.**

  ```
  bin/cosmic --make test _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl
  ```

  ends `test: PASS (6 files)`, and no file loses an assertion:

  ```
  grep -c 'assert(' _eval/score_test.tl _eval/stage_test.tl \
    _make/pin_test.tl cosmic/teal_config_test.tl \
    _tool/doc/index_test.tl cosmic/fetch/verbs_test.tl
  ```

  reports at least **43, 24, 86, 10, 42, 44** respectively — the counts
  at `e7ac1580`. Rewriting `assert((row.silent_bugs as number) == 0, …)`
  to `assert(row.silent_bugs == 0, …)` keeps the count; deleting an
  assertion to make a cast disappear does not, which is what this
  catches.

- **No cast was added.**

  ```
  git diff origin/main...HEAD | grep -c '^+.*-- cast:'
  ```

  reports `0`.

- **The file cap still holds** for the two tight files:

  ```
  wc -l _make/pin_test.tl _tool/doc/index_test.tl
  ```

  each ≤ **500**.

## Enablement

No blocker. `cosmic.shape` landed (`3IOefXSz`, PR #1370): its module
doc names the three call shapes that infer `T` and the one that does
not, and `cosmic/shape_example.tl` is a runnable worked example. `is`
narrowing over a decoded `any` is probe-verified above.
`eval_types.EvalResults` already exists, so no new record is needed.

One thing to know at pull: **`3IOeg86u` (PR #1378) is in flight and
touches `_build/casts_baseline.tl` and adds one test to
`_eval/score_test.tl`.** Neither is a blocker — the floor conflict
resolves by re-running the regen command after merging the base, and
that added test carries no cast — but merge the base before
regenerating, or the floor will be written against a stale tree.

Conventions are AGENTS.md; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.
