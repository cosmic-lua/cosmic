## Evidence

`MVs4_UosO` ("tl: number assigns to integer unchecked — prototype a
gated strict rule with math.type narrowing and census what it
refuses") re-measured 2026-09-03 by a builder session against the
pinned checker (tl 0.24.8, `bin/cosmic --make fetch` then `--make
build`, checker exercised directly via `tl.process_string`).

The item's own evidence repro still reproduces literally:

    local n: number = 3
    local j: integer = n
    → Type check passed

But every *general* case of "a genuinely `number`-typed value assigned
or passed where `integer` is declared" is **already refused by stock,
ungated tl** — no patch needed. Confirmed for: a `number`-returning
function's result fed to a `number`-declared local then assigned to an
`integer` local; a `number`-typed parameter assigned to a declared
`integer` local; reassigning the evidence's own `n` via a
`number`-returning call before the `integer` assignment; a
`number`-typed record field assigned to a declared `integer` local;
passing a `number` parameter where `integer` is declared; assigning a
`number`-typed value into an `{integer}` array element. Every one of
these already errors (`got number, expected integer`) with zero
patching.

Root cause, isolated by instrumenting `TypeChecker:assert_is_a` to
print the operand types actually compared: for the evidence's own
passing example, the comparison that runs at `local j: integer = n` is
`is_a(integer, integer)` — **not** `is_a(number, integer)`. Stock
(unpatched) tl's `local_declaration` handler (`tl.lua` ~13172–13182)
re-narrows a local's flow-tracked type to its *initializer's* inferred
type whenever it's narrower than the declared type (the same
"narrowed_declaration" mechanism that lets `local x: Base =
Derived()` track as `Derived`). Since `n`'s initializer `3` infers as
`integer`, `n`'s tracked type from that point on is `integer`, not the
declared `number`. This is sound (`n` genuinely holds an integer value
there) and fully general — nothing integer/number-specific about it.
The same laundering makes `local n: number = 3; take(n)` (where `take`
declares an `integer` parameter) pass too, for the identical reason.

Separately, the escape-hatch half of the original premise still holds:
`math.type(x) == "integer"` narrows nothing today — a guarded `local
j: integer = n` inside such a branch still errors.

## The question

`MVs4_UosO`'s `## Change` describes a same-shape rule as
`3p/tl/tl_patch/cast.tl`'s gate: intervene at the `is_a`/`assert_is_a`
comparison and refuse when the compared-from type is `number` and the
declared type is `integer`. That rule would be a near no-op
census-wide (every case that genuinely reaches the comparison with a
`number` operand is already refused, unpatched) and would stay silent
on the item's own motivating example (by the time any comparison runs
for `local j: integer = n`, the operand has already been narrowed to
`integer` by stock declaration-narrowing, before any patched
comparison sees it).

Reaching the actual gap — a *declared* `number` local/field/parameter
being assignable to a narrower `integer` slot merely because its
*current* inferred value happens to be an integer literal, silently
laundering the declared width away — requires intervening in the
narrowing/declaration-tracking machinery itself (the
`narrowed_declaration` mechanism), a materially different and more
invasive shape than "add an `is_a` refusal entry," and outside what a
builder should improvise unprompted.

Decide: is this narrowing behavior itself the actual soundness gap
worth gating (in which case `MVs4_UosO`'s spec needs a rewritten
`## Change` describing a patch to `narrowed_declaration`, not to an
`is_a` comparison), or does the original motivating concern not
survive re-measurement at all (in which case `MVs4_UosO` should be
closed as resolved-by-non-issue, per the pattern other perf/cast items
on this board use for a falsified premise)?
