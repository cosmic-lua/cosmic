--- The relay's starter's side (cosmic/relay_start.tl): the connectors it
--- starts for a policy's `connect` targets and what it tells the relay of
--- them, the cap on the addresses a table holds, the upstream proxy
--- resolved once, and [`Relay.handed`], which routes the relay's
--- connections over what it was handed. A relay whose lookups a name server
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
local RelayConfig = require("cosmic.relay_config")
local RelayStart = require("cosmic.relay_start")
local Test = require("cosmic.test")
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

--- A policy naming more addresses literally than a connector holds is
--- refused before anything is started, naming the count and the cap; so is
--- one whose upstream proxy's address takes the table past it.
local function test_more_addresses_than_a_table_holds_are_refused()
  local grants: {string} = {}
  for port = 1, 129 do grants[port] = "127.0.0.1:" .. port end
  local none, why = RelayStart.prepare(grants, {}, { env = {} })
  assert(none == nil and why == "connect names 129 addresses literally: 129 endpoints, more than the " ..
      "relay's connector holds (128); grant fewer addresses, or names", why)
  grants[129] = nil
  local upstream_too, upstream_why = RelayStart.prepare(grants, {}, { env = { https_proxy = "http://10.0.0.1:3128" } })
  assert(upstream_too == nil and upstream_why:find("connect names 128 addresses literally, with the upstream " ..
      "proxy's: 129 endpoints", 1, true), upstream_why)
end

--- Literal targets fill the table, each address once in the form a table
--- takes, a port of "*" as 0; a policy that names no host by name gets no
--- public connector and no name servers' one.
local function test_literal_targets_get_a_table_connector_alone()
  require_native_connector()
  local handover = assert(RelayStart.prepare({ "127.0.0.1:80", "[::1]:*", "127.0.0.1:80", "[::1:443",
    "2001:db8::1:443" }, {}, { env = {} }))
  local config = handover.config
  local rows: {string} = {}
  for _, entry in ipairs(config.table) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "127.0.0.1 80,0:0:0:0:0:0:0:1 0", table.concat(rows, ","))
  assert(not config.public and config.name_servers == nil and config.unresolved == nil)
  assert(handover.fds[RelayConfig.table_fd] ~= nil and handover.fds[RelayConfig.public_fd] == nil and
      handover.fds[RelayConfig.name_server_fd] == nil)
  handover.close()
  handover.close()
end

--- A target naming a host starts a public connector and one of the name
--- servers; where those cannot be read, the relay is told why instead.
local function test_a_named_target_gets_a_public_connector_and_the_name_servers()
  require_native_connector()
  local handover = assert(RelayStart.prepare({ "api.example.test:443" }, { "127.0.0.1" },
    { env = {}, servers = { { host = "127.0.0.1", port = 53 } } }))
  local config = handover.config
  assert(config.table == nil and config.public and config.unresolved == nil)
  assert(#config.name_servers == 1 and config.name_servers[1].host == "127.0.0.1" and
      config.name_server_wait_ns > 0)
  assert(handover.fds[RelayConfig.public_fd] ~= nil and handover.fds[RelayConfig.name_server_fd] ~= nil)
  handover.close()
  -- More servers than a connector holds cannot be handed.
  local many: {Net.Endpoint} = {}
  for port = 1, 129 do many[port] = { host = "127.0.0.1", port = port } end
  local unread = assert(RelayStart.prepare({ "*:443" }, {}, { env = {}, servers = many }))
  assert(unread.config.public and unread.config.name_servers == nil, "no name server is handed: " ..
      tostring(unread.config.name_servers ~= nil and unread.config.name_servers[1].host))
  assert(unread.config.unresolved:find("more than a connector holds (128)", 1, true), unread.config.unresolved)
  unread.close()
end

--- An upstream the caller names by address is its own address, with no
--- lookup, and goes in the table at its port; one that cannot be used
--- fails the preparation, naming why.
local function test_a_numeric_upstream_goes_in_the_table()
  require_native_connector()
  local handover = assert(RelayStart.prepare({ "api.example.test:443" }, {},
    { env = { https_proxy = "http://127.0.0.1:3128" }, servers = { { host = "127.0.0.1", port = 53 } } }))
  assert(table.concat(handover.config.upstream_addresses, ",") == "127.0.0.1")
  assert(#handover.config.table == 1 and handover.config.table[1].host == "127.0.0.1" and
      handover.config.table[1].port == 3128)
  handover.close()
  local none, why = RelayStart.prepare({ "a.test:1" }, {}, { env = { https_proxy = "https://proxy.test:3128" } })
  assert(none == nil and why:find("https_proxy has the scheme \"https\"", 1, true), why)
end

--- [`Relay.handed`] asks the table's connector for what its table holds,
--- by its place, and the public one for any other address, which refuses
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
    local connect = Relay.handed({ table_connector = in_table, table = table_rows, public_connector = public,
      wait_ns = Clock.seconds(10) })
    local conn, why = connect("127.0.0.1", port, Clock.seconds(1))
    assert(conn ~= nil, "the table's address is reached: " .. why)
    assert(conn:close())
    local refused, refusal = connect("127.0.0.2", port, Clock.seconds(1))
    assert(refused == nil and refusal:find("refused by the connector's deny list", 1, true), refusal)
    local alone = Relay.handed({ table_connector = in_table, table = table_rows, wait_ns = Clock.seconds(10) })
    local none, none_why = alone("127.0.0.1", port + 1, Clock.seconds(1))
    assert(none == nil and none_why:find("is in no table of the connectors the relay was handed", 1, true), none_why)
    assert(in_table:close())
    assert(public:close())
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
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local RelayStart = require("cosmic.relay_start")
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
    local up = assert(RelayStart.upstream({ env = { https_proxy = "http://proxy.test:" .. proxy.address.port,
      no_proxy = "direct.test" }, servers = servers }))
    lines[#lines + 1] = "upstream " .. table.concat(up.addresses, ",")
    local resolve = assert(Relay.name_servers({ servers = servers }))
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
