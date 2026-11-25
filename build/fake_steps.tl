--- Steps a test's own fake main ([`cosmic.fake`]) is made of: each does
--- one thing a test checks from inside a child -- read a file, make
--- one, read a limit, test a descriptor -- and returns nil to go on, or
--- the status to end with. A step that fails says why on stderr, as
--- `fake: <what>: <why>`, and returns 1.
---
---     local Steps = require("build.fake_steps")
---     local function main(argv: {string}): integer
---       return Steps.cat(argv[2]) or Steps.print("read") or 0
---     end

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record Steps
end

--- Says `fake: <what>: <why>` on stderr; returns 1.
function Steps.fail(what: string, why: string): integer
  local _, _ = Fs.put(2, "fake: " .. what .. ": " .. why .. "\n")
  return 1
end

--- Writes `data` to descriptor `fd`, as it is.
function Steps.put(fd: integer, data: string): integer?
  local ok, trouble = Fs.put(fd, data)
  if not ok then return Steps.fail("write", tostring(trouble)) end
  return nil
end

--- `text` and a newline, to stdout.
function Steps.print(text: string): integer?
  return Steps.put(1, text .. "\n")
end

--- File `path`, or stdin to its end where `path` is nil, to stdout.
function Steps.cat(path?: string): integer?
  if path ~= nil then
    local bytes, trouble = Fs.read(path)
    if bytes == nil then return Steps.fail(path, tostring(trouble)) end
    return Steps.put(1, bytes)
  end
  while true do
    local chunk, trouble = Fs.take(0, 65536)
    if chunk == nil then return Steps.fail("stdin", tostring(trouble)) end
    if chunk == "" then return nil end
    local stopped = Steps.put(1, chunk)
    if stopped ~= nil then return stopped end
  end
end

--- `text` and a newline, as the whole of file `path`.
function Steps.write(path: string, text: string): integer?
  local ok, trouble = Fs.write(path, text .. "\n")
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- `text` and a newline, as a new file at `path`: one that is there
--- already fails.
function Steps.create(path: string, text: string): integer?
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 420)
  if fd == nil then return Steps.fail(path, trouble) end
  local written, write_trouble = sys.write(fd, text .. "\n")
  local _, _ = sys.close(fd)
  if written == nil then return Steps.fail(path, write_trouble) end
  return nil
end

--- Sets the mode bits of `path`, given in octal, as `chmod` does.
function Steps.chmod(path: string, octal: string): integer?
  local bits = math.tointeger(tonumber(octal, 8))
  if bits == nil then return Steps.fail("chmod", "no mode " .. octal) end
  local ok, trouble = Fs.chmod(path, bits)
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- `NAME=` and the variable's value, or `NAME unset`, and a newline, to
--- stdout.
function Steps.env_of(name: string): integer?
  local value = Env.get(name)
  return Steps.print(if value ~= nil then name .. "=" .. value else name .. " unset" end)
end

local resources: {string:integer} = {
  nofile = sys.RLIMIT_NOFILE, fsize = sys.RLIMIT_FSIZE, cpu = sys.RLIMIT_CPU,
  core = sys.RLIMIT_CORE, nproc = sys.RLIMIT_NPROC,
}

--- `<name> <soft> <hard>` of the limit `name` (nofile, fsize, cpu, core,
--- nproc), and a newline, to stdout.
function Steps.rlimit(name: string): integer?
  local resource = resources[name]
  if resource == nil then return Steps.fail("rlimit", "no resource " .. name) end
  local limits, trouble = sys.getrlimit(resource)
  if limits == nil then return Steps.fail("rlimit", trouble) end
  return Steps.print(name .. " " .. tostring(limits.soft) .. " " .. tostring(limits.hard))
end

--- Nil where descriptor `fd` is closed; 1 where it is open.
function Steps.fd_closed(fd: integer): integer?
  local open, _ = sys.fstat(fd)
  if open ~= nil then return 1 end
  return nil
end

--- The names in directory `path`, sorted, a line each, to stdout.
function Steps.ls(path: string): integer?
  local names, trouble = Fs.list(path)
  if names == nil then return Steps.fail(path, tostring(trouble)) end
  local sorted: mut {string} = {}
  for _, name in ipairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted)
  local lines: mut {string} = {}
  for _, name in ipairs(sorted) do lines[#lines + 1] = name .. "\n" end
  return Steps.put(1, table.concat(lines))
end

--- Nil where the file at `path` opens to write (appending, writing
--- nothing, making nothing).
function Steps.writable(path: string): integer?
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_APPEND)
  if fd == nil then return Steps.fail(path, trouble) end
  local _, _ = sys.close(fd)
  return nil
end

--- Empties the file at `path` by an open to write with O_TRUNC.
function Steps.truncate(path: string): integer?
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_TRUNC)
  if fd == nil then return Steps.fail(path, trouble) end
  local _, _ = sys.close(fd)
  return nil
end

--- Empties the file at `path` by an open to read with O_TRUNC, which
--- asks for no write right.
function Steps.truncate_unwritten(path: string): integer?
  local fd, trouble = sys.open(path, sys.O_RDONLY | sys.O_TRUNC)
  if fd == nil then return Steps.fail(path, trouble) end
  local _, _ = sys.close(fd)
  return nil
end

--- Makes directory `path` and its parents.
function Steps.mkdirs(path: string): integer?
  local ok, trouble = Fs.mkdirs(path)
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- Makes a named pipe at `path`.
function Steps.mkfifo(path: string): integer?
  local ok, trouble = sys.mkfifo(path)
  if not ok then return Steps.fail(path, trouble) end
  return nil
end

--- Renames `from` to `to`.
function Steps.rename(from: string, to: string): integer?
  local ok, trouble = sys.rename(from, to)
  if not ok then return Steps.fail(from, trouble) end
  return nil
end

--- Removes the file `path`.
function Steps.rm(path: string): integer?
  local ok, trouble = sys.unlink(path)
  if not ok then return Steps.fail(path, trouble) end
  return nil
end

--- Removes the empty directory `path`.
function Steps.rmdir(path: string): integer?
  local ok, trouble = sys.rmdir(path)
  if not ok then return Steps.fail(path, trouble) end
  return nil
end

--- Starts `argv` and waits for it, as a shell runs one: nil where it
--- ended with 0, its status where it failed (128 past a signal), and
--- 127 where it could not start.
function Steps.run(argv: {string}): integer?
  local result, _ = Child.run(argv, { timeout_ns = Child.FOREVER, process_group = false })
  if result == nil then return 127 end
  if not result.ok then return Child.shell_status(result) end
  return nil
end

--- What [`Steps.start`] started, kept from the collector, whose end of
--- a handle would end its process: [`Steps.finish`] then ends by
--- [`sys.exit`].
local started: mut {Child.Handle} = {}

--- Starts `argv` and goes on, leaving it running.
function Steps.start(argv: {string}): integer?
  local handle, trouble = Child.start(argv, { timeout_ns = Child.FOREVER, process_group = false })
  if handle == nil then return Steps.fail("start", tostring(trouble)) end
  started[#started + 1] = handle
  return nil
end

--- Ends a main with `status`: by [`sys.exit`] where it started anything,
--- so what it started runs on; returns `status` otherwise.
function Steps.finish(status: integer): integer
  if #started > 0 then sys.exit(status) end
  return status
end

--- Connects to the unix socket `path`: says `connected`, or why not, to
--- stdout.
function Steps.connect(path: string): integer?
  local conn, trouble = Net.connect(Net.unix(path), { timeout_ns = Clock.seconds(5) })
  if conn == nil then return Steps.print(tostring(trouble)) end
  local _, _ = conn:close()
  return Steps.print("connected")
end

--- Connects to `host`:`port` over TCP: says `connected`, or why not, to
--- stdout.
function Steps.connect_tcp(host: string, port: integer): integer?
  if port < 0 or port > 65535 then
    return Steps.fail("connect-tcp", "no port " .. tostring(port))
  end
  local conn, trouble = Net.connect(Net.tcp(host, port), { timeout_ns = Clock.seconds(5) })
  if conn == nil then return Steps.print(tostring(trouble)) end
  local _, _ = conn:close()
  return Steps.print("connected")
end

--- Its own pid and a newline, as the whole of file `path`.
function Steps.write_pid(path: string): integer?
  return Steps.write(path, tostring(sys.getpid()))
end

--- Waits until `path` exists, a few milliseconds at a time.
function Steps.wait_for(path: string): integer?
  while true do
    local there, _ = Fs.status(path)
    if there ~= nil and there.exists then return nil end
    assert(Clock.sleep(Clock.ms(5)))
  end
end

--- Sleeps until it is ended.
function Steps.sleep_forever(): integer
  while true do assert(Clock.sleep(Clock.seconds(1))) end
end

local signals: {string:integer} = {
  TERM = sys.SIGTERM, INT = sys.SIGINT, KILL = sys.SIGKILL, HUP = sys.SIGHUP,
}

--- Sends signal `name` (TERM, INT, KILL, HUP) to `pid` (negated for a
--- process group), or, where `pid` is nil, to itself, then waits two
--- seconds at most for it to end it, past which it says so and ends with
--- status 4. 0 and -1, which name no one process or group, fail.
function Steps.signal(name: string, pid?: integer): integer?
  local signal = signals[name]
  if signal == nil then return Steps.fail("signal", "no signal " .. name) end
  local target = pid or sys.getpid()
  if target == 0 or target == -1 then
    return Steps.fail("signal", "refusing pid " .. tostring(target) .. ", which names no one process or group")
  end
  local ok, trouble = sys.kill(target, signal)
  if not ok then return Steps.fail("signal", trouble) end
  if pid ~= nil then return nil end
  assert(Clock.sleep(Clock.seconds(2)))
  local _, _ = Fs.put(2, "fake: signal: SIG" .. name .. " sent to itself did not end it in 2 s\n")
  sys.exit(4)
end

--- The pid file `path` holds; nil, having said why, where it holds none.
function Steps.pid_in(path: string): integer?
  local held, trouble = Fs.read(path)
  if held == nil then
    Steps.fail(path, tostring(trouble))
    return nil
  end
  local pid = math.tointeger(tonumber(String.trim(held)))
  if pid == nil then Steps.fail(path, "no pid in it") end
  return pid
end

return Steps
