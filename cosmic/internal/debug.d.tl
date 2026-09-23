-- The native line-coverage collector provided by core/coverage.c. Lua's
-- `debug` library is never opened. A shipped runtime exposes this module
-- through the store searcher's trusted-module gate; boot preloads it for
-- the trusted source-tree bridge.

local record native
  -- Every source line hit while collecting was on, by the module's
  -- own import path: the chunk's full source identifier with its
  -- leading `@` removed. Other source identifiers are kept verbatim.
  type Hits = {string: {integer: boolean}}

  -- Installs the line hook and begins a fresh, empty collection,
  -- discarding anything collected before. With `watched`, which maps C
  -- functions to names, calls are hooked too, and each one called is
  -- named by `called`.
  start: function(watched?: {any: string})

  -- Removes the line hook and returns everything hit since the
  -- matching `start`.
  stop: function(): Hits

  -- A copy of everything hit so far, without touching the hook or the
  -- collection -- safe to call while collection keeps running, unlike
  -- `stop`. Empty when no `start` has run.
  snapshot: function(): Hits

  -- The name of every watched function called since `start`.
  called: function(): {string: boolean}
end

return native
