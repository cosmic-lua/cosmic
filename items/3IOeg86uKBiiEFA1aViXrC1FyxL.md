## Goal

G3 — an honest type layer, no escape hatches. The parent
(`3IOK2K7z`) is "close the decoded-data shaping `from any` sites with a
validating decode"; the mechanism it needed landed as `cosmic.shape`
(blocker `3IOefXSz`, PR #1370, accepted). This slice spends that
mechanism on the non-test half: 21 casts in 5 files become five
declared Specs, and two hand-rolled presence checks the validator
subsumes are deleted.

## Evidence

Measured 2026-08-25 against `e7ac1580`.

The whole `from any` bucket is 165 sites
(`git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l`).
The non-test decoded-data-shaping sites, per file
(`grep -n -- "-- cast: .*from any" <file>`):

| file | sites | lines | shape |
| --- | --- | --- | --- |
| `_eval/score.tl` | 10 | 194–202, 205 | nine field lifts off decoded `meta.json` into `eval_types.ResultMeta`, plus optional `cosmic_version` |
| `_eval/stage.tl` | 8 | 114, 118, 125, 126, 132–135 | `raw.version`, `raw.tasks`, then per-task `id`/`brief`/`surfaces`/`metrics`/`status` |
| `_build/size.tl` | 1 | 179 | whole decoded report to `Report` |
| `_perf/baseline.tl` | 1 | 154 | `Response:json()` to `{Release}` |
| `_perf/compare.tl` | 1 | 41 | whole decoded file to `pt.Results` |
| **total** | **21** | | |

`_eval/stage.tl` carries a ninth `from any` cast at `:239`
(`local v = version as {string: string}`, from
`pcall(require, "cosmic._version")`). It is the dynamic-value boundary,
owned by a different item under the same parent, and is not touched
here.

**`_tool/coverage/report.tl` is excluded, and its 2 sites (`:227`,
`:235`) stay.** They shape `{string: {integer: integer}}` — a
file-path map of sparse line-number-keyed hit counts — and
`cosmic.shape` cannot express that: `shape.map` refuses a non-string
key (`cosmic/shape.tl:179`) and `shape.list` refuses keys that are not
dense `1..n` (`:164`). The missing combinator is filed
separately; closing those two sites is that item's work, not this one's.

**The target records already exist and are small enough to spec
field-for-field**: `eval_types.ResultMeta` (`_eval/eval_types.tl:77-96`),
`eval_types.Task` (`:11`), `_build/size.tl`'s `Report` (`:36-45`) over
`TreeStats` (`:30-33`), `_perf/baseline.tl`'s `Release` (`:42-48`) over
`Asset` (`:34-37`), and `perf_types.Results` (`_perf/perf_types.tl:66-69`)
over `Meta` (`:48-63`) and `Measurement` (`:34-45`).

**Two loaders under-declare their nil**, which blocks `into`'s
inference and is a lie besides:

```text
_perf/compare.tl:32   local function load_results(path: string): pt.Results, string
_perf/baseline.tl:130 local function list_releases(repo: string): {Release}, string
```

Both `return nil, msg` on failure. `shape.into` returns `T | nil,
string` and infers `T` from the caller's annotation only when that
annotation admits nil (`cosmic/shape.tl:9-19`), so both signatures must
widen. `load_results` is re-exported in `_perf/compare.tl`'s module
record at `:274` and that copy must move with it. Callers, all of which
already capture the error slot or use `check.must`:
`_perf/run.tl:310` and `:315`, `_perf/gate_test.tl:94`,
`_perf/compare_test.tl:163` and `:171`, and `_perf/baseline.tl:193`
(`grep -rn "load_results\|list_releases" _perf/`).

**Headroom** (`wc -l`, 500-line cap): `_eval/score.tl` 434,
`_eval/stage.tl` 379, `_build/size.tl` 294, `_perf/baseline.tl` 237,
`_perf/compare.tl` 293. Each Spec is a `<const>` table of roughly one
line per field, so `_eval/score.tl` — the tightest, at 66 lines of
headroom for a ten-field Spec that also deletes a four-line
`REQUIRED_META_FIELDS` table and its five-line loop — has room.

**The two hand-rolled checks the validator subsumes**:
`_eval/score.tl:167-170` (`REQUIRED_META_FIELDS`) with its loop at
`:188-192`, and `_perf/compare.tl:42-44` (`if results.results == nil`).

**The ratchet.** `_build/casts.tl` counts every `as` token per file
through `_cli.lint`'s scanner and gates it against
`_build/casts_baseline.tl`. Today's rows for the five files:
`_build/size.tl` 1, `_eval/score.tl` 10, `_eval/stage.tl` 9,
`_perf/baseline.tl` 1, `_perf/compare.tl` 1
(`grep -n '"_eval/score.tl"' _build/casts_baseline.tl` and siblings).

## Change

In each of the five files, declare a module-level `<const>` Spec beside
the record it validates into and replace the cast sites with one
`shape.into` call.

1. **`_eval/score.tl`** — add `local shape = require("cosmic.shape")`
   and a `META_SPEC` naming the nine required fields with their
   `eval_types.ResultMeta` types (`timestamp` number, `suite_version`
   integer, `bin`/`bin_sha`/`os`/`isa`/`model`/`agent_tool` string,
   `timeout_secs` integer) plus `cosmic_version =
   shape.optional(shape.string)`. `load_meta` becomes
   `return shape.into(raw, META_SPEC)` after the decode. Delete
   `REQUIRED_META_FIELDS` and its loop.

   `into` returns the SAME table, so `load_meta` now yields the decoded
   `meta.json` table rather than a fresh nine-field one. Both leave
   `probe_output` and `leaked` unset — `fold_probe` fills them — and
   nothing iterates the record's keys
   (`grep -n "pairs(meta)" _eval/score.tl` reports nothing), so the
   extra keys a payload may carry are inert. Say so in a comment at the
   Spec.

2. **`_eval/stage.tl`** — the manifest's `surfaces` and `metrics` are
   CSV STRINGS that `split_csv` turns into `{string}`, so the Spec
   validates the raw shape, not `eval_types.Task`. Declare a local
   `record RawTask { id, brief, surfaces, metrics, status: string }` and
   `record RawManifest { version: integer; tasks: {string: RawTask} }`,
   with `surfaces`/`metrics`/`status` optional (today's `rt.surfaces as
   string or ""` admits absence). `load_manifest` validates once into
   `RawManifest`, then builds each `eval_types.Task` from typed reads,
   keeping the existing `tasks[tostring(i)]` walk and the two
   `return nil, path .. ": …"` messages for an empty id and a
   task-less suite.

3. **`_build/size.tl`** — `REPORT_SPEC` mirroring `Report`: `trees =
   shape.map(shape.record({tl_files = shape.integer, lines =
   shape.integer}))`, `agents_md_lines` and `public_modules` integer,
   `binary_bytes = shape.optional(shape.integer)`. `load_report`
   becomes `return shape.into(decoded, REPORT_SPEC)`.

4. **`_perf/baseline.tl`** — `RELEASES_SPEC = shape.list(shape.record({
   tag_name = shape.string, created_at = shape.string, draft =
   shape.boolean, prerelease = shape.boolean, assets =
   shape.list(shape.record({name = shape.string,
   browser_download_url = shape.string})) }))`. Widen `list_releases`
   to `{Release} | nil, string`, update its `@return` comment, and
   `return shape.into(decoded, RELEASES_SPEC)`.

5. **`_perf/compare.tl`** — `RESULTS_SPEC` mirroring
   `perf_types.Results`: `meta` a record of `Meta`'s fields with
   `bin_sha` optional (its own doc says it is absent when the binary
   could not be read), `results` a `shape.list` of `Measurement`'s
   fields with `error` optional (absent on success). Widen
   `load_results` to `pt.Results | nil, string` at `:32` and at `:274`,
   update its `@return` comment, `return shape.into(decoded,
   RESULTS_SPEC)`, and delete the `results.results == nil` check.

Then rewrite the ratchet floor with exactly the command the gate
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and
commit the result. Never hand-edit `_build/casts_baseline.tl`.

## Non-goals

- **No test, example or benchmark file.** The sibling item
  (`3IOegofM`) owns the 38 test-side sites; a diff touching a
  `*_test.tl` beyond what a widened signature forces is scope creep.
  The two signature widenings force nothing: every caller listed in
  `Evidence` already handles the nil slot.
- **Do not touch `_tool/coverage/report.tl`.** Its 2 sites need a
  combinator `cosmic.shape` does not have.
- **Do not touch `_eval/stage.tl:239`.** It is the dynamic-value
  boundary class, another item's work.
- **Do not change `cosmic/shape.tl`**, its tests or its example. The
  mechanism is landed and frozen; if a site cannot be expressed, leave
  the site and file a capture rather than widening the module.
- **Do not widen what any affected loader accepts.** `shape.into`
  ignores keys a Spec does not name, so a payload that grows a field
  still loads; a payload MISSING a field the code reads must still
  fail, with the loader's own path-prefixed message where it has one.
- **Do not change any of these modules' public return contracts**
  beyond the two nil widenings named in `Change`, which make an
  existing runtime nil visible in the type.
- **No new `as` cast and no new `-- cast:` line anywhere in the diff.**

## Acceptance

All commands run verbatim from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The 21 sites are gone and nothing else moved.**

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports **144** (165 today, minus 21).

  ```
  grep -c -- "-- cast: .*from any" _eval/stage.tl
  ```

  reports **1** — the `:239` dynamic-value cast, untouched — and

  ```
  grep -c -- "-- cast: " _eval/score.tl _build/size.tl _perf/baseline.tl _perf/compare.tl
  ```

  reports `0` for each of the four.

  ```
  grep -c -- "-- cast: .*from any" _tool/coverage/report.tl
  ```

  still reports **2**.

- **The floor was regenerated, not edited.** After
  `bin/cosmic --make run _build/casts.tl --baseline`,
  `git diff --name-only origin/main...HEAD` includes
  `_build/casts_baseline.tl`, and

  ```
  bin/cosmic --make test _build/casts_test.tl
  ```

  ends `test: PASS`. `grep -n '"_eval/stage.tl"' _build/casts_baseline.tl`
  reports `= 1` (9 today), and the rows for `_eval/score.tl`,
  `_build/size.tl`, `_perf/baseline.tl` and `_perf/compare.tl` are gone
  (`_build/casts.tl` reads a file missing from the floor as having had
  none).

- **The hand-rolled checks are gone.**

  ```
  grep -c REQUIRED_META_FIELDS _eval/score.tl
  ```

  reports `0` (2 today), and
  `grep -n 'results.results == nil' _perf/compare.tl` reports nothing
  (line 42 today).

- **The validators actually reject.** The existing tests that feed
  garbage to these loaders must still pass, unchanged, and their
  messages must still be the loader's:

  ```
  bin/cosmic --make test _perf/compare_test.tl _build/size_test.tl _eval/score_test.tl _eval/stage_test.tl
  ```

  ends `test: PASS`. `_perf/compare_test.tl:162`
  (`test_load_results_rejects_garbage`) is the one that pins the
  behaviour this change is most likely to break; it is not to be
  edited.

- **The widened signatures are honest and complete.**

  ```
  grep -n 'load_results' _perf/compare.tl
  ```

  shows `pt.Results | nil, string` at both the definition and the
  module record, and

  ```
  grep -n 'list_releases' _perf/baseline.tl
  ```

  shows `{Release} | nil, string`.

- **No cast was added.**

  ```
  git diff origin/main...HEAD | grep -c '^+.*-- cast:'
  ```

  reports `0`.

## Enablement

No blocker. `cosmic.shape` landed (`3IOefXSz`, PR #1370) and is the
whole mechanism: `cosmic/shape.tl`'s module doc names the three call
shapes that infer `T` and the one that does not, and
`cosmic/shape_example.tl` is a runnable worked example. The one shape
this slice found the mechanism cannot express —
`_tool/coverage/report.tl`'s sparse integer-keyed map — is excluded
above and captured as its own item rather than worked around here.
Conventions are AGENTS.md; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.
