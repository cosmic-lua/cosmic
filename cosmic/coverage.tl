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
---
--- That load-time gate answers a narrower question than it looks like
--- it does. `names_trusted_kind` (core/store.c) trusts a load by the
--- LOADED module's own name and kind, not by who is requiring it, and
--- `require` caches the result of the first load process-wide -- so in
--- an ordinary running binary `cosmic.coverage` loads trusted exactly
--- once, and every later `require("cosmic.coverage")`, from `build.test`
--- or from any ordinary test file anywhere in the tree, gets back the
--- SAME already-trusted module table, closing over the SAME shared
--- `hits`/`collecting` state. The load-time gate keeps a hostile or
--- malformed database from ever handing out a working `debug` table; it
--- was never a way to keep one legitimate caller's collection window
--- safe from another caller that also holds this module.
---
--- `start`/`stop` close that second gap with a session token, entirely
--- independent of the load-time trust check above. `start` refuses (and
--- touches nothing) when a collection is already open, so a second
--- caller cannot silently reset the window a first caller is still
--- using; the `Session` value it returns on success is an opaque table,
--- compared only by identity. `stop` refuses (and touches nothing) for
--- any session that is not that exact value -- a bare `Coverage.stop()`
--- with no argument, or one holding a session from its own unrelated
--- `start`/`stop` pair, cannot end or corrupt a window it did not open.
--- The only caller today is `build.test`'s own whole-run instrumentation;
--- nothing else in this tree's actual design needs a second one, so this
--- is the one built for that one caller, not a general multi-tenant
--- scheduler.

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

  --- An opaque handle to one open collection window, compared only by
  --- identity: the value `start` returns is the only value `stop`
  --- accepts back to close that same window. It carries no fields --
  --- there is nothing for a caller to read or forge a lookalike from.
  record Session
  end
end

local hits: Coverage.Hits = {}
local collecting = false
local active: Coverage.Session | nil = nil

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

--- Starts collecting line hits, discarding anything collected before,
--- and hands back the session `stop` needs to end this exact window.
--- Refuses, touching no shared state, while a window opened by an
--- earlier `start` is still open -- a second, unrelated caller cannot
--- silently reset a collection already in progress.
---
--- `install_hook` (default true) governs only whether the per-line
--- hook itself goes in: a caller that passes false still opens a real
--- window -- `stop` still ends it, a second `start` still refuses --
--- it just collects nothing, at none of the per-line `debug.getinfo`
--- cost. `build.test` uses this to keep the window/session contract
--- its own tests rely on without paying that cost on every run, until
--- a collector cheap enough to leave on by default lands (see
--- doc/roadmap.md).
--- @param install_hook boolean? Install the actual line hook (default true)
--- @return Session | nil The session `stop` must be called with, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.start(install_hook?: boolean): Coverage.Session | nil, string
  if collecting then
    return nil, "coverage collection is already active"
  end
  hits = {}
  collecting = true
  local session: Coverage.Session = {}
  active = session
  if install_hook ~= false then
    dbg.sethook(on_line, "l")
  end
  return session, ""
end

--- Stops collecting and hands back every line hit since the matching
--- `start`, by module import path -- but only for the exact `session`
--- that `start` returned. Any other value, including no collection
--- being open at all, is refused without touching the real window: the
--- hook stays installed, `collecting` stays true, and nothing already
--- gathered is discarded. This is what keeps a caller other than the
--- one that opened the window from ending or corrupting it.
--- @param session Session The value the matching `start` returned
--- @return Hits | nil Every line hit since `start`, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.stop(session: Coverage.Session): Coverage.Hits | nil, string
  if not collecting or session ~= active then
    return nil, "no matching open coverage collection for this session"
  end
  dbg.sethook(nil, "")
  collecting = false
  active = nil
  local collected = hits
  hits = {}
  return collected, ""
end

return Coverage
