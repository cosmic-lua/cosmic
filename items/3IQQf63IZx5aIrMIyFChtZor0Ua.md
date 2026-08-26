## Goal
G3 — an honest type layer, under `3IOuS3IE`. The eight `from any` casts
inside `cosmic.sqlite` and `cosmic.fetch`, closed.

**The item's original premise is retired by this refinement.** It was
filed as "the declaration half": the sites whose casts exist because one
of OUR OWN signatures says `any`, closing by making that declaration
honest. Refinement asked each of its four open questions against the tree
and every answer came back the same — **no signature can move, and every
one of the eight closes with an `is` guard at the point of use.** The
evidence is below, question by question. What is left is a second
guard-half slice, disjoint by file from the first (`3IQQeXC3`), and the
`Change` states each site's decided shape rather than deferring it.

## Evidence

Measured 2026-08-26 against `c2ae0466` (`git diff origin/main -- <the
three files>` is empty, so these are main's figures):

| file | `from any` | all casts | lines | baseline row |
| --- | --- | --- | --- | --- |
| `cosmic/sqlite/bind.tl` | 2 (`:50`, `:52`) | 6 | 142 | `= 6` |
| `cosmic/sqlite/extras.tl` | 4 (`:32`, `:44`, `:60`, `:102`) | 4 | 124 | `= 4` |
| `cosmic/fetch/extras.tl` | 2 (`:273`, `:298`) | 6 | 375 | `= 6` |

**Q1 — does a union parameter on `bind_at` survive its callers? No.**
`grep -rn "bind_at\|is_blob" --include='*.tl' .` finds four call sites:
`cosmic/sqlite/bind.tl:64` and `:91`, `cosmic/sqlite/init.tl:172` and
`:187`. Every one passes an element of a `{any}` or of the `table`-typed
`Params`, so a `Blob | string | number | boolean | nil` parameter would
push the cast UP into four call sites instead of removing it. `is_blob(v:
any)` is a public predicate that must keep accepting anything. The
signature stays; both casts close guard-shaped.

**Q2 — can `Database` move to a shared shard so `attach` names it? No,
and it would not help.** `cosmic/sqlite/init.tl:37` requires `extras`,
and `extras` requires only `cosmic.sqlite.bind` — so `extras → init` is
the cycle the `any` was chosen to avoid. A shared shard would have to
carry `Statement`, `Row` and the rest of `Database`'s method types with
it, which is a `cosmic/sqlite` restructuring, not one cast. And it would
not close the cast anyway: Teal records are NOMINAL, so a `Database`
value does not satisfy `extras`'s structural three-method `Db` record
(`:15–19`) however either is declared. `attach` keeps `any` and guards.

**Q3 — can `Made` name `fetch`'s real `Options`/`Response`? No.**
`cosmic/fetch/init.tl:13` requires `cosmic.fetch.extras`; `extras`
requires `cosmo`, `cosmic.url`, `cosmic.stream`, `cosmic.json`,
`cosmic.codec`, `cosmic.rand`, `cosmic.fd`, `cosmic.fs` — and NOT
`init`. Naming init's records in `Made` reverses that edge into a cycle.
The façade's `function(string, any): any, any` shape is load-bearing;
both casts close guard-shaped.

**Q4 — the narrowing forms these closures need, probed against the built
checker at `c2ae0466`.** Four probe functions, each type-checked with
`o/bin/cosmic --check types`:

1. `if v is Blob and getmetatable(v) == blob_mt as any then return
   v.data end` over `v: any` — **passes.** The conjunction narrows, so
   the identity test keeps deciding and the index is legal.
2. `if v is string or v is number or v is boolean then sink(1, v) end`,
   where `sink`'s parameter is `string | number | boolean | nil` —
   **passes.** A disjunctive `is` chain over `any` narrows to the union
   at argument position.
3. The control for (2): `sink(1, v)` on a bare `any` — **fails**,
   `error: argument 2: got <any type>, expected string | number |
   boolean | nil`. So (2)'s pass is real narrowing, not `any` being
   waved through.
4. `assert(x is M, "...")` narrows below itself exactly as an
   `if not (x is M) then error(...) end` guard does — both forms pass,
   so a test may use whichever reads better.

**Q5 — OPEN. `cosmic/sqlite/extras.tl:60` and `:102` are not `any` at
all, and `is string` is refused there.** Found at implementation
2026-08-26 (the bounce below): six of the eight sites closed as this
spec's `Change` describes and type-checked, but `o/bin/cosmic --check
types cosmic/sqlite/extras.tl` rejects the two `verdict` guards with

```
cosmic/sqlite/extras.tl:62:18: warning: verdict (of type boolean) can never be a string
cosmic/sqlite/extras.tl:62:7:  error:   cannot resolve a type for verdict here
```

(and the same pair at `:105`). The cause: `local success, verdict, why =
pcall(fn, self)` types slot 2 from `TxFn`'s declared return
(`local type TxFn = function(any): boolean, string`, `:13`), so
`verdict` is `boolean` to the checker even though in the `not success`
branch it holds the RAISED error at runtime. **The original
`-- cast: from any` reason on those two lines was itself wrong** — the
value is not `any` — which is why the guard-shaped treatment this spec
assumed for them does not apply.

`:32` is unaffected and closed cleanly: `rollback_reason(why: any)`
really is `any`, so `if why is string then return why end` type-checks.

The refinement that takes this item back to `ready` must choose between:

1. **Keep both casts with a truthful reason** (e.g. `-- cast: pcall slot
   2 is the raised error, typed boolean from TxFn`). Closes the
   `from any` count to 0 without pretending the value is `any`; the
   `extras.tl` ratchet row then stays at `= 2`, not absent.
2. **Name the raised value for what it is** — `local raised: any =
   verdict` before the guard, with a comment. Removes both casts but
   launders a `boolean` through `any`, which is the kind of move G3
   exists to discourage; only take it if the comment carries its weight.

Whichever is chosen, the `Change` for `:60`/`:102`, the `extras.tl` row
in the ratchet table, and the `grep -c -- "-- cast:"` acceptance lines
all move with it. The other six sites' shapes are validated and should
be carried forward unchanged.

## Change

Three files, eight casts. Six shapes below are validated by a
type-checked implementation; `:60` and `:102` are blocked on Q5.

**`cosmic/sqlite/bind.tl` (2 casts).**
- `:50` — `if v is Blob and getmetatable(v) == blob_mt as any then
  return raw_stmt:bind_blob(i, v.data) end`. The `is Blob` is only the
  narrowing the `.data` index needs; the metatable identity test still
  decides, so a plain `{data = ...}` table is rejected exactly as today
  (the module header at `:20–21` freezes that). The existing
  `-- cast: metatable identity compare` on `blob_mt as any` is not a
  `from any` cast and is untouched.
- `:52` — guard the whole declared contract of `lsqlite3`'s `bind`
  (`string | number | boolean | nil`, `o/_types/types_gen/cosmo/lsqlite3.d.tl:256`):
  `if v == nil or v is string or v is number or v is boolean then return
  raw_stmt:bind(i, v) end`. **The fallthrough keeps a cast, with the
  truer reason.** Today an out-of-contract `v` (a table, a function)
  reaches the C `bind` and raises; binding NULL instead would silently
  widen exactly the failure `3IOHOiGM` is open about. So the last line
  stays `return raw_stmt:bind(i, v as string)` under
  `-- cast: out-of-contract value, passed through so the binding raises
  as it does today`. `bind.tl` therefore ends at `from any` = 0 and 5
  casts, not 4.

**`cosmic/sqlite/extras.tl` (4 casts).**
- `:44` — `if not (db_any is Db) then return end` at the top of
  `attach`, then use `db_any` directly in place of `db`. One
  `type(x) == "table"` test; the `Database` under construction always
  passes it. The doc comment at `:41–43` explaining why the parameter is
  `any` stays, since Q2 confirms the reason still holds.
- `:32` — in `rollback_reason`, replace `return (why as string) or (what
  .. " rolled back")` with `if why is string then return why end` above
  the existing `return what .. " rolled back"`.
- `:60`, `:102` — **BLOCKED on Q5.** The `is string` guard this spec
  described is refused by the checker: `verdict` is typed `boolean`, not
  `any`. Settle Q5's two options before this slice is pullable again.
  The behaviour question stands under either: today a pcall error value
  that is not a string is returned in slot 2 under a declared `string`,
  and `cosmic/sqlite/extras_test.tl` must pass unmodified (Non-goals),
  which is what pins the string cases.

**`cosmic/fetch/extras.tl` (2 casts).**
- `:273` — in `verb`, replace `if opts_any then` + `pairs(opts_any as
  {string: any})` with `if opts_any is {string: any} then` and a bare
  `pairs(opts_any)`. Nil still skips the copy. **Stated behaviour
  change:** a truthy non-table `opts` used to raise inside `pairs`; it
  is now skipped, and the request goes out with only `method` set.
- `:298` — in `download`, replace `local res = res_any as StreamRes`
  with `if not (res_any is StreamRes) then return fail_make("download:
  stream returned no response") end`, then use `res_any` directly.
  `fail_make(msg: string)` is the module's own failure builder
  (declared `:285`, used at `:305` and `:348`), so the failure shape
  matches the file's existing ones.

**The ratchet.** `_build/casts_baseline.tl` counts every cast in a file,
not only the `from any` ones. Run exactly the command the gate's failure
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and commit
the result. Expected row moves:

| file | row today | row after |
| --- | --- | --- |
| `cosmic/sqlite/bind.tl` | `= 6` | `= 5` |
| `cosmic/sqlite/extras.tl` | `= 4` | row absent |
| `cosmic/fetch/extras.tl` | `= 6` | `= 4` |

A row at zero is absent from the floor by construction — `_build/casts.tl`
emits only files with at least one cast.

## Non-goals
- **No signature moves.** Q1–Q3 settled that none is available:
  `bind_at`, `is_blob`, `attach`, and the `Made` record all keep the
  declarations they have. Do not add a shared `cosmic/sqlite` types
  shard, and do not reverse either module's import direction.
- **No behaviour change beyond the two stated above** (`extras.tl`'s
  non-string pcall error value, and `fetch/extras.tl`'s truthy non-table
  `opts`). `cosmic.sqlite`'s transaction/savepoint verdict strings and
  `cosmic.fetch`'s response shape are frozen: `git diff origin/main --
  cosmic/sqlite/extras_test.tl` is empty and every `cosmic/fetch/*_test.tl`
  passes unmodified. No test file is edited by this slice at all.
- **Do not touch the guard half's nine files** (`cosmic/quicksand/box/**`,
  `cosmic/doc/query.tl`, `_docs/publish_test.tl`, `cosmic/searcher_test.tl`,
  `_perf/perf_test.tl`, `_perf/run.tl`, `cosmic/fs/path_test.tl`,
  `_perf/harness_test.tl`). The two slices are deliberately file-disjoint;
  only `_build/casts_baseline.tl` is shared, and a conflict there is the
  landing's mechanical regen, not a fresh review.
- **No new public module.** `_build/public_surface_baseline.tl` must not
  move.
- **Do not touch the other `from any` casts.** 46 lines carry that reason
  across 26 files at `c2ae0466` (`git ls-files '*.tl' | xargs grep -h --
  "-- cast: " | grep -c "from any"`, and the same pipeline with `grep -l
  ... | wc -l`; two of the 46 are string literals in `_build/casts_test.tl`
  that the lexer-based counter does not count). Only the eight above close
  here.

## Acceptance
Run from the repo root:
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/sqlite/bind.tl
  cosmic/sqlite/extras.tl cosmic/fetch/extras.tl` prints `0` for each
  (today `2`, `4`, `2`).
- `grep -c -- "-- cast:" cosmic/sqlite/bind.tl` prints `5` (today `6`) —
  the `:52` fallthrough cast survives with its out-of-contract reason.
- `grep -n '"cosmic/sqlite/extras.tl"' _build/casts_baseline.tl` prints
  nothing (today one row, `= 4`).
- `grep -n '"cosmic/sqlite/bind.tl"\|"cosmic/fetch/extras.tl"'
  _build/casts_baseline.tl` shows `= 5` and `= 4` (today `= 6`, `= 6`).
- `bin/cosmic --make test cosmic/sqlite/extras_test.tl
  cosmic/sqlite/data_test.tl cosmic/sqlite/advanced_test.tl
  cosmic/sqlite/init_test.tl cosmic/fetch/verbs_test.tl
  cosmic/fetch/stream_test.tl cosmic/fetch/init_test.tl` ends
  `test: PASS (7 files)`. All seven exist at `c2ae0466` (`ls
  cosmic/sqlite/*_test.tl cosmic/fetch/*_test.tl`); there is no
  `bind_test.tl` and no `fetch/extras_test.tl` — `bind_at` is exercised
  through `data_test`/`advanced_test`, and the `verb`/`download` façade
  through `verbs_test`/`stream_test`.
- `git diff origin/main -- cosmic/sqlite/extras_test.tl` is empty.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.
- `wc -l cosmic/fetch/extras.tl` reports at most 500 (today `375`).
- `git diff --stat origin/main...HEAD` names exactly four files: the
  three sources above and `_build/casts_baseline.tl`.

## Enablement
none needed. Every mechanism is probed above against the built checker
(Q4), the import directions are read from the two modules' own `require`
lines (Q2, Q3), and the ratchet's regen command is printed by the gate
that fails. The one trap worth restating: the checker resolves
`require("cosmic")` from the RUNNING binary's embedded source before the
working tree, so run `bin/cosmic --make ci` (which converges) rather than
a bare `--check types` after editing a `cosmic/**` file.
