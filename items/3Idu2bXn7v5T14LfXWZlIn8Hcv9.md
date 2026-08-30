## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port the correctness check for this
fork's Lua-language syntax extensions — binary and octal numeral
literals, the `*` string-repeat operator, and the `%` string-format
operator — into `tool/lua/`, wired into `o//tool/lua/test`. Nothing in
`tool/lua/` asserts these directly today, even though many of the
fork's OWN test files use them.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory row (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/lua_test.lua`, `none`, `covered by` `—`.

```text
cat test/tool/net/lua_test.lua
# assert(0b100 == 4); assert(0200 == 128); assert("\e" == "\x1b")
# assert("hi" * 3 == "hihihi"); assert("hello %d" % {123} == "hello 123")
# + a ProgramContentType block
grep -rl "' *%' \|string-repeat\|0b[01]" tool/lua/*_test.lua
# (no dedicated test found; the operators are USED throughout, e.g.
#  test/tool/net/futex_test.lua and mapshared_test.lua both call
#  'process %d exited with %s' % {rc, ...})
```

`0b100`/`0200` are numeral-literal syntax extensions the Lua parser
itself was patched to accept (`0200` is 128 in octal, not 200 in
decimal — plain Lua has no octal literal, so this is not a
restatement of an existing rule); `"hi" * 3` and `"fmt" % {...}` are
operator-overload extensions on the `string` metatable. That the whole
fork uses `%` formatting constantly (`spinlock_test.lua`,
`futex_test.lua`, and others all call it) proves the FEATURE works;
none of that is the same as a dedicated correctness assertion for it,
and there is no such assertion anywhere in `tool/lua/`.

`lua_test.lua` ALSO asserts `ProgramContentType("txt") ==
"text/plain"` and related calls — `ProgramContentType` is a
redbean-only MIME-type-registry global tied to redbean's static file
server. It has no `cosmo.*` equivalent (absent from every module
`test_definitions_coverage.lua` enumerates: `cosmo`, `unix`, `path`,
`re`, `argon2`, `lsqlite3`, `getopt`, `zip`, `cov`, `repl`) — this is
the one genuinely retired fragment inside an otherwise-portable file;
drop it rather than port a call to a global the fork does not link.

The file uses no `require`; it calls `unix.pledge` and
`ProgramContentType` as bare globals; the language-extension
assertions (`0b100`, `"hi"*3`, etc.) are pure syntax and need no
binding at all.

## Change

One new file, `tool/lua/test_lua_extensions.lua`, from
`test/tool/net/lua_test.lua`, with:

```lua
local unix = require("cosmo.unix")
```

...and the `ProgramContentType` block (source lines 25-32: the
`assert(ProgramContentType(...) == ...)` calls and the
`ProgramContentType("1", "text/x-foo")` registration) DROPPED. Every
other assertion (`0b100`, `0200`, `"\e"`, `"hi" * 3`,
`"hello %d" % {123}`) moves unchanged.

`tool/lua/BUILD.mk:222-251` gets one new three-line rule
(`o/$(MODE)/tool/lua/test_lua_extensions.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_lua_extensions.lua`, run, `@touch $@`) and one new
`TOOL_LUA_TESTS` line.

## Non-goals

- No binding change, and no language-parser change. If `0b100`/`0200`
  or the `*`/`%` string operators no longer parse or no longer produce
  the asserted value, that is a real regression finding for a
  DIFFERENT item — this slice only writes the check, it does not
  repair the language.
- Do not port `ProgramContentType`. It is genuinely retired (a redbean
  server global with no fork equivalent) — see Evidence. Do not invent
  a `cosmo.*` substitute for it here; that would be a binding change.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 1 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the new
`tool/lua/test_lua_extensions.lua` file and the `tool/lua/BUILD.mk`
diff.
