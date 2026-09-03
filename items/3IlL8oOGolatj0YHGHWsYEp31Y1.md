## Question

Which Lua-side representation makes a SQLite BLOB distinguishable
from TEXT at `db_push_value` (`tool/net/lsqlite3.c:1085`, moved from
the originally-cited :948 by unrelated upstream growth — same body),
and does that change apply to column reads as well as UDF arguments?

## Evidence

`db_push_value` pushes both `SQLITE_TEXT` and `SQLITE_BLOB` through
`lua_pushlstring`, so a UDF cannot tell `x'00FF'` from the text with
the same bytes. It has exactly two callers: `db_sql_normal_function`
(line 1160, UDF arguments) and `liter_table` (line 2036, backing
`liter_new`/`liter_old`/`liter_conflict` — the session/changeset
extension's old/new/conflict values; `SQLITE_ENABLE_SESSION` is
enabled in this build, `third_party/sqlite3/BUILD.mk:151`).

**Column reads do not go through `db_push_value`.** `db:rows()`,
`db:query()` and `vm:get_value()` go through a separate, textually
near-identical function `vm_push_column` (lines 153–176). Same
collapse pattern, different C function, structurally decoupled
already — `cosmic/sqlite/column.tl`'s own doc comment on
`column_text` already documents this path's ambiguity: "BLOB columns
also arrive as Lua strings ... the row carries no column affinity to
tell the two apart."

**Neither `db_push_value` call site is reachable from `cosmic.sqlite`
today**: it wraps neither `create_function`/`create_aggregate` nor
the session/changeset iterator (confirmed absent from every
`cosmic/sqlite/*.tl`). So candidate (a)'s stated cost — "every
existing reader of a blob column receives a new type" — is false for
`db_push_value` specifically; there is no existing `cosmic.sqlite`
consumer of its output to break. That cost is real only for
`vm_push_column`, which none of the candidates below propose
touching by default.

Three candidates, each with a real cost:

a. a wrapper userdata or table carrying the bytes — unambiguous, but
   costs a new public unwrap API (`cosmic/sqlite/bind.tl`'s `Blob`
   marker is write-only today) and breaks string ergonomics for any
   caller that wants to use a blob value directly;
b. a separate accessor reporting the SQL runtime type
   (`sqlite3_value_type`/`sqlite3_column_type` — nothing today
   exposes this; the existing `vm:type()`/`get_named_types()` report
   `sqlite3_column_decltype`, the *declared* schema type, which is
   unreliable since SQLite is dynamically typed) beside the value —
   the pushed value is unchanged everywhere, purely additive;
c. a distinct Lua type only inside UDF arguments, column reads left
   alone — narrow blast radius, two conventions in one binding.

Binding contracts are frozen at the C boundary (cosmopolitan
AGENTS.md); a and c are contract changes needing a `definitions.lua`
update in the same commit and a cosmic-side type regen plus wrapper
fix (`cosmic/sqlite/bind.tl`, `cosmic/sqlite/column.tl`) as their own
change; b is additive and does not change any existing contract.

The file's own established idiom for distinguishing SQL type at the
Lua boundary is a dedicated method per type, never a tagged return
value: `bind` vs `bind_blob` (`dbvm_bind_blob`, line 526) on the way
in, `Context:result` vs `result_blob`/`result_text`/`result_int`/
`result_double` (`definitions.lua` ~L630–660) on the way out. No
existing binding in this file hands back a runtime-type-tagged
*value*.

The same switch's `SQLITE_INTEGER` path (`PUSH_INT64`, lines 64–74)
falls back to a string when a 64-bit SQLite integer does not fit
`lua_Integer`. This is **dead code on this build**: `LUA_INT_TYPE`
defaults to `LUA_INT_LONGLONG` (`third_party/lua/luaconf.h:137,180`,
no override in any `BUILD.mk`), so `lua_Integer` is 64-bit signed,
exactly matching `sqlite_int64` — the fallback branch cannot execute.
There is no live behavior here to settle, in this change or any
other.

Gate re-run on the current tree (2026-09-03, cold build): `make
-j$(nproc) o//tool/lua/test` builds and passes clean — 28/28 in the
fetch/proxy suite, `test_coverage: PASS`, 340/539 binding functions
covered, no failures anywhere. `test_sqlite_deterministic.lua` (the
only existing test touching `db_push_value`'s UDF path) passes but
only exercises numeric arguments — no blob or out-of-range-integer
round-trip case exists today.

## Change

A decision, recorded on this item and applied to 3If5s4hN's spec:
the chosen representation, its scope (UDF arguments only, or every
`db_push_value`/`vm_push_column` caller), and whether the integer
fallback is settled in the same change. The decision belongs to the
project owner.

## Decision (confirmed by the project owner, 2026-09-03)

Representation: **(b)**, a new accessor exposing the real SQL
runtime type, matching this file's own established idiom of a
dedicated method per SQL type rather than a runtime-type-tagged
return value:

- `value_type(n)` on the UDF/session-extension side
  (`sqlite3_value_type`), named distinctly from the existing
  decltype-reporting `type()`/`get_named_types()` to avoid confusing
  the two (decltype is the declared schema type; this is the actual
  runtime type of the value, which SQLite's dynamic typing can
  disagree with);
- `column_type(n)` on the row-read side (`sqlite3_column_type`).

Both are called **separately from, not merged into**, the existing
value-getting call — an earlier draft of this decision considered a
combined `value, type = get_typed(n)` accessor for cosmic's internal
convenience (it always wants both), but the project owner chose the
two-separate-methods shape specifically to match this file's
established convention, over the efficiency argument for a combined
getter. Every existing push stays exactly as-is — still a plain Lua
string for both TEXT and BLOB — so this costs nothing against
existing callers, since none currently consume `db_push_value`'s
output through `cosmic.sqlite`.

Scope: **not narrowed to UDF arguments** — the same accessor pattern
applies to `db_push_value`'s two callers (UDF args, changeset
iterator) and to `vm_push_column`'s callers (ordinary column reads),
since (b) is additive everywhere and candidate (c)'s narrow-blast-
radius rationale doesn't apply when there is no blast radius to
narrow. This directly answers the item's own Question: yes, extend
to column reads too.

Integer fallback: **not part of this decision, and not its own
follow-up item either** — it is dead code under the current build
configuration (see Evidence: `lua_Integer` is already 64-bit,
matching `sqlite_int64` exactly, so `PUSH_INT64`'s string fallback
cannot execute). 3If5s4hN's spec is corrected to drop this claim
rather than carry a fix for a defect that cannot occur.

Layering (cosmopolitan repo vs. cosmic repo): the new `value_type`/
`column_type` accessors and their `definitions.lua` annotations are
a cosmopolitan-repo change (frozen C-boundary contract, additive, no
existing behavior changes). `cosmic.sqlite`'s ergonomic distinct
`Blob` type on read — built by checking the new accessor and
wrapping BLOB values before returning them to a `cosmic.sqlite`
caller — is a separate, follow-up cosmic-repo change (3If5s4hN),
landed against the cosmopolitan pin that carries the new accessors.
`cosmic/sqlite/bind.tl` dispatching on that `Blob` type to call
`bind_blob` automatically (giving round-trip fidelity without the
caller having to remember to do it manually) is part of that same
cosmic-repo follow-up, not a separate item.

## Non-goals

- No code; the build is 3If5s4hN once its spec names the choice —
  which it now does.
