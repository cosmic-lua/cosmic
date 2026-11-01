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

local function new_started(stop: function(signal?: integer): boolean, string,
                           try_wait: function(): Child.TryWait?, string,
                           drain: function(options: Child.DrainOptions): Child.DrainResult,
                           close: function(): boolean, string): Started
  return { stop = stop, try_wait = try_wait, drain = drain, close = close }
end

local record Seams
  type Started = Started
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
    --- A started child that calls these, for a test to stand in for [`Child.start`]'s.
    started: function(stop: function(signal?: integer): boolean, string,
                      try_wait: function(): Child.TryWait?, string,
                      drain: function(options: Child.DrainOptions): Child.DrainResult,
                      close: function(): boolean, string): Started
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
  local handle, why = Child.start(argv, options)
  if handle == nil then return nil, why end
  return new_started(
    function(signal?: integer): boolean, string return handle:stop(signal) end,
    function(): Child.TryWait?, string return handle:try_wait() end,
    function(drained: Child.DrainOptions): Child.DrainResult
      return handle:drain(drained)
    end,
    function(): boolean, string return handle:close() end), ""
end

local current: Seams.Calls = {
  child_run = Child.run,
  child_start = start,
  env_all = Env.all,
  env_get = Env.get,
  fs_absolute = Fs.absolute,
  fs_append = Fs.append,
  fs_exists = Fs.exists,
  fs_open_write = Fs.open_write,
  fs_put = Fs.put,
  fs_read = Fs.read,
  proc_user = Proc.user,
  started = new_started,
  signal_guard = Signal.guard,
  stream_tee = Stream.tee,
  sys_getuid = sys.getuid,
  sys_mkdtemp = sys.mkdtemp,
  sys_pread = sys.pread,
}

function Seams.calls(): Seams.Calls
  return current
end

return Seams
