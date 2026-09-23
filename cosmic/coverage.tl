--- Line coverage collected by the native C line hook in core/coverage.c.
--- A core built with native coverage adds the lines of its own C, by
--- repository path (see `Coverage.native_lines`).
--- Lua's `debug` library is never opened; the VM's internal debugging
--- support remains available to the native hook and tracebacks.
---
--- A C function has no lines for the line hook to see, so a caller that
--- wants to know which C functions ran names them to `start`, and every
--- one called comes back among the hits as one line of a path of its
--- own, `called_path(name)`: a path that starts with `=`, which is
--- Lua's own mark for a chunk name that is not a file, so no module's
--- path is ever one. Carried that way, a call goes wherever a hit
--- already goes.
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

  --- One of the core's own C functions: `path` and `line` name the line
  --- it begins on, which a hit names when the function was entered.
  type Function = NativeCoverage.Function

  --- The line of a `called_path` path a call is recorded on.
  called_line: integer

  --- An opaque handle to one open collection window, compared only by
  --- identity: the value `start` returns is the only value `stop`
  --- accepts back to close that same window. It carries no fields --
  --- there is nothing for a caller to read or forge a lookalike from.
  record Session
  end
end

Coverage.called_line = 1

local called_prefix <const> = "=C "

--- The path the hits record a call of the watched function `name` under.
function Coverage.called_path(name: string): string
  return called_prefix .. name
end

--- The watched name `path` records calls of, or nil when `path` is a
--- chunk's own.
function Coverage.called_name(path: string): string | nil
  if path:sub(1, #called_prefix) == called_prefix then
    return path:sub(#called_prefix + 1)
  end
  return nil
end

--- `hits`, with every watched function called so far added to it.
local function with_calls(hits: Coverage.Hits): Coverage.Hits
  for name in pairs(native.called()) do
    hits[Coverage.called_path(name)] = { [Coverage.called_line] = true }
  end
  return hits
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
---
--- `watch` maps each C function whose calls should be recorded to the
--- name `called_path` records it under. Without it only lines are
--- hooked, and a call costs nothing extra.
--- @param watch {any: string} The C functions to record calls of, by name
--- @return Session | nil The session `stop` must be called with, or nil if refused
--- @return string Error message when refused, "" on success
function Coverage.start(watch?: {any: string}): Coverage.Session | nil, string
  if collecting then
    return nil, "coverage collection is already active"
  end
  collecting = true
  local session: Coverage.Session = {}
  active = session
  native.start(watch)
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
  local hits = native.stop()
  return with_calls(hits), ""
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
  return with_calls(native.snapshot())
end

--- Every line of the core's own C a hit could land on, by repository
--- path (`core/syscalls.c`), in the same form hits on it take: what C
--- hits are counted out of. Every core cosmic ships and tests with is
--- built with native coverage; one that is not (a test fixture's)
--- answers an empty table, and its hits never name a C file.
--- @return Hits Every observable C line, each true
function Coverage.native_lines(): Coverage.Hits
  return native.lines()
end

--- The line each of the core's own C functions begins on, among
--- `native_lines`: a function was entered when a hit names its line.
--- Empty in a core without native coverage, like `native_lines`.
--- @return Hits Every C function's first line, each true
function Coverage.native_entries(): Coverage.Hits
  return native.entries()
end

--- Every one of the core's own C functions, by the line it begins on
--- (`native_entries`) and its name. Empty in a core without native
--- coverage.
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
