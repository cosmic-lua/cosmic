## Evidence

`vmX5_zQH2` («gentype: carry a binding's success @overload into its Teal
declaration, closing the 4 unix-path casts») named 4 cast sites to close
by teaching `_types/gentype_parse.tl`/`gentype_render.tl` to render a
binding's success `@overload` entries into its Teal declaration:
`cosmic/net/socket.tl:334` (`bind`), `:397` (`connect`), `:437`
(`setsockopt`), and `cosmic/net/connect.tl:95`.

A builder implemented the generator change (collecting and rendering
success overloads, folding the error tuple onto them when the primary is
fallible) and verified it against all 32 real upstream `@overload`
entries in `tool/net/definitions.lua` — all parse and render as valid
Teal. Using it, 3 of the 4 named casts close cleanly and are verified
green (`bind`, `connect`, and `cosmic/net/connect.tl:95`'s
`unix_with_timeout`).

The 4th, `cosmic/net/socket.tl:437` (`-- cast: function shape (timeval
overload)`), does NOT close. That cast covers `unix.setsockopt`'s
`SO_RCVTIMEO`/`SO_SNDTIMEO` `(secs, nanos)` shape — a real call form the
C binding supports (`third_party/lua/cosmo/lunix.c:2069`,
`IsSockoptTimeval`) — but `tool/net/definitions.lua` documents this shape
only in PROSE (`unix.setsockopt(fd:int, level:int, optname:int,
secs:int[, nanos:int])` at lines 6450-6452), never as a machine-readable
`@overload` tag. The generator has nothing to render for it. Confirmed
directly against the generated types with the cast removed:

    cosmic/net/socket.tl:432:82: error: argument 5: got integer, expected boolean
    cosmic/net/socket.tl:436:76: error: argument 5: got integer, expected boolean

The two real `setsockopt` `@overload` entries in `definitions.lua`
(SO_LINGER, TCP_SAVE_SYN) don't match this call's argument shape either
— this is a distinct, undocumented overload, not a rendering bug in the
generator built for this item.

## The question

`cosmic/net/socket.tl:437`'s cast cannot close within `vmX5_zQH2`'s
scope: the fix is a `tool/net/definitions.lua` change in the
`cosmic-lua/cosmopolitan` repo (add the missing
`---@overload fun(fd: integer, level: integer, optname: integer, secs:
integer, nanos: integer): true` — or equivalent — to `unix.setsockopt`'s
existing annotation), landed as its own change there, then a
`bin/cosmic.pin` bump on the cosmic side to pick it up (per this repo's
own convention: a binding annotation change is never folded into an
unrelated change, and a new pin-dependent capability stages behind the
pin bump). Until that lands, `socket.tl:437`'s cast is a genuine floor
case, not a defect in the generator.

Two things need doing, in order:
1. File and land the `definitions.lua` change in `cosmic-lua/cosmopolitan`
   (its own item, its own PR).
2. Bump `bin/cosmic.pin` to a release carrying it (blocked on 1).

Only then can a successor to `vmX5_zQH2`'s 4th site close.

## Non-goals

Not re-litigating the generator design (`gentype_parse.tl`/
`gentype_render.tl`'s overload collection and rendering) — it is correct
and verified against all 32 real upstream overloads. Not blocking the
other 3 sites' closure on this — they should land as their own,
re-scoped change once refined.
