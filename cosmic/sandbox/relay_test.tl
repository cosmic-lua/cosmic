--- What the relay's starter reads and decides (cosmic/sandbox/relay.tl):
--- what a policy's `connect` targets open, the cap on the addresses a
--- table holds, the name servers, the upstream proxy resolved once, and
--- [`Relay.handed`], which routes the relay's connections over the
--- connectors it was handed. A relay whose lookups a name server
--- of this test's own answers holds its thread while it looks up, so it
--- runs in a process of its own (this program, standalone) while this one
--- is the name server, on a loopback port it listens at for TCP and binds
--- for UDP, to see each query and that no datagram is sent.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local SandboxRelay = require("cosmic.sandbox.relay")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local _ = require("build.standalone")

--- The program itself, which runs a relay; a loopback alone answers; the
--- connectors are processes this one and the program fork.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, promises = { "fork" } }

--- Skips where the native connector does not run (it is Linux only).
local function require_native_connector()
  local probe, why = Net.connector({ { host = "127.0.0.1", port = 9 } })
  if probe == nil then
    Test.skip("this host has no native connector: " .. why)
  else
    assert(probe:close())
  end
end

--- Literal targets are each address once, in the form a table takes, a
--- port of "*" as 0; a target that is no literal of the forms a grant
--- takes opens nothing; any name, or "*", opens names.
local function test_a_plan_reads_the_targets_as_the_relay_does()
  local plan = assert(SandboxRelay.plan({ "127.0.0.1:80", "[::1]:*", "127.0.0.1:80", "[::1:443",
    "2001:db8::1:443", "[10.0.0.1]:80" }, {}))
  local rows: {string} = {}
  for _, entry in ipairs(plan.literals) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "127.0.0.1 80,0:0:0:0:0:0:0:1 0", table.concat(rows, ","))
  assert(not plan.names and plan.upstream == nil)
  for _, grant in ipairs({ "api.example.test:443", "*:443", "*:*" }) do
    assert(assert(SandboxRelay.plan({ grant }, {})).names, grant)
  end
  assert(not assert(SandboxRelay.plan({ "a*.test:443", "a.test:0443" }, {})).names, "a pattern opens nothing")
end

--- More addresses named literally than a connector holds are refused,
--- naming the count and the cap, before anything is started; so are those
--- the upstream proxy's address takes past it. An upstream that cannot be
--- used is refused naming why.
local function test_more_addresses_than_a_table_holds_are_refused()
  local grants: {string} = {}
  for port = 1, 129 do grants[port] = "127.0.0.1:" .. port end
  local none, why = SandboxRelay.plan(grants, {})
  assert(none == nil and why == "connect names 129 addresses literally, more than the relay's connector " ..
      "holds (128): grant fewer addresses, or names", why)
  grants[129] = nil
  local plan = assert(SandboxRelay.plan(grants, { https_proxy = "http://10.0.0.1:3128" }))
  assert(plan.upstream.host == "10.0.0.1" and plan.upstream.port == 3128)
  local over, over_why = SandboxRelay.table(plan, { "10.0.0.1" })
  assert(over == nil and over_why:find("connect names 128 addresses literally, with the upstream " ..
      "proxy's: 129 endpoints", 1, true), over_why)
  local bad, bad_why = SandboxRelay.plan({ "a.test:1" }, { https_proxy = "https://proxy.test:3128" })
  assert(bad == nil and bad_why:find("https_proxy has the scheme \"https\"", 1, true), bad_why)
end

--- The table holds the literals and the upstream's addresses at its port,
--- each once; a numeric upstream is its own address, with no lookup.
local function test_the_table_holds_the_literals_and_the_upstream()
  local plan = assert(SandboxRelay.plan({ "127.0.0.1:3128", "[2001:db8::1]:443" },
    { HTTPS_PROXY = "http://127.0.0.1:3128" }))
  local addresses = assert(SandboxRelay.upstream_addresses(plan.upstream, nil, "no name servers"))
  assert(table.concat(addresses, ",") == "127.0.0.1", table.concat(addresses, ","))
  local rows: {string} = {}
  local table_rows = assert(SandboxRelay.table(plan, addresses))
  for _, entry in ipairs(table_rows) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "127.0.0.1 3128,2001:db8:0:0:0:0:0:1 443", table.concat(rows, ","))
  local named = assert(SandboxRelay.plan({}, { https_proxy = "http://proxy.test:3128" }))
  local none, why = SandboxRelay.upstream_addresses(named.upstream, nil, "no name servers here")
  assert(none == nil and why == "https_proxy's host proxy.test cannot be resolved: no name servers here", why)
end

--- The name servers' connector waits for each server a share of the
--- lookup's time; more servers than a connector holds are refused; the
--- public connector refuses the relay's deny list and the host's own
--- addresses.
local function test_name_servers_and_the_public_lists()
  local one = assert(SandboxRelay.name_servers({ servers = { { host = "127.0.0.1", port = 53 } } }))
  assert(#one.servers == 1 and one.wait_ns == Clock.seconds(5) // 2, tostring(one.wait_ns))
  local many: {Net.Endpoint} = {}
  for port = 1, 129 do many[port] = { host = "127.0.0.1", port = port } end
  local none, why = SandboxRelay.name_servers({ servers = many })
  assert(none == nil and why:find("more than a connector holds (128)", 1, true), why)
  local public = SandboxRelay.public({ "10.1.0.2" })
  local own, deny = assert(public.own), public.deny
  assert(own[1] == "10.1.0.2" and deny[1] == "169.254.169.254/32", deny[1])
end

--- [`Relay.handed`] asks the table's connector for what its table holds,
--- by its place, and a public one for any other address, which refuses
--- what its deny list does.
local function test_handed_connectors_route_by_the_table()
  require_native_connector()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local accepting = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        local _, _ = conn:close()
      end
    end)
    local table_rows: {Net.Endpoint} = { { host = "127.0.0.1", port = port } }
    local in_table = assert(Net.connector(table_rows))
    local public = assert(Net.connector(nil, { public = { deny = { "127.0.0.0/8" } } }))
    local connect = Relay.handed({ table_connectors = { in_table }, table = table_rows, public_connectors = { public },
      wait_ns = Clock.seconds(10) })
    local conn, why = connect("127.0.0.1", port, Clock.seconds(1))
    assert(conn ~= nil, "the table's address is reached: " .. why)
    assert(conn:close())
    local refused, refusal = connect("127.0.0.2", port, Clock.seconds(1))
    assert(refused == nil and refusal:find("refused by the connector's deny list", 1, true), refusal)
    local alone = Relay.handed({ table_connectors = { in_table }, table = table_rows, wait_ns = Clock.seconds(10) })
    local none, none_why = alone("127.0.0.1", port + 1, Clock.seconds(1))
    assert(none == nil and none_why:find("is in no table of the connectors the relay was handed", 1, true), none_why)
    assert(in_table:close())
    assert(public:close())
    accepting:cancel()
    assert(listener:close())
  end)
end

--- A listener of its own whose backlog this fills, so that the kernel
--- drops what else asks it to connect: a public address whose connect
--- hangs. `held` gets a closer for the listener and each connection the
--- queue took.
local function stuck_port(held: {function()}): integer
  local stuck = assert(Net.listen(Net.tcp("127.0.0.1", 0), { backlog = 1 }))
  held[#held + 1] = function() local _, _ = stuck:close() end
  local taken = 0
  for _ = 1, 4 do
    local conn = Net.connect(stuck.address, { timeout_ns = Clock.ms(200) })
    if conn ~= nil then
      held[#held + 1] = function() local _, _ = conn:close() end
      taken = taken + 1
    end
  end
  assert(taken >= 1 and taken < 4, taken .. " connections were taken")
  return stuck.address.port
end

--- A connect that hangs holds its own public connector alone: another
--- connection to a public address goes through a free one at once; and
--- one that finds every connector held waits for one to be free, rather
--- than failing.
local function test_a_public_connect_that_hangs_holds_its_connector_alone()
  require_native_connector()
  local held: {function()} = {}
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local accepting = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        local _, _ = conn:close()
      end
    end)
    local stuck = stuck_port(held)
    local wait = Clock.seconds(1)
    local publics: {Net.Connector} = {}
    for i = 1, 2 do
      publics[i] = assert(Net.connector(nil, { timeout_ns = wait, public = { deny = { "10.0.0.0/8" } } }))
    end
    local connect = Relay.handed({ public_connectors = publics, wait_ns = wait })
    local hanging = Poll.spawn(function()
      local _, _ = connect("127.0.0.1", stuck, wait)
    end)
    assert(Poll.delay(Clock.ms(50)))
    local began = Clock.monotonic_ns()
    local conn, why = connect("127.0.0.1", listener.address.port, wait)
    assert(conn ~= nil, "a free connector connects: " .. why)
    assert(conn:close())
    assert(Clock.monotonic_ns() - began < Clock.ms(500), "the connection waited for the hanging one")
    local _, _ = hanging:join()
    -- Both connectors held by connects that hang: the next waits for one.
    local first = Poll.spawn(function() local _, _ = connect("127.0.0.1", stuck, wait) end)
    local second = Poll.spawn(function() local _, _ = connect("127.0.0.1", stuck, wait) end)
    assert(Poll.delay(Clock.ms(50)))
    local queued_at = Clock.monotonic_ns()
    local late, late_why = connect("127.0.0.1", listener.address.port, Clock.seconds(5))
    assert(late ~= nil, "a request with every connector held waits and connects: " .. late_why)
    assert(late:close())
    assert(Clock.monotonic_ns() - queued_at >= Clock.ms(500), "it waited for a connector to be free")
    local _, _ = first:join()
    local _, _ = second:join()
    for _, public in ipairs(publics) do assert(public:close()) end
    accepting:cancel()
    assert(listener:close())
  end)
  for _, close in ipairs(held) do close() end
end

--- Two public connectors served by processes of this test's own, each
--- stream adopted as the relay adopts one: the processes, to end, and the
--- connectors.
local function adopted_pair(wait: integer): {Child.ConnectorProcess}, {Net.Connector}
  local processes: {Child.ConnectorProcess} = {}
  local connectors: {Net.Connector} = {}
  for i = 1, 2 do
    processes[i] = assert(Child.start_connector({}, wait // 1000000, { deny = { "10.0.0.0/8" } }))
    connectors[i] = assert(Net.connector_from(assert(sys.dup(processes[i].fd)), nil, true, wait))
  end
  return processes, connectors
end

--- A public connector whose process has ended is passed over: the request
--- that finds it so is asked of another live one, and every later request
--- goes to the live one; once every one has ended, a request fails saying
--- so.
local function test_a_public_connector_that_ended_is_passed_over()
  require_native_connector()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local accepting = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        local _, _ = conn:close()
      end
    end)
    local wait = Clock.seconds(1)
    local processes, connectors = adopted_pair(wait)
    local connect = Relay.handed({ public_connectors = connectors, wait_ns = wait })
    assert(sys.kill(assert(processes[1].pid), sys.SIGKILL))
    assert(processes[1]:close())
    for round = 1, 3 do
      local conn, why = connect("127.0.0.1", port, Clock.seconds(5))
      assert(conn ~= nil, "round " .. round .. ": the live connector connects: " .. why)
      assert(conn:close())
    end
    assert(connectors[1]:ended() and not connectors[2]:ended())
    assert(sys.kill(assert(processes[2].pid), sys.SIGKILL))
    assert(processes[2]:close())
    local none, why = connect("127.0.0.1", port, Clock.seconds(5))
    assert(none == nil and why == "relay: every public connector has ended", tostring(why))
    for _, connector in ipairs(connectors) do assert(connector:close()) end
    accepting:cancel()
    assert(listener:close())
  end)
end

local TYPE_A <const> = 1

--- The name and type a query asks, and where its question ends.
local function question(query: string): string, integer, integer
  local labels: {string} = {}
  local at = 13
  while true do
    local size = query:byte(at)
    assert(size ~= nil, "a malformed query")
    if size == 0 then break end
    labels[#labels + 1] = query:sub(at + 1, at + size)
    at = at + size + 1
  end
  local qtype = string.unpack(">I2", query, at + 1)
  return table.concat(labels, "."), qtype, at + 4
end

--- The answer to `query`: an A query for proxy.test is 127.0.0.1, where
--- the program's proxy listens, and for any other name 192.0.2.7; an AAAA
--- query has no answer.
local function answer(query: string): string
  local name, qtype, question_end = question(query)
  local id = string.unpack(">I2", query)
  local head = query:sub(13, question_end)
  if qtype ~= TYPE_A then
    return string.pack(">I2I2I2I2I2I2", id, 0x8180, 1, 0, 0, 0) .. head
  end
  local data = name == "proxy.test" and string.char(127, 0, 0, 1) or string.char(192, 0, 2, 7)
  return string.pack(">I2I2I2I2I2I2", id, 0x8180, 1, 1, 0, 0) .. head ..
    string.pack(">I2I2I2I4s2", 0xC00C, qtype, 1, 60, data)
end

--- Prepares the upstream proxy.test, named by the caller's https_proxy, as
--- the starter does (resolving it through the name server at 127.0.0.1
--- port argv[1]), and serves a relay that resolves through the same server,
--- with a proxy of its own at the port https_proxy names: asks it for
--- api.test three times (through the proxy), for ungranted.test (refused
--- before any lookup) and for direct.test (granted, reached directly, and so
--- looked up). Prints each answer's status line, a line each.
local SCRIPT <const> = [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local SandboxRelay = require("cosmic.sandbox").Relay
return function(argv: {string}): integer
  local servers: {Net.Endpoint} = { { host = "127.0.0.1", port = assert(math.tointeger(tonumber(argv[1]))) } }
  local lines: {string} = {}
  Poll.run(function()
    local proxy = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local serving = Poll.spawn(function()
      while true do
        local conn = proxy:accept()
        if conn == nil then return end
        Poll.spawn(function()
          local head = ""
          while not head:find("\r\n\r\n", 1, true) do
            local data = conn:read(4096)
            if data == nil then break end
            head = head .. data
          end
          local _, _ = conn:write("HTTP/1.1 200 Connection established\r\n\r\n")
          local _, _ = conn:close()
        end)
      end
    end)
    -- As the starter does: the upstream's host resolved once, through a
    -- connector of the name servers.
    local plan = assert(SandboxRelay.plan({}, { https_proxy = "http://proxy.test:" .. proxy.address.port,
      no_proxy = "direct.test" }))
    local up = plan.upstream
    local name_servers = assert(SandboxRelay.name_servers({ servers = servers }))
    local dns = assert(Child.start_connector(name_servers.servers, name_servers.wait_ns // 1000000))
    up.addresses = assert(SandboxRelay.upstream_addresses(up, { fd = dns.fd, name_servers = name_servers }, ""))
    assert(dns:close())
    lines[#lines + 1] = "upstream " .. table.concat(up.addresses, ",")
    local resolve: Net.ResolveOptions = { servers = Relay.udp_servers(name_servers.servers),
      connector = assert(Net.connector(name_servers.servers, { timeout_ns = name_servers.wait_ns })) }
    local http = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local relay = Relay.start({
      http = http, grants = { "api.test:443", "direct.test:443" }, upstream = up, resolve = resolve,
      log = function(_: string) end,
      connector = function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
        return Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      end,
    })
    for _, target in ipairs({ "api.test:443", "api.test:443", "api.test:443", "ungranted.test:443",
        "direct.test:443" }) do
      local conn = assert(Net.connect(http.address, { timeout_ns = Clock.seconds(5) }))
      conn:set_timeout(Clock.seconds(10))
      assert(conn:write("CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n\r\n"))
      local reply = ""
      while not reply:find("\r\n") do
        local data = conn:read(4096)
        if data == nil then break end
        reply = reply .. data
      end
      lines[#lines + 1] = target .. " " .. (reply:match("^HTTP/1.1 (%d+)") or "none")
      local _, _ = conn:close()
    end
    relay:stop()
    relay:wait()
    assert(resolve.connector:close())
    serving:cancel()
    assert(http:close())
    assert(proxy:close())
  end)
  Fs.put(Fs.stdout, table.concat(lines, "\n"))
  return 0
end
]]

--- Reads exactly `count` bytes of `conn`, or nil at its end.
local function read_exact(conn: Net.Conn, count: integer): string | nil
  local out = ""
  while #out < count do
    local data, _ = conn:read(count - #out)
    if data == nil then return nil end
    out = out .. data
  end
  return out
end

--- The upstream's host is looked up once, by the starter, however many
--- connections go through it; a name no grant opens is never looked up;
--- and a granted one is, over TCP alone.
local function test_the_upstream_is_resolved_once_and_an_ungranted_name_never(tmp: string)
  require_native_connector()
  local script = tmp .. "/relay.tl"
  assert(Fs.write(script, SCRIPT))
  local queries: {string} = {}
  local datagrams = 0
  local lines: {string} = {}
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local udp = assert(Net.datagram(Net.udp("127.0.0.1", port), { timeout_ns = Clock.ms(20) }))
    local serving = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        Poll.spawn(function()
          conn:set_timeout(Clock.seconds(20))
          while true do
            local head = read_exact(conn, 2)
            if head == nil then break end
            local query = read_exact(conn, (string.unpack(">I2", head)))
            if query == nil then break end
            local asked, qtype = question(query)
            queries[#queries + 1] = qtype .. " " .. asked
            assert(conn:write(string.pack(">s2", answer(query))))
          end
          local _, _ = conn:close()
        end)
      end
    end)
    local watching = Poll.spawn(function()
      while true do
        local packet, why = udp:receive()
        if packet ~= nil then
          datagrams = datagrams + 1
        elseif why ~= Poll.TIMEOUT then
          return
        end
      end
    end)
    local started = this_program.program({ "--standalone", script, tostring(port) },
      { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
    local child <close> = assert(Child.start(started.argv, started.options))
    local result: Child.Result
    while result == nil do
      local state = assert(child:try_wait())
      if state.finished then
        result = state.result
      else
        assert(Poll.delay(Clock.ms(10)))
      end
    end
    assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
    for line in ((result.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    serving:cancel()
    watching:cancel()
    assert(listener:close())
    assert(udp:close())
  end)
  table.sort(queries)
  assert(table.concat(lines, "|") == "upstream 127.0.0.1|api.test:443 200|api.test:443 200|api.test:443 200|" ..
      "ungranted.test:443 403|direct.test:443 403", table.concat(lines, "|"))
  assert(table.concat(queries, ",") == "1 direct.test,1 proxy.test,28 direct.test,28 proxy.test",
    table.concat(queries, ","))
  assert(datagrams == 0, datagrams .. " datagrams were sent")
end
