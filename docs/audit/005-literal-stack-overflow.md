# 005 — `cosmic.literal` throws on deep nesting

severity: high
type: bug (contract violation), minor security (crash on crafted input)
area: `cosmic/literal.tl`, callers in `_make/pin.tl`, `_build/*`

## issue

`parse_table` recurses once per nesting level with no depth cap. a deeply
nested `return { a = { a = { ... }}}` blows the Lua stack and **throws**
(`stack overflow`) instead of returning `nil, string`. verified empirically
against the branch binary with a 200k-deep literal:
`pcall ok = false, "/zip/cosmic/literal.lua:66: stack overflow"`.

this violates the repo's library contract ("never throw from library code")
in exactly the module whose promise is that reading a pin "is data, never
executed, and cannot do anything". no caller pcalls it, so
`cosmic --make fetch` over such a pin dies with a traceback.

## where

- `cosmic/literal.tl:36` (`parse_table`) — recursive descent, no depth
  parameter.
- `cosmic/literal.tl:65-71` — the nested-table branch recurses.
- unprotected callers: `_make/pin.tl:63`, `_build/build-fetch.tl:106`,
  `_build/build-stage.tl:324`, `_build/make-boot.tl:49`.

## failure scenario

a hostile or corrupted `*.pin.tl` (e.g. in a third-party repo someone runs
`--make check`/`fetch` against — the untrusted-repo case the design
explicitly defends) crashes the process instead of producing the polite
refusal every other malformed pin gets.

## suggested fix

thread a depth counter through `parse_table` and return
`nil, where .. ": literal nesting too deep (limit N)"` past a small limit —
16 or 32 is far beyond any real pin. this keeps the fix inside the module;
callers need no change.

## test to add

a literal test feeding a programmatically built deep literal (a few hundred
levels is enough once the limit exists) and asserting a `nil, err` return,
not a throw.
