--- Net.resolve through a connector ([`ResolveOptions.connector`]): over TCP
--- alone, each connection made by the native connector, which reaches the
--- name servers of its table and nothing else. A lookup that a server of
--- the test's own answers holds its thread, so it runs in a process of
--- its own (this program, standalone) while this one is the server, on a
--- loopback port it listens at for TCP and binds for UDP, to see that no
--- datagram is sent. Lookups no server answers run here.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local type raw_process = require("cosmic.internal.process")

--- The program itself, which runs a lookup; a loopback alone answers; the
--- connector is a process the lookup's forks.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, promises = { "fork" } }

local type Searcher = function(string): any, any

--- The raw table `require` hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("no raw table behind " .. wrapper)
end

local process = raw_behind("cosmic.child") as raw_process -- cast: core/process.h's table

--- Skips where the native connector does not run (it is Linux only).
local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. tostring(why))
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

--- The answer to `query`: 192.0.2.7 for A, 2001:db8::7 for AAAA.
local function answer(query: string): string
  local _, qtype, question_end = question(query)
  local id = string.unpack(">I2", query)
  local data = qtype == TYPE_A and string.char(192, 0, 2, 7) or
    string.pack(">I2I2I2I2I2I2I2I2", 0x2001, 0xdb8, 0, 0, 0, 0, 0, 7)
  return string.pack(">I2I2I2I2I2I2", id, 0x8180, 1, 1, 0, 0) .. query:sub(13, question_end) ..
    string.pack(">I2I2I2I4s2", 0xC00C, qtype, 1, 60, data)
end

--- Resolves argv[1] through a connector whose table is 127.0.0.1 at the
--- port argv[2] and nothing else, twice, so the second asks the same
--- process again; prints each answer's addresses, sorted, on a line.
local SCRIPT <const> = [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local port = assert(math.tointeger(argv[2]))
  local dns = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
  local said: {string} = {}
  for _ = 1, 2 do
    local found, why = Net.resolve(argv[1], { timeout_ns = Clock.seconds(20), connector = dns,
      servers = { Net.udp("127.0.0.1", port) } })
    local lines: {string} = {}
    for _, resolved in ipairs(found or {}) do lines[#lines + 1] = resolved.address end
    table.sort(lines)
    said[#said + 1] = found == nil and "error " .. why or table.concat(lines, ",")
  end
  assert(dns:close())
  Fs.put(Fs.stdout, table.concat(said, "\n"))
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

local function test_a_name_resolves_over_tcp_through_the_connector_and_sends_no_datagram(tmp: string)
  require_native_connector()
  local script = tmp .. "/resolve.tl"
  assert(Fs.write(script, SCRIPT))
  local lines: {string}
  local queries: {string} = {}
  local datagrams = 0
  local connections = 0
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    -- The same port for UDP, where a lookup that sent a datagram would.
    local udp = assert(Net.datagram(Net.udp("127.0.0.1", port), { timeout_ns = Clock.ms(20) }))
    local serving = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        connections = connections + 1
        Poll.spawn(function()
          conn:set_timeout(Clock.seconds(20))
          while true do
            local head = read_exact(conn, 2)
            if head == nil then break end
            local query = read_exact(conn, (string.unpack(">I2", head)))
            if query == nil then break end
            local asked, qtype = question(query)
            queries[#queries + 1] = qtype .. " " .. asked
            local reply = answer(query)
            assert(conn:write(string.pack(">s2", reply)))
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
    local started = this_program.program({ "--standalone", script, "tcp.example.test", tostring(port) },
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
    lines = {}
    for line in ((result.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    serving:cancel()
    watching:cancel()
    assert(listener:close())
    assert(udp:close())
  end)
  assert(lines[1] == "192.0.2.7,2001:db8::7", tostring(lines[1]))
  assert(lines[2] == "192.0.2.7,2001:db8::7", tostring(lines[2]))
  assert(datagrams == 0, datagrams .. " datagrams were sent")
  table.sort(queries)
  assert(table.concat(queries, ",") ==
      "1 tcp.example.test,1 tcp.example.test,28 tcp.example.test,28 tcp.example.test", table.concat(queries, ","))
  assert(connections == 2, connections .. " connections")
end

local function test_an_unreachable_name_server_fails_the_lookup()
  require_native_connector()
  -- A port that was free a moment ago.
  local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = free.address.port
  assert(free:close())
  local dns <close> = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
  local found, why = Net.resolve("down.example.test", { timeout_ns = Clock.seconds(20), connector = dns,
    servers = { Net.udp("127.0.0.1", port) } })
  assert(found == nil and why == "Connection refused", tostring(why))
  -- The connector answered each request, so it is asked again.
  found, why = Net.resolve("down.example.test", { timeout_ns = Clock.seconds(20), connector = dns,
    servers = { Net.udp("127.0.0.1", port) } })
  assert(found == nil and why == "Connection refused", tostring(why))
  -- A numeric address answers itself and asks no one.
  local literal = assert(Net.resolve("192.0.2.1", { connector = dns, servers = { Net.udp("127.0.0.1", port) } }))
  assert(#literal == 1 and literal[1].address == "192.0.2.1")
end

local function test_a_name_server_the_connector_lacks_is_refused_before_anything_is_asked()
  require_native_connector()
  local dns <close> = assert(Net.connector({ { host = "127.0.0.1", port = 53 } }))
  local found, why = Net.resolve("example.test", { connector = dns, servers = { Net.udp("127.0.0.1", 5353) } })
  assert(found == nil and why == "net: the name server 127.0.0.1:5353 is not in the connector's table", why)
  found, why = Net.resolve("example.test", { connector = dns, servers = { Net.udp("192.0.2.53", 53) } })
  assert(found == nil and why:find("is not in the connector's table", 1, true) ~= nil, why)
  local each <close> = assert(Net.connector())
  found, why = Net.resolve("example.test", { connector = each, servers = { Net.udp("127.0.0.1", 53) } })
  assert(found == nil and why:find("with a table", 1, true) ~= nil, why)
  assert(dns:close())
  found, why = Net.resolve("example.test", { connector = dns, servers = { Net.udp("127.0.0.1", 53) } })
  assert(found == nil and why == "net: the connector is closed", why)
  local stand_in: any = { connect = function() end }
  assert(not pcall(Net.resolve, "example.test", { connector = stand_in as Net.Connector }))
end

--- The connector made of the name servers resolv.conf names is confined
--- to them at port 53: its process refuses any other port, any other
--- endpoint and any address of a public request.
local function test_the_name_servers_connector_refuses_what_is_no_name_server(tmp: string)
  require_native_connector()
  local conf = tmp .. "/resolv.conf"
  assert(Fs.write(conf, "nameserver 127.0.0.1\n"))
  local servers = assert(Net.nameservers({ resolv_conf = conf }))
  assert(#servers == 1 and servers[1].host == "127.0.0.1" and servers[1].port == 53)
  local dns <close> = assert(Net.connector(servers))
  local conn, why = dns:connect("127.0.0.1", 80, Clock.seconds(5))
  assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
  conn, why = dns:connect("192.0.2.1", 53, Clock.seconds(5))
  assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
  -- The process itself, asked past the checks of its Lua side.
  local started <close> = assert(Child.start_connector(servers, 1000))
  local function asked(request: string): integer
    assert(sys.write(started.fd, request) == #request)
    local reply = ""
    while #reply < 4 do
      local data, trouble, number = sys.read(started.fd, 4 - #reply)
      if data == nil then
        assert(number == sys.EAGAIN, trouble)
        local ready = Poll.readable(started.fd, Clock.seconds(5))
        assert(ready, "the connector did not reply")
      else
        assert(data ~= "", "the connector ended")
        reply = reply .. data
      end
    end
    return (string.unpack(">I4", reply))
  end
  assert(asked(string.pack(">I4I4", 1, 80)) == sys.EPERM)
  assert(asked(string.pack(">I4I4", 2, 53)) == sys.EPERM)
  assert(asked(string.pack(">I4I4I4", 0xffffffff, 53, 4) .. string.char(192, 0, 2, 1) .. string.rep("\0", 12)) ==
      sys.EPERM)
end

--- A connector that never replies holds the lookup to its deadline, and
--- the stream it leaves with a reply unread is ended, not asked again.
local function test_a_connector_that_never_replies_ends_the_lookup_and_is_not_asked_again()
  local pair = assert(process.connector_pair())
  local peer = pair[2]
  local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }))
  local opts: Net.ResolveOptions = { timeout_ns = Clock.ms(200), connector = dns,
    servers = { Net.udp("127.0.0.1", 53) } }
  local found, why = Net.resolve("stalled.example.test", opts)
  local sysname = assert(sys.uname()).sysname
  if sysname ~= "Linux" then
    assert(found == nil and why:find("not implemented", 1, true) ~= nil, tostring(why))
    assert(sys.close(peer))
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  -- What was asked: the table's first endpoint at port 53, as eight bytes.
  local request = assert(sys.read(peer, 64))
  assert(request == string.pack(">I4I4", 1, 53), ("%q"):format(request))
  found, why = Net.resolve("stalled.example.test", opts)
  assert(found == nil and why == "net: the connector has ended", tostring(why))
  assert(sys.close(peer))
end

local function test_nameservers_reads_the_servers_resolv_conf_names(tmp: string)
  local conf = tmp .. "/resolv.conf"
  assert(Fs.write(conf, "nameserver 192.0.2.53\nnameserver 2001:db8::53\nnameserver fe80::1%lo\n"))
  local servers, why = Net.nameservers({ resolv_conf = conf })
  assert(servers ~= nil and #servers >= 1, why)
  for _, server in ipairs(servers) do
    assert(server.host:find("%", 1, true) == nil and server.port >= 1, server.host)
  end
  local scoped = tmp .. "/scoped.conf"
  assert(Fs.write(scoped, "nameserver fe80::1%lo\n"))
  local none, trouble = Net.nameservers({ resolv_conf = scoped })
  local missing = Net.nameservers({ resolv_conf = tmp .. "/missing.conf" })
  local bad, invalid = Net.nameservers({ resolv_conf = tmp .. "/x\0y" })
  assert(bad == nil and invalid == "Invalid argument", tostring(invalid))
  local number: any = 7
  local numbered: any = { resolv_conf = 7 }
  assert(not pcall(Net.nameservers, number as Net.NameserversOptions))
  assert(not pcall(Net.nameservers, numbered as Net.NameserversOptions))
  -- On macOS the system's DNS configuration comes before any resolv.conf.
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("the system's DNS configuration answers before resolv.conf here")
  end
  local listed: {string} = {}
  for _, server in ipairs(servers) do listed[#listed + 1] = server.host .. " " .. server.port end
  assert(table.concat(listed, ",") == "192.0.2.53 53,2001:db8::53 53", table.concat(listed, ","))
  -- A link-local server is never answered: refused, or, where the resolver
  -- cannot find its interface (a sandbox's own network), dropped by it in
  -- favour of its default.
  if none == nil then
    assert(trouble:find("scoped to an interface", 1, true) ~= nil, trouble)
  else
    assert(#none == 1 and none[1].host == "127.0.0.1", none[1].host)
  end
  -- None configured: the resolver's default.
  assert(missing ~= nil and #missing == 1 and missing[1].host == "127.0.0.1" and missing[1].port == 53)
end
