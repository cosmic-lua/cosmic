--- Line coverage: which lines of the tree's own modules actually ran,
--- collected by a native, C-side line hook while the tests run
--- (core/coverage.c) -- one hook firing per line executed, entirely in
--- C, with no Lua-level `debug.getinfo` call and no Lua closure
--- invoked per line.
---
--- The raw module behind this one lives under `cosmic.internal.`, the
--- same reserved namespace `cosmic.store`/`cosmic.sqlite` route
--- through -- see cosmic/store.tl for why a wrapper never gets the raw
--- value by requiring it directly at runtime. What it hands over here
--- is the native collector itself, `{start, stop}` (cosmic/internal/
--- debug.d.tl): this module used to need the real Lua `debug` library
--- instead, back when collection ran through `debug.sethook`/
--- `debug.getinfo` from Lua. `debug` stays hidden the same way and for
--- the same reason regardless -- full debug access can inspect or
--- rewrite any local variable and the whole call stack of a running
--- state, grouped with `io`/`os` under core/surface.c's
--- `make_private` on its own account, not this module's -- nothing
--- fetches it back out any more, this module included, so the raw
--- name it used to occupy now carries the native collector instead.
--- Same trust gate as before, no looser a check: the searcher hands
--- the raw table over only when `cosmic.coverage` is itself loaded,
--- trusted, from the binary's own tree (core/store.c's
--- `store_searcher`), and this module's own API never hands the raw
--- table back out: only `start`/`stop`.
---
--- That load-time gate answers a narrower question than it looks like
--- it does. `names_trusted_kind` (core/store.c) trusts a load by the
--- LOADED module's own name and kind, not by who is requiring it, and
--- `require` caches the result of the first load process-wide -- so in
--- an ordinary running binary `cosmic.coverage` loads trusted exactly
--- once, and every later `require("cosmic.coverage")`, from `build.test`
--- or from any ordinary test file anywhere in the tree, gets back the
--- SAME already-trusted module table, closing over the SAME shared
--- `collecting` state. The load-time gate keeps a hostile or malformed
--- database from ever handing out a working native collector; it was
--- never a way to keep one legitimate caller's collection window safe
--- from another caller that also holds this module.
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

local type NativeCoverage = require("cosmic.internal.debug")

local extra: any = select(2, ...)
local native: NativeCoverage
if type(extra) == "table" then
  native = extra as NativeCoverage
else
  native = require("cosmic.internal.debug")
end

local record Coverage
  --- Every source line hit while collecting was on, by the module's
  --- own import path: the chunk's full source identifier with its
  --- leading `@` removed (see cosmic/internal/debug.d.tl).
  type Hits = NativeCoverage.Hits

  --- An opaque handle to one open collection window, compared only by
  --- identity: the value `start` returns is the only value `stop`
  --- accepts back to close that same window. It carries no fields --
  --- there is nothing for a caller to read or forge a lookalike from.
  record Session
  end
end

local collecting = false
local active: Coverage.Session | nil = nil

--- Starts collecting line hits, discarding anything collected before,
--- and hands back the session `stop` needs to end this exact window.
--- Refuses, touching no shared state, while a window opened by an
--- earlier `start` is still open -- a second, unrelated caller cannot
--- silently reset a collection already in progress.
--- Only one collection window may be open at a time: call
--- `Coverage.stop` with the session an earlier `Coverage.start`
--- returned before starting another.
--- @return Session | nil The session `stop` must be called with, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.start(): Coverage.Session | nil, string
  if collecting then
    return nil, "coverage collection is already active"
  end
  collecting = true
  local session: Coverage.Session = {}
  active = session
  native.start()
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
  collecting = false
  active = nil
  return native.stop(), ""
end

--- A copy of every line hit so far, without ending the collection or
--- needing the session `start` returned: unlike `stop`, this only
--- reads, so any caller may look in on a window it did not open,
--- while it is still running, without the session token's refusal
--- rules -- there is nothing here for a second caller to corrupt.
--- Empty when no collection is open.
--- @return Hits Every line hit so far
function Coverage.snapshot(): Coverage.Hits
  if not collecting then
    return {}
  end
  return native.snapshot()
end

return Coverage
