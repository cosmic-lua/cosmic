-- The native line-coverage collector, as the core provides it
-- (core/coverage.c). This raw name once carried the real Lua `debug`
-- library instead, back when line coverage collected hits by calling
-- `debug.sethook`/`debug.getinfo` directly; `debug` itself is still
-- taken out of reach exactly the same way (core/surface.c's
-- `make_private`), for reasons that have nothing to do with this one
-- module, and nothing fetches it back out any more -- the native
-- collector goes behind this name in its place.

local record native
  -- Every source line hit while collecting was on, by the module's
  -- own import path: the chunk's full source identifier with its
  -- leading `@` removed. Other source identifiers are kept verbatim.
  type Hits = {string: {integer: boolean}}

  -- Installs the line hook and begins a fresh, empty collection,
  -- discarding anything collected before.
  start: function()

  -- Removes the line hook and returns everything hit since the
  -- matching `start`.
  stop: function(): Hits

  -- A copy of everything hit so far, without touching the hook or the
  -- collection -- safe to call while collection keeps running, unlike
  -- `stop`. Empty when no `start` has run.
  snapshot: function(): Hits
end

return native
