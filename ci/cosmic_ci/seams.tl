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

local record Seams
  --- A started child, as far as the fuzz run supervises it: the calls of a
  --- [`Child.Handle`] it makes, as functions a test can fake.
  record Started
    stop: function(signal?: integer): boolean, string
    try_wait: function(): Child.TryWait | nil, string
    drain: function(options: Child.DrainOptions): Child.DrainResult
    close: function(): boolean, string
  end
  --- Each call, named for the library function it starts as.
  record Calls
    child_run: function(argv: {string}, options?: Child.Options): Child.Result | nil, string
    child_start: function(argv: {string}, options?: Child.Options): Seams.Started | nil, string
    env_all: function(): {string:string}
    env_get: function(name: string): string | nil
    fs_absolute: function(path: string): string | nil, string
    fs_append: function(path: string, data: string, mode?: integer): boolean, string
    fs_exists: function(path: string): boolean | nil, string
    fs_open_write: function(path: string, mode?: integer): integer | nil, string
    fs_put: function(fd: integer, bytes: string): boolean, string
    fs_read: function(path: string): string | nil, string
    proc_user: function(name: string): Proc.User | nil, string
    signal_guard: function(): Signal.Guard | nil, string
    stream_tee: function(first: Stream.Writer, second: Stream.Writer): Stream.Writer
    sys_getuid: function(): integer
    sys_mkdtemp: function(template: string): string | nil, string, integer
    sys_pread: function(fd: integer, count: integer, offset: integer): string | nil, string, integer
  end
  --- The calls in force: the library's, until a test assigns its own to a
  --- field of the record, and puts the library's back.
  calls: function(): Calls
end

--- [`Child.start`], its handle offered as [`Seams.Started`].
local function start(argv: {string}, options?: Child.Options): Seams.Started | nil, string
  local handle, why = Child.start(argv, options)
  if handle == nil then return nil, why end
  return {
    stop = function(signal?: integer): boolean, string return handle:stop(signal) end,
    try_wait = function(): Child.TryWait | nil, string return handle:try_wait() end,
    drain = function(drained: Child.DrainOptions): Child.DrainResult
      return handle:drain(drained)
    end,
    close = function(): boolean, string return handle:close() end,
  }, ""
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
