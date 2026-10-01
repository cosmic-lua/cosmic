--- Line coverage for test tooling: which source lines ran between
--- `start` and `stop`. A core built with native coverage also reports
--- the lines of its own C, by repository path (see
--- [`Coverage.native_lines`]).
---
--- Only one collection window may be open. `start` refuses, changing
--- nothing, while another is active, and `stop` accepts only the
--- session that `start` returned. All callers share this state.

-- The collector is exposed as [`cosmic.internal.debug`] only while this
-- trusted wrapper loads from the binary's own tree. The wrapper keeps
-- the raw table private and exposes collection windows guarded by an
-- opaque session token. Lua's `debug` library is never opened.

local type NativeCoverage = require("cosmic.internal.debug")

local extra: any = select(2, ...)
local native: NativeCoverage
if type(extra) == "table" then
  native = extra as NativeCoverage
else
  native = require("cosmic.internal.debug")
end

local record Coverage
  --- The lines hit, as a map from a module's import path to the set of
  --- its line numbers (`hits[path][line] == true`). The path is the
  --- chunk's full source identifier with its leading `@` removed.
  type Hits = NativeCoverage.Hits

  --- One of the core's own C functions: `path` is its file by
  --- repository path, `line` the line it begins on, which a hit names
  --- when the function was entered, and `name` its name.
  type Function = NativeCoverage.Function

  --- An opaque handle to one open collection window, compared only by
  --- identity: the value `start` returns is the only value `stop`
  --- accepts back to close that same window. It carries no fields --
  --- there is nothing for a caller to read or forge a lookalike from.
  record Session
  end
end

--- The open window's session, nil while none is open.
local active: Coverage.Session | nil = nil

--- Starts collecting line hits, discarding anything collected before,
--- and hands back the session `stop` needs to end this exact window.
--- Refuses, touching no shared state, while a window opened by an
--- earlier `start` is still open -- a second, unrelated caller cannot
--- silently reset a collection already in progress.
--- @return Session | nil The session `stop` must be called with, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.start(): Coverage.Session | nil, string
  if active ~= nil then
    return nil, "coverage collection is already active"
  end
  local session: Coverage.Session = {}
  active = session
  native.start()
  return session, ""
end

--- Stops collecting and hands back every line hit since the matching
--- `start`, by module import path -- but only for the exact `session`
--- that `start` returned. Any other value, including no collection
--- being open at all, is refused without touching the real window: the
--- hook stays installed, the window stays open, and nothing already
--- gathered is discarded. This is what keeps a caller other than the
--- one that opened the window from ending or corrupting it.
--- @param session Session The value the matching `start` returned
--- @return Hits | nil Every line hit since `start`, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.stop(session: Coverage.Session): Coverage.Hits | nil, string
  if active == nil or session ~= active then
    return nil, "no matching open coverage collection for this session"
  end
  active = nil
  return native.stop(), ""
end

--- Every line of the core's own C a hit could land on, by the file's
--- path in the cosmic repository, in the same form hits on it take:
--- what C hits are counted out of. Every core cosmic ships and tests with is
--- built with native coverage; one that is not (a test fixture's)
--- answers an empty table, and its hits never name a C file.
--- @return Hits Every observable C line, each true
function Coverage.native_lines(): Coverage.Hits
  return native.lines()
end

--- Every one of the core's own C functions, by the line it begins on --
--- a function was entered when a hit names that line -- and its name.
--- Empty in a core without native coverage.
--- @return {Function} Every C function of the core
function Coverage.native_functions(): {Coverage.Function}
  return native.functions()
end

--- Every process started from now on, and every one those start --
--- whatever environment it is given -- writes the core's C it ran into
--- `directory` as it exits: one file a process, each line a repository
--- path, a tab, and a line number. A program never sees how: the core
--- carries the directory to each process itself.
--- @param directory string Where each process writes its lines
function Coverage.children(directory: string)
  native.children(directory)
end

return Coverage
