## Evidence

`literal.parse(literal.format(v))` does not round-trip a value nested
exactly 33 tables deep: `format` writes it, `parse` refuses what it
wrote. This is the module's founding promise broken, not a refusal.

Measured 2026-08-23 against the tree at PR #1346's head
(`b5605716`), with `o/bin/cosmic` built from it. The defect is
PRE-EXISTING — #1346 does not touch `render_table`, `render_inline` or
`all_scalar_values` — and was found while reviewing that PR's compact
layout against the reader.

```lua
-- 33 nested tables, the innermost holding one scalar
local function nest(n)
  local root, cur = {}, nil
  cur = root
  for _ = 2, n do local t = {}; cur.k = t; cur = t end
  cur.leaf = 1
  return root
end
local text = literal.format(nest(33))          -- returns source, no refusal
local back, err = literal.parse(text)
-- back == nil, err == "literal:33: a literal nests deeper than 32 tables"
```

`nest(32)` round-trips; `nest(33)` writes and then fails to read.

## Cause

`render_table` (`cosmic/_literal_format.tl:206`) is the only place the
writer checks depth — `if depth > MAX_DEPTH`. But a nested table whose
values are all scalars is rendered by `render_inline`
(`cosmic/_literal_format.tl:177`), which takes no `depth` argument and
performs no check, and `render_table` never recurses into it. So the
deepest table in any value is rendered by the un-checked path, and the
writer's effective limit is `MAX_DEPTH + 1` while the reader's
(`cosmic/literal.tl`'s own `MAX_DEPTH`, deliberately the same 32) is
`MAX_DEPTH`. The two are off by one exactly at the boundary.

## Shape of the fix

`render_inline` takes the depth of the table it is rendering and
refuses past `MAX_DEPTH` with the same `refusal(path, ...)` message
`render_table` gives, so the writer refuses precisely what the reader
refuses. A test asserting `format` refuses at the first depth `parse`
refuses — driven off `MAX_DEPTH` rather than a hard-coded 33, so the
two stay pinned together — belongs with it.

The general property worth pinning at the same time: for every depth
d, `format` succeeding implies `parse(format(v))` succeeds. `_fuzz`
has no literal property today; that may be the better home.
