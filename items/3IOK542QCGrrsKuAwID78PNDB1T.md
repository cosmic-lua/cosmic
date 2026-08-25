## Goal

G3 — an honest type layer. This slice closes the **untyped-probe fallout**
class of `from any` casts: the sites where a test re-types an API to
`function(any): any, any` so it can feed the malformed value the real
signature forbids, and then pays a cast on every value read back off that
call. One helper in `cosmic.check` makes the untyped call and hands back a
typed message, so the class collapses to one cast inside the helper.

Re-measured 2026-08-25 against `1dc5aa14` (the census in
`docs/design/casts.md` is dated `d3e59de7` and counts 15 here; the tree
now carries 17 `-- cast: from any` lines across the six files, of which 14
are this class). The split, from
`grep -n -- "-- cast: " <file>` on each:

| file | cast lines today | of which this class |
| --- | --- | --- |
| `cosmic/quicksand/box/init_test.tl` | 13 | 10 |
| `cosmic/quicksand/box/run_test.tl` | 2 | 2 |
| `cosmic/surface_test.tl` | 3 | 2 (dead, see Change 5) |
| `cosmic/sqlite/close_test.tl` | 4 | 2 (relabel only) |
| `cosmic/fd_read_test.tl` | 3 | 1 (relabel only) |
| `cosmic/fs/find_close_test.tl` | 2 | 1 (relabel only) |

The two halves want opposite answers, and this slice gives each its own:
an invalid-input probe closes (Change 1–4), a **surface** probe does not —
a test asserting that a type deliberately hides something is doing its job,
and its cast is honest, so it earns a reason of its own (Change 6) and
leaves the `from any` census, which is what stops the census over-counting
it as debt.

The whole change was prototyped 2026-08-25 against `1dc5aa14` and run to
`ci: PASS (5 stages)`; every number in `Acceptance` is that run's.
`git diff --stat` on the prototype: 9 files, 90 insertions, 38 deletions.

## Change

**1. `cosmic/check.tl` — add `refuses`.** Insert directly after `truthy`
and before `failed`, verbatim:

```teal
--- Assert that a call refuses arguments its declared signature forbids.
--- The call is made through `any`, so a test can pass the malformed value
--- the declared types exist to prevent, and the refusal comes back typed:
--- one cast here instead of one at every probe and one on every value read
--- off it. Throws when the call returns a value instead of refusing, or
--- refuses with an empty message.
--- @param f any The function to call, whose declared signature forbids these arguments
--- @param ... any The arguments to call it with
--- @return string The message the call refused with
local function refuses(f: any, ...: any): string
  -- cast: the probe calls past the declared signature, which is the point
  local call = f as function(...: any): (any, any)
  local value, err = call(...)
  local message = tostring(err)
  if value ~= nil or err == nil or message == "" then
    error(string.format("refuses: expected a refusal, got (%s, %s)",
        render(value), render(err)), 2)
  end
  return message
end
```

and declare it on the module record and the table, both immediately after
`must`:

```teal
  refuses: function(f: any, ...: any): string
```
```teal
  refuses = refuses,
```

`error(..., 2)` is deliberate and matches the module: the failure points at
the caller's line. `wc -l < cosmic/check.tl` is 324 today and 347 after —
153 lines of headroom under the 500-line cap.

**2. `cosmic/check_assertions_test.tl` — three tests**, appended at the end
of the file (this file has no trailing `print`), each called on the line
after its `end`, using the file's own `must_fail` helper:
`test_refuses_returns_the_refusal_message` (a local function returning
`nil, "cwd must be a string"`; the helper returns that string),
`test_refuses_throws_when_the_call_succeeds` (returns a value; must throw,
message contains `expected a refusal`), and
`test_refuses_throws_on_an_empty_message` (returns `nil, ""`; same). The
three cover every branch of `refuses`, which is what keeps the coverage
ratchet quiet. `wc -l < cosmic/check_assertions_test.tl` is 426 today and
461 after — 39 lines of headroom left.

**3. `cosmic/quicksand/box/init_test.tl` — three probes, 10 cast lines.**
- `test_new_rejects_bad_types`: delete the `new_any` re-type (line 35) and
  the four fallout casts (lines 47–49); the loop body becomes
  `local err = check.refuses(Box.new, c.opts)` followed by one
  `assert(err:find(c.want, 1, true), ...)`. Retype the cases table from
  `{{string: any}}` to `{Case}` with

  ```teal
  local record Case
    opts: {string: any}
    want: string
  end
  ```

  **declared at FILE SCOPE, above the test function, not inside it.** A
  `local record` nested inside a `test_*` function trips the
  call-after-define lint, which reads the record's `end` as the function's:
  measured 2026-08-25 — an 8-line file whose only content is a `test_*`
  function containing a nested record fails
  `cosmic --check lint <file>` with
  `call-after-define: 'test_nested_record' must be called immediately after
  its definition`, and hoisting the record makes the same file pass. The
  defect itself is captured as board item `3IP9ijhv`; do not fix it here.
- `test_run_requires_argv`: delete the `run_any` re-type (line 57) and both
  fallout casts; the first probe becomes
  `local err = check.refuses(j.run, j, nil)` (the receiver is passed
  explicitly — `refuses` takes a plain function). The second call stays a
  normal `j:run({})` and its error is already typed; rename its locals so
  they do not collide with the first (`local code, err2 = j:run({})`).
- `test_fs_deny_rejected_at_new`: delete the `new_any` re-type (line 129)
  and both fallout casts; both probes become
  `check.refuses(Box.new, ...)`, keeping the two existing assertion
  messages.

Lines 118–121 of this file are NOT touched — see `Non-goals`.

**4. `cosmic/quicksand/box/run_test.tl` — one probe, 2 cast lines.**
`test_bogus_sys_promise_rejected_at_new` becomes
`local err = check.refuses(quicksand.new, {sys = {promises = "stdio bogus_promise"}})`
plus the existing `find("bogus_promise", 1, true)` assertion. The file's
cast count reaches zero, so its row leaves `_build/casts_baseline.tl`
entirely.

**5. `cosmic/surface_test.tl` — two dead casts.** Both narrow nothing
today; verified 2026-08-25 by deleting each and running
`bin/cosmic --check types cosmic/surface_test.tl`, which prints
`Type check passed`:
- line 98 — `require("cosmic.doc") as {string: any}`: the module name is a
  literal, so the searcher resolves the real record and `doc["query"]`
  indexes it directly. Becomes `local doc = require("cosmic.doc")`.
- line 132 — `(mod as {string: any}).internal`: `mod` comes from
  `idx.modules`, declared `{string: ModuleDoc}` (`cosmic/doc/types.tl:62`),
  and `ModuleDoc.internal: boolean` is a declared field
  (`cosmic/doc/types.tl:57`). Becomes `mod.internal == true`.

**6. Four surface probes — relabel the reason, keep the cast.** Each is
live (verified 2026-08-25 by deleting it and running `--check types`), and
each probes a surface the declared type deliberately does not describe.
Replace the trailing `-- cast: from any` with
`-- cast: probe past the declared surface` on:
`cosmic/fd_read_test.tl:109` (calling the `fs.sync_all` value read off a
module-as-map probe; without the cast: `not a function: <any type>`),
`cosmic/fs/find_close_test.tl:87` and `cosmic/sqlite/close_test.tl:62,179`
(reading `__close` off a raw metatable; same error). The cast counts of
these three files do not move; only the reason does. `fd_read_test.tl`
already uses the neighbouring spelling `-- cast: probe module surface` on
lines 107–108; leave those alone — this slice adds one spelling for the
class, it does not unify the existing ones.

**7. `_build/casts_baseline.tl` — regenerate.** Run exactly the command the
gate's failure message prints,
`bin/cosmic --make run _build/casts.tl --baseline`, and commit the result.
Expect `casts: wrote _build/casts_baseline.tl — 363 casts in 119 files`
(today 376). Read the diff before committing: only the five rows named in
`Acceptance` may move. `cosmic/check.tl` RISES from 3 to 4 — that is the
intended trade, one cast inside the helper for the 13 it retires, and the
gate is a per-file ratchet that must be re-baselined for it, never
weakened. The prototype run needed no `.cosmic-coverage` rewrite
(`coverage ratchet ok`); if the coverage gate does ask on the day, run the
command IT prints and commit that too.

## Non-goals

- **`cosmic/quicksand/box/init_test.tl:118–121` stays untouched.** Those
  three casts read fields off a merged `BoxOptions`; they are the any-map
  field-walk class and belong to board item `3IOmgCA2`, whose spec names
  them explicitly. The file keeps exactly 3 cast lines after this slice.
- **`cosmic/surface_test.tl:92` stays.** `require("cosmic." .. name)` is a
  non-literal require indexed as a map — dropping the cast fails with
  `cannot index object of type <any type> with string`. That is the shape
  board item `3IOuS3IE` closes with a typed dynamic require; its site list
  does not currently include this line. Do not close it here and do not
  edit that item's spec from inside this diff.
- **The other 11 `-- cast: deliberate invalid input` sites stay.** Only the
  four that re-type a function to `function(any...): any, any`
  (`init_test.tl:35,57,129`, `run_test.tl:111`) are this class; the rest
  (`cosmic/log_test.tl`, `cosmic/hash_test.tl`, `cosmic/rand_test.tl`,
  `cosmic/sandbox/init_test.tl`, `cosmic/quicksand/proxy/rules_test.tl`,
  `cosmic/check_assertions_test.tl:360`) widen an enum or a nil union at
  the call and produce no `any` to read back. `refuses` does not fit them.
- **Do not fix the call-after-define lint.** Hoisting the record is the
  whole workaround this slice needs; the defect is board item `3IP9ijhv`.
- **`cosmic.check` may still not be required from library code.** `check`
  throws by design (D23); `refuses` is for tests and examples only. Do not
  add a `require("cosmic.check")` to any non-test `cosmic/*.tl`.
- **No gate weakened or exempted**, and no cast added anywhere outside the
  single justified one inside `refuses`.
- **Do not rewrite `docs/design/casts.md`.** It is a dated census against
  `d3e59de7`; correcting it is separate work.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/check_assertions_test.tl` passes and
  reports 48 test functions (today 45).
- `bin/cosmic --make test cosmic/quicksand/box/init_test.tl cosmic/quicksand/box/run_test.tl cosmic/surface_test.tl cosmic/fd_read_test.tl cosmic/fs/find_close_test.tl cosmic/sqlite/close_test.tl`
  ends `test: PASS (6 files)`.
- `grep -c -- "-- cast: " cosmic/quicksand/box/init_test.tl cosmic/quicksand/box/run_test.tl cosmic/surface_test.tl cosmic/check.tl`
  reports `3`, `0`, `1`, `4` (today `13`, `2`, `3`, `3`).
- `grep -c -- "-- cast: " cosmic/fd_read_test.tl cosmic/fs/find_close_test.tl cosmic/sqlite/close_test.tl`
  reports `3`, `2`, `4` — unchanged, because Change 6 relabels and does not
  remove.
- `grep -c -- "-- cast: from any" cosmic/fd_read_test.tl cosmic/fs/find_close_test.tl cosmic/sqlite/close_test.tl cosmic/quicksand/box/run_test.tl`
  reports `0` for each (today `1`, `1`, `2`, `1`).
- `grep -c -- "-- cast: probe past the declared surface" cosmic/fd_read_test.tl cosmic/fs/find_close_test.tl cosmic/sqlite/close_test.tl`
  reports `1`, `1`, `2`.
- `git grep -c -- "-- cast: from any" -- '*.tl' | awk -F: '{s+=$2} END {print s}'`
  prints `163` (today `177`).
- `grep -n '"cosmic/check.tl"\|"cosmic/quicksand/box/init_test.tl"\|"cosmic/quicksand/box/run_test.tl"\|"cosmic/surface_test.tl"' _build/casts_baseline.tl`
  shows `["cosmic/check.tl"] = 4`, `["cosmic/quicksand/box/init_test.tl"] = 3`,
  `["cosmic/surface_test.tl"] = 1`, and NO row for
  `cosmic/quicksand/box/run_test.tl` (today `3`, `13`, `3`, and a row of
  `2`).
- `wc -l cosmic/check.tl cosmic/check_assertions_test.tl` reports `347` and
  `461`, both under the 500-line cap.
- `grep -rn 'require("cosmic.check")' cosmic --include='*.tl' | grep -v _test`
  prints nothing.

## Enablement

none needed. The whole change was prototyped against `1dc5aa14` on
2026-08-25 and taken to `ci: PASS (5 stages)`, so every command in
`Acceptance` has been run in the shape this spec asks for, and the two
surprises that pass found — the call-after-define lint tripping on a nested
record, and the `cosmic/check.tl` row rising by one — are written into
`Change` as instructions rather than left for the implementer to discover.

Two findings this refinement produced, recorded rather than acted on:

- `3IP9ijhv` — the call-after-define lint reads a nested `local record`'s
  `end` as the test function's, and fails a file that is correct. Captured
  with the 8-line repro; the workaround here costs nothing.
- `docs/design/casts.md`'s class assignment is wrong again — it puts
  `cosmic/surface_test.tl:92` in this class when it is the non-literal
  require shape, and counts 15 sites where the six files now carry 17. This
  is the second item in a row to inherit a bad row from that census at
  intake (the first was `3IOK4iuU`). Re-measuring the census, or gating it,
  is separate work that is now twice-evidenced.
