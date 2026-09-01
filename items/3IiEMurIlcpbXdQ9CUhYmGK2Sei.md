## Finding

`tool/net/fetch.inc:696` raises the `too_large` fetch error as:

```c
LuaFetchError(L, "too_large", "response too large (max %I bytes)",
              (LUAI_UACINT)maxresponse);
```

`%I` is not a recognized conversion in Cosmopolitan's libc format engine, so
the rendered message is literally `"response too large (max I bytes)"` — the
configured byte limit never actually appears in the error string.

## Symptom

Any caller inspecting a `too_large` `cosmo.Fetch` error to report or log the
configured `maxresponse` value gets a message with no number in it. Confirmed
live against a current `cosmic-lua/cosmopolitan` build, real network
reachable:

```text
$ o/tool/lua/lua.dbg -e 'local Fetch = require("cosmo").Fetch
local _, err = Fetch("https://httpbin.org/get", {maxresponse = 100})
print(err)'
response too large (max I bytes)
```

## Provenance

Surfaced 2026-09-01 while building item `3Idu1WF5` (handle «mWAm_RQTM»,
"salvage cosmo.Fetch's HTTP-proxy contract tests") — that item's spec named
`test_response_too_large_error_message` as a test to port, which asserts
`err:match("max %d+ bytes")`; the assertion fails against the current tree
because of this bug, independent of the test's own network-reachability
question (filed as its own sibling item). Fixing this binding is outside
that item's `## Change` and its `## Non-goals` explicitly forbid touching
`tool/net/fetch.inc`.

## Change

Needs a refiner: the fix is presumably swapping `%I` for the correct libc
format conversion matching `LUAI_UACINT`'s actual type (likely `%zu` or a
`PRI*`-style macro depending on how Cosmopolitan's fmt engine handles
`LUAI_UACINT`, which should be checked against its typedef), updating
`tool/net/definitions.lua`'s documented error string for `too_large` in the
same commit per this repo's binding-contract doctrine (the new AGENTS.md
bullet from `3IRIi0Dz`/PR #302), and a regression test pinning the byte
count actually appears in the message.
