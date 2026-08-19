## Evidence (2026-08-19, measured at f420391)

`cosmic.literal.format` lays every nested table out multi-line, and its
grammar refuses sequence values outright (`{47, 65}` → "a number is not
a string key" on format, "found '47'" on parse). Board item 3I1J9Xhg
(the coverage floor becomes a literal) is blocked on exactly this: a
floor row must be ONE line — `.cosmic-coverage` carries `merge=union`,
which merges rows only while a row is a line — and the natural encoding
`["path"] = { ["covered"] = 47, ["total"] = 65 },` already PARSES
one-lined (whitespace is free), but nothing can WRITE it that way.

## Suggested shape

A layout rule in `cosmic.literal.format`/`format_file`, not a grammar
change: a nested table whose values are all scalars formats inline on
its parent's line. Grammar stays closed (sequences stay refused).
Measured blast radius today: zero — no committed floor holds a nested
value (`grep -c '= {' _build/casts_baseline.tl` is 0), so no committed
byte changes until 3I1J9Xhg consumes the rule. `_tool/floor.tl` needs
no change (it forwards to literal). Attach under the ratchet-unification
container (3I1IoF4k) once plan has drained; 3I1J9Xhg's blocked_by
already names this item.
