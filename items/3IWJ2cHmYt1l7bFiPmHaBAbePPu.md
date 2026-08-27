## Goal

G3 — an honest type layer, no escape hatches. The metatable `is`-rescue
(3ISSFrCO / PR #1439, widened to named targets by 3IVSDpFq / PR #1477,
recorded as D32) admits a map- or array-shaped target by its KIND alone
and then narrows `mt` to that target's full type, VALUE type included.
A `metatable<T>` value's values are metamethods, not the target's value
type, so the narrowing manufactures a type the runtime never has.

D32's consequences section states this cost and says "closing it is
separate work with its own decision". Nothing on the board carried that
work; this item does.

Measured 2026-08-27 with `cosmic.teal.check_file`, driven with
`package.loaded["tl"] = dofile(<derived tl.lua>)` (a `package.path`
probe silently measures the shipped checker — 3IVenbbU), against a
checker derived by applying `3p/tl/tl_patch/*.tl` to a pristine
tl 0.24.8 unpacked from `o/3p/tl/v0.24.8.tar.gz`:

```
local function f(x: any): integer
  local mt = getmetatable(x)
  if not (mt is {string: integer}) then
    return 0
  end
  return mt.__index + 1
end
print(f(setmetatable({}, {__index = function() end})))
```

- main `a80cf0cd` derived checker: `ok=true`
- PR #1477 derived checker: `ok=true`, and the same subject spelled
  `type Ints = {string: integer}` then `mt is Ints` is `ok=true` too
  (it was `ok=false` before #1477 — reach widened, hole unchanged)

`mt.__index` is typed `integer`; at runtime it is a function, so
`mt.__index + 1` throws. The checker passes a program that cannot run.

## Change

Not yet specified — this needs the same measure-then-decide loop
3IVL4phw and 3IVSDpFq ran. Sketch of the question: the rescue's job is
to say a `metatable<T>` value survives a `type(x) == "table"` test. It
has no business handing the target's VALUE type to the narrowed
variable. Candidate shapes to measure before choosing:

- narrow to the metatable's own shape (`{string: any}`) rather than to
  the target, so the kind test still passes but no value type is
  invented;
- refuse a target whose value type is not `any`, keeping
  `mt is {string: any}` and rejecting `mt is {string: integer}`;
- close it upstream in tl instead, per D21's upstream-first clause,
  which would delete the carried entry rather than grow it.

Whichever wins amends D32 (its accepted cost goes away) rather than
superseding it.

## Non-goals

- Do NOT re-narrow which KINDS the rescue admits — D32 settled `{map,
  array}`, records and interfaces refused. That is the shape question,
  not the value-type question.
- Do NOT reintroduce the spelling asymmetry D32 removed.

## Acceptance

To be specified when the item is refined. It must include: the subject
above checking `ok=false` (or narrowing to a type whose `__index` is
not `integer`) under the tree checker, both inline and via a named
alias; the five existing metatable tests in
`cosmic/teal_narrowing_test.tl` plus #1477's two alias tests unchanged
and passing; every patch entry still applying exactly once
(`bin/cosmic --make fetch`); `bin/cosmic --make ci` ending `ci: PASS`;
and D32 amended, with `bin/cosmic _docs/derive.tl` run.
