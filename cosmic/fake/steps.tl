--- Steps a test's own fake main ([`cosmic.fake`]) is made of: each does
--- one thing a test checks from inside a child -- read a file, make
--- one, read a limit, test a descriptor -- and returns nil to go on, or
--- the status to end with. A step that fails says why on stderr, as
--- `fake: <what>: <why>`, and returns 1.
---
--- A probe -- a step that asks whether something can be done: connect,
--- bind, start a child under a policy -- reports what it met on stdout
--- instead, `connected` or the reason it was refused, and goes on:
--- being refused is what the test checks, not a failure of the fake.
--- A step that starts a child keeps its handle until the main ends;
--- [`Steps.finish`] ends a main that started any by [`sys.exit`], so
--- they run on.
---
---     local Steps = require("cosmic.fake.steps")
---     local function main(argv: {string}): integer
---       return Steps.cat(argv[2]) or Steps.print("read") or 0
---     end
---
--- @public

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local type Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record Steps
  --- A case of a fake main: handed the words past its name, it returns
  --- the status to end with.
  type Case = function({string}): integer
end

--- How many [`Steps.attempt`]s are running, in which a failure is not said.
local quiet = 0

--- Says `fake: <what>: <why>` on stderr, unless in [`Steps.attempt`];
--- returns 1.
function Steps.fail(what: string, why: string): integer
  if quiet == 0 then
    local _, _ = Fs.put(2, "fake: " .. what .. ": " .. why .. "\n")
  end
  return 1
end

--- Whether `step` went on (returned nil), saying nothing of its failure:
--- the `a || b` of a case, where `b` takes the failure up.
function Steps.attempt(step: function(): integer?): boolean
  quiet = quiet + 1
  local ok, stopped = pcall(step)
  quiet = quiet - 1
  if not ok then error(stopped, 0) end
  return stopped == nil
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
  if bits == nil or bits < 0 then return Steps.fail("chmod", "no mode " .. octal) end
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
  if fd < 0 then return Steps.fail("fd-closed", "no descriptor " .. tostring(fd)) end
  local open, _ = sys.fstat(fd)
  if open ~= nil then return 1 end
  return nil
end

--- The names in directory `path`, sorted, a line each, to stdout.
function Steps.list(path: string): integer?
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
function Steps.remove(path: string): integer?
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

--- `text` and a newline, at the end of file `path`, which it makes
--- where it is not there.
function Steps.append(path: string, text: string): integer?
  local ok, trouble = Fs.append(path, text .. "\n")
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- File `path` to stdout where it reads; nothing, and no failure, where
--- it does not.
function Steps.cat_quiet(path: string): integer?
  local bytes, _ = Fs.read(path)
  if bytes == nil then return nil end
  return Steps.put(1, bytes)
end

--- Whether `path` is there, taking a failure to look as its absence.
function Steps.exists(path: string): boolean
  local there, _ = Fs.status(path)
  return there ~= nil and there.exists == true
end

--- Nil where `path` is there; fails where it is not.
function Steps.present(path: string): integer?
  if Steps.exists(path) then return nil end
  return Steps.fail(path, "not there")
end

--- Sleeps `ms` milliseconds.
function Steps.sleep(ms: integer): integer?
  if ms < 0 then return Steps.fail("sleep", "no time " .. tostring(ms)) end
  assert(Clock.sleep(Clock.ms(ms)))
  return nil
end

--- Copies file `from` to `to`.
function Steps.copy(from: string, to: string): integer?
  local bytes, trouble = Fs.read(from)
  if bytes == nil then return Steps.fail(from, tostring(trouble)) end
  local ok, write_trouble = Fs.write(to, bytes)
  if not ok then return Steps.fail(to, tostring(write_trouble)) end
  return nil
end

--- Its working directory and a newline: to stdout where `path` is nil,
--- or as the whole of file `path`.
function Steps.cwd(path?: string): integer?
  local here, trouble = sys.getcwd()
  if here == nil then return Steps.fail("cwd", trouble) end
  if path == nil then return Steps.print(here) end
  return Steps.write(path, here)
end

--- How many lines of file `path` hold `text`, and a newline, to stdout.
function Steps.grep_count(path: string, text: string): integer?
  local bytes, trouble = Fs.read(path)
  if bytes == nil then return Steps.fail(path, tostring(trouble)) end
  local count = 0
  for line in bytes:gmatch("[^\n]*") do
    if line ~= "" and line:find(text, 1, true) ~= nil then count = count + 1 end
  end
  return Steps.print(tostring(count))
end

--- The line of /proc/self/status that field `name` starts, to stdout.
function Steps.status_field(name: string): integer?
  local status, trouble = Fs.read("/proc/self/status")
  if status == nil then return Steps.fail("/proc/self/status", tostring(trouble)) end
  for line in status:gmatch("[^\n]+") do
    if String.starts_with(line, name .. ":") then return Steps.print(line) end
  end
  return Steps.fail("status-field", "no " .. name)
end

--- Starts `argv` up to `count` times, leaving each running, and says
--- `started <n>`, and ` then <why>` where a start failed, to stdout.
function Steps.start_count(count: integer, argv: {string}): integer?
  if count < 0 then return Steps.fail("start-count", "no count " .. tostring(count)) end
  local made = 0
  local refusal = ""
  for _ = 1, count do
    local handle, trouble = Child.start(argv, { timeout_ns = Child.FOREVER, process_group = false })
    if handle == nil then
      refusal = tostring(trouble)
      break
    end
    started[#started + 1] = handle
    made = made + 1
  end
  return Steps.print("started " .. tostring(made) .. (if refusal ~= "" then " then " .. refusal else "" end))
end

--- `sockets <n>`, the descriptors 3 to 1023 open on a socket, to stdout.
function Steps.sockets_open(): integer?
  local count = 0
  for fd = 3, 1023 do
    -- fstat raises for the retained artifact descriptor, which is no socket.
    local ok, stat = pcall(sys.fstat, fd)
    if ok and stat ~= nil and stat.mode & 0xF000 == 0xC000 then count = count + 1 end
  end
  return Steps.print("sockets " .. tostring(count))
end

--- Sets both limits of `name` (as [`Steps.rlimit`] names them) to
--- `limit`, and says `set` to stdout.
function Steps.setrlimit(name: string, limit: integer): integer?
  local resource = resources[name]
  if resource == nil then return Steps.fail("setrlimit", "no resource " .. name) end
  if limit < 0 then return Steps.fail("setrlimit", "no limit " .. tostring(limit)) end
  local ok, trouble = sys.setrlimit(resource, limit, limit)
  if not ok then return Steps.fail("setrlimit", trouble) end
  return Steps.print("set")
end

--- `pgid <n>`, the process group of `pid` (0 for its own), to stdout.
function Steps.getpgid(pid: integer): integer?
  if pid < 0 then return Steps.fail("getpgid", "no pid " .. tostring(pid)) end
  local group, trouble = sys.getpgid(pid)
  if group == nil then return Steps.fail("getpgid", trouble) end
  return Steps.print("pgid " .. tostring(group))
end

local function round_trip(address: Net.Address): integer?
  local server, trouble = Net.listen(address, { timeout_ns = Clock.seconds(5) })
  if server == nil then return Steps.print(tostring(trouble)) end
  local to = if address.kind == "unix" then address else Net.tcp(assert(address.host), assert(server.address.port)) end
  local conn, connect_trouble = Net.connect(to, { timeout_ns = Clock.seconds(5) })
  if conn == nil then
    local _, _ = server:close()
    return Steps.print(tostring(connect_trouble))
  end
  local accepted, accept_trouble = server:accept()
  local _, _ = conn:close()
  local _, _ = server:close()
  if accepted == nil then return Steps.print(tostring(accept_trouble)) end
  local _, _ = accepted:close()
  return Steps.print("connected")
end

--- Listens over TCP on `host`, at a port the kernel picks, connects to
--- it and takes the connection: says `connected`, or why not, to stdout.
function Steps.loopback_tcp(host: string): integer?
  return round_trip(Net.tcp(host, 0))
end

--- Listens on the unix socket `path`, connects to it and takes the
--- connection: says `connected`, or why not, to stdout.
function Steps.loopback_unix(path: string): integer?
  return round_trip(Net.unix(path))
end

--- Listens on `host`:`port` over TCP and stops: says `bound`, or why
--- not, to stdout.
function Steps.bind_tcp(host: string, port: integer): integer?
  if port < 0 or port > 65535 then return Steps.fail("bind-tcp", "no port " .. tostring(port)) end
  local server, trouble = Net.listen(Net.tcp(host, port), { timeout_ns = Clock.seconds(5) })
  if server == nil then return Steps.print(tostring(trouble)) end
  local _, _ = server:close()
  return Steps.print("bound")
end

--- Swaps the names of `a` and `b` with each other, without end.
function Steps.flip(a: string, b: string): integer
  while true do
    local _, _ = sys.rename(a, a .. ".t")
    local _, _ = sys.rename(b, a)
    local _, _ = sys.rename(a .. ".t", b)
  end
end

--- The permission bits of `path`, in octal, and a newline, to stdout.
function Steps.mode(path: string): integer?
  local st, trouble = sys.stat(path)
  if st == nil then return Steps.fail(path, trouble) end
  return Steps.print(string.format("%o", st.mode & 0xfff))
end

--- Each file below directory `root` that opens to write, a line each,
--- in sorted order, to stdout.
function Steps.find_writable(root: string): integer?
  local lines: mut {string} = {}
  local pending: mut {string} = { root }
  while #pending > 0 do
    local directory = assert(table.remove(pending), "pending is not empty")
    local entries, _ = sys.readdir(directory)
    if entries ~= nil then
      local names: mut {string} = {}
      for name in pairs(entries) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local path = directory .. "/" .. name
        if entries[name] == "dir" then
          pending[#pending + 1] = path
        elseif entries[name] == "file" then
          -- A listing may take a device bound over an entry for the file it hides.
          local st, _ = sys.stat(path)
          local fd: integer? = nil
          if st ~= nil and st.kind == "file" then
            local opened, _ = sys.open(path, sys.O_WRONLY | sys.O_APPEND)
            fd = opened
          end
          if fd ~= nil then
            local _, _ = sys.close(fd)
            lines[#lines + 1] = path .. "\n"
          end
        end
      end
    end
  end
  return Steps.put(1, table.concat(lines))
end

--- Runs `argv` as a child isolated to its own files, granted to run
--- `argv[1]` and read `.`, and `loopback` where given: says
--- `exit <status>` and what it printed, or why it did not start, to
--- stdout.
function Steps.run_isolated(argv: {string}, loopback?: {string}): integer?
  if #argv == 0 then return Steps.fail("run-isolated", "no program") end
  local grants: mut {Sandbox.Grant} = { { path = argv[1]!, letters = "rx" }, { path = ".", letters = "r" } }
  for _, address in ipairs(loopback or {}) do grants[#grants + 1] = { loopback = address } end
  local result, trouble = Child.run(argv, { timeout_ns = Child.FOREVER, policy = {
    isolate = { "file" }, grants = grants }, stdout = "capture", stderr = "stdout" })
  if result == nil then return Steps.print(tostring(trouble)) end
  return Steps.put(1, "exit " .. tostring(result.code) .. "\n" .. (result.stdout or ""))
end

--- Starts `program` as [`Steps.run_isolated`] would and ends it: says
--- `started`, or why it did not, to stdout.
function Steps.start_isolated(program: string): integer?
  local handle, trouble = Child.start({ program }, { timeout_ns = Child.FOREVER, policy = {
    isolate = { "file" }, grants = { { path = program, letters = "rx" },
      { path = ".", letters = "r" } } } })
  if handle == nil then return Steps.print(tostring(trouble)) end
  local _, _ = handle:close()
  return Steps.print("started")
end

--- `text` and a newline, to descriptor `fd`.
function Steps.write_fd(fd: integer, text: string): integer?
  if fd < 0 then return Steps.fail("write-fd", "no descriptor " .. tostring(fd)) end
  return Steps.put(fd, text .. "\n")
end

--- Runs the case of `cases` that `argv[1]` names, handed the words past
--- it; a name of none fails, saying `fake` has no such case.
function Steps.dispatch(fake: string, cases: {string:Steps.Case}, argv: {string}): integer
  local name = argv[1] or ""
  local words: mut {string} = {}
  for i = 2, #argv do words[#words + 1] = argv[i] end
  local case = cases[name]
  if case == nil then return Steps.fail(fake, "no case " .. name) end
  return case(words)
end

--- `word` as an integer, or -1 where it is none, which each step that
--- takes a number refuses.
function Steps.int(word: string): integer
  return math.tointeger(tonumber(word)) or -1
end

return Steps
