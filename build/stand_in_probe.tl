--- The stand-in's whole program (build/stand_in.tl, whose doc comment
--- says what its script runs): the main module of the host program
--- [`stand_in.build`] makes, which carries it and the modules it requires,
--- and nothing else of this tree.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local String = require("cosmic.string")

local SLICE_NS <const> = Time.ms(5)

--- How long `signal` waits for one it sent itself to end it, and the
--- status it ends with past that.
local SIGNAL_WAIT_NS <const> = Time.seconds(2)
local SIGNAL_MISSED <const> = 4

local signals: {string:integer} = {
  TERM = sys.SIGTERM, INT = sys.SIGINT, KILL = sys.SIGKILL, HUP = sys.SIGHUP,
}

--- The guard `trap` opened, the status it ends with, and whether it
--- ends with it at all (`trap -` goes on).
local guard: Child.Guard = nil
local trapped = 0
local ignoring = false

--- What `start` started, kept from the collector, whose end of a handle
--- would end its process: the script then ends by [`sys.exit`].
local started: {Child.Handle} = {}

--- What the commands of the chain running have said of their failures,
--- said once the chain ends the script, and not where a `||` takes one
--- up.
local troubles: {string} = {}

local function trap_fired(): boolean
  return guard ~= nil and not ignoring and guard:cancelled() ~= 0
end

--- Sleeps `ns` nanoseconds by the clock, a slice at a time, however
--- long a slice's sleep takes (a host may coalesce short timers into
--- longer ones): the status a trap ends it with, or nil.
local function sleep_for(ns: integer): integer
  local deadline = Time.monotonic_ns() + ns
  while true do
    if trap_fired() then return trapped end
    local left = deadline - Time.monotonic_ns()
    if left <= 0 then break end
    local _, _ = sys.nanosleep(math.min(left, SLICE_NS))
  end
  if trap_fired() then return trapped end
  return nil
end

--- Whether `path` is there, taking a failure to look as its absence.
local function exists(path: string): boolean
  local there, _ = Fs.exists(path)
  return there == true
end

local function failed(what: string, trouble: string): integer
  troubles[#troubles + 1] = "probe: " .. what .. ": " .. trouble .. "\n"
  return 1
end

local function number(word: string): integer
  return math.tointeger(tonumber(word))
end

local function put_all(fd: integer, data: string): integer
  local ok, trouble = Fs.put(fd, data)
  if not ok then return failed("write", trouble) end
  return nil
end

local function append(path: string, data: string): integer
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, 420)
  if fd == nil then return failed(path, trouble) end
  local written, write_trouble = sys.write(fd, data)
  local _, _ = sys.close(fd)
  if written == nil then return failed(path, write_trouble) end
  return nil
end

local function status_of(result: Child.Result): integer
  if result.signal ~= nil then return 128 + result.signal end
  return result.code or 1
end

--- `program`, with `argument` its one where there is one.
local function argv_of(program: string, argument: string): {string}
  local argv: {string} = { program }
  if argument ~= "" then argv[2] = argument end
  return argv
end

--- Whether the file at `path` opens to write, appending and writing
--- nothing; it is never made.
local function opens_to_write(path: string): boolean, string
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_APPEND)
  if fd == nil then return false, trouble end
  local _, _ = sys.close(fd)
  return true, ""
end

--- Each verb, handed its first word and the rest, each substituted;
--- answers the status to end with, or nil to go on.
local verbs: {string:function(string, string): integer} = {
  print = function(first: string, rest: string): integer
    return put_all(1, (rest ~= "" and first .. " " .. rest or first) .. "\n")
  end,
  eprint = function(first: string, rest: string): integer
    return put_all(2, (rest ~= "" and first .. " " .. rest or first) .. "\n")
  end,
  write = function(path: string, text: string): integer
    local ok, trouble = Fs.write(path, text .. "\n")
    if not ok then return failed(path, trouble) end
    return nil
  end,
  append = function(path: string, text: string): integer
    return append(path, text .. "\n")
  end,
  cat = function(path: string): integer
    if path ~= "" then
      local bytes, trouble = Fs.read(path)
      if bytes == nil then return failed(path, trouble) end
      return put_all(1, bytes)
    end
    while true do
      local chunk, trouble = Fs.take(0, 65536)
      if chunk == nil then return failed("stdin", trouble) end
      if chunk == "" then return nil end
      local stopped = put_all(1, chunk)
      if stopped ~= nil then return stopped end
    end
  end,
  ["cat-quiet"] = function(path: string): integer
    local bytes, _ = Fs.read(path)
    if bytes == nil then return nil end
    return put_all(1, bytes)
  end,
  ls = function(path: string): integer
    local names, trouble = Fs.list(path)
    if names == nil then return failed(path, trouble) end
    table.sort(names)
    local lines: {string} = {}
    for _, name in ipairs(names) do lines[#lines + 1] = name .. "\n" end
    return put_all(1, table.concat(lines))
  end,
  exit = function(status: string): integer
    return number(status) or 2
  end,
  signal = function(name: string, target: string): integer
    local signal = signals[name]
    if signal == nil then return failed("signal", "no signal " .. name) end
    local named = target
    if target:sub(1, 1) == "@" then
      local held, trouble = Fs.read(target:sub(2))
      if held == nil then return failed(target:sub(2), trouble) end
      named = String.trim(held)
    end
    local pid = target == "" and sys.getpid() or number(named)
    if pid == nil then return failed("signal", "no process " .. named) end
    -- kill(2) takes 0 for its own group and -1 for every process this
    -- user may signal: a script names a group by its number.
    if pid == 0 or pid == -1 then
      return failed("signal", "refusing pid " .. tostring(pid) ..
          ", which names no one process or group")
    end
    local ok, trouble = sys.kill(pid, signal)
    if not ok then return failed("signal", trouble) end
    if target ~= "" then return nil end
    -- Sent to itself, the signal ends the script soon, or a `trap`
    -- that holds it does. One that never lands ends it all the same,
    -- saying so: a `trap -` goes on, and the kernel delivers no
    -- uncaught signal to a pid namespace's init.
    local stopped = sleep_for(SIGNAL_WAIT_NS)
    if stopped ~= nil then return stopped end
    -- Past the bound it ends at once, running no more of the script
    -- and nothing its end would run.
    local _, _ = Fs.put(2, "probe: signal: SIG" .. name .. " sent to itself did not end it in " ..
        Time.format_duration({ ns = SIGNAL_WAIT_NS }) .. "\n")
    sys.exit(SIGNAL_MISSED)
    return SIGNAL_MISSED
  end,
  trap = function(status: string): integer
    local opened, trouble = guard, ""
    if opened == nil then opened, trouble = Child.guard() end
    if opened == nil then return failed("trap", trouble) end
    guard, trapped, ignoring = opened, number(status) or 2, status == "-"
    return nil
  end,
  sleep = function(ms: string): integer
    return sleep_for(Time.ms(number(ms) or 0))
  end,
  ["sleep-forever"] = function(): integer
    while true do
      local stopped = sleep_for(Time.seconds(1))
      if stopped ~= nil then return stopped end
    end
  end,
  ["wait-for"] = function(path: string): integer
    while not exists(path) do
      local stopped = sleep_for(SLICE_NS)
      if stopped ~= nil then return stopped end
    end
    return nil
  end,
  exists = function(path: string, status: string): integer
    if exists(path) then return number(status) or 2 end
    return nil
  end,
  copy = function(from: string, to: string): integer
    local bytes, trouble = Fs.read(from)
    if bytes == nil then return failed(from, trouble) end
    local ok, write_trouble = Fs.write(to, bytes)
    if not ok then return failed(to, write_trouble) end
    return nil
  end,
  cwd = function(path: string): integer
    local here, trouble = sys.getcwd()
    if here == nil then return failed("cwd", trouble) end
    if path == "" then return put_all(1, here .. "\n") end
    local ok, write_trouble = Fs.write(path, here .. "\n")
    if not ok then return failed(path, write_trouble) end
    return nil
  end,
  mkfifo = function(path: string): integer
    local ok, trouble = sys.mkfifo(path)
    if not ok then return failed(path, trouble) end
    return nil
  end,
  mkdirs = function(path: string): integer
    local ok, trouble = Fs.mkdirs(path)
    if not ok then return failed(path, trouble) end
    return nil
  end,
  ["grep-count"] = function(path: string, text: string): integer
    local bytes, trouble = Fs.read(path)
    if bytes == nil then return failed(path, trouble) end
    local count = 0
    for line in bytes:gmatch("[^\n]*") do
      if line ~= "" and line:find(text, 1, true) ~= nil then count = count + 1 end
    end
    return put_all(1, tostring(count) .. "\n")
  end,
  ["status-field"] = function(name: string): integer
    local status, trouble = Fs.read("/proc/self/status")
    if status == nil then return failed("/proc/self/status", trouble) end
    for line in status:gmatch("[^\n]+") do
      if String.starts_with(line, name .. ":") then return put_all(1, line .. "\n") end
    end
    return failed("status-field", "no " .. name)
  end,
  run = function(program: string, argument: string): integer
    local result, _ = Child.run(argv_of(program, argument), { process_group = false })
    if result == nil then return 127 end
    if not result.ok then return status_of(result) end
    return nil
  end,
  start = function(program: string, argument: string): integer
    local handle, trouble = Child.start(argv_of(program, argument), { process_group = false })
    if handle == nil then return failed("start", trouble) end
    started[#started + 1] = handle
    return nil
  end,
  ["start-count"] = function(word: string, rest: string): integer
    local program, argument = rest:match("^(%S+)%s*(.-)$")
    if program == nil then return failed("start-count", "no program") end
    local wanted = number(word)
    if wanted == nil or wanted < 0 then return failed("start-count", "no count " .. word) end
    local count = 0
    local refusal = ""
    for _ = 1, wanted do
      local handle, trouble = Child.start(argv_of(program, argument), { process_group = false })
      if handle == nil then
        refusal = trouble
        break
      end
      started[#started + 1] = handle
      count = count + 1
    end
    return put_all(1, "started " .. count .. (refusal ~= "" and (" then " .. refusal) or "") .. "\n")
  end,
  ["fd-closed"] = function(word: string): integer
    local fd = number(word)
    if fd == nil or fd < 0 then
      local _, _ = Fs.put(2, "probe: fd-closed: no descriptor " .. word .. "\n")
      return 2
    end
    local open, _ = sys.fstat(fd)
    if open ~= nil then return 1 end
    return nil
  end,
  ["write-fd"] = function(word: string, text: string): integer
    local fd = number(word)
    if fd == nil or fd < 0 then return failed("write-fd", "no descriptor " .. word) end
    return put_all(fd, text .. "\n")
  end,
  rlimit = function(name: string): integer
    local resources: {string:integer} = {
      nofile = sys.RLIMIT_NOFILE, fsize = sys.RLIMIT_FSIZE, cpu = sys.RLIMIT_CPU,
      core = sys.RLIMIT_CORE, nproc = sys.RLIMIT_NPROC,
    }
    local resource = resources[name]
    if resource == nil then return failed("rlimit", "no resource " .. name) end
    local limits, trouble = sys.getrlimit(resource)
    if limits == nil then return failed("rlimit", trouble) end
    return put_all(1, name .. " " .. limits.soft .. " " .. limits.hard .. "\n")
  end,
  ["env-of"] = function(name: string): integer
    local value = sys.getenv(name)
    return put_all(1, value ~= nil and name .. "=" .. value .. "\n" or name .. " unset\n")
  end,
  connect = function(path: string): integer
    local conn, trouble = Net.connect(Net.unix(path), { timeout_ns = Time.seconds(5) })
    if conn == nil then return put_all(1, trouble .. "\n") end
    local _, _ = conn:close()
    return put_all(1, "connected\n")
  end,
  ["connect-tcp"] = function(host: string, word: string): integer
    local port = number(word)
    if port == nil or port < 0 or port > 65535 then
      return failed("connect-tcp", "no port " .. word)
    end
    local conn, trouble = Net.connect(Net.tcp(host, port), { timeout_ns = Time.seconds(5) })
    if conn == nil then return put_all(1, trouble .. "\n") end
    local _, _ = conn:close()
    return put_all(1, "connected\n")
  end,
  ["loopback-tcp"] = function(host: string): integer
    local server, trouble = Net.listen(Net.tcp(host, 0), { timeout_ns = Time.seconds(5) })
    if server == nil then return put_all(1, trouble .. "\n") end
    local conn, connect_trouble = Net.connect(Net.tcp(host, server.address.port),
      { timeout_ns = Time.seconds(5) })
    if conn == nil then
      local _, _ = server:close()
      return put_all(1, connect_trouble .. "\n")
    end
    local accepted, accept_trouble = server:accept()
    local _, _ = conn:close()
    local _, _ = server:close()
    if accepted == nil then return put_all(1, accept_trouble .. "\n") end
    local _, _ = accepted:close()
    return put_all(1, "connected\n")
  end,
  ["start-isolated"] = function(program: string): integer
    local handle, trouble = Child.start({ program }, { policy = {
      isolate = { "file" }, grants = { { path = program, letters = "rx" },
        { path = ".", letters = "r" } } } })
    if handle == nil then return put_all(1, trouble .. "\n") end
    local _, _ = handle:close()
    return put_all(1, "started\n")
  end,
  ["run-isolated"] = function(program: string, script: string): integer
    local result, trouble = Child.run({ program, script }, { policy = {
      isolate = { "file" }, grants = { { path = program, letters = "rx" },
        { path = ".", letters = "r" } } }, stdout = "capture", stderr = "stdout" })
    if result == nil then return put_all(1, trouble .. "\n") end
    return put_all(1, "exit " .. tostring(result.code) .. "\n" .. (result.stdout or ""))
  end,
  present = function(path: string): integer
    if exists(path) then return nil end
    return failed(path, "not there")
  end,
  writable = function(path: string): integer
    local opened, trouble = opens_to_write(path)
    if not opened then return failed(path, trouble) end
    return nil
  end,
  create = function(path: string, text: string): integer
    local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 420)
    if fd == nil then return failed(path, trouble) end
    local written, write_trouble = sys.write(fd, text .. "\n")
    local _, _ = sys.close(fd)
    if written == nil then return failed(path, write_trouble) end
    return nil
  end,
  truncate = function(path: string): integer
    local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_TRUNC)
    if fd == nil then return failed(path, trouble) end
    local _, _ = sys.close(fd)
    return nil
  end,
  rm = function(path: string): integer
    local ok, trouble = sys.unlink(path)
    if not ok then return failed(path, trouble) end
    return nil
  end,
  rmdir = function(path: string): integer
    local ok, trouble = sys.rmdir(path)
    if not ok then return failed(path, trouble) end
    return nil
  end,
  rename = function(from: string, to: string): integer
    local ok, trouble = sys.rename(from, to)
    if not ok then return failed(from, trouble) end
    return nil
  end,
  chmod = function(path: string, word: string): integer
    local bits = math.tointeger(tonumber(word, 8))
    if bits == nil then return failed("chmod", "no mode " .. word) end
    local ok, trouble = Fs.chmod(path, bits)
    if not ok then return failed(path, trouble) end
    return nil
  end,
  mode = function(path: string): integer
    local st, trouble = sys.stat(path)
    if st == nil then return failed(path, trouble) end
    return put_all(1, string.format("%o\n", st.mode & 0xfff))
  end,
  ["find-writable"] = function(root: string): integer
    local lines: {string} = {}
    local pending: {string} = { root }
    while #pending > 0 do
      local directory = table.remove(pending)
      local entries, _ = sys.readdir(directory)
      if entries ~= nil then
        local names: {string} = {}
        for name in pairs(entries) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          local path = directory .. "/" .. name
          if entries[name] == "dir" then
            pending[#pending + 1] = path
          elseif entries[name] == "file" then
            local st, _ = sys.stat(path)
            if st ~= nil and st.kind == "file" then
              local opens, _ = opens_to_write(path)
              if opens then lines[#lines + 1] = path .. "\n" end
            end
          end
        end
      end
    end
    return put_all(1, table.concat(lines))
  end,
}

--- `word` with `$@`, `$DIR` and `$NAME` put in, in one pass: what is
--- put in is never read for a `$` again, so an argument holding `$HOME`
--- stays as it was given, and reads nothing of the environment.
local function substituted(word: string, args: string, dir: string): string
  local out = word:gsub("%$([@%a_][%w_]*)", function(name: string): string
    if name:sub(1, 1) == "@" then return args .. name:sub(2) end
    if name == "DIR" then return dir end
    return sys.getenv(name) or ""
  end)
  return out
end

--- `line` split at each `&&` and `||` standing between blanks: its
--- commands, and the operator before each but the first.
local function chained(line: string): {string}, {string}
  local commands, operators: {string}, {string} = {}, {}
  local at = 1
  while true do
    local from, to, operator = line:find("%s+(([&|])%2)%s+", at)
    if from == nil then break end
    commands[#commands + 1] = line:sub(at, from - 1)
    operators[#operators + 1] = operator
    at = to + 1
  end
  commands[#commands + 1] = line:sub(at)
  return commands, operators
end

--- Runs the script's commands: the status to end with.
local function run_script(script: string, args: {string}, dir: string): integer
  local joined = table.concat(args, " ")
  --- Runs one command: nil to go on, or the status to end with.
  local function command(line: string): integer
    -- The verb, its first word and the rest: the blanks between them
    -- go, however many, while the rest keeps its own as written.
    local verb, first, rest: string, string, string = line:match("^(%S+)%s*(%S*)%s*(.-)$")
    local run = verbs[verb]
    if run == nil then
      troubles[#troubles + 1] = "probe: unknown verb " .. verb .. "\n"
      return 2
    end
    return run(substituted(first, joined, dir), substituted(rest, joined, dir))
  end
  for each in script:gmatch("[^;\n]+") do
    local line: string = String.trim(each)
    local only, guarded: string, string = line:match("^%[([^%]]*)%]%s+(.*)$")
    if only ~= nil then
      line = only == args[1] and guarded or ""
    end
    if line ~= "" then
      local commands, operators = chained(line)
      local stopped = command(commands[1])
      for i, operator in ipairs(operators) do
        if operator == "&&" and stopped == nil then
          stopped = command(commands[i + 1])
        elseif operator == "||" and stopped ~= nil then
          troubles = {}
          stopped = command(commands[i + 1])
        end
      end
      if stopped ~= nil then
        local _, _ = Fs.put(2, table.concat(troubles))
        return stopped
      end
      troubles = {}
    end
    if trap_fired() then return trapped end
  end
  return 0
end

return function(argv: {string}): integer
  local executable, _ = Proc.executable()
  local self = executable or ""
  local beside, _ = Fs.read(self .. ".do")
  if beside == nil and argv[1] ~= nil then
    -- A script file whose `#!` line names it: its body.
    local st, _ = sys.stat(argv[1])
    local text: string = nil
    if st ~= nil and st.kind == "file" then
      local read, _ = Fs.read(argv[1])
      text = read
    end
    if text ~= nil and text:sub(1, 2) == "#!" then
      beside = text:match("^[^\n]*\n(.*)$") or ""
      table.remove(argv, 1)
    end
  end
  local script = beside or argv[1] or ""
  local first_arg = beside ~= nil and 1 or 2
  local args: {string} = {}
  for i = first_arg, #argv do args[#args + 1] = argv[i] end
  local status = run_script(script, args, Fs.dirname(self))
  -- What `start` started runs on: ending here, rather than by returning,
  -- keeps the collector from ending it with its handle.
  if #started > 0 then sys.exit(status) end
  return status
end
