## Question

Which Lua-side representation makes a SQLite BLOB distinguishable
from TEXT at `db_push_value` (`tool/net/lsqlite3.c:948`), and does
that change apply to column reads as well as UDF arguments?

## Evidence

`db_push_value` pushes both `SQLITE_TEXT` and `SQLITE_BLOB` through
`lua_pushlstring`, so a UDF cannot tell `x'00FF'` from the text with
the same bytes, and the same collapse applies to every reader of the
switch. Item 3If5s4hN («uYH1_dq7T») names three candidates, each with
a real cost:

a. a wrapper userdata or table carrying the bytes — unambiguous, but
   every existing reader of a blob column receives a new type;
b. a separate accessor reporting the SQL type beside the value — the
   pushed value is unchanged, additive, but the ambiguity stays for
   anyone who does not ask;
c. a distinct Lua type only inside UDF arguments, column reads left
   alone — narrow blast radius, two conventions in one binding.

Binding contracts are frozen at the C boundary (cosmopolitan
AGENTS.md); a and c are contract changes needing a `definitions.lua`
update in the same commit and a cosmic-side type regen plus wrapper
fix (`cosmic/sqlite/bind.tl`, `cosmic/sqlite/column.tl`) as their own
change. The same switch's `SQLITE_INTEGER` path falls back to a
string for out-of-range values; whether that is settled with this
decision or separately is part of the answer.

## Change

A decision, recorded on this item and applied to 3If5s4hN's spec:
the chosen representation, its scope (UDF arguments only, or every
`db_push_value` caller), and whether the integer fallback is settled
in the same change. The decision belongs to the project owner; the
orchestrator carries the a/b/c question to them.

## Non-goals

- No code; the build is 3If5s4hN once its spec names the choice.
