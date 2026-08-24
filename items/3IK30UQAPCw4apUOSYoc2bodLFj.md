## Goal
G6 — the defining paths, ratcheted (this item's parent is the G6
container). `cosmic --docs sqlite` is the first thing a session reads
before writing sqlite code, and today it hands that reader eight lines
that its own gate rejects. Evidence: the 2026-08-23 clean-room eval
round (`skills/agent-eval`), where this was agent 3's attempt-1 build
failure and its top-ranked friction — 11 sites across 2 files. 1 of 4
agents hit it; it was the only sqlite brief.

## Change
One file: `cosmic/sqlite/init.tl`. Measured `wc -l cosmic/sqlite/init.tl`
= **448**, so **52 lines of headroom** under the 500-line cap — this
change adds about 6, but the cap is close enough that Acceptance bounds
it.

**1. The module header example (lines 14-21) must compile.** It does not
today. Measured 2026-08-24 at `9bcb0f7d`, copying the block verbatim
into a file and running `o/bin/cosmic --check types` on it: **7 errors**,
from three independent causes — `sqlite.open` returns `Database | nil`
and is never narrowed (4 errors, plus 2 cascading `unknown variable:
row`), and `db:close()` discards a fallible return (1). With the
narrowing repaired, the discard check alone gives 2 errors, on
`db:exec` and `db:close`:

    discarded error return of function(Database): (boolean, string)
      — capture it: `local v, err = f(...)` (or `local _ok, _err = f(...)`
      for deliberate fire-and-forget; assert/check.must in tests)

Replace the indented block at lines 14-21 with this fenced one. It is
verified: `--check types` passes clean at full strictness and
`--check fmt` reports it a formatter fixpoint, both run 2026-08-24 on
the body below exactly as written.

    ```teal
    local sqlite = require("cosmic.sqlite")
    local db = assert(sqlite.open(":memory:"))
    assert(db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"))
    assert(db:exec("INSERT INTO users (name) VALUES (?)", {"alice"}))
    for row in assert(db:query("SELECT * FROM users WHERE name = :n", {n = "alice"})) do
      print(row.id, row.name)
    end
    assert(db:close())
    ```

**The fence is load-bearing, not cosmetic.** `_build/snippets_test.tl`
collects doc-comment code only from fences (`doc_comment_fences`, lines
162-192, matching "^```(%w*)"), and holds every `teal`- or `lua`-tagged
fence to both the formatter and the checker at full strictness
(`test_every_snippet_is_a_formatter_fixpoint`, line 220;
`test_every_snippet_compiles`, line 245). An indented block is collected
by nothing. Converting this one puts it permanently under the gate, so
it cannot rot again — which is why the conversion is in scope and a
plain in-place repair of the indented block would not be. Precedent for
the form: `cosmic/shm.tl:288`, the file the gate's own header names.

**2. The one-line note beside `close`.** `close` is declared at line 145
and its doc comment runs 138-144; it already explains the failure mode
in detail but never tells the reader to capture the return. Add one
sentence to that existing comment saying `close()` returns
`boolean, string` like every other fallible Database method, so it must
be captured — `assert(db:close())`, or `local _ok, _err = db:close()`
for deliberate fire-and-forget. This is the eval agent's own ask,
quoted: "the fix is pure boilerplate (local _ok, _err = ...) with no way
to write it once."

## Non-goals
- **Do not weaken, disable, or narrow the discarded-fallible-return
  check** (`cosmic/_teal_discard.tl`, reached via
  `_teal_engine.collect_discards`). The eval agent explicitly endorsed
  it: "defensible as a design choice (a swallowed close failure is a
  real bug class) ... an exec/add/take result I *did* want to be forced
  to check." The docs are what is wrong here, not the checker.
- **Do not add `close_ignoring_errors()`, or any second spelling of a
  fallible method.** The eval agent floated it and this item deferred it
  to plan; plan has now settled it as NO, and this is the record.
  Three reasons: the checker's own message already names the escape
  (`local _ok, _err = f(...)`); D20 fixes a fallible effect's shape at
  `boolean, string`, so a fire-and-forget twin would be owed to `exec`,
  `query`, `transaction` and every other fallible method, not just
  `close`; and the idiom is already modelled in shipped docs
  (`cosmic/shm.tl:150`, "every call reports, so every call is
  captured"). Reopening this needs a decision record, not a slice.
- **Do not touch the other 18 files** carrying indented doc-comment code
  (`grep -rc "^---     [^ ]" cosmic/**/*.tl` — 19 files, 84 lines).
  Closing the gate's blind spot generally is board item **3IMCXGgK**,
  filed 2026-08-24, and its breakage is unmeasured. This slice converts
  exactly one block, the one with eval evidence behind it.
- Do not touch `docs/guides/**`. They were checked and are already
  correct — `checking.md:116` and `gotchas.md:103` narrow `open`, and
  `recipes.md:90` writes `assert(db:close())`.
- Do not change any signature in `cosmic/sqlite/**`, the `Database`
  record's shape, or `close`'s idempotence and retry contract (the
  behaviour lines 138-144 describe). This is a docs change.

## Acceptance
Run from the repo root; the build under test is what this change
produces (`bin/cosmic --make build`, then `o/bin/cosmic`).

1. `bin/cosmic --make ci` ends with `ci: PASS`. This is the criterion
   that proves the example compiles: `_build/snippets_test.tl` runs
   inside the gate, and once the block is a `teal` fence it is checked
   at full strictness with warnings as errors. A fence that does not
   compile fails the gate by name and line.
2. The example is under the gate, not merely fixed — the fence count in
   the file goes from 0 to 1:

   ```sh
   grep -c '^--- ```teal' cosmic/sqlite/init.tl
   ```

   prints **1** (**0** today). And the indented form is gone from the
   header: `grep -c "^---     [^ ]" cosmic/sqlite/init.tl` prints **0**
   (**7** today).
3. The rendered reference shows the corrected code:
   `o/bin/cosmic --docs sqlite` contains the line
   `local db = assert(sqlite.open(":memory:"))` and contains no line
   matching `^ *db:close\(\)$`.
4. `o/bin/cosmic --make test cosmic/sqlite/init_test.tl
   cosmic/sqlite/lifecycle_test.tl cosmic/sqlite/close_test.tl` ends
   with `test: PASS`. No behaviour moved, and these are the tests that
   would notice if it had.
5. `wc -l cosmic/sqlite/init.tl` is ≤ 500 (448 today, ~454 after).

## Enablement
none needed. The one decision the item left open — the
`close_ignoring_errors()` escape hatch — is settled in Non-goals with
its reasons, so no judgment is left to the implementing session. The
replacement example is given verbatim and was verified against both
gates during this refinement, so it cannot be got wrong by
transcription. The gate that enforces the result already exists and
already runs in `--make ci`; nothing new has to be built or wired.
