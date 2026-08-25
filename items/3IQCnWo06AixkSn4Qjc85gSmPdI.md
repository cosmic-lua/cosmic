## Goal
G3 — an honest type layer. Parent: "casts: the 16 any-map residue".
This is its no-new-type group: the 9 sites where the type the cast
asserts ALREADY exists, and the cast is there because the code reached
for `type(x) == "table"` (or an under-declared local helper) instead of
naming it.

## Evidence

Measured 2026-08-25 against `1f9279ab` with
`grep -n -- "-- cast: .*from any" <file>`. Nine sites, five files, none
of them needing a record that does not already exist:

| file | sites | lines | the shape |
| --- | --- | --- | --- |
| `cosmic/check.tl` | 2 (`:43`, `:44`) | 347 | `deep_equal(a: any, b: any)` after a `type(a) ~= "table"` guard |
| `cosmic/fetch/headers.tl` | 2 (`:25`, `:29`) | 47 | a `pairs` value after `value is table` |
| `cosmic/fs/types.tl` | 2 (`:251`, `:255`) | 300 | `getmetatable(raw)` and its `__index`, each after `type(x) ~= "table"` |
| `cosmic/quicksand/proxy/rules.tl` | 1 (`:95`) | 231 | a user-supplied rule after `rule is table` |
| `cosmic/sandbox/init_test.tl` | 2 (`:162`, `:177`) | 368 | the test's own `find_rule` helper |
| **total** | **9** | | |

**Seven are guard-then-cast.** Each writes the check twice — once as a
`type()`/`is table` test the checker learns nothing from, once as the
cast that states what the test proved. `is {K: V}` folds them into one:
`if value is {string} then` in place of `value is table` plus
`value as {string}`. No new declaration anywhere.

**Two are self-inflicted, and they are the cheapest sites in the whole
census.** `cosmic/sandbox/init_test.tl` casts because its OWN helper
under-declares:

```teal
local function find_rule(rules: {any}, path: string): {string: any}
  for _, r in ipairs(rules) do
    local rr = r as {string: any} -- cast: from any
```

The value is already typed upstream. `plan.for_landlock` returns
`landlock.RestrictOptions` (`cosmic/sandbox/plan.tl:83`), whose `rules`
field is `{Rule}` (`cosmic/sandbox/landlock.tl:104-106`), and `Rule` is
`path: string` / `access: integer` (`:87-89`). Declaring `find_rule` as
`(rules: {landlock.Rule}, path: string): landlock.Rule` makes `r.path`
and `r.access` plain typed reads and closes both sites, `:177`'s
`r.access as integer` included.

## Direction, not a decision

Replace each guard-then-cast with `is {K: V}` dispatch, and give
`find_rule` its real signature. The open questions refinement must
settle by MEASURING, not by assuming:

- **Which of the seven actually narrow today.** `is` narrows in the
  POSITIVE branch. `cosmic/check.tl`, `cosmic/fs/types.tl` and
  `cosmic/quicksand/proxy/rules.tl` all guard with a NEGATIVE test and
  an early `return`, and the checker does not credit that exit — which
  is the gap board item `3IPXM4K2` exists to close. So some of these
  seven may need the guard inverted into a positive branch rather than
  just rewritten, and one or two may not close at all until
  `3IPXM4K2` lands. Run `bin/cosmic --check types <file>` on each
  rewrite and record which is which; if any site cannot close, drop it
  from this slice and say so rather than carrying a `blocked_by` for
  the whole group.
- **Whether `cosmic/check.tl`'s two are worth the churn at all.**
  `deep_equal` casts both operands once each and then only uses
  `pairs`; `if a is {any: any} and b is {any: any} then` inverts the
  whole function body one level deeper. Judge readability against two
  casts and say which won.
- **Whether this stays one slice or splits.** Nine sites over five
  files in five subsystems is a wide review surface even though every
  edit is one or two lines. If the measurement above shows the seven
  need materially different treatment, cut this into the ones that are
  a pure `is` rewrite and the ones that need the guard restructured.

## What this must not do

Every one of these files carries a frozen contract, and none of them
moves: `cosmic.check` throwing is D23 and is not reopened;
`cosmic.fetch`'s structured `Error` record and its `kind` field are
D24; `cosmic.fs`'s `Stat` predicates keep their userdata-metatable
mechanism; `cosmic/quicksand/proxy/rules.tl`'s validation MESSAGES are
matched by tests and must stay byte-identical.

`cosmic/fetch/headers.tl`'s normalize contract — lowercase names,
repeats joined `", "` per RFC 9110 §5.3, `raw_headers` in arrival order
— does not change. This slice moves types, never behaviour.

Do not add a record anywhere. A site that turns out to need one is not
in this group; leave it and note it for the parent.

The closure diff lowers the affected rows in `_build/casts_baseline.tl`:
run exactly the regen command the gate's failure message prints
(`bin/cosmic --make run _build/casts.tl --baseline`) and commit the
result; no gate is weakened any other way. Leave `docs/design/casts.md`
alone — it is a stale snapshot, tracked as `3IQC4GeO`.
