## Goal

Same deviation family as `re.Regex:search`/`re.Regex:match`
(captures `3IiuEB99` and the `re.Regex:match` capture) — the
module-level one-shot convenience `re.search` carries the identical
slot-2 double-duty, compiling internally then delegating to the same
search body.

## Evidence

- C source: `tool/net/lre.c:136-153` (`LuaReSearch`), calling
  `LuaReCompileImpl` (`lre.c:42-59`) then `LuaReSearchImpl`
  (`lre.c:61-93`); error path `LuaReReturnError` (`lre.c:34-40`).
- `tool/net/definitions.lua:1494-1527`, same "third slot" doc text as
  `re.Regex:search`.
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); print(re.search("(a)(b)", "xxabxx"))'
  ab	table: 0x...
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); print(re.search("[invalid", "xxabxx"))'
  nil	Missing ']'
  ```
  (Second probe demonstrates the data-dependent path: a malformed
  pattern is compiled internally on every call, so bad user-supplied
  regex text reaches this exact slot-2 error string.)
- cosmic-side spend (`grep -rn '\bre\.search(' cosmic/` in a
  `cosmic-lua/cosmic` checkout): zero hits. `cosmic/re.tl`'s
  module doc frames its own `match`/`find` convenience functions as
  the replacement (cached `compile` + method call), so this binding is
  unused by cosmic today.

## Change

Same shape fix as the `re.Regex:search` capture `3IiuEB99` (delegates
to the same `LuaReSearchImpl`); land together — a single
`definitions.lua` + `lre.c` comment change plausibly resolves that
capture, this capture, and the `re.Regex:match` capture at once.

## Non-goals

Same as `3IiuEB99`. No change proposed to make cosmic adopt this
binding — it currently has zero cosmic-side callers and that is out of
this capture's scope.

## Acceptance

Same as `3IiuEB99`, scoped to `re.search`'s own `definitions.lua`
annotation and the coverage/conformance test for `re`.
