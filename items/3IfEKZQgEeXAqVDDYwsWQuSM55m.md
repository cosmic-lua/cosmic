## Question

`skK4_s4BS`'s spec (salvage cosmo.path/readlink/Slurp-range tests) directs a
verbatim move of `test/tool/net/path_test.lua` to `tool/lua/test_path_values.lua`
(prelude only, no content adaptation) — but two of its assertions contradict the
binding's current, frozen contract:

```lua
assert(nil == path.join(nil))
assert(nil == path.join(nil, nil))
```

`cosmo.path.join` (`tool/net/lpath.c:78-118`) now **raises** on an all-nil call
(`luaL_error(L, "missing argument")`) instead of returning `nil` — a deliberate,
already-documented behavior change, already asserted the new way in
`tool/lua/test_definitions_conformance.lua` (a file this item's Non-goals forbid
touching):

```lua
assert(not pcall(path.join, nil), "join(nil) must raise")
assert(not pcall(path.join, nil, nil), "join(nil, nil) must raise")
```

Confirmed directly: running the two `path_test.lua` assertions as literally
written against the current `o/tool/lua/lua.dbg` fails both
(`FAIL join nil -- missing argument`, `FAIL join nil,nil -- missing argument`).
Every other assertion in `path_test.lua` (all `dirname`/`basename` cases, every
other `join` case including the long-string stress case and numeric-coercion
case) checks out cleanly against the current binary.

The item's spec already has precedent for exactly this: `slurp_test.lua`'s one
`Barf(...)` call is explicitly authorized to adapt from the old positional form
to the current options-table form on the way over. The two `join(nil[, nil])`
assertions need the analogous treatment, but the spec's Change table doesn't
authorize it for `path_test.lua` — it says "verbatim... only a `require` prelude
added."

## What needs deciding

How should `path_test.lua`'s two `path.join(nil[, nil])` assertions be handled
on the port? The evident analogous fix (mirroring the `Barf` precedent) is:

```lua
assert(not pcall(path.join, nil), "join(nil) must raise")
assert(not pcall(path.join, nil, nil), "join(nil, nil) must raise")
```

in place of the two `assert(nil == path.join(...))` lines, with `skK4_s4BS`'s
Change table amended to authorize this one content adaptation the same way it
already authorizes the `Barf` one. Confirm this is the right call (rather than,
say, dropping the two assertions as already covered by
`test_definitions_conformance.lua`, or some other resolution), then update
`skK4_s4BS`'s spec accordingly.
