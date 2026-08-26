`cosmo.EncodeLua` writes a table key that is a Lua keyword as a bare
identifier, producing source that does not parse. Measured 2026-08-26
with `o/bin/cosmic` built from cosmic main `5ba85817` (cosmos pin
`2026.08.26-1e1658153`):

```text
cosmo.EncodeLua({["end"] = 1})      --> {end=1}
  load("return {end=1}")            --> nil, unexpected symbol near 'end'
cosmo.EncodeLua({["function"] = 2}) --> {function=2}
  load("return {function=2}")       --> nil, '(' expected near '='
```

The encoder decides bare-vs-bracketed with `IsLuaIdentifier`
(`third_party/lua/luaencodeluadata.c:41-50` in whilp/cosmopolitan),
which asks only `lislalpha` on the first byte and `lislalnum` on the
rest. All 22 Lua keywords pass that test, so each is emitted unquoted.
The bracketed form the encoder already knows how to write
(`{["k\e"]=1}` in the same probe) is correct for every one of them.

The fix is one condition in `IsLuaIdentifier`: a string that is a Lua
keyword is not an identifier for this purpose. That is a whilp/cosmopolitan
change (`--repo whilp/cosmopolitan`), landed with a
`tool/lua/test/` case and no `definitions.lua` movement — the return
shape does not change, only the bytes for input that is currently
mis-encoded.

Severity: `EncodeLua` is advertised as producing Lua source, and this is
the one input class where it silently does not. cosmic does not hit it
today because `cosmic/_literal_format.tl:307-314` carries its own
`RESERVED` keyword table and hands such a value to the pin layout
instead — a workaround for this bug, whether or not it was written as
one. That workaround is on the path board item `3IOFN9bn` is deleting,
so this should be fixed before the walk goes, or the bug becomes
reachable from `literal.format`.
