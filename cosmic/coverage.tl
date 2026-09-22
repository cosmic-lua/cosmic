--- Line coverage collected by the native C line hook in core/coverage.c.
--- Lua's `debug` library is never opened; the VM's internal debugging
--- support remains available to the native hook and tracebacks.
---
--- The collector is exposed as `cosmic.internal.debug` only while this
--- trusted wrapper loads from the binary's own tree. The wrapper keeps
--- the raw table private and exposes collection windows guarded by an
--- opaque session token.
---
--- Only one window may be open. `start` refuses without changing state
--- while another is active, and `stop` accepts only the exact token that
--- opened it. All callers share this module's cached state.

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
