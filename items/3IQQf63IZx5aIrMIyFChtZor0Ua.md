## Goal
G3 — an honest type layer, under `3IOuS3IE`. This is the declaration
half: the eight `from any` casts inside `cosmic.sqlite` and `cosmic.fetch`
that exist because one of OUR OWN signatures says `any` where the value's
type is knowable. Unlike its sibling (the guard half), these do not close
with an `is` at the point of use — they close by making the declaration
state what the value is, which is a change to a public module's contract
and therefore a decision this item must settle before it is ready.

## Change
Three files, eight casts. Measured 2026-08-25 against `47adef2c` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"` and
`grep -c -- "-- cast:" <file>` for the per-file totals the ratchet rows
carry:

| file | `from any` | all casts | lines |
| --- | --- | --- | --- |
| `cosmic/sqlite/bind.tl` | 2 (`:50`, `:52`) | 6 | 142 |
| `cosmic/sqlite/extras.tl` | 4 (`:32`, `:44`, `:60`, `:102`) | 4 | 124 |
| `cosmic/fetch/extras.tl` | 2 (`:273`, `:298`) | 6 | 375 |

What each site is, and the decision it turns on:

- **`cosmic/sqlite/bind.tl:50,52`** — `bind_at(raw_stmt, i, v: any)` routes
  a `blob()` wrapper to `bind_blob` and everything else to `bind`. The
  value is a `Blob` marker or a bindable scalar, so the parameter could
  read `Blob | string | number | boolean | nil`. *Open:* whether a union
  parameter survives its callers — `bind_values(values: {any})` and
  `bind_named` pass elements straight through, and `is_blob(v: any)` is a
  predicate that must keep accepting anything. Refinement enumerates the
  callers (`grep -rn "bind_at\|is_blob" --include='*.tl' .`) and states
  whether the union stops at `bind_at` or has to reach the table types.
- **`cosmic/sqlite/extras.tl:44`** — `attach(db_any: any)` takes the
  `Database` under construction and immediately casts it to a local `Db`.
  The doc comment at `:41–43` says the parameter is `any` so that
  `cosmic.sqlite`'s nominal `Database` record need not be duplicated here.
  *Open:* whether `Database` can be declared in a shared types module both
  files require without re-creating the import cycle that made `any` the
  answer.
- **`cosmic/sqlite/extras.tl:32,60,102`** — `(why as string)` and
  `(verdict as string)`, each reading a `pcall(fn, self)` result. These
  are guard-shaped (`is string`), not declaration-shaped, and are in
  scope here only because they share a file with `:44`: one file is one
  PR, and splitting a file across two slices would collide in review.
- **`cosmic/fetch/extras.tl:273,298`** — `opts_any` and `res_any` inside
  the `verb`/`download` façade. They are `any` because the `Made` record
  (`:262–269`) declares every verb as `function(string, any): any, any`.
  *Open:* whether `Made` can name `fetch`'s real `Options`/`Response`
  records, or whether the façade is built precisely to avoid importing
  them (`cosmic/fetch/init.tl` requires `extras`, so the direction of any
  new import has to be checked before it is written into a spec).

The refinement that takes this item to `ready` settles all four open
questions, names the exact new declaration for each site, and writes the
ratchet rows the way its sibling's spec does — including the
`bin/cosmic --make run _build/casts.tl --baseline` regen, which is the
only permitted way to move the floor.

## Non-goals
- **No behaviour change.** `cosmic.sqlite`'s transaction/savepoint verdict
  strings and `cosmic.fetch`'s response shape are frozen contracts: the
  error strings and return shapes callers see must be byte-identical.
  `cosmic/sqlite/extras_test.tl` and `cosmic/fetch/**_test.tl` pass
  unmodified.
- **Do not touch the guard half's nine files** (`cosmic/quicksand/box/**`,
  `cosmic/doc/query.tl`, `_docs/publish_test.tl`,
  `cosmic/searcher_test.tl`, `_perf/perf_test.tl`, `_perf/run.tl`,
  `cosmic/fs/path_test.tl`, `_perf/harness_test.tl`). The two slices are
  deliberately file-disjoint; only `_build/casts_baseline.tl` is shared.
- **No new public module.** `_build/public_surface_baseline.tl` must not
  move. If a shared types module is the answer for `Database`, it is a
  private `cosmic/sqlite/*` shard, not a new `cosmic.<name>`.
- **Do not touch the other 91 `from any` casts** (99 in the tree today
  across 41 files, by `git ls-files '*.tl' | xargs grep -h -- "-- cast: "
  | grep -c "from any"`; two of them are string literals in
  `_build/casts_test.tl`).

## Acceptance
Provisional — the numeric rows are fixed and re-measured by the
refinement that takes this to `ready`; the shape is settled:
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/sqlite/bind.tl
  cosmic/sqlite/extras.tl cosmic/fetch/extras.tl` prints `0` for each
  (today `2`, `4`, `2`).
- `grep -n '"cosmic/sqlite/bind.tl"\|"cosmic/sqlite/extras.tl"\|"cosmic/fetch/extras.tl"'
  _build/casts_baseline.tl` shows `= 4`, row absent, `= 4` (today `= 6`,
  `= 4`, `= 6`).
- `bin/cosmic --make test cosmic/sqlite cosmic/fetch` — narrowed to the
  test files the refinement names — ends `test: PASS`, with
  `git diff origin/main -- cosmic/sqlite/extras_test.tl` empty.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `wc -l cosmic/fetch/extras.tl` reports at most 500 (today `375`).

## Enablement
none needed to refine: the four open questions are answerable from the
tree with `grep` over the call sites and a read of the two modules'
import direction. The mechanism, once decided, is an ordinary Teal
signature change; `is` narrowing over `any` (AGENTS.md, demonstrated by
PR #1382) covers the three pcall-verdict sites that ride along.
