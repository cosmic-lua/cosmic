-- The native line-coverage collector provided by core/coverage.c. Lua's
-- `debug` library is never opened. A shipped runtime exposes this module
-- through the store searcher's trusted-module gate; boot preloads it for
-- the trusted source-tree bridge.

local record native
  -- Every source line hit while collecting was on, by the module's
  -- own import path: the chunk's full source identifier with its
  -- leading `@` removed. Other source identifiers are kept verbatim.
  -- A core built with native coverage adds its own C files here too.
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

  -- Every line of the core's own C that a hit could land on, keyed by
  -- repository path (core/syscalls.c) the way hits on it are. Empty in
  -- a core built without native coverage.
  lines: function(): Hits
end

return native
