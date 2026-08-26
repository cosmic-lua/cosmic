## Goal

G3 — an honest type layer. Parent: "casts: the 16 any-map residue".
This is its no-new-type group: the sites where the type the cast
asserts already exists, and the cast is there because the code reached
for `type(x) == "table"` (or an under-declared local helper) instead
of naming it. Outcome: eight of the nine casts close outright; the
ninth keeps a cast with a truer reason (measured below — the checker
refuses `is`-dispatch on it).

## Evidence

Re-measured 2026-08-26 against `b5739e40` with
`grep -n -- "-- cast: .*from any" cosmic/check.tl cosmic/fetch/headers.tl cosmic/fs/types.tl cosmic/quicksand/proxy/rules.tl cosmic/sandbox/init_test.tl`
— nine sites, five files, same lines as first measured:

| file | sites | lines (wc -l) |
| --- | --- | --- |
| `cosmic/check.tl` | `:43`, `:44` | 347 |
| `cosmic/fetch/headers.tl` | `:25`, `:29` | 47 |
| `cosmic/fs/types.tl` | `:251`, `:255` | 300 |
| `cosmic/quicksand/proxy/rules.tl` | `:95` | 231 |
| `cosmic/sandbox/init_test.tl` | `:162`, `:177` | 368 |

**The open questions are settled by probe, 2026-08-26, on the built
checker at `b5739e40`:**

1. **Negative `is` guards narrow.** A probe function
   (`if not (a is R) then return "" end; return a.path` with `a: any`,
   and the `{string: string}` map equivalent) passes
   `o/bin/cosmic --check types`, while the unguarded control
   (`return a.path` on a bare `any`) fails with "cannot index key" —
   so the patched checker credits `not (x is T)` plus an early return,
   for records and for map types. No guard needs inverting; the old
   concern about the negative-guard gap is stale.
2. **`cosmic/check.tl`'s two are worth it.** The rewrite is the guard
   line plus deleting the two cast lines and the `ta`/`tb` renames —
   the body's shape (early return, two `pairs` loops) is unchanged, so
   readability is a wash and two casts disappear.
3. **One slice, no split.** Every closable site takes the same
   one-shape treatment; the whole validated diff is 116 lines of
   `git diff` across the five files, checked file-by-file below.
4. **The one refusal**: `cosmic/fs/types.tl:251` guards
   `getmetatable(raw)`, and the checker types that as
   `metatable<any>` — a nominal it refuses to `is`-test against a map:
   `warning: mt (of type metatable<<any type>>) can never be a
   {string : <any type>}` then `error: cannot resolve a type for mt
   here`, including when `mt` is first declared `any`. That site keeps
   a cast with the truer reason; its sibling `:255` closes.

## Change

One shape per file; each was applied and passed
`o/bin/cosmic --check types <file>` during refinement.

1. **`cosmic/check.tl`** (`deep_equal`): replace the
   `type(a) ~= "table" or type(b) ~= "table"` early return with
   `if not (a is {any: any}) or not (b is {any: any}) then return
   false end`; delete the `ta`/`tb` cast lines and use `a`/`b`
   directly in both `pairs` loops.
2. **`cosmic/fetch/headers.tl`** (`normalize`): replace the
   `value is table` branch with `value is {string}` (drops the `:25`
   cast; `ipairs(value)` is then typed), and split the else into
   `elseif value is string then table.insert(list, value)` with a
   final `else table.insert(list, tostring(value)) end`. The decision,
   stated: the binding contract is string-or-{string} (the module
   header says so); a value that is neither is a contract violation,
   and `tostring` keeps the declared `{string}` list true at runtime
   while producing the same joined output the old blind cast did for
   e.g. numbers.
3. **`cosmic/fs/types.tl`** (`extend_metatable`): keep the
   `type(mt) ~= "table"` guard and the `mt as {string: any}` cast, but
   change its reason to the measured one — a comment line above:
   `-- cast: metatable<any> is a nominal the checker refuses
   is-dispatch on`. Then `local idx = (mt as ...).__index`, replace
   the `type(idx) ~= "table"` guard + `methods` cast with
   `if not (idx is {string: any}) then return false end` and write
   through `idx` directly.
4. **`cosmic/quicksand/proxy/rules.tl`** (`validate_rule`): change the
   guard to `if not (rule is {string: any}) then ... end` (same
   runtime check — `is {K: V}` compiles to `type(x) == "table"`), then
   `local r = rule` with no cast.
5. **`cosmic/sandbox/init_test.tl`**: give `find_rule` its real
   signature — `(rules: {landlock.Rule}, path: string):
   landlock.Rule` (the module already requires
   `cosmic.sandbox.landlock` at line 4; `plan.for_landlock` returns
   `RestrictOptions` whose `rules` is `{Rule}`), drop the `rr` cast,
   and drop the `:177` `r.access as integer` cast — `r.access` is a
   plain `integer` read.

During refinement the full diff also passed
`o/bin/cosmic --make test cosmic/check_test.tl cosmic/fetch/headers_test.tl`
(`test: PASS (2 files)`).

## Non-goals

- No new type declarations anywhere — this group exists because every
  needed type already does.
- No behavior change beyond `headers.tl`'s stated `tostring` fallback
  for contract-violating header values; every guard keeps its runtime
  semantics (`is {K: V}` compiles to the same `type(x) == "table"`
  test the code already ran).
- Do not chase the `metatable<any>` checker limitation here — if it
  deserves closing, that is a tl-patch capture, not this diff.
- Do not touch the other 7 sites of the parent's 16-site residue; they
  are the sibling slices'.
- `deep_equal`'s semantics (`==` first, then structural) are frozen —
  test helpers across the tree depend on them.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -rn -- '-- cast: .*from any' cosmic/check.tl cosmic/fetch/headers.tl cosmic/fs/types.tl cosmic/quicksand/proxy/rules.tl cosmic/sandbox/init_test.tl | wc -l`
  reports 0 (today 9).
- `grep -c -- '-- cast:' cosmic/fs/types.tl` reports 13 (today 14 —
  the file carries twelve other casts with other reasons, outside this
  slice) — the `:255` cast is gone and `:251` survives with the
  metatable reason.
- `bin/cosmic --make test cosmic/check_test.tl cosmic/fetch/headers_test.tl cosmic/sandbox/init_test.tl cosmic/quicksand/proxy/rules_test.tl`
  ends `test: PASS` (all four exist; `cosmic/fs/types.tl` has no
  sibling test file and is covered by the ci line above).

## Enablement

none needed. The narrowing patch group already credits negative `is`
guards (probed above), so nothing blocks this; the validated diff from
refinement exists as evidence and the implementer re-derives it from
this spec.
