--- A stand-in program for a test that needs an outside program to start
--- -- a fake zig, codesign or cosmic, a process to leave running --
--- without the system's shell: a host program built from this core
--- (`embed.tree(dir, true)`, as `cosmic build --host` builds one), a
--- static executable of the core and a small database, which the
--- kernel runs directly and which reads only itself. A caller that
--- starts it with no environment and no descriptors of its own, as
--- bin/zig, codesign's verifier and the eval grader start theirs, starts
--- it all the same, which this program past its launcher
--- (`Proc.relaunch`) could not be.
---
--- `build` makes one, in well under a second, and `place` copies it
--- where a test needs one, with the script it runs. A test that builds
--- one declares `tool = true`: the build reads this program's core.
---
--- The script is `<its path>.do`; or, with none there, the body of the
--- file its first argument names, past its first line, where that is a
--- regular file whose first line is a `#!` one -- so a file starting
--- `#!<stand-in>` and nothing more runs its body, as a shell script
--- runs, on every system, however one splits the words after `#!` --
--- or else its first argument itself; its arguments are then the rest. Commands are split on `;`
--- and newlines, each a verb and its words:
---
---     print T          T and a newline, to stdout
---     eprint T         T and a newline, to stderr
---     write F T        T and a newline, as the whole of file F
---     append F T       T and a newline, at the end of file F
---     cat [F]          file F, or stdin to its end, to stdout
---     cat-quiet F      file F to stdout, or nothing where it cannot be read
---     ls D             the names in directory D, sorted, a line each
---     exit N           ends with status N
---     signal S [P]     sends SIGS (TERM, INT, KILL, HUP) to itself, and
---                      waits to end of it -- two seconds at most, after
---                      which it says so and ends with status 4; or to
---                      pid P, negated for a process group, as kill(2)
---                      takes it, or `@F` for the one file F holds, and
---                      goes on. 0 and -1, which name no one process or
---                      group, fail
---     trap N           holds SIGINT and SIGTERM (`Child.guard`) and ends
---                      with status N once one arrives: checked between
---                      commands and while it sleeps or waits; `trap -`
---                      holds them and goes on, as a shell's `trap ''`
---                      does -- though, caught rather than ignored, not
---                      for a program it starts
---     sleep MS         sleeps MS milliseconds
---     sleep-forever    sleeps until it is ended
---     wait-for F       waits until file F exists
---     exists P N       ends with status N if P exists
---     copy A B         file A's bytes as the whole of file B
---     cwd [F]          its working directory and a newline, to stdout or F
---     mkfifo P         makes a named pipe at P
---     mkdirs D         makes directory D and its parents
---     grep-count F T   how many lines of file F hold T, to stdout
---     status-field K   its line of /proc/self/status that names K
---     run P [T]        starts P, with T its one argument, and waits for
---                      it, as a shell runs one: what P leaves running
---                      runs on, and none of it is adopted here; ends
---                      with P's status where it fails (128 past a
---                      signal), and 127 where P cannot start, as after
---                      a `trap`: a process holds one guard at once
---     start P [T]      starts P, with T its one argument, and goes on
---                      without waiting for it, as a shell's `P &` does:
---                      it outlives the script, which then ends by
---                      `sys.exit`, past what would end it
---     fd-closed N      ends with status 1 unless descriptor N is
---                      closed, and 2 when N names no descriptor
---     write-fd N T     T and a newline, to descriptor N
---     env-of NAME      `NAME=` and the variable's value, or `NAME unset`,
---                      and a newline, to stdout: unlike `$NAME`, it
---                      tells an empty variable from an unset one
---     present P        fails unless P exists, as `test -e` does
---     writable P       fails unless file P opens to write, appending
---                      and writing nothing, as `: >> P` does, but never
---                      making it
---     mode P           P's permission bits in octal and a newline, to
---                      stdout, as `stat -c %a` prints them
---     find-writable D  each regular file beneath D that opens to write,
---                      as `writable` opens one, a line each: a link is
---                      neither listed nor walked into, as `find D -type
---                      f` walks, and a file is listed only where it
---                      leads to one too, as `test -f` takes it; a
---                      directory it cannot list is passed over
---
--- A verb, its first word and the rest are split at the blanks between
--- them, however many, which go; the rest keeps its own spacing. In a
--- command's words, `$@` is its arguments joined by spaces, `$DIR` the
--- directory it sits in, and `$NAME` the environment variable NAME, empty
--- when unset, each put in once: what is put in is not read for a `$`
--- again. A command written `[w] ...` runs only when its first
--- argument is `w`. A command that fails says why on stderr and ends
--- with status 1; an unknown verb ends with 2. The script's end is
--- status 0.
---
--- Commands chain as a shell's do, left to right, at an `&&` or `||`
--- standing between blanks: `A && B` runs B only where A went on, and
--- `A || B` runs B only where A would have ended the script -- failed,
--- or exited -- and goes on as B does. What a failure a `||` takes up
--- would have said is not said. A chain that ends the script ends it
--- with the status of the last command run.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local type _ = require("build.embed")

local record stand_in
end

--- The stand-in's whole program, `cmd/probe/main.tl` of the tree it is
--- built from.
local main_source <const> = [==[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

local SLICE_MS <const> = 5

--- How long `signal` waits for one it sent itself to end it, and the
--- status it ends with past that.
local SIGNAL_WAIT_MS <const> = 2000
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
--- would end its process: the script then ends by `sys.exit`.
local started: {Child.Handle} = {}

--- What the commands of the chain running have said of their failures,
--- said once the chain ends the script, and not where a `||` takes one
--- up.
local troubles: {string} = {}

local function trap_fired(): boolean
  return guard ~= nil and not ignoring and guard:cancelled() ~= 0
end

--- Sleeps `ms` milliseconds by the clock, a slice at a time, however
--- long a slice's sleep takes (a host may coalesce short timers into
--- longer ones): the status a trap ends it with, or nil.
local function sleep_ms(ms: integer): integer
  local deadline = Time.monotonic_ns() + ms * 1000000
  while true do
    if trap_fired() then return trapped end
    local left = (deadline - Time.monotonic_ns()) // 1000000
    if left <= 0 then break end
    local _, _ = sys.nanosleep(math.min(left, SLICE_MS) * 1000000)
  end
  if trap_fired() then return trapped end
  return nil
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
      named = held:match("^%s*(.-)%s*$")
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
    -- Its own: it ends of it, or of a trap that holds it, soon; one
    -- that never lands -- a trap that goes on, or a process to which
    -- the kernel delivers no signal it does not catch, as its pid
    -- namespace's init -- ends it all the same, saying so.
    local stopped = sleep_ms(SIGNAL_WAIT_MS)
    if stopped ~= nil then return stopped end
    -- Past the bound by the clock, it ends here and now, through no
    -- more of the script, nor anything its end would run.
    local _, _ = Fs.put(2, "probe: signal: SIG" .. name .. " sent to itself did not end it in " ..
      tostring(SIGNAL_WAIT_MS) .. " ms\n")
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
    return sleep_ms(number(ms) or 0)
  end,
  ["sleep-forever"] = function(): integer
    while true do
      local stopped = sleep_ms(1000)
      if stopped ~= nil then return stopped end
    end
  end,
  ["wait-for"] = function(path: string): integer
    while Fs.exists(path) ~= true do
      local stopped = sleep_ms(SLICE_MS)
      if stopped ~= nil then return stopped end
    end
    return nil
  end,
  exists = function(path: string, status: string): integer
    if Fs.exists(path) == true then return number(status) or 2 end
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
      if line:sub(1, #name + 1) == name .. ":" then return put_all(1, line .. "\n") end
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
  ["env-of"] = function(name: string): integer
    local value = sys.getenv(name)
    return put_all(1, value ~= nil and name .. "=" .. value .. "\n" or name .. " unset\n")
  end,
  present = function(path: string): integer
    if Fs.exists(path) == true then return nil end
    return failed(path, "not there")
  end,
  writable = function(path: string): integer
    local opened, trouble = opens_to_write(path)
    if not opened then return failed(path, trouble) end
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
            if st ~= nil and st.kind == "file" and opens_to_write(path) then
              lines[#lines + 1] = path .. "\n"
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
    local line: string = each:match("^%s*(.-)%s*$")
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
  local self = Proc.executable() or ""
  local beside, _ = Fs.read(self .. ".do")
  if beside == nil and argv[1] ~= nil then
    -- A script file whose `#!` line names it: its body.
    local st, _ = sys.stat(argv[1])
    local text: string = nil
    if st ~= nil and st.kind == "file" then text = Fs.read(argv[1]) end
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
]==]

--- What builds the stand-in's tree, `...` its root, in a process of
--- its own.
local build_chunk <const> = [[
local names, trouble = require("build.embed").tree((...), true)
if names == nil then
  require("cosmic.fs").put(2, trouble .. "\n")
  return 1
end
return 0
]]

--- Builds a stand-in under `dir`, made if it is not there, and answers
--- the executable's path: `dir/o/bin/probe`. The build runs in a
--- process of this program of its own, started past its launcher
--- (`this_program.program`) with the environment a process of this
--- program needs (`this_program.environment`): a test worker's coverage
--- hook, which a child is not given, would make it several times slower.
function stand_in.build(dir: string): string | nil, string
  -- TODO: compile only cmd/probe/main.tl, against the modules this
  -- program already carries, and append it to the core, rather than
  -- stage, check and project a whole tree with `embed.tree`, once
  -- build.embed takes a prebuilt store (or build.importer compiles one
  -- module to a database on its own): a whole tree's build takes about
  -- 0.7 s, and on the checked core about 2 s.
  local made, trouble = Fs.mkdirs(dir .. "/cmd/probe")
  if not made then return nil, trouble end
  local written, write_trouble = Fs.write(dir .. "/cmd/probe/main.tl", main_source)
  if not written then return nil, write_trouble end
  local started = this_program.program({ "-e", build_chunk, dir },
    { env = this_program.environment(), stdout = "null", stderr = "capture" })
  local result, run_trouble = Child.run(started.argv, started.options)
  if result == nil then return nil, "building the stand-in: " .. run_trouble end
  if not result.ok then
    local said = result.stderr or ""
    return nil, "building the stand-in failed" ..
      (said ~= "" and ": " .. said or " (" .. tostring(result.code or result.signal) .. ")")
  end
  return dir .. "/o/bin/probe", ""
end

--- Copies the stand-in `probe` to `path`, executable -- a copy, not a
--- symbolic link, since it finds its script beside the path it
--- resolves itself to -- and writes `script` to `path .. ".do"`, when
--- one is given, for it to run.
-- TODO: make a hard link to `probe` where one can be made (the same
-- file system), falling back to this copy, once cosmic.sys carries
-- link: a checked core's probe is 39.5 MB, about 0.2 s a copy.
function stand_in.place(probe: string, path: string, script?: string): boolean, string
  local bytes, trouble = Fs.read(probe)
  if bytes == nil then return false, trouble end
  local written, write_trouble = Fs.write(path, bytes, 0x1ed)
  if not written then return false, write_trouble end
  if script ~= nil then
    return Fs.write(path .. ".do", script)
  end
  return true, ""
end

return stand_in
