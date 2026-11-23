--- The calls into the host that the driver's modules make through one
--- record, so that a test can put another in their place for as long as
--- it needs and restore them: the new checker holds a library's functions
--- fixed, and a test cannot assign [`Fs.append`] itself. A module that a
--- test stands a call in for takes that call from [`Seams.calls`], and
--- nothing else is routed through it.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

-- TODO: Child.FOREVER in place of CEILING_NS once ci/cosmic-driver.pin
-- names a release whose Child has it: ci/ runs on that release, where a
-- limit must be stated for the tree's checker yet FOREVER is not there.
local CEILING_NS <const> = 24 * 60 * 60 * 1000000000

--- A started child, as far as the fuzz run supervises it: the calls of a [`Child.Handle`] it makes, as functions a
--- test can fake. A `<close>` variable holding it calls `close` and reports no trouble, as one holding the handle does.
local class Started
  stop: function(signal?: integer): boolean, string
  try_wait: function(): Child.TryWait?, string
  drain: function(options: Child.DrainOptions): Child.DrainResult
  close: function(): boolean, string

  function __close(self)
    local _, _ = self.close()
  end
end

--- The calls a [`Started`] is made of, named, so a test cannot give one in another's place.
local record Parts
  stop: function(signal?: integer): boolean, string
  try_wait: function(): Child.TryWait?, string
  drain: function(options: Child.DrainOptions): Child.DrainResult
  close: function(): boolean, string
end

local function new_started(parts: Parts): Started
  return { stop = parts.stop, try_wait = parts.try_wait, drain = parts.drain, close = parts.close }
end

local record Seams
  type Started = Started
  type Parts = Parts
  --- Each call, named for the library function it starts as.
  record Calls
    mut child_run: function(argv: {string}, options?: Child.Options): Child.Result?, string
    mut child_start: function(argv: {string}, options?: Child.Options): Seams.Started?, string
    mut env_all: function(): {string:string}
    mut env_get: function(name: string): string?
    mut fs_absolute: function(path: string): string?, string
    mut fs_append: function(path: string, data: string, mode?: integer): boolean, string
    mut fs_exists: function(path: string): boolean?, string
    mut fs_open_write: function(path: string, mode?: integer): integer?, string
    mut fs_put: function(fd: integer, bytes: string): boolean, string
    fs_read: function(path: string): string?, string
    proc_user: function(name: string): Proc.User?, string
    mut signal_guard: function(): Signal.Guard?, string
    mut stream_tee: function(first: Stream.Writer, second: Stream.Writer): Stream.Writer
    sys_getuid: function(): integer
    sys_mkdtemp: function(template: string): string?, string, integer
    sys_pread: function(fd: integer, count: integer, offset: integer): string?, string, integer
  end
  --- The calls in force: the library's, until a test assigns its own to a
  --- field of the record, and puts the library's back.
  calls: function(): Calls
end

--- [`Child.start`], its handle offered as [`Seams.Started`].
local function start(argv: {string}, options?: Child.Options): Seams.Started?, string
  local handle, why = Child.start(argv, options or { timeout_ns = CEILING_NS })
  if handle == nil then return nil, why end
  return new_started({
    stop = function(signal?: integer): boolean, string return handle:stop(signal) end,
    try_wait = function(): Child.TryWait?, string return handle:try_wait() end,
    drain = function(drained: Child.DrainOptions): Child.DrainResult
      return handle:drain(drained)
    end,
    close = function(): boolean, string return handle:close() end,
  }), ""
end

local current: Seams.Calls = {
  child_run = function(argv: {string}, options?: Child.Options): Child.Result?, string
    return Child.run(argv, options or { timeout_ns = CEILING_NS })
  end,
  child_start = start,
  env_all = Env.all,
  env_get = Env.get,
  fs_absolute = function(path: string): string?, string
    local real, why = Fs.absolute(path)
    if real == nil then return nil, tostring(why) end
    return real, ""
  end,
  fs_append = function(path: string, data: string, mode?: integer): boolean, string
    local appended, why = Fs.append(path, data, mode)
    if not appended then return false, tostring(why) end
    return true, ""
  end,
  fs_exists = Fs.exists,
  fs_open_write = Fs.open_write,
  fs_put = function(fd: integer, data: string): boolean, string
    local wrote, why = Fs.put(fd, data)
    if not wrote then return false, tostring(why) end
    return true, ""
  end,
  fs_read = function(path: string): string?, string
    local text, why = Fs.read(path)
    if text == nil then return nil, tostring(why) end
    return text, ""
  end,
  proc_user = Proc.user,
  signal_guard = Signal.guard,
  stream_tee = Stream.tee,
  sys_getuid = sys.getuid,
  sys_mkdtemp = sys.mkdtemp,
  sys_pread = sys.pread,
}

--- A started child made of `parts`, for a test to stand in for [`Child.start`]'s.
function Seams.started(parts: Seams.Parts): Seams.Started
  return new_started(parts)
end

function Seams.calls(): Seams.Calls
  return current
end

return Seams
