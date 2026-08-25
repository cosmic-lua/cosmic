Close the decoded-data shaping `from any` casts in non-test code by
running each decoded value through the validating decode this item's
blocker delivers.

Measured 2026-08-25 against `5cd43b78` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

| file | sites | shape |
| --- | --- | --- |
| _eval/score.tl | 10 | 9 consecutive field lifts off one decoded meta table into `eval_types.ResultMeta` (`:194`-`:202`) plus one optional field (`:205`); `REQUIRED_META_FIELDS` above it is a hand-rolled presence check the validator subsumes |
| _eval/stage.tl | 8 | `raw.version`, `raw.tasks`, then per-task `id`/`brief`/`surfaces`/`metrics`/`status` (`:114`-`:135`) |
| _tool/coverage/report.tl | 2 | `pcall(chunk)` result to `{string: any}` then `hits` to `{string: {integer: integer}}` (`:227`, `:235`) |
| _build/size.tl | 1 | whole decoded report to `Report` (`:179`) |
| _perf/baseline.tl | 1 | `Response:json()` to `{Release}` (`:154`) |
| _perf/compare.tl | 1 | whole decoded file to `pt.Results` (`:41`), followed by a hand-rolled `results.results == nil` presence check |
| **total** | **23** | |

`_eval/stage.tl` carries a ninth `from any` cast at `:239`
(`pcall(require, "cosmic._version")`) that is NOT in this class — it is
the dynamic-value boundary, owned by a different item under the same
parent, and must not be touched here.

The records to validate into already exist (`eval_types.ResultMeta`,
`pt.Results`, `_build/size.tl`'s `Report`), so this is a call-shape
change per site plus the deletion of each hand-rolled presence check
the validator now performs.

Non-goals to carry forward: no test files (the sibling item owns
those), no change to any of these modules' own public return
contracts, and no widening of what the affected loaders accept.

The diff must lower the affected rows in `_build/casts_baseline.tl` —
run exactly the regen command the gate prints and commit the result.
