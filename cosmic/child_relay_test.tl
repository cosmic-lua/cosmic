--- [`Child.start`]'s `policy` with `connect` (cosmic/child.tl), on live
--- children: the network relay it starts for the grants (cosmic/relay/main.tl,
--- this program's core on a database sealed for it), the proxy environment
--- the program is given, and what the relay does to a flow it is asked for.
--- The program is this program's core on a database sealed for it, which sends
--- an HTTP CONNECT and a SOCKS5 request to the relay and says what came back.
--- The servers are this test's own, at 127.0.0.2 of the worker's network,
--- which the relay's connectors (started by the start, in the worker's
--- network) reach and the program (a network of its own) and the relay
--- (which makes no socket) do not. They need a sandbox that nests
--- (`requires`): where the platform has none they are not applicable, and where
--- this host gives no user namespace, Landlock or seccomp each skips itself
--- (Test.skip).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Relay = require("cosmic.relay")
local Sandbox = require("cosmic.sandbox")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given (the
--- grant of o/cosmic.db), and so does the start's own seal of the relay's
--- program. The core is started past its launcher (the grant of o/bin). Both
--- programs make namespaces of their own ("nest"), which a worker held by
--- a Landlock ruleset cannot. The two addresses are the servers' and the one
--- a program is told to leave direct.
Test.policy{
  profiles = { "cosmic" },
  promises = { "nest" },
  loopback = { "127.0.0.1", "127.0.0.2" },
  env = { "TMPDIR" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "o/cosmic.db", letters = "r" },
  },
  requires = { "nest" },
}

--- The program: what it does depends on its first argument. "flows" sends
--- requests at the relay and says what came back, a line `name<TAB>value`
--- each; "wait" sleeps until it is ended.
local CLIENT <const> = [==[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local sys = require("cosmic.sys")

local function say(name, value) print(name .. "\t" .. tostring(value)) end

-- Exactly `count` bytes, fewer where the peer ends first.
local function bytes(conn, count)
  local data = ""
  while #data < count do
    local chunk = conn:read(count - #data)
    if chunk == nil then break end
    data = data .. chunk
  end
  return data
end

local function head(conn)
  local data = ""
  while not data:find("\r\n\r\n", 1, true) do
    local chunk = conn:read(4096)
    if chunk == nil then break end
    data = data .. chunk
  end
  return data
end

local function relay(port)
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(20) })
  assert(conn, why)
  return conn
end

local function through_connect(label, target)
  local conn = relay(3128)
  assert(conn:write("CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n\r\n"))
  local reply = head(conn)
  say(label, (reply:match("^[^\r]*")))
  if reply:find("^HTTP/1.1 200") then
    assert(conn:write("ping"))
    say(label .. "_echo", bytes(conn, 9))
  end
  conn:close()
end

local function through_socks(label, port)
  local conn = relay(1080)
  assert(conn:write("\5\1\0"))
  assert(bytes(conn, 2) == "\5\0", "the greeting was not taken")
  assert(conn:write("\5\1\0\1" .. string.char(127, 0, 0, 2) .. string.pack(">I2", port)))
  local reply = bytes(conn, 10)
  say(label, reply:byte(2))
  if reply:byte(2) == 0 then
    assert(conn:write("ping"))
    say(label .. "_echo", bytes(conn, 9))
  end
  conn:close()
end

return function(args)
  if args[1] == "flows" then
    local granted, ungranted = math.tointeger(tonumber(args[2])), math.tointeger(tonumber(args[3]))
    for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY",
        "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY" }) do
      say("env_" .. name, sys.getenv(name))
    end
    through_connect("connect", "127.0.0.2:" .. granted)
    through_connect("connect_ungranted", "127.0.0.2:" .. ungranted)
    through_socks("socks", granted)
    through_socks("socks_ungranted", ungranted)
    local conn, why = Net.connect(Net.tcp("127.0.0.2", granted), { timeout_ns = Clock.seconds(20) })
    say("direct", conn ~= nil and "connected" or why)
  elseif args[1] == "env" then
    for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY",
        "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY" }) do
      say("env_" .. name, sys.getenv(name))
    end
  elseif args[1] == "fds" then
    local names = assert(Fs.list("/proc/self/fd"))
    for _, name in ipairs(names) do
      say("fd_" .. name, sys.readlink("/proc/self/fd/" .. name))
    end
  elseif args[1] == "dial" then
    local conn, why = Net.connect(Net.tcp(args[2], math.tointeger(tonumber(args[3]))), { timeout_ns = Clock.seconds(5) })
    say("dial", conn ~= nil and "connected" or why)
  elseif args[1] == "wait" then
    sys.nanosleep(Clock.seconds(120))
  elseif args[1] == "later" then
    -- Asks only once standard input ends, which the test closes when it
    -- is ready for the request.
    while true do
      local data = sys.read(0, 4096)
      if data == nil or data == "" then break end
    end
    through_connect("later", "127.0.0.2:" .. args[2])
    sys.nanosleep(Clock.seconds(120))
  end
  return 0
end
]==]

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- The program's database, sealed in `tmp`, and its SHA-256 in hex:
--- this program's core runs it.
local function sealed_client(tmp: string): string, string
  local chunk = assert(load(CLIENT, "=relay_client"))
  local requires = { "cosmic.clock", "cosmic.fs", "cosmic.net" }
  local path = tmp .. "/client.db"
  local digest = assert(Store.seal(Store.closure(requires), path, { extra = { name = "relay_client",
    bytecode = string.dump(chunk), source = CLIENT, requires = requires } }))
  return path, digest
end

--- An echo server for `listener`, answering "echo:" and the four bytes each
--- connection sends, as a task of the run.
local function echoing(listener: Net.Listener): Poll.Task
  return Poll.spawn(function()
    while true do
      local conn = listener:accept()
      if conn == nil then return end
      Poll.spawn(function()
        local data = conn:read(4)
        if data ~= nil then
          local _, _ = conn:write("echo:" .. data)
        end
        local _, _ = conn:close()
      end)
    end
  end)
end

--- Runs `body` in a task of a run, with echo servers at two ports of
--- 127.0.0.2: the first is the one a policy grants, the second one it does not.
local function serving(body: function(granted: integer, ungranted: integer))
  Poll.run(function()
    local first = assert(Net.listen(Net.tcp("127.0.0.2", 0)))
    local second = assert(Net.listen(Net.tcp("127.0.0.2", 0)))
    local tasks = { echoing(first), echoing(second) }
    body(first.address.port, second.address.port)
    for _, task in ipairs(tasks) do task:cancel() end
    assert(first:close())
    assert(second:close())
  end)
end

--- The policy that grants `port` of 127.0.0.2 to the program on `database`.
local function granting(database: string, port: integer): Child.Options
  return { policy = { database = database, connect = { "127.0.0.2:" .. port },
    loopback = { "127.0.0.2" } }, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60) }
end

--- A handle to a program that waits, which a test then ends in its own
--- way, started under a policy granting `port`; or nil and why where this
--- host gives no sandbox (a start refused for any other reason fails).
local function waiting(tmp: string, port: integer): Child.Handle | nil, string
  local options = granting(sealed_client(tmp), port)
  options.stdout, options.stderr = "null", "null"
  local handle, why = Child.start({ assert(Proc.executable()), "wait" }, options)
  if handle == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    return nil, why
  end
  return handle, ""
end

--- Runs `body` in a task of a run with a handle to a program that waits,
--- and ends the test, skipped, where the host gives no sandbox. A skip
--- raised in the run would come out of it as the run's own failure.
local function while_waiting(tmp: string, body: function(handle: Child.Handle))
  local refusal: string
  Poll.run(function()
    local handle, why = waiting(tmp, 9)
    if handle == nil then
      refusal = why
      return
    end
    body(handle)
  end)
  if refusal ~= nil then Test.skip(refusal) end
end

--- Whether the process `pid` is gone: reaped, or never there.
local function gone(pid: integer): boolean
  local alive, _, errno = sys.kill(pid, 0)
  return not alive and errno == sys.ESRCH
end

--- The lines `name<TAB>value` of a program's output, by name.
local function fields(output: string): {string:string}
  local out: {string:string} = {}
  for line in output:gmatch("([^\n]*)\n") do
    local name, value = line:match("^([^\t]+)\t(.*)$")
    if name ~= nil then out[name] = value end
  end
  return out
end

--- What the program says of its flows, and the port its servers left
--- ungranted: ends the test, skipped, where the host gives no sandbox.
local function flows(tmp: string): {string:string}, integer
  local database = sealed_client(tmp)
  local said: {string:string}
  local refusal: string
  local other: integer
  serving(function(granted: integer, ungranted: integer)
    local result, why = Child.run({ assert(Proc.executable()), "flows", tostring(granted),
      tostring(ungranted) }, granting(database, granted))
    if result == nil then
      assert(unsandboxable(why), "the start was refused: " .. why)
      refusal = why
      return
    end
    assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    said, other = fields(assert(result.stdout)), ungranted
  end)
  if refusal ~= nil then Test.skip(refusal) end
  return said, other
end

--- A granted flow reaches its server, in both protocols; one nothing
--- granted is refused with the grant that would open it; and the program's
--- own network holds no route of its own to the server.
local function test_a_granted_flow_echoes_and_an_ungranted_one_is_refused(tmp: string)
  local said, ungranted = flows(tmp)
  assert(said.connect_ungranted:find(" 403 not granted: --connect 127.0.0.2:" .. ungranted, 1, true),
    tostring(said.connect_ungranted))
  assert(said.connect == "HTTP/1.1 200 Connection established", tostring(said.connect))
  assert(said.connect_echo == "echo:ping", tostring(said.connect_echo))
  assert(said.socks == "0" and said.socks_echo == "echo:ping", tostring(said.socks))
  assert(said.socks_ungranted ~= "0" and said.socks_ungranted_echo == nil,
    tostring(said.socks_ungranted))
  assert(said.connect_ungranted_echo == nil, "an ungranted flow went through")
  assert(said.direct ~= "connected" and said.direct:find("refused", 1, true),
    "the program's network is its own: " .. tostring(said.direct))
end

--- The program is pointed at the relay by every variable a proxy client
--- reads, and its own network (the policy's loopback) is left direct.
local function test_the_program_is_given_the_proxy_environment(tmp: string)
  local said = flows(tmp)
  for name, value in pairs(Relay.Config.proxy_env({ "127.0.0.2" })) do
    assert(said["env_" .. name] == value, name .. " is " .. tostring(said["env_" .. name]))
  end
  assert(said.env_HTTPS_PROXY == "http://127.0.0.1:3128" and said.env_ALL_PROXY == "socks5h://127.0.0.1:1080" and
      said.env_NO_PROXY == "localhost,127.0.0.1,::1,127.0.0.2" and said.env_NODE_USE_ENV_PROXY == "1",
    "the variables are the relay's")
end

--- Once the program has been waited for, its relay is ended and reaped.
local function test_the_relay_is_gone_once_the_program_is_waited_for(tmp: string)
  while_waiting(tmp, function(handle: Child.Handle)
    local relay = assert(handle._relay, "the start runs a relay")
    assert(not gone(relay.pid), "the relay runs while the program does")
    assert(handle:stop())
    local result = assert(handle:wait(Clock.seconds(20)))
    assert(result.signal == sys.SIGTERM, "the program was ended")
    assert(gone(relay.pid), "the relay is gone after the wait")
    assert(handle._relay == nil, "the handle let go of it")
  end)
end

--- A handle dropped unwaited ends the program and its relay too.
local function test_a_dropped_handle_ends_the_relay(tmp: string)
  local relay_pid, program_pid: integer, integer
  while_waiting(tmp, function(handle: Child.Handle)
    relay_pid, program_pid = assert(handle._relay).pid, handle.pid
    assert(not gone(relay_pid) and not gone(program_pid))
  end)
  collectgarbage()
  collectgarbage()
  assert(gone(relay_pid), "the relay outlived its handle")
  assert(gone(program_pid), "the program outlived its handle")
end

--- A relay whose standard input closes ends, which leaves the program no
--- way out, so it is ended at the next wait; so is one that dies.
local function test_a_relay_that_ends_ends_its_program(tmp: string)
  while_waiting(tmp, function(first: Child.Handle)
    local relay = assert(first._relay)
    assert(assert(relay.stdin_stream):close())
    local result = assert(first:wait(Clock.seconds(20)))
    assert(result.signal == sys.SIGKILL and not result.timed_out,
      "the program was ended: " .. tostring(result.signal))
    assert(gone(relay.pid), "the relay ended with its input")
  end)
  while_waiting(tmp, function(second: Child.Handle)
    local killed = assert(second._relay)
    assert(sys.kill(killed.pid, sys.SIGKILL))
    local after = assert(second:wait(Clock.seconds(20)))
    assert(after.signal == sys.SIGKILL and not after.timed_out,
      "the program was ended: " .. tostring(after.signal))
    assert(gone(killed.pid))
  end)
end

--- The host's own addresses the relay is told include the worker's loopback.
local function test_the_hosts_own_addresses_are_read_from_proc(_tmp: string)
  local found = assert(Relay.Config.host_addresses())
  local seen = false
  for _, address in ipairs(found) do
    if address == "127.0.0.1" then seen = true end
  end
  assert(seen, "127.0.0.1 is among: " .. table.concat(found, " "))
end

--- Starts a program under a policy with `connect` and says what the start
--- answered, and which of this process's children are still running after it.
local STARTER <const> = [==[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local started, why = Child.start({ assert(Proc.executable()), "wait" }, { policy = {
    database = argv[1], connect = { "127.0.0.2:9" } }, stdout = "null", stderr = "null" })
  local pid = sys.getpid()
  local running: {string} = {}
  for child in (Fs.read("/proc/" .. pid .. "/task/" .. pid .. "/children") or ""):gmatch("%d+") do
    local state = (Fs.read("/proc/" .. child .. "/stat") or ""):match("%) (%a)")
    if state ~= "Z" then running[#running + 1] = child .. ":" .. tostring(state) end
  end
  local left: {string} = {}
  for _, name in ipairs((assert(Fs.list(sys.getenv("TMPDIR") or "/tmp")))) do
    if name:find("^cosmic%-relay%-") then left[#left + 1] = name end
  end
  Fs.put(Fs.stdout, (started == nil and "refused: " .. why or "started") .. "\nrunning: " ..
    table.concat(running, ",") .. "\ndirectories: " .. table.concat(left, ","))
  return 0
end
]==]

--- A relay that will not serve fails the start, with the relay's own words,
--- and the program it was to serve is ended, not left running unserved.
--- The relay cannot use the caller's `https_proxy` here (a scheme it does
--- not speak), which it says on starting.
local function test_a_relay_that_will_not_serve_fails_the_start_and_ends_the_program(tmp: string)
  local script = tmp .. "/start.tl"
  assert(Fs.write(script, STARTER))
  local env = this_program.environment()
  env.https_proxy = "https://proxy.test:3128"
  local started = this_program.program({ "--standalone", script, sealed_client(tmp) },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local said = assert(result.stdout)
  if said:find("Landlock", 1, true) or said:find("namespace", 1, true) then Test.skip(said) end
  assert(said:find("^refused: child: start: sandbox: relay: https_proxy has the scheme \"https\""), said)
  assert(said:find("running: \n", 1, true), "a program was left running: " .. said)
  assert(said:find("directories: $"), "the relay's database was left: " .. said)
end

--- An upstream proxy whose host does not resolve fails the start, naming
--- the host, with nothing left running: the starter resolves it once, and
--- a relay that could reach nothing through it serves nothing.
local function test_an_upstream_whose_host_does_not_resolve_fails_the_start(tmp: string)
  local script = tmp .. "/start.tl"
  assert(Fs.write(script, STARTER))
  local env = this_program.environment()
  env.https_proxy = "http://proxy.invalid:3128"
  local started = this_program.program({ "--standalone", script, sealed_client(tmp) },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  local said = assert(result.stdout)
  if said:find("Landlock", 1, true) or said:find("namespace", 1, true) then Test.skip(said) end
  assert(said:find("^refused: child: start: sandbox: relay: https_proxy's host proxy.invalid "), said)
  assert(said:find("running: \n", 1, true), "a program or connector was left running: " .. said)
  assert(said:find("directories: $"), "the relay's database was left: " .. said)
end

--- Runs the flows of the program in a process of this program's own, which
--- starts it with `relay_log` as given, and says what that process's
--- standard error, where an "inherit" relay logs, held.
local FLOWS <const> = [==[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
return function(argv: {string}): integer
  local log: Child.RelayLog = argv[4] == "inherit" and "inherit" or "null"
  local result, why = Child.run({ assert(Proc.executable()), "flows", argv[2], argv[3] }, {
    policy = { database = argv[1], connect = { "127.0.0.2:" .. argv[2] }, loopback = { "127.0.0.2" } },
    stdout = "capture", stderr = "capture", relay_log = log })
  assert(result, why)
  Fs.put(Fs.stdout, assert(result.stdout))
  return 0
end
]==]

--- A relay's decision lines go to this process's standard error where
--- `relay_log` is "inherit", and nowhere by default.
local function test_the_relays_log_goes_where_the_start_says(tmp: string)
  local script = tmp .. "/flows.tl"
  assert(Fs.write(script, FLOWS))
  local database = sealed_client(tmp)
  local errors: {string:string} = {}
  local refusal: string
  serving(function(granted: integer, ungranted: integer)
    for _, log in ipairs({ "inherit", "null" }) do
      local started = this_program.program({ "--standalone", script, database, tostring(granted),
        tostring(ungranted), log }, { env = this_program.environment(), stdout = "capture",
          stderr = "capture", timeout_ns = Clock.seconds(60) })
      local result = assert(Child.run(started.argv, started.options))
      if not result.ok and unsandboxable(result.stderr or "") then
        refusal = result.stderr
        return
      end
      assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
      errors[log] = assert(result.stderr)
      assert(fields(assert(result.stdout)).connect_echo == "echo:ping", "the flow was served")
    end
    assert(errors.inherit:find("not granted: --connect 127.0.0.2:" .. ungranted, 1, true),
      "the refusal is logged: " .. errors.inherit)
    assert(errors.inherit:find("connect 127.0.0.2:" .. granted .. ": allowed", 1, true),
      "the granted flow is logged: " .. errors.inherit)
  end)
  if refusal ~= nil then Test.skip(refusal) end
  assert(not errors["null"]:find("not granted", 1, true), "the log was dropped: " .. errors["null"])
end

--- A descriptor of this process as `relay_log` gets the relay's decision
--- lines, and nothing reaches this process's standard error: the way a
--- caller whose own standard error is a terminal, which a sandboxed relay
--- may not hold, shows them.
local function test_the_relays_log_goes_to_a_descriptor_the_caller_gives(tmp: string)
  local database = sealed_client(tmp)
  assert(sys.mkfifo(tmp .. "/log", 384))
  local reader = assert(sys.open(tmp .. "/log", sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(tmp .. "/log", sys.O_WRONLY, 0))
  local refusal: string
  local program_stderr: string
  serving(function(granted: integer, ungranted: integer)
    local options = granting(database, granted)
    options.relay_log = writer
    local result, why = Child.run({ assert(Proc.executable()), "flows", tostring(granted), tostring(ungranted) },
      options)
    if result == nil then
      assert(unsandboxable(why), "the start was refused: " .. why)
      refusal = why
      return
    end
    assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    program_stderr = result.stderr
    local lines = assert(sys.read(reader, 65536))
    assert(lines:find("not granted: --connect 127.0.0.2:" .. ungranted, 1, true), "the refusal is in it: " .. lines)
    assert(lines:find("connect 127.0.0.2:" .. granted .. ": allowed", 1, true), "the flow is in it: " .. lines)
  end)
  assert(sys.close(reader))
  assert(sys.close(writer))
  if refusal ~= nil then Test.skip(refusal) end
  assert(not program_stderr:find("not granted", 1, true), "the program's own standard error holds no line")
end

--- A relay whose connector of a kind has ended can reach nothing of that
--- kind again: at the next connection of that kind it logs why and ends,
--- and so its program is ended, rather than refused each such connection
--- for the rest of its life.
local function test_a_relay_whose_connector_has_ended_ends_with_its_program(tmp: string)
  local database = sealed_client(tmp)
  assert(sys.mkfifo(tmp .. "/log", 384))
  local reader = assert(sys.open(tmp .. "/log", sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(tmp .. "/log", sys.O_WRONLY, 0))
  local refusal: string
  serving(function(granted: integer, _: integer)
    local options = granting(database, granted)
    options.stdin, options.stdout, options.stderr, options.relay_log = "stream", "null", "null", writer
    local handle, why = Child.start({ assert(Proc.executable()), "later", tostring(granted) }, options)
    if handle == nil then
      assert(unsandboxable(why), "the start was refused: " .. why)
      refusal = why
      return
    end
    local relay = assert(handle._relay)
    -- Every connector the relay was handed ends, and only then does the
    -- program ask for its target.
    assert(relay._handover).close()
    assert(assert(handle.stdin_stream):close())
    local result = assert(handle:wait(Clock.seconds(20)))
    assert(result.signal == sys.SIGKILL and not result.timed_out,
      "the program was ended: " .. tostring(result.signal) .. " " .. tostring(result.timed_out))
    assert(gone(relay.pid), "the relay ended")
    local lines = assert(sys.read(reader, 65536))
    assert(lines:find("relay: the table connector has ended: the relay ends", 1, true), "it says why: " .. lines)
  end)
  assert(sys.close(reader))
  assert(sys.close(writer))
  if refusal ~= nil then Test.skip(refusal) end
end

--- The directories of a start's making that are in the temporary directory.
local function relay_directories(): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list(sys.getenv("TMPDIR") or "/tmp")))) do
    if name:find("^cosmic%-relay%-") then found[#found + 1] = name end
  end
  return found
end

--- A terminal as the relay's log is refused naming the option, with nothing
--- left running (test/terminal/relay.tl does this where no pty is given).
local function test_a_terminal_or_a_kept_descriptor_is_no_place_for_the_relays_log(tmp: string)
  local database = sealed_client(tmp)
  local opened, pty_why = sys.openpty()
  if opened == nil then Test.skip("no pty: " .. pty_why) end
  local pty = assert(opened)
  local options = granting(database, 9)
  options.relay_log = pty.slave
  local started, why = Child.start({ assert(Proc.executable()), "wait" }, options)
  assert(sys.close(pty.slave))
  assert(sys.close(pty.master))
  if started ~= nil then
    assert(started:stop())
    assert(false, "a start with a terminal as the relay's log went on")
  end
  if unsandboxable(why) then Test.skip(why) end
  assert(why:find("relay_log " .. pty.slave .. " is a terminal", 1, true), why)
  assert(#relay_directories() == 0, "the relay's database was left")
end

--- A descriptor this program keeps for itself, where one is to be found,
--- is refused as the relay's log, not raised on.
local function test_a_descriptor_the_program_keeps_is_no_place_for_the_relays_log(tmp: string)
  local database = sealed_client(tmp)
  local tried = 0
  for fd = 3, 255 do
    local looked, _ = pcall(sys.isatty, fd)
    if not looked then
      local kept = granting(database, 9)
      kept.relay_log = fd
      local refused, refusal = Child.start({ assert(Proc.executable()), "wait" }, kept)
      assert(refused == nil and refusal:find("relay_log " .. fd .. " is a descriptor this program keeps", 1, true),
        tostring(refusal))
      tried = tried + 1
    end
  end
  if tried == 0 then Test.skip("this program keeps no descriptor for itself here") end
end

--- The relay's database is removed before the program exists, so a program
--- that can write where it was made has nothing to swap; and nothing of it
--- is left once the program is gone.
local function test_the_relays_database_is_gone_while_the_program_runs(tmp: string)
  while_waiting(tmp, function(handle: Child.Handle)
    assert(#relay_directories() == 0, "the database is still on disk: " .. table.concat(relay_directories(), " "))
    assert(handle:stop())
    assert(handle:wait(Clock.seconds(20)))
  end)
  assert(#relay_directories() == 0)
end

--- A policy with no `connect` starts no relay and sets no proxy variable;
--- neither the program nor the relay holds a descriptor of this process's
--- that it did not give: an open file of the test is in neither's table, and
--- the program holds no socket.
local function test_no_connect_means_no_relay_and_no_extra_descriptors(tmp: string)
  local database = sealed_client(tmp)
  local plain, why = Child.run({ assert(Proc.executable()), "env" }, { policy = { database = database },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  if plain == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
  end
  assert(plain ~= nil and plain.ok, tostring(plain ~= nil and plain.stderr))
  for name, value in pairs(fields(assert(plain.stdout))) do
    assert(value == "nil", name .. " is set without connect: " .. value)
  end
  local kept = tmp .. "/kept"
  local fd = assert(sys.open(kept, sys.O_CREAT | sys.O_RDWR, 420))
  local options = granting(database, 9)
  options.policy.grants = { { path = "/proc", letters = "r" } }
  local program = assert(Child.run({ assert(Proc.executable()), "fds" }, options))
  assert(program.ok, tostring(program.stderr))
  local held = fields(assert(program.stdout))
  assert(held.fd_0 ~= nil and held.fd_1 ~= nil and held.fd_2 ~= nil, "the program lists its descriptors")
  for name, target in pairs(held) do
    assert(not target:find("socket:", 1, true), name .. " is a socket: " .. target)
    assert(not target:find(kept, 1, true), name .. " is this process's file: " .. target)
  end
  options.stdout, options.stderr = "null", "null"
  while_waiting(tmp, function(handle: Child.Handle)
    local relay = assert(handle._relay)
    local names = assert(Fs.list("/proc/" .. relay.pid .. "/fd"), "the relay's descriptors are readable")
    for _, name in ipairs(names) do
      local target = sys.readlink("/proc/" .. relay.pid .. "/fd/" .. name)
      assert(target == nil or not target:find(kept, 1, true), "the relay holds this process's file")
    end
    assert(handle:stop())
    assert(handle:wait(Clock.seconds(20)))
  end)
  assert(sys.close(fd))
end

--- The relay runs offline: a program under the very policy its process is
--- started under ([`cosmic.sandbox.relay`]'s `policy`) cannot connect to a
--- server this process reaches, as its filter refuses the socket, so the
--- relay reaches nothing but through the connectors it is handed.
local function test_the_relays_policy_gives_it_no_network_of_its_own(tmp: string)
  local database, digest = sealed_client(tmp)
  local said: string
  local refusal: string
  serving(function(granted: integer, _ungranted: integer)
    local reached = assert(Net.connect(Net.tcp("127.0.0.2", granted), { timeout_ns = Clock.seconds(5) }))
    assert(reached:close())
    local result, why = Child.run({ assert(Proc.executable()), "dial", "127.0.0.2", tostring(granted) },
      { policy = Sandbox.Relay.policy(database, digest), stdout = "capture", stderr = "capture",
        timeout_ns = Clock.seconds(60) })
    if result == nil then
      assert(unsandboxable(why), "the start was refused: " .. why)
      refusal = why
      return
    end
    assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    said = fields(assert(result.stdout)).dial
  end)
  if refusal ~= nil then Test.skip(refusal) end
  assert(said ~= nil and said ~= "connected", "the relay's policy made a connection: " .. tostring(said))
  assert(said:find("not permitted", 1, true), "the kernel refused the socket: " .. said)
end

--- A policy that names more addresses literally than the relay's
--- connector holds fails to start, saying so, with nothing left running.
local function test_more_literal_targets_than_a_connector_holds_fail_the_start(tmp: string)
  local options = granting(sealed_client(tmp), 9)
  local targets: {string} = {}
  for port = 1, 129 do targets[port] = "127.0.0.2:" .. port end
  options.policy.connect = targets
  local started, why = Child.start({ assert(Proc.executable()), "wait" }, options)
  if started ~= nil then
    assert(started:stop())
    assert(false, "a start with 129 literal targets went on")
  end
  if unsandboxable(why) then Test.skip(why) end
  assert(why:find("relay: connect names 129 addresses literally: 129 endpoints, more than the " ..
      "128 a connector holds; grant fewer addresses, or names", 1, true), why)
  assert(#relay_directories() == 0, "the relay's database was left")
end

--- An upstream proxy the caller names by address is reached through the
--- relay's table connector: the program's flow goes to it, and it is
--- asked to CONNECT to the target.
local function test_the_upstream_proxy_is_reached_through_the_table(tmp: string)
  local script = tmp .. "/flows.tl"
  assert(Fs.write(script, FLOWS))
  local database = sealed_client(tmp)
  local asked: {string} = {}
  local said: {string:string}
  local refusal: string
  serving(function(granted: integer, ungranted: integer)
    local listener = assert(Net.listen(Net.tcp("127.0.0.2", 0)))
    local proxy = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        Poll.spawn(function()
          local head = ""
          while not head:find("\r\n\r\n", 1, true) do
            local data = conn:read(4096)
            if data == nil then break end
            head = head .. data
          end
          asked[#asked + 1] = head:match("^[^\r]*") or ""
          local _, _ = conn:write("HTTP/1.1 200 Connection established\r\n\r\n")
          local data = conn:read(4)
          if data ~= nil then
            local _, _ = conn:write("echo:" .. data)
          end
          local _, _ = conn:close()
        end)
      end
    end)
    local env = this_program.environment()
    env.https_proxy = "http://127.0.0.2:" .. listener.address.port
    local started = this_program.program({ "--standalone", script, database, tostring(granted),
      tostring(ungranted), "null" }, { env = env, stdout = "capture", stderr = "capture",
        timeout_ns = Clock.seconds(60) })
    local result = assert(Child.run(started.argv, started.options))
    proxy:cancel()
    assert(listener:close())
    if not result.ok and unsandboxable(result.stderr or "") then
      refusal = result.stderr
      return
    end
    assert(result.ok, "exit " .. tostring(result.code) .. ": " .. tostring(result.stderr))
    said = fields(assert(result.stdout))
  end)
  if refusal ~= nil then Test.skip(refusal) end
  assert(said.connect == "HTTP/1.1 200 Connection established" and said.connect_echo == "echo:ping",
    tostring(said.connect) .. " " .. tostring(said.connect_echo))
  assert(#asked >= 1 and asked[1]:find("^CONNECT 127%.0%.0%.2:%d+ HTTP/1%.1$"), table.concat(asked, " | "))
end
