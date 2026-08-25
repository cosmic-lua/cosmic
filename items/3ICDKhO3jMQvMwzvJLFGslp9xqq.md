## Evidence

2026-08-20 audit at main 0b2907b9, reproduced by executing the tree's
own code. `cosmic/_literal_format.tl:181-188`: `render_table` checks
`depth > MAX_DEPTH` at entry and increments depth only on the
multi-line recursion (:190), but a nested table whose values are all
scalars is handed to `render_inline` (:136) with NO depth increment
and no check, so a flat table escapes the cap. `literal.parse` counts
every `{` (`parse_table` recurses with depth+1, cosmic/literal.tl:238),
so at the boundary format writes what parse refuses. Reproduced: a
value nesting 33 tables with a flat innermost — `format()` returns
source, `parse(format(v))` returns `nil, "…nests deeper than 32
tables"`; 32 round-trips. This violates the module's stated contract
("format must refuse exactly the depth parse refuses",
_literal_format.tl:12-17 and :213) and means `format_file` can write
a file `parse_file` cannot read back. Practical severity low (real
floors nest 2 deep). Fix shape: pass depth into render_inline, or
check depth before taking the inline path.

Re-measured 2026-08-25 at main a0c4ebd: BOTH layouts break at the
same boundary, not only the inline path. A value of 33 nested tables
with a flat `{leaf = 1}` innermost formats under `layout = "pin"`
AND `layout = "compact"`, and `parse` refuses both outputs ("nests
deeper than 32 tables"); at 34 tables both layouts refuse; at 32
both round-trip. So the fix must also cover the compact path
(`is_compact_writable` plus `cosmo.EncodeLua`,
cosmic/_literal_format.tl:395-407) with the same counting parse
uses, and the acceptance check belongs at the shared boundary: for
depths 32, 33, 34, either format refuses or parse(format(v))
succeeds, in both layouts.
