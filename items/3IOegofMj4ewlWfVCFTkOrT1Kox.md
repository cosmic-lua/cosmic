Close the decoded-data shaping `from any` casts in test files, which
split three ways rather than one.

Measured 2026-08-25 against `5cd43b78` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

| file | sites |
| --- | --- |
| _eval/score_test.tl | 12 |
| cosmic/json_test.tl | 10 |
| cosmic/literal_test.tl | 7 |
| _eval/stage_test.tl | 3 |
| _make/pin_test.tl | 2 |
| cosmic/teal_config_test.tl | 2 |
| _tool/doc/index_test.tl | 1 |
| cosmic/fetch/verbs_test.tl | 1 |
| **total** | **38** |

Three mechanisms, and which applies is a property of the site, not the
file:

1. **A call change alone.** `_eval/stage_test.tl:77` and `:95` cast
   `check.must(json.decode(body))` to `{string: any}`; `json.decode_object`
   returns that type already. `_eval/score_test.tl:39` casts
   `check.must(json.decode_object(body))` to `{string: any}`, which is
   what `check.must` already yields — the cast is redundant and deletes.
2. **The validating decode** (this item's blocker) where the test
   asserts on a shape it knows: `_eval/score_test.tl`'s repeated
   `results.rows`/`results.meta`/`row.silent_bugs` reads,
   `_make/pin_test.tl:51`-`:52`, `cosmic/teal_config_test.tl:15`/`:30`,
   `_tool/doc/index_test.tl:38`, `cosmic/fetch/verbs_test.tl:205`.
3. **Neither.** Some sites are inside tests whose SUBJECT is the
   dynamic decode: `cosmic/json_test.tl:174`-`:208` pin the null
   policy of `json.decode` specifically, and `cosmic/literal_test.tl:143`-`:145`
   walk a deliberately-nested value to prove nesting is accepted.
   Replacing `decode` with `decode_object` there changes what is under
   test, and validating into a record hides the very dynamism being
   asserted. `is {string: any}` narrowing is the available answer, and
   refinement must decide per site whether the honest outcome is a
   narrowing guard or a cast with a truer reason than `from any`.

Refinement should also decide whether the three groups are one slice
or split — group 3 is judgment per site and group 1 is mechanical.

Non-goals to carry forward: no non-test files (the sibling item owns
those), no change to what any of these tests assert, and no weakening
of a null-policy or nesting-limit assertion to make a cast disappear.

The diff must lower the affected rows in `_build/casts_baseline.tl` —
run exactly the regen command the gate prints and commit the result.
