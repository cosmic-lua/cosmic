--- [`Relay.handed`], which routes the relay's connections over the
--- connectors its starter handed it (cosmic/internal/relay_start.tl), and a relay
--- behind an upstream the starter resolved once. A relay whose lookups a
--- name server of this test's own answers holds its thread while it looks
--- up, so it runs in a process of its own (this program, running a child of build.relay_children_test) while
--- this one is the name server, on a loopback port it listens at for TCP
--- and binds for UDP, to see each query and that no datagram is sent.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Connector = require("cosmic.internal.connector")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.internal.relay_server")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")
local sys = require("cosmic.sys")
local _ = require("build.relay_children_test")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

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

--- [`Relay.handed`] asks one connector, whose table is asked first: an
--- address and port the table holds is reached though the public lists
--- refuse that address at any other port, and a table-only connector
--- refuses everything else.
local function test_handed_connector_asks_its_table_before_its_public_lists()
  require_native_connector()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = assert(listener.address.port)
    local accepting = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        local _, _ = conn:close()
      end
    end)
    local table_rows: {Net.Endpoint} = { { host = "127.0.0.1", port = port } }
    local mixed = assert(Net.connector(table_rows, { public = { deny = { "127.0.0.0/8" } } }))
    local connect = Relay.handed({ connector = mixed })
    local conn, why = connect("127.0.0.1", port, Clock.seconds(1))
    assert(conn ~= nil, "the table's address is reached: " .. why)
    assert(conn:close())
    local refused, refusal = connect("127.0.0.1", port + 1, Clock.seconds(1))
    assert(refused == nil and refusal:find("refused by the connector's deny list", 1, true), refusal)
    local other, other_why = connect("127.0.0.2", port, Clock.seconds(1))
    assert(other == nil and other_why:find("refused by the connector's deny list", 1, true), other_why)
    local alone = Relay.handed({ connector = assert(Net.connector(table_rows)) })
    local none, none_why = alone("127.0.0.1", port + 1, Clock.seconds(1))
    assert(none == nil and none_why:find("is not in the connector's table", 1, true), none_why)
    assert(mixed:close())
    accepting:cancel()
    assert(listener:close())
  end)
end

--- A listener of its own whose backlog this fills, so that the kernel
--- drops what else asks it to connect: a public address whose connect
--- hangs. `held` gets a closer for the listener and each connection the
--- queue took.
local function stuck_port(held: mut {function()}): integer
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
  assert(taken >= 1 and taken < 4, tostring(taken) .. " connections were taken")
  return stuck.address.port
end

--- A connect that hangs holds up no other through the same public
--- connector: another connection to a public address is made at once,
--- while the hanging one waits out its own time.
local function test_a_public_connect_that_hangs_holds_up_no_other()
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
    local public = assert(Net.connector({}, { timeout_ns = wait, public = { deny = { "10.0.0.0/8" } } }))
    local connect = Relay.handed({ connector = public })
    local hung = { value = nil as string? }
    local hanging = Poll.spawn(function()
      local _, why = connect("127.0.0.1", stuck, wait)
      hung.value = why
    end)
    assert(Poll.delay(Clock.ms(50)))
    for _ = 1, 3 do
      local began = Clock.monotonic_ns()
      local conn, why = connect("127.0.0.1", assert(listener.address.port), wait)
      assert(conn ~= nil, "the connector connects beside the hanging connect: " .. why)
      assert(conn:close())
      assert(Clock.monotonic_ns() - began < Clock.ms(500), "the connection waited for the hanging one")
    end
    assert(hanging:join())
    assert(hung.value == Poll.TIMEOUT, tostring(hung.value))
    assert(not public:ended(), "a connect that timed out leaves the stream in step")
    assert(public:close())
    accepting:cancel()
    assert(listener:close())
  end)
  for _, close in ipairs(held) do close() end
end

--- A public connector whose process has ended fails the request that
--- finds it so, and every later one, telling `lost` once: no connector is
--- started anew for an adopted stream.
local function test_a_public_connector_that_ended_tells_lost()
  require_native_connector()
  local told: mut {string} = {}
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = assert(listener.address.port)
    local accepting = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        local _, _ = conn:close()
      end
    end)
    local wait = Clock.seconds(1)
    local process = assert(Connector.start({}, wait // 1000000, { deny = { "10.0.0.0/8" } }))
    local connector = assert(Connector.adopted(assert(sys.dup(process.fd)), nil, true, wait))
    local connect = Relay.handed({ connector = connector,
      lost = function(why: string) told[#told + 1] = why end })
    local conn, why = connect("127.0.0.1", port, Clock.seconds(5))
    assert(conn ~= nil, "the adopted connector connects: " .. why)
    assert(conn:close())
    assert(sys.kill(assert(process.pid), sys.SIGKILL))
    assert(process:close())
    for _ = 1, 2 do
      local none, none_why = connect("127.0.0.1", port, Clock.seconds(5))
      assert(none == nil, "a connector whose process ended connects nothing")
      assert(none_why == "net: the connector has ended" or none_why == "relay: the connector has ended",
        tostring(none_why))
    end
    assert(connector:ended())
    assert(connector:close())
    accepting:cancel()
    assert(listener:close())
  end)
  assert(#told == 1 and told[1] == "relay: the connector has ended", table.concat(told, ","))
end

--- A relay whose name servers' connector has ended can resolve no name
--- again: the lookup that finds it so fails, and tells `lost` why, once
--- however many lookups follow.
local function test_a_lookup_through_an_ended_name_servers_connector_tells_lost()
  require_native_connector()
  local told: mut {string} = {}
  local statuses: mut {string} = {}
  Poll.run(function()
    local dns = assert(Net.connector({ { host = "127.0.0.1", port = 53 } }))
    assert(dns:close())
    local http = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local relay = Relay.start({
      http = http, grants = { "api.test:443" }, log = function(_: string) end,
      resolve = { connector = dns, servers = { { host = "127.0.0.1", port = 53 } } },
      connector = function(_: string, _: integer, _: integer): Net.Conn?, string
        return nil, "nothing is connected here"
      end,
      lost = function(why: string) told[#told + 1] = why end,
    })
    for _ = 1, 2 do
      local conn = assert(Net.connect(http.address, { timeout_ns = Clock.seconds(5) }))
      conn:set_timeout(Clock.seconds(10))
      assert(conn:write("CONNECT api.test:443 HTTP/1.1\r\nHost: api.test:443\r\n\r\n"))
      local reply = ""
      while not reply:find("\r\n", 1, true) do
        local data = conn:read(4096)
        if data == nil then break end
        reply = reply .. data
      end
      table.insert(statuses, reply:match("^HTTP/1.1 (%d+)") or "none")
      local _, _ = conn:close()
    end
    relay:stop()
    relay:wait()
    assert(http:close())
  end)
  assert(table.concat(statuses, ",") == "502,502", table.concat(statuses, ","))
  assert(#told == 1 and told[1] == "relay: the name servers' connector has ended", table.concat(told, ","))
end

local TYPE_A <const> = 1

--- The name and type a query asks, and where its question ends.
local function question(query: string): string, integer, integer
  local labels: mut {string} = {}
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

--- Reads exactly `count` bytes of `conn`, or nil at its end.
local function read_exact(conn: Net.Conn, count: integer): string?
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
  local queries: mut {string} = {}
  local datagrams = { value = 0 }
  local lines: mut {string} = {}
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = assert(listener.address.port)
    local udp = assert(Udp.bind("127.0.0.1", port))
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
            table.insert(queries, tostring(qtype) .. " " .. asked)
            assert(conn:write(string.pack(">s2", answer(query))))
          end
          local _, _ = conn:close()
        end)
      end
    end)
    local watching = Poll.spawn(function()
      while true do
        local packet, why = Udp.receive(udp, Clock.ms(20))
        if packet ~= nil then
          datagrams.value = datagrams.value + 1
        elseif why ~= Poll.TIMEOUT then
          return
        end
      end
    end)
    local started = this_program.program(test_child.words(tmp, "build.relay_children_test", "serve", { tostring(port) }),
      { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
    local child <close> = assert(Child.start(started.argv, started.options))
    local result: Child.Result?
    while result == nil do
      local state = assert(child:try_wait())
      if state.finished then
        result = state.result
      else
        assert(Poll.delay(Clock.ms(10)))
      end
    end
    local finished = assert(result)
    assert(finished.code == 0, tostring(finished.code) .. " " .. tostring(finished.stderr))
    for line in ((finished.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    serving:cancel()
    watching:cancel()
    assert(listener:close())
    Udp.close(udp)
  end)
  table.sort(queries)
  assert(table.concat(lines, "|") == "upstream 127.0.0.1|api.test:443 200|api.test:443 200|api.test:443 200|" ..
      "ungranted.test:443 403|direct.test:443 403", table.concat(lines, "|"))
  assert(table.concat(queries, ",") == "1 direct.test,1 proxy.test,28 direct.test,28 proxy.test",
    table.concat(queries, ","))
  assert(datagrams.value == 0, datagrams.value .. " datagrams were sent")
end
