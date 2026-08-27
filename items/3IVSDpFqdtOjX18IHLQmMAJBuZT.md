Measured while refining 3IVL4phw (the dead `table_kinded` keys), and
worth recording separately because it limits the LIVE half of the
metatable is-dispatch rescue, not the dead half.

`is_table_metatable` (`3p/tl/tl_patch/narrow.tl`, entry
`narrow-metatable-helper`) tests `target.typename` against a set of
structural kinds, but the is-fact carries `ub` — the UNRESOLVED type
(`o/3p/tl/tl.lua:14118`, `node.known = IsFact({ var = node.e1.tk,
typ = ub, w = node })`). So the rescue fires only for an INLINE type
literal. A named alias of a map is refused exactly like a record:

```teal
local type Rec = {string: any}
local function f(x: any): boolean
  local mt = getmetatable(x)
  if not (mt is Rec) then return false end
  return mt.__index ~= nil
end
```

checks as `ok=false` — `cannot resolve a type for mt here` (x2) plus
`mt (of type metatable<<any type>>) can never be a Rec` — while the
byte-equivalent `mt is {string: any}` checks clean. Probed
2026-08-27 at main `267c2a4d` with `cosmic.teal.check_file` under
`o/bin/cosmic`, and identically under `o/bootstrap/cosmic` (the
pinned release).

Nothing in the tree hits this today: the only production metatable
is-dispatch site is `cosmic/fs/types.tl:248`, an inline
`mt is {string: any}` (`grep -rn -A2 '= getmetatable(' --include=*.tl
cosmic _cli _make _tool _build _types _perf cmd 3p | grep ' is '` →
that site plus the two tests in `cosmic/teal_narrowing_test.tl`).

Triage note: 3ISSFrCO's Non-goals (the spec that landed the rescue as
PR #1439) deliberately said "a nominal that merely resolves to some
record must keep failing", so resolving the target nominal is a NEW
decision rather than a bug fix — an alias of a map and a record are
the same case to the checker, and admitting one admits the other.
