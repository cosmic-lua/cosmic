--- Line coverage: which lines of the tree's own modules actually ran,
--- collected through Lua's line hook while the tests run.
---
--- The raw module behind this one lives under `cosmic.internal.`, the
--- same reserved namespace `cosmic.store`/`cosmic.sqlite` route
--- through -- see cosmic/store.tl for why a wrapper never gets the raw
--- value by requiring it directly at runtime. What it hands over here
--- is Lua's own `debug` library, taken out of reach everywhere else in
--- this runtime (core/surface.c's `make_private`): full debug access
--- can inspect or rewrite any local variable and the whole call stack
--- of a running state, a strictly more dangerous surface than sqlite's,
--- so the same trust gate applies here with no looser a check -- the
--- searcher hands the raw table over only when `cosmic.coverage` is
--- itself loaded, trusted, from the binary's own tree
--- (core/store.c's `store_searcher`), and this module's own API never
--- hands the raw table back out: only `start`/`stop`.

local type raw_debug = require("cosmic.internal.debug")

local extra: any = select(2, ...)
local dbg: raw_debug
if type(extra) == "table" then
  dbg = extra as raw_debug
else
  dbg = require("cosmic.internal.debug")
end

local record Coverage
  --- Every source line hit while collecting was on, by the module's
  --- own import path -- a chunk's `short_src`, which is exactly its
  --- import path for every module this runtime loads (see
  --- cosmic/internal/debug.d.tl).
  type Hits = {string: {integer: boolean}}
end

local hits: Coverage.Hits = {}
local collecting = false

--- The line hook itself. Level 2 is the function whose line just
--- executed: level 0 is `getinfo` itself, level 1 is this function,
--- the hook `debug.sethook` calls directly.
local function on_line(_event: string, line: integer)
  local info = dbg.getinfo(2, "S")
  local path = info.short_src
  local for_path = hits[path]
  if for_path == nil then
    for_path = {}
    hits[path] = for_path
  end
  for_path[line] = true
end

--- Starts collecting line hits, discarding anything collected before.
--- Calling it again while already collecting starts over.
function Coverage.start()
  hits = {}
  collecting = true
  dbg.sethook(on_line, "l")
end

--- Stops collecting and hands back every line hit since the matching
--- `start`, by module import path. Calling it while not collecting
--- hands back an empty table.
function Coverage.stop(): Coverage.Hits
  if collecting then
    dbg.sethook(nil, "")
    collecting = false
  end
  local collected = hits
  hits = {}
  return collected
end

return Coverage
