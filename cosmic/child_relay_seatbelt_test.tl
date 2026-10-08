--- [`Child.start`]'s `policy` with `connect` on macOS (cosmic/child.tl),
--- where Seatbelt holds the program and its network relay
--- (cosmic/relay/main.tl): the relay listens at a port of the host's
--- loopback behind a token drawn for the start, and the program's profile
--- lets it reach that port and nothing else. The program is this program's
--- core on a database sealed for it, which speaks to the relay through the
--- proxy variables it is given and says what came back; the servers are the
--- test's own, on 127.0.0.1. macOS alone has Seatbelt, and no `requires`
--- name stands for it, so every test calls [`Test.skip`] on any other host
--- (cosmic/child_relay_test.tl is Linux's). A failure says what the program
--- saw, the relay's decision lines and what Seatbelt denied.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`] (the grant of o/cosmic.db), as the start's own
--- seal of the relay's program does; the core is started past its
--- launcher (the grant of o/bin). The system's own paths are what the
--- core and its loader are read from. The servers are on 127.0.0.1.
Test.policy{
  profiles = { "cosmic", "system" },
  loopback = { "127.0.0.1" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } },
  env = { "TMPDIR" },
}

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- The program: "flows" speaks to the relay the proxy variables name and
--- says what came back, a line `name<TAB>value` each; "wait" sleeps until it
--- is ended.
local CLIENT <const> = [==[
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
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

-- The relay a proxy variable names: its user, token and port.
local function relay_of(name)
  local user, token, port = (sys.getenv(name) or ""):match("^%a[%w]*://([^:@]*):([^@]*)@127%.0%.0%.1:(%d+)$")
  return { user = user, token = token, port = math.tointeger(tonumber(port or "")) }
end

local function dial(label, port, host)
  local conn, why = Net.connect(Net.tcp(host or "127.0.0.1", port), { timeout_ns = Clock.seconds(20) })
  if conn == nil then say(label, "dial: " .. why) end
  return conn
end

-- A CONNECT to `target` through the relay at `port` of `host` (127.0.0.1 by
-- default), with `password` as the Basic credential's, or none.
local function through_connect(label, port, target, password, host)
  local conn = dial(label, port, host)
  if conn == nil then return end
  conn:set_timeout(Clock.seconds(20))
  local auth = ""
  if password ~= nil then
    auth = "Proxy-Authorization: Basic " .. Codec.base64("cosmic:" .. password) .. "\r\n"
  end
  conn:write("CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n" .. auth .. "\r\n")
  local reply = head(conn)
  say(label, reply:match("^[^\r]*") or "")
  if reply:find("^HTTP/1.1 200") then
    conn:write("ping")
    say(label .. "_echo", bytes(conn, 9))
  end
  conn:close()
end

-- A SOCKS5 request for 127.0.0.1:`target` through the relay at `port`, with
-- `password` as RFC 1929's.
local function through_socks(label, port, target, password)
  local conn = dial(label, port)
  if conn == nil then return end
  conn:set_timeout(Clock.seconds(20))
  conn:write("\5\1\2")
  local method = bytes(conn, 2)
  if method ~= "\5\2" then
    say(label, "method " .. Codec.hex(method))
    conn:close()
    return
  end
  conn:write("\1\6cosmic" .. string.char(#password) .. password)
  local authed = bytes(conn, 2)
  if authed ~= "\1\0" then
    say(label, "auth " .. Codec.hex(authed))
    conn:close()
    return
  end
  conn:write("\5\1\0\1\127\0\0\1" .. string.pack(">I2", target))
  local reply = bytes(conn, 10)
  say(label, reply:byte(2))
  if reply:byte(2) == 0 then
    conn:write("ping")
    say(label .. "_echo", bytes(conn, 9))
  end
  conn:close()
end

-- A connection that does not go through the relay.
local function direct(label, host, port)
  local conn, why = Net.connect(Net.tcp(host, port), { timeout_ns = Clock.seconds(5) })
  say(label, conn ~= nil and "connected" or why)
  if conn ~= nil then conn:close() end
end

return function(args)
  if args[1] == "flows" then
    local granted, ungranted = math.tointeger(tonumber(args[2])), math.tointeger(tonumber(args[3]))
    for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY",
        "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY" }) do
      say("env_" .. name, sys.getenv(name))
    end
    local http, socks = relay_of("HTTP_PROXY"), relay_of("ALL_PROXY")
    if http.port == nil or socks.port == nil then
      say("relay", "the proxy variables name no relay")
      return 0
    end
    local target = "127.0.0.1:" .. granted
    through_connect("connect", http.port, target, http.token)
    through_connect("connect_v6", http.port, target, http.token, "::1")
    through_connect("connect_v6_no_token", http.port, target, nil, "::1")
    through_connect("connect_name", http.port, "localhost:" .. granted, http.token)
    through_connect("connect_ungranted", http.port, "127.0.0.1:" .. ungranted, http.token)
    through_connect("connect_no_token", http.port, target, nil)
    through_connect("connect_wrong_token", http.port, target, http.token:sub(1, -2) .. "x")
    through_socks("socks", socks.port, granted, socks.token)
    through_socks("socks_ungranted", socks.port, ungranted, socks.token)
    through_socks("socks_wrong_token", socks.port, granted, "not-the-sandboxes-token")
    direct("direct_granted", "127.0.0.1", granted)
    direct("direct_ungranted", "127.0.0.1", ungranted)
    direct("direct_outside", "192.0.2.1", 443)
  elseif args[1] == "public" then
    local http = relay_of("HTTPS_PROXY")
    through_connect("public", http.port, args[2], http.token)
  elseif args[1] == "listeners" then
    -- Any descriptor of a listening socket the program was started with.
    local found = {}
    for fd = 3, 64 do
      -- The core's own descriptors raise when named; any other is no listener.
      local ok, listener = pcall(Net.listener_from, fd)
      if ok and listener ~= nil then
        found[#found + 1] = fd .. "=" .. listener.address.host .. ":" .. listener.address.port
        listener:close()
      end
    end
    say("listeners", #found == 0 and "none" or table.concat(found, ","))
  elseif args[1] == "probe" then
    -- Run under the relay's own profile: what it may read.
    for _, path in ipairs({ "/etc/hosts", args[2] }) do
      local fd, why = sys.open(path, sys.O_RDONLY)
      say("read " .. path, fd ~= nil and "read" or why)
      if fd ~= nil then sys.close(fd) end
    end
  elseif args[1] == "wait" then
    sys.nanosleep(Clock.seconds(120))
  end
  return 0
end
]==]

--- `text` with the relay's token, wherever a proxy URL carries it, hidden:
--- a failure's message is a log anyone reading CI sees.
local function redacted(text: string): string
  return (text:gsub("cosmic:%x+@", "cosmic:<token>@"))
end

--- The program's database, sealed in `tmp`: this program's core runs it.
local function sealed_client(tmp: string): string
  local chunk = assert(load(CLIENT, "=relay_seatbelt_client"))
  local requires = { "cosmic.clock", "cosmic.codec", "cosmic.net" }
  local path = tmp .. "/client.db"
  assert(Store.seal(Store.closure(requires), path, { extra = { name = "relay_seatbelt_client",
    bytecode = string.dump(chunk), source = CLIENT, requires = requires } }))
  return path
end

--- An echo server for `listener`, answering "echo:" and the four bytes each
--- connection sends, as a task of the run, and counting the connections.
local function echoing(listener: Net.Listener, count: {integer}): Poll.Task
  return Poll.spawn(function()
    while true do
      local conn = listener:accept()
      if conn == nil then return end
      count[1] = count[1] + 1
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

--- What Seatbelt denied lately, as the system's log names it, which says
--- what a profile lacks. Empty where the log cannot be read.
local function denials(): string
  local result = Child.run({ "/usr/bin/log", "show", "--last", "2m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox: \"" },
    { stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(60) })
  if result == nil then return "" end
  local lines: {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return "\nlog: " .. table.concat(lines, "\n", math.max(1, #lines - 60), #lines)
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

--- What a flows run saw: the program's lines, the relay's decision lines,
--- the servers' connection counts, and everything for a failure's message.
local record Flows
  said: {string:string}
  log: string
  granted: integer
  ungranted: integer
  reached: integer
  report: string
end

--- Runs the program's flows under a policy that grants the first of two
--- servers on 127.0.0.1, by address and as localhost, and says what it saw.
local function flows(tmp: string): Flows
  local database = sealed_client(tmp)
  local log_path = tmp .. "/relay.log"
  local log = assert(sys.open(log_path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 384))
  local seen: Flows
  Poll.run(function()
    local first = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local second = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local granted_count, ungranted_count = { 0 }, { 0 }
    local tasks = { echoing(first, granted_count), echoing(second, ungranted_count) }
    local granted, ungranted = first.address.port, second.address.port
    local result, why = Child.run({ assert(Proc.executable()), "flows", tostring(granted), tostring(ungranted) },
      { policy = { database = database, profiles = { "system" },
        connect = { "127.0.0.1:" .. granted, "localhost:" .. granted } },
        stdout = "capture", stderr = "capture", relay_log = log, timeout_ns = Clock.seconds(90) })
    for _, task in ipairs(tasks) do task:cancel() end
    assert(first:close())
    assert(second:close())
    local relay_log = Fs.read(log_path) or ""
    assert(result, tostring(why) .. "\nrelay: " .. relay_log .. denials())
    local report = redacted("code " .. tostring(result.code) .. ", signal " .. tostring(result.signal) ..
        "\nstdout: " .. tostring(result.stdout) .. "\nstderr: " .. tostring(result.stderr) ..
        "\nrelay: " .. relay_log)
    assert(result.ok, report .. denials())
    seen = { said = fields(result.stdout or ""), log = relay_log, granted = granted, ungranted = ungranted,
      reached = ungranted_count[1], report = report }
  end)
  assert(sys.close(log))
  return seen
end

--- A granted server is reached through the relay by HTTP CONNECT (by address
--- and by a granted name the relay resolves) and by SOCKS5, each with the
--- token the proxy variables carry; an ungranted one is refused by the relay
--- and never reached, as is a request without the token or with another.
local function test_a_granted_server_is_reached_through_the_relay_and_an_ungranted_one_is_not(tmp: string)
  macos_only()
  local seen = flows(tmp)
  local said, report = seen.said, seen.report
  assert(said.connect == "HTTP/1.1 200 Connection established" and said.connect_echo == "echo:ping",
    "CONNECT by address\n" .. report .. denials())
  assert(said.connect_name == "HTTP/1.1 200 Connection established" and said.connect_name_echo == "echo:ping",
    "CONNECT by a granted name\n" .. report .. denials())
  assert(said.socks == "0" and said.socks_echo == "echo:ping", "SOCKS5\n" .. report .. denials())
  assert(said.connect_v6 == "HTTP/1.1 200 Connection established" and said.connect_v6_echo == "echo:ping",
    "CONNECT to the relay's port on ::1\n" .. report .. denials())
  assert(said.connect_v6_no_token == "HTTP/1.1 407 Proxy Authentication Required",
    "no token on ::1\n" .. report)
  assert(tostring(said.connect_ungranted):find(" 403 not granted: --connect 127.0.0.1:" .. seen.ungranted, 1, true),
    "an ungranted CONNECT\n" .. report)
  assert(said.socks_ungranted == "2" and said.socks_ungranted_echo == nil, "an ungranted SOCKS5 request\n" .. report)
  assert(seen.reached == 0, "the ungranted server was reached\n" .. report)
  assert(said.connect_no_token == "HTTP/1.1 407 Proxy Authentication Required", "no token\n" .. report)
  assert(said.connect_wrong_token == "HTTP/1.1 407 Proxy Authentication Required", "a wrong token\n" .. report)
  assert(said.socks_wrong_token == "auth 0101", "a wrong SOCKS5 password\n" .. report)
  assert(seen.log:find("not granted: --connect 127.0.0.1:" .. seen.ungranted, 1, true),
    "the relay logs the refusal\n" .. report)
end

--- The program's profile lets it reach the relay's port alone: a direct
--- connection to the granted server, to another port of the loopback and to
--- an address outside are each refused by Seatbelt.
local function test_the_program_reaches_nothing_but_the_relay_directly(tmp: string)
  macos_only()
  local seen = flows(tmp)
  local said, report = seen.said, seen.report
  for _, name in ipairs({ "direct_granted", "direct_ungranted", "direct_outside" }) do
    assert(tostring(said[name]):find("not permitted", 1, true), name .. " was not refused by Seatbelt (EPERM)\n" ..
        report .. denials())
  end
end

--- The program is pointed at the relay by every variable a proxy client
--- reads, each naming the one port and the one token, 64 hex digits, as the
--- password of the user "cosmic"; its own loopback is left direct.
local function test_the_program_is_given_the_relay_and_its_token(tmp: string)
  macos_only()
  local said, report = flows(tmp).said, ""
  local token, port = tostring(said.env_HTTPS_PROXY):match("^http://cosmic:(%x+)@127%.0%.0%.1:(%d+)$")
  assert(token ~= nil and #token == 64, "HTTPS_PROXY is " .. redacted(tostring(said.env_HTTPS_PROXY)) .. report)
  local http = "http://cosmic:" .. token .. "@127.0.0.1:" .. port
  local socks = "socks5h://cosmic:" .. token .. "@127.0.0.1:" .. port
  for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" }) do
    assert(said["env_" .. name] == http, name .. " is " .. redacted(tostring(said["env_" .. name])))
  end
  assert(said.env_ALL_PROXY == socks and said.env_all_proxy == socks, redacted(tostring(said.env_ALL_PROXY)))
  assert(said.env_NO_PROXY == "localhost,127.0.0.1,::1" and said.env_NODE_USE_ENV_PROXY == "1")
  local again = flows(tmp).said
  assert(not tostring(again.env_HTTPS_PROXY):find(token, 1, true), "each start draws a token of its own")
end

--- A handle to a program that waits under a policy with `connect`.
local function waiting(tmp: string): Child.Handle
  local handle, why = Child.start({ assert(Proc.executable()), "wait" }, { policy = {
    database = sealed_client(tmp), profiles = { "system" }, connect = { "127.0.0.1:9" } },
    stdout = "null", stderr = "null" })
  assert(handle, tostring(why) .. denials())
  return handle
end

--- Whether the process `pid` is gone: reaped, or never there.
local function gone(pid: integer): boolean
  local alive, _, errno = sys.kill(pid, 0)
  return not alive and errno == sys.ESRCH
end

--- The relay lives as long as its program: it is ended and reaped once the
--- program is waited for, and one that dies ends the program at its next wait.
local function test_the_relay_ends_with_its_program(tmp: string)
  macos_only()
  Poll.run(function()
    local handle = waiting(tmp)
    local relay = assert(handle._relay, "the start runs a relay")
    assert(not gone(relay.pid), "the relay runs while the program does")
    assert(handle:stop())
    local result = assert(handle:wait(Clock.seconds(20)))
    assert(result.signal == sys.SIGTERM, "the program was ended")
    assert(gone(relay.pid), "the relay is gone after the wait")
    local second = waiting(tmp)
    local killed = assert(second._relay)
    assert(sys.kill(killed.pid, sys.SIGKILL))
    local after = assert(second:wait(Clock.seconds(20)))
    assert(after.signal == sys.SIGKILL and not after.timed_out, "the program was ended: " .. tostring(after.signal))
    assert(gone(killed.pid))
  end)
end

local type Searcher = function(string): any, any

--- The process table cosmic.child starts a child through.
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child has no process table")
end

--- How a program started under a profile ended.
local record Ran
  --- Why the start failed, or "" where it ran.
  refused: string
  code: integer
  output: string
end

--- `argv` run under the profile `held`, through the raw spawn, which applies
--- it before it executes the program.
local function run_under(held: raw_process.Seatbelt, argv: {string}, tmp: string): Ran
  local out_path = tmp .. "/run.out"
  local out = assert(sys.open(out_path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 384))
  local null = assert(sys.open("/dev/null", sys.O_RDONLY))
  local process = process_table()
  local pid, why = process.spawn(argv[1], argv, { COSMIC_STANDALONE = "1" }, "/", null, out, out, false, nil,
    { seatbelt = held })
  assert(sys.close(out))
  assert(sys.close(null))
  if pid == nil then return { refused = tostring(why), code = -1, output = "" } end
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  local status = assert(process.waitpid(pid, true))
  while status.pid == 0 do
    assert(Clock.monotonic_ns() < deadline, argv[1] .. " did not end")
    assert(Clock.sleep_ns(Clock.ms(20)))
    status = assert(process.waitpid(pid, true))
  end
  return { refused = "", code = status.code, output = Fs.read(out_path) or "" }
end

--- The port the program's profile lets it reach, the relay's.
local function relay_port(handle: Child.Handle): integer
  local program = assert(handle._seatbelt)
  local port = math.tointeger(tonumber(program.profile:match('%(remote tcp "localhost:(%d+)"%)') or ""))
  return (assert(port, program.profile))
end

--- Whether a listener of this process's can take `port` of `host`, and why not.
local function taken(host: string, port: integer): string
  local listener, why = Net.listen(Net.tcp(host, port))
  if listener ~= nil then
    assert(listener:close())
    return "a listener took the port"
  end
  return why
end

--- The start holds the relay's port on 127.0.0.1 and on ::1, both of which
--- the program's `localhost:PORT` rule reaches, and hands both sockets to
--- the relay: no other process can listen at either while it runs.
local function test_no_other_process_can_listen_at_the_relays_port(tmp: string)
  macos_only()
  Poll.run(function()
    local handle = waiting(tmp)
    local port = relay_port(handle)
    for _, host in ipairs({ "127.0.0.1", "::1" }) do
      local why = taken(host, port)
      assert(why:find("in use", 1, true), host .. ", the relay running: " .. why)
    end
    assert(handle:stop())
    local _ = handle:wait(Clock.seconds(20))
  end)
end

--- The program is handed no descriptor of the relay's listening sockets:
--- Seatbelt does not refuse accept() on one inherited (a profile without
--- network-inbound accepted connections there), and any user of the host can
--- connect to the port, so holding one would give the program a way in past
--- the token and the relay.
local function test_the_program_holds_no_listener_of_the_relays(tmp: string)
  macos_only()
  local result, why = Child.run({ assert(Proc.executable()), "listeners" }, { policy = {
    database = sealed_client(tmp), profiles = { "system" }, connect = { "127.0.0.1:9" } },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(90) })
  assert(result, tostring(why) .. denials())
  local report = redacted(tostring(result.stdout) .. "\nstderr: " .. tostring(result.stderr))
  assert(result.ok, report .. denials())
  assert(fields(result.stdout or "").listeners == "none", "the program holds a listening socket\n" .. report)
end

--- The relay itself is held by a profile of its own: it accepts at its
--- port, binds nothing, and runs no program but its core. That profile, run
--- with the test's program in place of the relay's database, reads the
--- resolver's files it grants and refuses a file it does not, and a program
--- it does not run, /bin/cat, is refused.
local function test_the_relay_is_held_by_a_profile_of_its_own(tmp: string)
  macos_only()
  local secret = tmp .. "/secret"
  assert(Fs.write(secret, "secret"))
  local client = sealed_client(tmp)
  Poll.run(function()
    local handle = waiting(tmp)
    local port = relay_port(handle)
    local relay = assert(handle._relay, "the start runs a relay")
    local held = assert(relay._seatbelt, "the relay was started under a profile")
    assert(held.profile:find("(deny default)", 1, true), held.profile)
    assert(held.profile:find('(allow network-inbound (local tcp "localhost:' .. port .. '"))', 1, true), held.profile)
    assert(not held.profile:find("network-bind", 1, true) and not held.profile:find("(allow file-read*)", 1, true),
      held.profile)
    assert(select(2, held.profile:gsub("process%-exec", "")) == 1, "the relay runs its core alone: " .. held.profile)
    local program = assert(handle._seatbelt)
    assert(not program.profile:find("*:*", 1, true), "the program reaches only the relay: " .. program.profile)
    local cat = run_under(held, { "/bin/cat", "/etc/hosts" }, tmp)
    assert(cat.refused ~= "" or cat.code ~= 0, "the relay's profile ran /bin/cat: " .. cat.output)
    -- The relay's database is gone once it opened it: the test's program
    -- takes its place in the profile's parameters.
    local swapped: raw_process.Seatbelt = { profile = held.profile, parameters = {} }
    local real_client = assert(sys.realpath(client))
    local replaced = false
    for name, value in pairs(held.parameters) do
      if value:find("/relay%.db$") then
        swapped.parameters[name] = real_client
        replaced = true
      else
        swapped.parameters[name] = value
      end
    end
    assert(replaced, "no parameter names the relay's database")
    local core = assert(sys.realpath(assert(Proc.relaunch()).argv[1]))
    local probe = run_under(swapped, { core, "--database", real_client, "probe", secret }, tmp)
    assert(probe.refused == "" and probe.code == 0, "the probe did not run under the relay's profile: " ..
        probe.refused .. " " .. probe.output .. denials())
    local said = fields(probe.output)
    assert(said["read /etc/hosts"] == "read", "the relay's profile does not read /etc/hosts: " .. probe.output)
    assert(tostring(said["read " .. secret]):find("not permitted", 1, true),
      "the relay's profile read a file it does not grant: " .. probe.output)
    assert(handle:stop())
    local _ = handle:wait(Clock.seconds(20))
  end)
end

--- A granted public name is resolved by the relay under its own profile,
--- through the system's DNS configuration and name servers, and connected.
--- Skipped where this host itself reaches no such name.
local function test_a_public_name_is_resolved_and_reached_through_the_relay(tmp: string)
  macos_only()
  local name = "example.com"
  local found, resolve_why = Net.resolve(name, { timeout_ns = Clock.seconds(5) })
  if found == nil then
    Test.skip("this host resolves no public name: " .. resolve_why)
    return
  end
  local reached, reach_why = Net.connect(Net.tcp(found[1].address, 443), { timeout_ns = Clock.seconds(5) })
  if reached == nil then
    Test.skip("this host reaches no public address: " .. reach_why)
    return
  end
  assert(reached:close())
  local log_path = tmp .. "/relay.log"
  local log = assert(sys.open(log_path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 384))
  local result, why = Child.run({ assert(Proc.executable()), "public", name .. ":443" }, { policy = {
    database = sealed_client(tmp), profiles = { "system" }, connect = { name .. ":443" } },
    stdout = "capture", stderr = "capture", relay_log = log, timeout_ns = Clock.seconds(90) })
  assert(sys.close(log))
  local relay_log = Fs.read(log_path) or ""
  assert(result, tostring(why) .. "\nrelay: " .. relay_log .. denials())
  local said = fields(result.stdout or "")
  assert(said.public == "HTTP/1.1 200 Connection established", redacted(tostring(result.stdout)) ..
      "\nrelay: " .. relay_log .. denials())
end

--- What the relay answered a CONNECT to `target` that a policy granting
--- `target` alone asked of it: the status line, and the relay's log.
local function connect_through(tmp: string, target: string): string, string
  local log_path = tmp .. "/relay.log"
  local log = assert(sys.open(log_path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 384))
  local result, why = Child.run({ assert(Proc.executable()), "public", target }, { policy = {
    database = sealed_client(tmp), profiles = { "system" }, connect = { target } },
    stdout = "capture", stderr = "capture", relay_log = log, timeout_ns = Clock.seconds(90) })
  assert(sys.close(log))
  local relay_log = Fs.read(log_path) or ""
  assert(result, tostring(why) .. "\nrelay: " .. relay_log .. denials())
  assert(result.ok, redacted(tostring(result.stdout) .. "\nstderr: " .. tostring(result.stderr)) ..
      "\nrelay: " .. relay_log .. denials())
  return tostring(fields(result.stdout or "").public), relay_log
end

--- The start tells the relay this host's own addresses, which it refuses
--- for a granted name as Linux's does: `localhost` granted by name, and
--- 127.0.0.1 not literally, is refused as one of them, which the relay
--- would otherwise name only a loopback address.
local function test_a_granted_name_of_the_hosts_loopback_is_refused_as_its_own(tmp: string)
  macos_only()
  local line, log = connect_through(tmp, "localhost:9")
  assert(line:find("^HTTP/1.1 403 ") and line:find("127.0.0.1 is one of this host's own addresses", 1, true),
    line .. "\nrelay: " .. log)
  assert(log:find("one of this host's own addresses", 1, true), log)
end

--- A granted name that resolves to an address of one of this host's other
--- interfaces is refused as one of its own, whatever other class the
--- address is in. The name is a wildcard DNS service's for the address
--- (sslip.io answers `10-1-2-3.sslip.io` with 10.1.2.3); skipped where this
--- host has no such routable (not link-local) address or the name does not resolve to it alone.
local function test_a_granted_name_of_another_host_address_is_refused_as_its_own(tmp: string)
  macos_only()
  local address: string
  for _, entry in ipairs((assert(sys.getifaddrs()))) do
    if entry.family == "ipv4" and not entry.loopback and not entry.address:find("^169%.254%.") then
      address = entry.address
      break
    end
  end
  if address == nil then
    Test.skip("this host has no routable IPv4 address but its loopback's and link-local ones")
    return
  end
  local name = address:gsub("%.", "-") .. ".sslip.io"
  local found, resolve_why = Net.resolve(name, { timeout_ns = Clock.seconds(5) })
  if found == nil then
    Test.skip("this host does not resolve " .. name .. ": " .. resolve_why)
    return
  end
  if #found == 0 then
    Test.skip(name .. " resolves to no address")
    return
  end
  for _, answer in ipairs(found) do
    if answer.address ~= address then
      Test.skip(name .. " resolves to " .. answer.address .. ", not " .. address)
      return
    end
  end
  local line, log = connect_through(tmp, name .. ":443")
  assert(line:find("^HTTP/1.1 403 ") and line:find(address .. " is one of this host's own addresses", 1, true),
    line .. "\nrelay: " .. log)
end

--- The proxy variables are the relay's to set, so a policy with `connect`
--- that names one is refused on macOS too.
local function test_a_policy_with_connect_may_not_set_a_proxy_variable(tmp: string)
  macos_only()
  local handle, why = Child.start({ assert(Proc.executable()), "wait" }, { policy = {
    database = sealed_client(tmp), profiles = { "system" }, connect = { "127.0.0.1:9" },
    set_env = { HTTPS_PROXY = "http://elsewhere:1" } } })
  assert(handle == nil and why:find("HTTPS_PROXY is set by the relay", 1, true), tostring(why))
end

--- The relay's own policy reads the database it runs on and the resolver's
--- files, and is no policy a program could ask for: a profile of the system,
--- with no write.
local function test_the_relays_policy_grants_reads_alone(_tmp: string)
  macos_only()
  local policy = Sandbox.Relay.seatbelt_policy("/tmp/relay.db", string.rep("0", 64))
  assert(policy.database == "/tmp/relay.db" and policy.profiles[1] == "system")
  for _, grant in ipairs(policy.grants) do
    assert(grant.letters == "r", grant.path .. " is granted " .. grant.letters)
  end
  assert(#(policy.connect or {}) == 0 and #(policy.promises or {}) == 0)
end
