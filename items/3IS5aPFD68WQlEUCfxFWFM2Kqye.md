`tool/net/definitions.lua`'s prose for `cosmo.EncodeLua` still ends with
"The only failure return condition currently implemented is when C runs
out of heap memory." That stopped being true when the `literal` option
landed (PR #278, released in `2026.08.26-fe7c36c4c`): with
`literal = true` the encoder returns `nil, reason` for a non-string or
reserved-word key, byte 27 in a key or string, `math.mininteger`, NaN and
the infinities, a function/thread/userdata/light userdata, a cyclic
table, and nesting past `maxdepth`.

Observed against the released binary (the definitions file ships at
`/zip/.lua/definitions.lua`):

```text
unzip -q cosmos.zip -d cosmos
./cosmos/lua -e 'local f=io.open("/zip/.lua/definitions.lua")
  local s=f:read("a") print(s:match("The only failure return[^\n]*"))'
# The only failure return condition currently implemented is when C runs out of heap memory.
```

The `@field literal` annotation added by that PR documents the refusals
correctly; only this older sentence, a few lines below it, contradicts
them. `definitions.lua` is the fork's single source of truth for binding
annotations and cosmic generates its Teal declarations from it, so the
contradiction is carried into the type layer's own doc text.

Fix is one sentence in `tool/net/definitions.lua`, in whilp/cosmopolitan.
