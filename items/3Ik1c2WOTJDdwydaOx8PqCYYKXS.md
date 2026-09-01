## Goal

`unix.readlink`'s second parameter is documented as a directory file
descriptor but the implementation actually treats it as a buffer size
— a doc/implementation parameter-meaning mismatch surfaced while
classifying the unix filesystem-namespace census. A caller trusting
the documented `@param` would silently misuse this argument with no
type error to catch the mistake.

## Evidence

`tool/net/definitions.lua:5245-5246` declares:
```
---@param path string
---@param dirfd? integer
```
with the doc prose above (lines 5235-5244) never mentioning any
deviation from that claim.

But `third_party/lua/cosmo/lunix.c:538-543` (`LuaUnixReadlink`,
function body `:544-562`) carries its own comment stating explicitly:

"Note: this fork changed arg 2 from a dirfd (upstream) to a buffer
size; AT_FDCWD is always used. bufsiz is clamped to `[1, 0x7ffff000]`."

Confirmed by the implementation itself, which passes arg 2 straight
into `luaL_buffinitsize(L, &lb, bufsiz)` and never into any `*at()`
dirfd slot.

A caller following `definitions.lua`'s own `@param dirfd? integer`
annotation and passing an actual directory fd as the second argument
would have it silently reinterpreted as a buffer size (likely under-
or over-allocating, or hitting the `ENAMETOOLONG` path at an
unexpected size) with no type error to catch the mistake.

## Change

Update `tool/net/definitions.lua`'s `unix.readlink` doc comment and
`@param` annotation to describe the real second parameter (an optional
buffer size, clamped to `[1, 0x7ffff000]`, defaulting to `AT_FDCWD`
resolution semantics as implemented) instead of the stale "dirfd"
claim inherited from upstream.

## Non-goals

- No change to `unix.readlink`'s actual behavior — documentation only.
- No change to any other binding in the filesystem-namespace census
  slice.

## Acceptance

- `unix.readlink`'s `tool/net/definitions.lua` doc comment and
  `@param` annotation for its second parameter match its actual,
  current behavior (a buffer size, not a dirfd).
