--- Net.resolve through a connector ([`ResolveOptions.connector`]): over TCP
--- alone, each connection made by the native connector, which reaches the
--- name servers of its table and nothing else. A lookup that a server of
--- the test's own answers runs in a process of its own (this program,
--- standalone) while this one is the server, on a loopback port it
--- listens at for TCP and binds for UDP, to see that no datagram is
--- sent. Lookups no server answers, and those in a task beside others,
--- run here.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")

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
local socket = raw_behind("cosmic.net") as raw_socket -- cast: core/socket.h's table

--- A lookup's request of `tag` for the table's endpoint `index` at
--- `port`: no wait of its own, family or address.
local function request(tag: integer, index: integer, port: integer): string
  return string.pack(">I4I4I4I4I4", tag, index, port, 0, 0) .. string.rep("\0", 16)
end

--- Skips where the native connector does not run (it is Linux only).
local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. tostring(why))
end

--- The resolver options of a connector of the name servers `opts` names,
--- waiting for each as cosmic.sandbox.relay chooses: its `connector` and the
--- same servers as `servers`. Nil and why where they cannot be read.
local function name_server_options(opts: Sandbox.Relay.NameServerOptions): Net.ResolveOptions | nil, string
  local plan, why = Sandbox.Relay.name_servers(opts)
  if plan == nil then return nil, why end
  local connector, trouble = Net.connector(plan.servers, { timeout_ns = plan.wait_ns })
  if connector == nil then return nil, trouble end
  local servers: {Net.Address} = {}
  for i, server in ipairs(plan.servers) do servers[i] = Net.udp(server.host, server.port) end
  return { connector = connector, servers = servers }, ""
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

--- Resolves argv[1] through a connector whose table is 127.0.0.1 at each
--- port of argv[2] (comma-separated) and nothing else, waiting argv[3]
--- milliseconds for each connection (or, where argv[3] is "relay", as
--- cosmic.sandbox.relay chooses for its default lookup time), twice, so the second asks the same
--- process again: the first within argv[4] milliseconds, if given, the
--- second within five seconds. Prints each answer's addresses, sorted, on
--- a line, and then how many milliseconds each lookup took, on a line.
local SCRIPT <const> = [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Sandbox = require("cosmic.sandbox")
return function(argv: {string}): integer
  local endpoints: {Net.Endpoint} = {}
  local servers: {Net.Address} = {}
  for text in argv[2]:gmatch("[^,]+") do
    local port = assert(math.tointeger(tonumber(text)))
    endpoints[#endpoints + 1] = { host = "127.0.0.1", port = port }
    servers[#servers + 1] = Net.udp("127.0.0.1", port)
  end
  local dns: Net.Connector
  if argv[3] == "relay" then
    local plan = assert(Sandbox.Relay.name_servers({ servers = endpoints }))
    dns = assert(Net.connector(plan.servers, { timeout_ns = plan.wait_ns }))
  else
    dns = assert(Net.connector(endpoints, { timeout_ns = Clock.ms(assert(math.tointeger(tonumber(argv[3])))) }))
  end
  local said: {string} = {}
  local took: {string} = {}
  for round = 1, 2 do
    local began = Clock.monotonic_ns()
    local limit = round == 1 and argv[4] ~= nil and Clock.ms(assert(math.tointeger(tonumber(argv[4])))) or
      Clock.seconds(5)
    local found, why = Net.resolve(argv[1], { timeout_ns = limit, connector = dns, servers = servers })
    took[#took + 1] = tostring((Clock.monotonic_ns() - began) // 1000000)
    local lines: {string} = {}
    for _, resolved in ipairs(found or {}) do lines[#lines + 1] = resolved.address end
    table.sort(lines)
    said[#said + 1] = found == nil and "error " .. why or table.concat(lines, ",")
  end
  assert(dns:close())
  said[#said + 1] = table.concat(took, ",")
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

--- What a run of SCRIPT saw: the lines it printed, and what the test's
--- name server saw.
local record Served
  lines: {string}
  --- Each query, "type name", sorted.
  queries: {string}
  datagrams: integer
  connections: integer
end

--- Runs SCRIPT for `name` against a TCP name server of the test's own on
--- 127.0.0.1, which a UDP socket at the same port watches for datagrams.
--- `before` gives the ports of the connector's table that come before
--- the server's, made in the run; `wait_ms` is the connector's wait, and
--- `first_ms` the first lookup's time.
local function served(tmp: string, name: string, wait_ms: integer | string, before?: function(): {integer},
                      first_ms?: integer): Served
  local script = tmp .. "/resolve.tl"
  assert(Fs.write(script, SCRIPT))
  local out: Served = { lines = {}, queries = {}, datagrams = 0, connections = 0 }
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    -- The same port for UDP, where a lookup that sent a datagram would.
    local udp = assert(Net.datagram(Net.udp("127.0.0.1", port), { timeout_ns = Clock.ms(20) }))
    local serving = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        out.connections = out.connections + 1
        Poll.spawn(function()
          conn:set_timeout(Clock.seconds(20))
          while true do
            local head = read_exact(conn, 2)
            if head == nil then break end
            local query = read_exact(conn, (string.unpack(">I2", head)))
            if query == nil then break end
            local asked, qtype = question(query)
            out.queries[#out.queries + 1] = qtype .. " " .. asked
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
          out.datagrams = out.datagrams + 1
        elseif why ~= Poll.TIMEOUT then
          return
        end
      end
    end)
    local ports: {string} = {}
    for _, other in ipairs(before ~= nil and before() or {}) do
      ports[#ports + 1] = tostring(other)
    end
    ports[#ports + 1] = tostring(port)
    local argv = { "--standalone", script, name, table.concat(ports, ","), tostring(wait_ms) }
    if first_ms ~= nil then argv[#argv + 1] = tostring(first_ms) end
    local started = this_program.program(argv,
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
    for line in ((result.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
      out.lines[#out.lines + 1] = line
    end
    serving:cancel()
    watching:cancel()
    assert(listener:close())
    assert(udp:close())
  end)
  table.sort(out.queries)
  return out
end

local function test_a_name_resolves_over_tcp_through_the_connector_and_sends_no_datagram(tmp: string)
  require_native_connector()
  local seen = served(tmp, "tcp.example.test", 10000)
  assert(seen.lines[1] == "192.0.2.7,2001:db8::7", tostring(seen.lines[1]))
  assert(seen.lines[2] == "192.0.2.7,2001:db8::7", tostring(seen.lines[2]))
  assert(seen.datagrams == 0, seen.datagrams .. " datagrams were sent")
  assert(table.concat(seen.queries, ",") ==
      "1 tcp.example.test,1 tcp.example.test,28 tcp.example.test,28 tcp.example.test", table.concat(seen.queries, ","))
  assert(seen.connections == 2, seen.connections .. " connections")
end

--- Fills the backlog of a listener of its own, so that the kernel drops
--- what else asks it to connect: a name server that never takes a
--- connection. `held` gets a closer for the listener and each connection the
--- queue took.
local function stuck_server(held: {function()}): {integer}
  local stuck = assert(Net.listen(Net.tcp("127.0.0.1", 0), { backlog = 1 }))
  held[#held + 1] = function() local _, _ = stuck:close() end
  -- The queue takes the backlog and one more; the rest wait unanswered.
  local taken = 0
  for _ = 1, 4 do
    local conn = Net.connect(stuck.address, { timeout_ns = Clock.ms(200) })
    if conn ~= nil then
      held[#held + 1] = function() local _, _ = conn:close() end
      taken = taken + 1
    end
  end
  assert(taken >= 1 and taken < 4, taken .. " connections were taken")
  return { stuck.address.port }
end

--- A first name server that never takes the connection costs the
--- connector's wait, and the lookup goes on to the next within its own
--- time: the stream stays in step, so the same connector serves again.
local function test_a_server_that_never_answers_its_connect_fails_over_to_the_next(tmp: string)
  require_native_connector()
  local held: {function()} = {}
  local seen = served(tmp, "next.example.test", 500, function(): {integer}
    return stuck_server(held)
  end)
  for _, close in ipairs(held) do close() end
  assert(seen.lines[1] == "192.0.2.7,2001:db8::7", tostring(seen.lines[1]))
  assert(seen.lines[2] == "192.0.2.7,2001:db8::7", tostring(seen.lines[2]))
  for took in seen.lines[3]:gmatch("[^,]+") do
    local ms = assert(math.tointeger(tonumber(took)))
    assert(ms >= 400 and ms < 5000, seen.lines[3] .. " ms")
  end
  assert(seen.datagrams == 0, seen.datagrams .. " datagrams were sent")
end

--- A lookup whose time runs out while the connector still waits on a
--- connection ends then, and the connector's late reply is taken and its
--- socket closed rather than cutting the stream off, so the next lookup
--- through the same connector is served.
local function test_a_lookup_out_of_time_still_takes_the_connectors_reply(tmp: string)
  require_native_connector()
  local held: {function()} = {}
  local seen = served(tmp, "late.example.test", 500, function(): {integer}
    return stuck_server(held)
  end, 100)
  for _, close in ipairs(held) do close() end
  assert(seen.lines[1] == "error " .. Poll.TIMEOUT, tostring(seen.lines[1]))
  assert(seen.lines[2] == "192.0.2.7,2001:db8::7", tostring(seen.lines[2]))
  local first = assert(math.tointeger(tonumber(seen.lines[3]:match("^(%d+)"))))
  assert(first >= 100 and first < 480, "the first lookup ended after " .. first .. " ms, not at its deadline")
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
  local servers = assert(Relay.nameservers(conf))
  assert(#servers == 1 and servers[1].host == "127.0.0.1" and servers[1].port == 53)
  local dns <close> = assert(Net.connector(servers))
  local conn, why = dns:connect("127.0.0.1", 80, Clock.seconds(5))
  assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
  conn, why = dns:connect("192.0.2.1", 53, Clock.seconds(5))
  assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
  -- The process itself, asked past the checks of its Lua side.
  local started <close> = assert(Child.start_connector(servers, 1000))
  local function read_whole(count: integer): string
    local reply = ""
    while #reply < count do
      local data, trouble, number = sys.read(started.fd, count - #reply)
      if data == nil then
        assert(number == sys.EAGAIN, trouble)
        local ready = Poll.readable(started.fd, Clock.seconds(5))
        assert(ready, "the connector did not reply")
      else
        assert(data ~= "", "the connector ended")
        reply = reply .. data
      end
    end
    return reply
  end
  assert(string.unpack(">I4", read_whole(4)) == socket.CONNECTOR_HELLO)
  local function asked(tag: integer, index: integer, port: integer, family?: integer, address?: string): integer
    local wire = string.pack(">I4I4I4I4I4", tag, index, port, 0, family or 0) ..
      (address or "") .. string.rep("\0", 16 - #(address or ""))
    assert(sys.write(started.fd, wire) == #wire)
    local replied, errno = string.unpack(">I4I4", read_whole(8))
    assert(replied == tag, "the reply carries another tag: " .. replied)
    return errno
  end
  assert(asked(7, 1, 80) == sys.EPERM)
  assert(asked(8, 2, 53) == sys.EPERM)
  assert(asked(9, 0xffffffff, 53, 4, string.char(192, 0, 2, 1)) == sys.EPERM)
end

--- A connection a name server resets as it is made fails that server
--- alone: the connector's reply came whole, so the lookup leaves its stream
--- in step, not shut down, and the connector serves the next lookup. A
--- stand-in on the stream's other end replies with sockets refused at once,
--- which have no peer, as a reset one has none.
local function test_a_name_server_reset_as_it_is_made_leaves_the_stream_in_step(tmp: string)
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = free.address.port
  assert(free:close())
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local pair = assert(process.connector_pair())
  assert(sys.set_nonblocking(pair[1], true))
  assert(sys.set_nonblocking(pair[2], true))
  assert(sys.write(pair[2], string.pack(">I4", socket.CONNECTOR_HELLO)) == 4)
  local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
  local asked: string
  local found, why: {Net.Resolved} | nil, string
  Poll.run(function()
    -- The reply to the lookup's one request, tagged from 1: a socket the
    -- server reset as it was made.
    Poll.spawn(function()
      assert(Poll.readable(pair[2], Clock.seconds(5)))
      asked = assert(sys.read(pair[2], 4096))
      local reset = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
      assert(socket.wait(reset:fd(), true, 5000))
      assert(sys.write(pair[2], string.pack(">I4I4", 1, 0)) == 8)
      assert(socket.sendfds(pair[2], { reset:fd() }))
      assert(reset:close())
    end)
    found, why = Net.resolve("reset.example.test", { timeout_ns = Clock.seconds(2), connector = dns,
      servers = { Net.udp("127.0.0.1", 53) }, hosts_file = hosts })
  end)
  assert(found == nil and why ~= "", tostring(why))
  assert(asked == request(1, 1, 53), ("%q"):format(asked))
  -- Shut down, the stream would read as ended here; in step, nothing waits.
  local more, _, number = sys.read(pair[2], 1)
  assert(more == nil and number == sys.EAGAIN, "the lookup shut the stream down: " .. tostring(more))
  assert(not dns:ended())
  assert(sys.close(pair[2]))
end

--- A lookup through a connector whose stream says another word first asks
--- it nothing: [`Net.resolve`] says a connector of another protocol,
--- ended.
local function test_a_lookup_reads_the_connectors_hello_before_it_asks(tmp: string)
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local other = assert(process.connector_pair())
  assert(sys.write(other[2], string.pack(">I4", 0x434e4301)) == 4)
  local dns <close> = assert(Net.connector_from(other[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
  local none, trouble = Net.resolve("hello.example.test", { timeout_ns = Clock.seconds(2), connector = dns,
    servers = { Net.udp("127.0.0.1", 53) }, hosts_file = hosts })
  assert(none == nil and trouble == "net: the connector speaks another protocol than this program's: " ..
      "it said 0x434e4301, not 0x434e4302", tostring(trouble))
  assert(dns:ended())
  assert(sys.close(other[2]))
end

--- A reply that came whole with a socket connected to another address
--- than the server asked, or with a descriptor that is no socket, is none a
--- connector that works gives: the lookup gives the stream up, shutting it
--- down so its owner sees it end, and asks it nothing more.
local function test_a_connector_that_passes_the_wrong_descriptor_is_given_up(tmp: string)
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local elsewhere = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = listener.address.port }))
  assert(socket.wait(elsewhere:fd(), true, 5000))
  local null = assert(sys.open("/dev/null", sys.O_RDONLY))
  for _, passed in ipairs({ elsewhere:fd(), null }) do
    local pair = assert(process.connector_pair())
    assert(sys.set_nonblocking(pair[1], true))
    assert(sys.set_nonblocking(pair[2], true))
    assert(sys.write(pair[2], string.pack(">I4", socket.CONNECTOR_HELLO)) == 4)
    local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
    local asked: string
    local found, why: {Net.Resolved} | nil, string
    Poll.run(function()
      Poll.spawn(function()
        assert(Poll.readable(pair[2], Clock.seconds(5)))
        asked = assert(sys.read(pair[2], 4096))
        assert(sys.write(pair[2], string.pack(">I4I4", 1, 0)) == 8)
        assert(socket.sendfds(pair[2], { passed }))
      end)
      found, why = Net.resolve("wrong.example.test", { timeout_ns = Clock.seconds(2), connector = dns,
        servers = { Net.udp("127.0.0.1", 53) }, hosts_file = hosts })
    end)
    assert(found == nil and why ~= "", tostring(why))
    assert(asked == request(1, 1, 53), "the stream was asked again: " .. ("%q"):format(asked))
    assert(dns:ended())
    -- Given up, the stream reads as ended.
    local more, trouble = sys.read(pair[2], 1)
    assert(more == "", "the lookup left the stream in step: " .. tostring(more) .. " " .. tostring(trouble))
    assert(sys.close(pair[2]))
  end
  assert(sys.close(null))
  assert(elsewhere:close())
  assert(listener:close())
end

--- A connector that never replies holds the lookup to its deadline, and
--- no longer: the request is given up on and stays pending on the stream,
--- which is in step for the next lookup, asked again under a tag of its own.
local function test_a_connector_that_never_replies_ends_the_lookup_and_is_not_asked_again()
  local pair = assert(process.connector_pair())
  local peer = pair[2]
  assert(sys.write(peer, string.pack(">I4", socket.CONNECTOR_HELLO)) == 4)
  -- Its process would wait 100 ms to connect and a grace more: the lookup ends at its own deadline.
  local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
  local opts: Net.ResolveOptions = { timeout_ns = Clock.ms(200), connector = dns,
    servers = { Net.udp("127.0.0.1", 53) } }
  local began = Clock.monotonic_ns()
  local found, why = Net.resolve("stalled.example.test", opts)
  local took = (Clock.monotonic_ns() - began) // 1000000
  local sysname = assert(sys.uname()).sysname
  if sysname ~= "Linux" then
    assert(found == nil and why:find("not implemented", 1, true) ~= nil, tostring(why))
    assert(sys.close(peer))
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  -- The process's wait given (100 ms) and a second's grace, not the default ten seconds.
  assert(took >= 150 and took < 3000, took .. " ms")
  -- What was asked: the table's first endpoint at port 53, its hello read first.
  local sent = assert(sys.read(peer, 64))
  assert(sent == request(1, 1, 53), ("%q"):format(sent))
  found, why = Net.resolve("stalled.example.test", opts)
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  assert(assert(sys.read(peer, 64)) == request(2, 1, 53))
  assert(not dns:ended())
  assert(sys.close(peer))
end

local function test_nameservers_reads_the_servers_resolv_conf_names(tmp: string)
  local conf = tmp .. "/resolv.conf"
  assert(Fs.write(conf, "nameserver 192.0.2.53\nnameserver 2001:db8::53\nnameserver fe80::1%lo\n"))
  local servers, why = Relay.nameservers(conf)
  assert(servers ~= nil and #servers >= 1, why)
  for _, server in ipairs(servers) do
    assert(server.host:find("%", 1, true) == nil and server.port >= 1, server.host)
  end
  local scoped = tmp .. "/scoped.conf"
  assert(Fs.write(scoped, "nameserver fe80::1%lo\n"))
  local none, trouble = Relay.nameservers(scoped)
  local missing = Relay.nameservers(tmp .. "/missing.conf")
  local bad, invalid = Relay.nameservers(tmp .. "/x\0y")
  assert(bad == nil and invalid == "Invalid argument", tostring(invalid))
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

--- The relay's resolver options name the servers read as it started, so a
--- lookup asks exactly the connector's table even once the system's
--- configuration names others; here the system's is whatever the worker
--- reads, and a hosts file answers the name.
local function test_the_relays_name_servers_stand_when_the_system_names_others(tmp: string)
  require_native_connector()
  local conf = tmp .. "/resolv.conf"
  assert(Fs.write(conf, "nameserver 192.0.2.53\n"))
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, "198.51.100.9 kept.example.test\n"))
  local opts = assert(name_server_options({ resolv_conf = conf }))
  local _dns <close> = opts.connector
  assert(#opts.servers == 1 and opts.servers[1].host == "192.0.2.53" and opts.servers[1].port == 53)
  local system = Relay.nameservers()
  assert(system == nil or system[1].host ~= "192.0.2.53", "the system names the test's server")
  local found, why = Net.resolve("kept.example.test",
    { connector = opts.connector, servers = opts.servers, hosts_file = hosts, timeout_ns = Clock.seconds(5) })
  assert(found ~= nil and #found == 1 and found[1].address == "198.51.100.9", tostring(why))
  -- Without the servers, the lookup asks the system's, which the table lacks.
  found, why = Net.resolve("kept.example.test", { connector = opts.connector, hosts_file = hosts })
  assert(found == nil, "the system's servers were asked through the table")
  -- Unreadable servers are a reason, not a raise.
  local none, trouble = Sandbox.Relay.name_servers({ resolv_conf = tmp .. "/x\0y" })
  assert(none == nil and trouble == "Invalid argument", tostring(trouble))
end

--- The relay's connector waits for each server the lookup's time over one
--- more than the servers: with its default five seconds and two servers,
--- a first that never takes the connection leaves the second time to answer.
local function test_the_relays_wait_leaves_the_second_server_time_to_answer(tmp: string)
  require_native_connector()
  local held: {function()} = {}
  local seen = served(tmp, "ratio.example.test", "relay", function(): {integer}
    return stuck_server(held)
  end)
  for _, close in ipairs(held) do close() end
  assert(seen.lines[1] == "192.0.2.7,2001:db8::7", tostring(seen.lines[1]))
  assert(seen.lines[2] == "192.0.2.7,2001:db8::7", tostring(seen.lines[2]))
  for took in seen.lines[3]:gmatch("[^,]+") do
    local ms = assert(math.tointeger(tonumber(took)))
    assert(ms >= 1500 and ms < 5000, seen.lines[3] .. " ms")
  end
end

--- `count` name servers that never take a connection, through a connector
--- of the name servers, waiting as cosmic.sandbox.relay chooses, for a lookup of `lookup_ms`: the lookup fails
--- as out of time, by its deadline, one connector wait and the grace.
local function silent_lookup(count: integer, lookup_ms: integer)
  require_native_connector()
  local held: {function()} = {}
  local endpoints: {Net.Endpoint} = {}
  for _ = 1, count do
    local port = stuck_server(held)[1]
    endpoints[#endpoints + 1] = { host = "127.0.0.1", port = port }
  end
  local opts = assert(name_server_options({ servers = endpoints, resolve = Clock.ms(lookup_ms) }))
  local wait = math.max(500, lookup_ms // (count + 1))
  local began = Clock.monotonic_ns()
  local found, why = Net.resolve("silent.example.test",
    { connector = opts.connector, servers = opts.servers, timeout_ns = Clock.ms(lookup_ms) })
  local took = (Clock.monotonic_ns() - began) // 1000000
  assert(opts.connector:close())
  for _, close in ipairs(held) do close() end
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  assert(took >= wait and took < lookup_ms + wait + 1000 + 300, took .. " ms")
end

local function test_a_silent_name_server_times_the_lookup_out_within_its_bound()
  silent_lookup(1, 1500)
end

local function test_three_silent_name_servers_time_the_lookup_out_within_its_bound()
  silent_lookup(3, 1500)
end

local function test_name_servers_and_a_connector_from_refuse_what_is_out_of_range()
  local zero: any = 0
  assert(not pcall(Sandbox.Relay.name_servers, { resolve = zero as integer }))
  assert(not pcall(Sandbox.Relay.name_servers, { resolve = -1 }))
  local pair = assert(process.connector_pair())
  assert(not pcall(Net.connector_from, pair[1], nil, false, 5))
  assert(not pcall(Net.connector_from, pair[1], nil, false, Clock.seconds(61)))
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
end

local function test_more_name_servers_than_a_connector_holds_is_a_failure()
  require_native_connector()
  local dns <close> = assert(Net.connector({ { host = "127.0.0.1", port = 53 } }))
  local servers: {Net.Address} = {}
  for i = 1, 129 do servers[i] = Net.udp("127.0.0.1", 1000 + i) end
  local found, why = Net.resolve("many.example.test", { connector = dns, servers = servers })
  assert(found == nil and why:find("at most 128", 1, true) ~= nil, tostring(why))
end

--- The lowest descriptor number a new one takes: the same before a lookup
--- and after it is ended means it left none open.
local function lowest_free_descriptor(): integer
  local pair = assert(process.connector_pair())
  local lowest = math.min(pair[1], pair[2])
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
  return lowest
end

--- Runs `lookup` in a task beside a task that ticks every 10 ms, and the
--- longest gap between its ticks, in milliseconds, with how long the
--- lookup took.
local function ticking_beside(lookup: function()): integer, integer
  local worst, took = 0, 0
  Poll.run(function()
    local running = true
    local ticker = Poll.spawn(function()
      local last = Clock.monotonic_ns()
      while running do
        assert(Poll.delay(Clock.ms(10)))
        local now = Clock.monotonic_ns()
        worst = math.max(worst, (now - last) // 1000000)
        last = now
      end
    end)
    local began = Clock.monotonic_ns()
    lookup()
    took = (Clock.monotonic_ns() - began) // 1000000
    running = false
    assert(ticker:join())
  end)
  return worst, took
end

--- A lookup in a task of a run waits through the run: a name server that
--- never answers holds up that task alone, to the lookup's own deadline.
local function test_a_lookup_nobody_answers_stalls_no_other_task(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local silent = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
  local found, why: {Net.Resolved} | nil, string
  local worst, took = ticking_beside(function()
    found, why = Net.resolve("silent.example.test", { timeout_ns = Clock.ms(600), servers = { silent.address },
      hosts_file = hosts })
  end)
  assert(silent:close())
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  assert(took >= 500 and took < 4000, took .. " ms")
  assert(worst < 450, "another task waited " .. worst .. " ms behind the lookup")
end

--- The same through a connector that never replies: the connect it was
--- asked for holds the lookup to its deadline, and no other task.
local function test_a_lookup_through_a_silent_connector_stalls_no_other_task(tmp: string)
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local pair = assert(process.connector_pair())
  assert(sys.write(pair[2], string.pack(">I4", socket.CONNECTOR_HELLO)) == 4)
  local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
  local found, why: {Net.Resolved} | nil, string
  local worst, took = ticking_beside(function()
    found, why = Net.resolve("silent.example.test", { timeout_ns = Clock.ms(600), connector = dns,
      servers = { Net.udp("127.0.0.1", 53) }, hosts_file = hosts })
  end)
  assert(found == nil and why == Poll.TIMEOUT, tostring(why))
  assert(took >= 500 and took < 4000, took .. " ms")
  assert(worst < 450, "another task waited " .. worst .. " ms behind the lookup")
  assert(not dns:ended())
  assert(sys.close(pair[2]))
end

--- Cancels a lookup of `opts` in its wait: how long the task took to end,
--- and that it failed "cancelled", with the lowest descriptor free before
--- and after.
local function cancelled_lookup(opts: Net.ResolveOptions): integer, string, integer, integer
  local before = lowest_free_descriptor()
  local outcome = ""
  local waited = 0
  Poll.run(function()
    local task = Poll.spawn(function()
      local found, why = Net.resolve("cancelled.example.test", opts)
      assert(found == nil)
      outcome = why
    end)
    assert(Poll.delay(Clock.ms(100)))
    local began = Clock.monotonic_ns()
    task:cancel()
    assert(task:join(Clock.seconds(5)))
    waited = (Clock.monotonic_ns() - began) // 1000000
  end)
  return waited, outcome, before, lowest_free_descriptor()
end

--- A lookup cancelled in its wait ends at once and leaves no descriptor
--- open.
local function test_a_cancelled_lookup_closes_everything_it_held(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local silent = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
  local waited, outcome, before, after = cancelled_lookup(
    { timeout_ns = Clock.seconds(30), servers = { silent.address }, hosts_file = hosts })
  assert(outcome == Poll.CANCELLED, outcome)
  assert(waited < 1500, "a cancelled lookup took " .. waited .. " ms to end")
  assert(after == before, "a cancelled lookup left a descriptor open")
  assert(silent:close())
end

--- The same through a connector, whose stand-ins for the sockets it was
--- asked for are closed too.
local function test_a_cancelled_lookup_through_a_connector_closes_everything_it_held(tmp: string)
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local pair = assert(process.connector_pair())
  assert(sys.write(pair[2], string.pack(">I4", socket.CONNECTOR_HELLO)) == 4)
  local dns <close> = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 53 } }, false, Clock.ms(100)))
  local waited, outcome, before, after = cancelled_lookup({ timeout_ns = Clock.seconds(30), connector = dns,
    servers = { Net.udp("127.0.0.1", 53) }, hosts_file = hosts })
  assert(outcome == Poll.CANCELLED, outcome)
  assert(waited < 1500, "a cancelled lookup took " .. waited .. " ms to end")
  assert(after == before, "a cancelled lookup left a descriptor open")
  assert(not dns:ended())
  assert(sys.close(pair[2]))
end
