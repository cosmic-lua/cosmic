local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fixture = require("build.relay_wire_fixture")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.internal.relay_server")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")

Test.policy{ loopback = { "127.0.0.1" } }

-- The relay is exercised against servers of the test's own on 127.0.0.1,
-- through a connector that stands in for the native one (which
-- core/connector_test.tl holds to its filter) and records what it was
-- asked to connect to. Names resolve through a hosts file the test writes.

--- The addresses a name resolves to in the test's hosts file: loopback
--- (which only a literal grant opens), and a name whose answers mix a
--- private address with two public ones, which the connector below maps to
--- a server of the test's.
local HOSTS <const> = table.concat({
  "127.0.0.1 svc.test other.test direct.test",
  "10.1.2.3 multi.test",
  "93.184.216.34 multi.test",
  "93.184.216.35 multi.test",
  "",
}, "\n")

--- A server of the test's own, and what it saw.
local record Origin
  address: Net.Address
  port: integer
  --- Every byte any connection sent it.
  received: string
  connections: integer
  --- Whether a connection ended what it sent.
  eof: boolean
  stop: function()
end

--- Starts a server on a port of its own that runs `handle` for each
--- connection it takes.
local function origin(handle: function(conn: Net.Conn, seen: Origin)): Origin
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local state: Origin = {
    address = listener.address, port = listener.address.port, received = "", connections = 0, eof = false,
    stop = function() end,
  }
  local acceptor = Poll.spawn(function()
    while true do
      local conn = listener:accept()
      if conn == nil then
        return
      end
      state.connections = state.connections + 1
      Poll.spawn(function()
        handle(conn, state)
        local _, _ = conn:close()
      end)
    end
  end)
  state.stop = function()
    acceptor:cancel()
    local _, _ = listener:close()
  end
  return state
end

--- Reads `conn` until the end, noting what arrives in `seen`; false if it was a failure.
local function drain(conn: Net.Conn, seen: Origin, answer?: string)
  while true do
    local data, _ = conn:read()
    if data == nil then
      seen.eof = true
      return
    end
    seen.received = seen.received .. data
    if answer ~= nil then
      local _, _ = conn:write(answer)
    end
  end
end

local function echo(conn: Net.Conn, seen: Origin)
  while true do
    local data, _ = conn:read()
    if data == nil then
      seen.eof = true
      return
    end
    seen.received = seen.received .. data
    local _, _ = conn:write(data)
  end
end

--- Reads to the end of what the client sends, then answers "after-eof".
local function answers_after_eof(conn: Net.Conn, seen: Origin)
  drain(conn, seen)
  local _, _ = conn:write("after-eof")
end

--- Speaks, ends its own side, and goes on reading.
local function greets_then_half_closes(conn: Net.Conn, seen: Origin)
  local _, _ = conn:write("greet")
  local _, _ = conn:shutdown("write")
  drain(conn, seen)
end

--- A server-first protocol: a banner, then whatever the client sends.
local function banner(conn: Net.Conn, seen: Origin)
  local _, _ = conn:write("SSH-2.0-origin\r\n")
  drain(conn, seen)
end

local function listen_here(): Net.Listener
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  return listener
end

local record Options
  grants: {string}
  upstream: Relay.Upstream
  timeouts: Relay.Timeouts
  limits: Relay.Limits
  tls_ports: {integer}
  connector: Relay.Connector
  resolve: Net.ResolveOptions
  --- Address of a name's answer, to the port of the server it stands for.
  redirect: {string: integer}
  own_addresses: {string}
  token: string
  unresolved: string
  --- Serve both protocols at one listener, as a relay on the host's
  --- loopback does: `http` and `socks` are then its one address.
  mixed: boolean
end

--- A running relay and what a test needs of it.
local record Rig
  http: Net.Address
  socks: Net.Address
  server: Relay.Serving
  --- The decision lines.
  log: {string}
  --- The connections the connector was asked for, as "address:port".
  asked: {string}
  --- The timeouts the connector was given.
  given: {integer}
  listeners: {Net.Listener}
end

--- Starts a relay in the calling task of a run, over the test's hosts file.
local function start(tmp: string, opts: Options): Rig
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, HOSTS))
  local http, socks, mixed: Net.Listener, Net.Listener, Net.Listener
  local rig: Rig = { log = {}, asked = {}, given = {}, server = nil as Relay.Serving }
  if opts.mixed then
    mixed = listen_here()
    rig.http, rig.socks, rig.listeners = mixed.address, mixed.address, { mixed }
  else
    http, socks = listen_here(), listen_here()
    rig.http, rig.socks, rig.listeners = http.address, socks.address, { http, socks }
  end
  local redirect = opts.redirect or {}
  local spec: Relay.Spec = {
    http = http, socks = socks, mixed = mixed ~= nil and { mixed } or nil, grants = opts.grants, upstream = opts.upstream,
    timeouts = opts.timeouts, limits = opts.limits, tls_ports = opts.tls_ports,
    resolve = opts.resolve or { hosts_file = hosts }, own_addresses = opts.own_addresses, token = opts.token,
    unresolved = opts.unresolved,
    log = function(line: string)
      rig.log[#rig.log + 1] = line
    end,
    connector = opts.connector or function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
      rig.asked[#rig.asked + 1] = address .. ":" .. port
      rig.given[#rig.given + 1] = timeout_ns
      return Net.connect(Net.tcp(redirect[address] ~= nil and "127.0.0.1" or address, redirect[address] or port),
        { timeout_ns = timeout_ns })
    end,
  }
  rig.server = Relay.start(spec)
  return rig
end

--- Stops the relay and every server, and waits for their tasks.
local function finish(rig: Rig, ...: Origin)
  rig.server:stop()
  rig.server:wait()
  for _, listener in ipairs(rig.listeners) do
    local _, _ = listener:close()
  end
  for _, server in ipairs({ ... }) do
    server.stop()
  end
end

local function dial(address: Net.Address): Net.Conn
  local conn = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
  conn:set_timeout(Clock.seconds(5))
  return conn
end

--- Reads exactly `count` bytes.
local function read_exact(conn: Net.Conn, count: integer): string
  local out = ""
  while #out < count do
    local data, why = conn:read(count - #out)
    assert(data ~= nil, "the connection ended after " .. #out .. " of " .. count .. " bytes: " .. why)
    out = out .. data
  end
  return out
end

--- Everything until the end of what `conn` sends.
local function read_all(conn: Net.Conn): string
  local out = ""
  while true do
    local data, _ = conn:read()
    if data == nil then
      return out
    end
    out = out .. data
  end
end

--- The head of a response, read a byte at a time so that none of what
--- follows it is taken.
local function read_head(conn: Net.Conn): string
  local out = ""
  while not out:find("\r\n\r\n", 1, true) do
    local data, why = conn:read(1)
    assert(data ~= nil, "the connection ended before the head was whole: " .. why .. " " .. out)
    out = out .. data
  end
  return out
end

--- Asks the relay's CONNECT listener for `target`: the connection and the
--- response head.
local function connect_to(rig: Rig, target: string, headers?: {string}): Net.Conn, string
  local conn = dial(rig.http)
  assert(conn:write(Fixture.connect(target, headers)))
  return conn, read_head(conn)
end

--- Asks the SOCKS listener for `host:port`: the connection and the reply code.
local function socks_to(rig: Rig, host: string, port: integer): Net.Conn, integer
  local conn = dial(rig.socks)
  assert(conn:write("\5\1\0"))
  assert(read_exact(conn, 2) == "\5\0")
  assert(conn:write(Fixture.socks_request(1, 3, string.char(#host) .. host, port)))
  local reply = read_exact(conn, 10)
  return conn, reply:byte(2)
end

--- The first line of a response head.
local function status_line(head: string): string
  return head:match("^[^\r\n]*")
end

--- The decision lines that hold `text`.
local function lines_with(rig: Rig, text: string): {string}
  local out: {string} = {}
  for _, line in ipairs(rig.log) do
    if line:find(text, 1, true) then
      out[#out + 1] = line
    end
  end
  return out
end

--- Waits until `done` holds, at most five seconds.
local function until_it(done: function(): boolean)
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  while not done() do
    assert(Clock.monotonic_ns() < deadline, "timed out waiting")
    assert(Poll.delay(Clock.ms(5)))
  end
end

local function test_a_granted_name_is_carried_both_ways_over_connect(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    -- The name is granted, and loopback by its address too.
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local conn, head = connect_to(rig, "svc.test:" .. port)
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    assert(conn:write("hello "))
    assert(read_exact(conn, 6) == "hello ")
    assert(conn:write("again"))
    assert(read_exact(conn, 5) == "again")
    assert(rig.asked[1] == "127.0.0.1:" .. port and #rig.asked == 1, table.concat(rig.asked, ","))
    assert(rig.given[1] == Clock.seconds(10), "the connector is given the connect timeout")
    assert(#lines_with(rig, "allowed via 127.0.0.1:" .. port) == 1, table.concat(rig.log, "\n"))
    local _, _ = conn:close()
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    assert(server.received == "hello again", server.received)
    finish(rig, server)
  end)
end

local function test_a_granted_name_is_carried_both_ways_over_socks5(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local conn, code = socks_to(rig, "svc.test", port)
    assert(code == 0, code)
    assert(conn:write("socks"))
    assert(read_exact(conn, 5) == "socks")
    -- An address request, as a client that resolved by itself would send it, is a literal.
    local direct = dial(rig.socks)
    assert(direct:write("\5\1\0"))
    assert(read_exact(direct, 2) == "\5\0")
    assert(direct:write(Fixture.socks_request(1, 1, "\127\0\0\1", port)))
    assert(read_exact(direct, 10):byte(2) == 0, "a literal grant opens the address")
    assert(direct:write("direct"))
    assert(read_exact(direct, 6) == "direct")
    local _, _ = conn:close()
    local _, _ = direct:close()
    finish(rig, server)
  end)
end

local function test_a_name_resolving_to_loopback_is_refused_unless_literally_granted(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port } })
    local conn, head = connect_to(rig, "svc.test:" .. port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 403 "), line)
    assert(line:find("127.0.0.1 is a loopback address: grant it literally with --connect 127.0.0.1:" .. port, 1, true), line)
    assert(#rig.asked == 0, "no connection was made")
    local _, _ = conn:close()
    -- The same through SOCKS5: not allowed, whose reply carries no text.
    local socks, code = socks_to(rig, "svc.test", port)
    assert(code == 2, code)
    local _, _ = socks:close()
    assert(#lines_with(rig, "grant it literally with --connect 127.0.0.1:" .. port) == 2, table.concat(rig.log, "\n"))
    assert(server.connections == 0, "the server was never reached")
    finish(rig, server)
  end)
end

local function test_a_name_is_matched_to_the_grants_before_it_is_resolved(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    -- Neither name is in the hosts file: resolving either would say so.
    local cases: {{string, string}} = {
      { "ungranted.test:" .. port, "not granted: --connect ungranted.test:" .. port },
      { "svc.test:" .. (port % 60000 + 1), "not granted: --connect svc.test:" .. (port % 60000 + 1) },
      { "sub.svc.test:" .. port, "not granted: --connect sub.svc.test:" .. port },
    }
    for _, case in ipairs(cases) do
      local conn, head = connect_to(rig, case[1])
      local line = status_line(head)
      assert(line:find("^HTTP/1.1 403 ") and line:find(case[2], 1, true), line)
      assert(not line:find("resolve", 1, true), line)
      local _, _ = conn:close()
    end
    -- The host as the reader canonicalises it: case and a trailing dot are not another name.
    local conn, head = connect_to(rig, "SVC.Test.:" .. port)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    local _, _ = conn:close()
    assert(#rig.asked == 1)
    finish(rig, server)
  end)
end

local function test_a_wildcard_host_grants_names_but_never_addresses(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "*:" .. port, "*.example.test:" .. port } })
    -- Any name passes the grants, so what it resolves to is judged: loopback is refused.
    local conn, head = connect_to(rig, "other.test:" .. port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 403 ") and line:find("is a loopback address", 1, true), line)
    local _, _ = conn:close()
    -- A literal, which "*" does not grant.
    local literal, answer = connect_to(rig, "127.0.0.1:" .. port)
    assert(status_line(answer):find("not granted: --connect 127.0.0.1:" .. port, 1, true), answer)
    local _, _ = literal:close()
    -- A pattern is no grant; the relay says so once, at its start.
    assert(#lines_with(rig, "\"*.example.test:" .. port .. "\" opens nothing") == 1, table.concat(rig.log, "\n"))
    local pattern, refused = connect_to(rig, "a.example.test:" .. port)
    assert(not status_line(refused):find("not granted"), refused)
    local _, _ = pattern:close()
    finish(rig, server)
  end)
end

local function test_an_ip_literal_is_refused_unless_a_grant_names_it_literally(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "*:*", "93.184.216.34:443" },
      redirect = { ["93.184.216.34"] = port } })
    local refused: {string} = {
      "127.0.0.1:" .. port, "[::1]:" .. port, "93.184.216.35:443", "93.184.216.34:80", "[2001:db8::1]:443",
    }
    for _, target in ipairs(refused) do
      local conn, head = connect_to(rig, target)
      local line = status_line(head)
      assert(line:find("^HTTP/1.1 403 ") and line:find("not granted: --connect " .. target, 1, true), line)
      assert(line:find("granted literally", 1, true), line)
      local _, _ = conn:close()
    end
    assert(#rig.asked == 0, table.concat(rig.asked, ","))
    -- A public address, but one a grant names with its port.
    local conn, head = connect_to(rig, "93.184.216.34:443")
    assert(status_line(head):find("^HTTP/1.1 200 "), "the grant passes: " .. head)
    assert(rig.asked[1] == "93.184.216.34:443", table.concat(rig.asked, ","))
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_an_ip_literal_a_grant_names_is_connected(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "127.0.0.1:" .. port } })
    local conn, head = connect_to(rig, "127.0.0.1:" .. port)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    assert(conn:write("literal"))
    assert(read_exact(conn, 7) == "literal")
    local _, _ = conn:close()
    -- The grant is of its own port: the same address on another is refused.
    local other, answer = connect_to(rig, "127.0.0.1:" .. (port % 60000 + 1))
    assert(status_line(answer):find("^HTTP/1.1 403 "), answer)
    local _, _ = other:close()
    finish(rig, server)
  end)
end

local function test_a_name_connects_to_the_first_allowed_answer_that_answers(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "multi.test:" .. port },
      redirect = { ["93.184.216.34"] = port, ["93.184.216.35"] = port } })
    local conn, head = connect_to(rig, "multi.test:" .. port)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    assert(conn:write("mixed"))
    assert(read_exact(conn, 5) == "mixed")
    assert(#rig.asked == 1, table.concat(rig.asked, ","))
    assert(rig.asked[1] == "93.184.216.34:" .. port or rig.asked[1] == "93.184.216.35:" .. port, rig.asked[1])
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

--- A connector that fails the first address it is asked and connects the
--- others to the loopback `port`, recording each address and the time it
--- was given.
local function first_fails_connector(how: string, port: integer, asked: {string}, given: {integer}): Relay.Connector
  return function(address: string, _port: integer, timeout_ns: integer): Net.Conn | nil, string
    asked[#asked + 1] = address
    given[#given + 1] = timeout_ns
    if #asked == 1 then return nil, how end
    return Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = timeout_ns })
  end
end

local function contains(list: {string}, value: string): boolean
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function test_a_name_whose_first_address_fails_connects_to_the_next(tmp: string)
  for _, how in ipairs({ "Connection refused", "Network is unreachable", Poll.TIMEOUT }) do
    Poll.run(function()
      local server = origin(echo)
      local port = server.port
      local asked, given: {string}, {integer} = {}, {}
      local rig = start(tmp, { grants = { "multi.test:" .. port },
        connector = first_fails_connector(how, port, asked, given) })
      local conn, head = connect_to(rig, "multi.test:" .. port)
      assert(status_line(head):find("^HTTP/1.1 200 "), how .. ": " .. head)
      assert(conn:write("second"))
      assert(read_exact(conn, 6) == "second")
      assert(#asked == 2 and asked[1] ~= asked[2], table.concat(asked, ","))
      -- Only the public answers are candidates: the private one is never tried.
      assert(not contains(asked, "10.1.2.3"), table.concat(asked, ","))
      assert(#lines_with(rig, "allowed via " .. asked[2] .. ":" .. port) == 1, table.concat(rig.log, "\n"))
      -- The two share the connect timeout: the second gets all that is left.
      assert(given[1] == Clock.seconds(5) and given[2] > Clock.seconds(9) and given[2] <= Clock.seconds(10), given[2])
      local _, _ = conn:close()
      finish(rig, server)
    end)
  end
end

local function test_a_name_none_of_whose_addresses_answer_is_refused_once_naming_each(tmp: string)
  Poll.run(function()
    local asked, given: {string}, {integer} = {}, {}
    local rig = start(tmp, { grants = { "multi.test:80" },
      connector = function(address: string, _port: integer, timeout_ns: integer): Net.Conn | nil, string
        asked[#asked + 1] = address
        given[#given + 1] = timeout_ns
        return nil, "Connection refused"
      end })
    local conn, head = connect_to(rig, "multi.test:80")
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 502 ") and line:find("could not connect to multi.test:80: none of its addresses answered", 1, true), line)
    assert(line:find("93.184.216.34:80: Connection refused", 1, true) and line:find("93.184.216.35:80: Connection refused", 1, true), line)
    assert(not line:find("10.1.2.3", 1, true), line)
    assert(#asked == 2 and not contains(asked, "10.1.2.3"), table.concat(asked, ","))
    local _, _ = conn:close()
    local socks, code = socks_to(rig, "multi.test", 80)
    assert(code == 5, code)
    local _, _ = socks:close()
    finish(rig)
  end)
end

local function test_the_connect_timeout_bounds_every_address_together(tmp: string)
  Poll.run(function()
    local asked, given: {string}, {integer} = {}, {}
    local rig = start(tmp, { grants = { "multi.test:80" }, timeouts = { connect = Clock.ms(600) },
      connector = function(address: string, _port: integer, timeout_ns: integer): Net.Conn | nil, string
        asked[#asked + 1] = address
        given[#given + 1] = timeout_ns
        -- A host that never answers: the attempt lasts what it is given.
        assert(Poll.delay(timeout_ns))
        return nil, Poll.TIMEOUT
      end })
    local began = Clock.monotonic_ns()
    local conn, head = connect_to(rig, "multi.test:80")
    local took = (Clock.monotonic_ns() - began) // 1000000
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 504 ") and line:find("none of its addresses answered", 1, true), line)
    assert(#asked == 2 and given[1] == Clock.ms(300) and given[2] <= Clock.ms(300), table.concat(asked, ","))
    assert(took >= 450 and took < 2500, took .. " ms for two addresses of a 600 ms connect timeout")
    local _, _ = conn:close()
    finish(rig)
  end)
end

local function test_the_hosts_own_addresses_are_never_connected_to(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "multi.test:" .. port }, own_addresses = { "93.184.216.34", "::ffff:93.184.216.35" },
      redirect = { ["93.184.216.34"] = port, ["93.184.216.35"] = port } })
    local conn, head = connect_to(rig, "multi.test:" .. port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 403 ") and line:find("one of this host's own addresses", 1, true), line)
    assert(#rig.asked == 0, table.concat(rig.asked, ","))
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_a_name_that_does_not_resolve_is_unreachable(tmp: string)
  Poll.run(function()
    local rig = start(tmp, { grants = { "nowhere.test:80" },
      -- A server that is closed: the query is refused at once.
      resolve = { hosts_file = tmp .. "/hosts", servers = { { host = "127.0.0.1", port = 9 } } } })
    local conn, head = connect_to(rig, "nowhere.test:80")
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 502 ") and line:find("could not resolve nowhere.test", 1, true), line)
    local _, _ = conn:close()
    local socks, code = socks_to(rig, "nowhere.test", 80)
    assert(code == 4, code)
    local _, _ = socks:close()
    finish(rig)
  end)
end

--- A relay whose name servers could not be read still serves: every name
--- is refused, saying why, and a literally granted address is connected.
local function test_a_relay_without_name_servers_refuses_names_and_reaches_granted_addresses(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port },
      unresolved = "no name servers here" })
    local conn, head = connect_to(rig, "svc.test:" .. port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 502 ") and line:find("could not resolve svc.test: no name servers here", 1, true), line)
    local _, _ = conn:close()
    local socks, code = socks_to(rig, "svc.test", port)
    assert(code == 4, code)
    local _, _ = socks:close()
    local literal, answer = connect_to(rig, "127.0.0.1:" .. port)
    assert(status_line(answer):find("^HTTP/1.1 200 "), answer)
    assert(literal:write("literal"))
    assert(read_exact(literal, 7) == "literal")
    local _, _ = literal:close()
    assert(#lines_with(rig, "no name is resolved") == 1, table.concat(rig.log, "\n"))
    finish(rig, server)
  end)
end

local function test_a_lookup_that_is_not_answered_times_out(tmp: string)
  Poll.run(function()
    -- A socket nothing reads: the query is sent and never answered.
    local silent = assert(Udp.bind("127.0.0.1", 0))
    local rig = start(tmp, { grants = { "slow.test:80" }, timeouts = { resolve = Clock.ms(200) },
      resolve = { hosts_file = tmp .. "/hosts", servers = { { host = "127.0.0.1", port = silent.address.port } } } })
    local conn, head = connect_to(rig, "slow.test:80")
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 504 ") and line:find("resolving slow.test timed out after 200 milliseconds", 1, true), line)
    local _, _ = conn:close()
    local socks, code = socks_to(rig, "slow.test", 80)
    assert(code == 6, code)
    local _, _ = socks:close()
    Udp.close(silent)
    finish(rig)
  end)
end

--- A lookup nobody answers holds up its own connection alone: a tunnel
--- to a literal address is opened and carries bytes meanwhile, and the
--- relay stops without waiting for the lookup's time.
local function test_a_lookup_that_is_not_answered_stalls_only_its_own_connection(tmp: string)
  Poll.run(function()
    local silent = assert(Udp.bind("127.0.0.1", 0))
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "slow.test:80", "127.0.0.1:" .. port },
      timeouts = { resolve = Clock.seconds(2) },
      resolve = { hosts_file = tmp .. "/hosts", servers = { { host = "127.0.0.1", port = silent.address.port } } } })
    local slow_answered = false
    local began = Clock.monotonic_ns()
    local waiting = Poll.spawn(function()
      local conn = dial(rig.http)
      assert(conn:write(Fixture.connect("slow.test:80")))
      -- Answered, or ended by the relay's stop.
      local _, _ = conn:read(1)
      slow_answered = true
      local _, _ = conn:close()
    end)
    -- Let the lookup start, then use the relay for something else.
    assert(Poll.delay(Clock.ms(100)))
    local conn, head = connect_to(rig, "127.0.0.1:" .. port)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    assert(conn:write("meanwhile"))
    assert(read_exact(conn, 9) == "meanwhile")
    local meanwhile = (Clock.monotonic_ns() - began) // 1000000
    assert(meanwhile < 1000, "a tunnel waited " .. meanwhile .. " ms behind another connection's lookup")
    assert(not slow_answered, "the lookup ended before its time")
    -- The relay stops while the lookup is pending, and does not wait it out.
    local _, _ = conn:close()
    local stopping = Clock.monotonic_ns()
    finish(rig, server)
    local stopped = (Clock.monotonic_ns() - stopping) // 1000000
    assert(stopped < 1500, "the relay took " .. stopped .. " ms to stop with a lookup pending")
    waiting:cancel()
    Udp.close(silent)
  end)
end

--- The lookup's own deadline still ends it, with the 504 that says so,
--- while another connection's lookup is answered at once.
local function test_a_lookup_out_of_time_is_refused_while_another_is_answered(tmp: string)
  Poll.run(function()
    local silent = assert(Udp.bind("127.0.0.1", 0))
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "slow.test:80", "svc.test:" .. port, "127.0.0.1:" .. port },
      timeouts = { resolve = Clock.ms(300) },
      resolve = { hosts_file = tmp .. "/hosts", servers = { { host = "127.0.0.1", port = silent.address.port } } } })
    local head = ""
    local waiting = Poll.spawn(function()
      local conn, answer = connect_to(rig, "slow.test:80")
      head = answer
      local _, _ = conn:close()
    end)
    -- A name the hosts file answers needs no server.
    local conn, answer = connect_to(rig, "svc.test:" .. port)
    assert(status_line(answer):find("^HTTP/1.1 200 "), answer)
    assert(conn:write("hosts"))
    assert(read_exact(conn, 5) == "hosts")
    assert(head == "", "the slow lookup ended before its time")
    until_it(function(): boolean return head ~= "" end)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 504 ") and line:find("resolving slow.test timed out after 300 milliseconds", 1, true), line)
    assert(waiting:join())
    local _, _ = conn:close()
    Udp.close(silent)
    finish(rig, server)
  end)
end

local function test_a_connection_that_fails_or_times_out_says_which(tmp: string)
  Poll.run(function()
    local port = 4000
    local outcome = "Connection refused"
    local rig = start(tmp, { grants = { "127.0.0.1:" .. port },
      timeouts = { connect = Clock.ms(750) },
      connector = function(_address: string, _port: integer, timeout_ns: integer): Net.Conn | nil, string
        assert(timeout_ns == Clock.ms(750), "the connect timeout reaches the connector")
        assert(Poll.delay(Clock.ms(5)))
        return nil, outcome
      end })
    local cases: {{string, string, integer, integer}} = {
      { "Connection refused", "^HTTP/1.1 502 ", 502, 5 },
      { Poll.TIMEOUT, "^HTTP/1.1 504 ", 504, 6 },
      { "Network is unreachable", "^HTTP/1.1 502 ", 502, 3 },
      { "No route to host", "^HTTP/1.1 502 ", 502, 4 },
    }
    for _, case in ipairs(cases) do
      outcome = case[1]
      local conn, head = connect_to(rig, "127.0.0.1:" .. port)
      local line = status_line(head)
      assert(line:find(case[2]) and line:find("could not connect to 127.0.0.1:" .. port .. ": " .. case[1], 1, true), line)
      local _, _ = conn:close()
      local socks = dial(rig.socks)
      assert(socks:write("\5\1\0"))
      assert(read_exact(socks, 2) == "\5\0")
      assert(socks:write(Fixture.socks_request(1, 1, "\127\0\0\1", port)))
      assert(read_exact(socks, 10):byte(2) == case[4], case[1])
      local _, _ = socks:close()
    end
    finish(rig)
  end)
end

local function test_an_sni_that_differs_from_the_host_is_refused(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen, "ack")
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local conn = connect_to(rig, "svc.test:" .. port)
    assert(conn:write(Fixture.records(Fixture.hello({ name = "evil.test" }))))
    -- A TLS alert, and then nothing: the connection is closed.
    local told = read_all(conn)
    assert(told == "\21\3\3\0\2\2\40", ("%q"):format(told))
    assert(server.received == "", "no byte of the hello reached the server")
    assert(#lines_with(rig, "refused a ClientHello naming evil.test for a connection to svc.test:" .. port) == 1,
      table.concat(rig.log, "\n"))
    assert(rig.log[#rig.log]:find("grant --connect evil.test:<port>", 1, true), rig.log[#rig.log])
    local _, _ = conn:close()
    -- The matching name, in any case, goes through whole.
    local hello = Fixture.records(Fixture.hello({ name = "SVC.test" }))
    local same = connect_to(rig, "svc.test:" .. port)
    assert(same:write(hello))
    assert(read_exact(same, 3) == "ack")
    assert(server.received == hello, "the hello arrived unchanged")
    local _, _ = same:close()
    finish(rig, server)
  end)
end

local function test_a_hello_split_across_writes_is_judged_whole(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen, "ack")
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local hello = Fixture.records(Fixture.hello({ name = "svc.test" }), { 40 })
    local conn = connect_to(rig, "svc.test:" .. port)
    assert(conn:write(hello:sub(1, 3)))
    assert(Poll.delay(Clock.ms(30)))
    assert(server.received == "", "nothing is passed on while the hello is incomplete")
    assert(conn:write(hello:sub(4)))
    assert(read_exact(conn, 3) == "ack")
    assert(server.received == hello)
    local _, _ = conn:close()
    -- And bytes that follow the hello in the same write go with it.
    local followed = connect_to(rig, "svc.test:" .. port)
    assert(followed:write(hello .. "more"))
    assert(read_exact(followed, 3) == "ack")
    assert(server.received == hello .. hello .. "more")
    local _, _ = followed:close()
    finish(rig, server)
  end)
end

local function test_an_encrypted_client_hello_is_refused(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen)
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    for _, kind in ipairs({ 0xfe0d, 0xffce }) do
      local conn = connect_to(rig, "svc.test:" .. port)
      local hello = Fixture.hello({ name = "svc.test", extra = { Fixture.extension(kind, "\0\1\2") } })
      assert(conn:write(Fixture.records(hello)))
      assert(read_all(conn) == "\21\3\3\0\2\2\40")
      local _, _ = conn:close()
    end
    assert(server.received == "")
    local lines = lines_with(rig, "encrypted server name (ECH or ESNI)")
    assert(#lines == 2 and lines[1]:find("turn Encrypted Client Hello off in the client", 1, true), table.concat(rig.log, "\n"))
    finish(rig, server)
  end)
end

local function test_a_malformed_hello_is_refused(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen)
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local conn = connect_to(rig, "svc.test:" .. port)
    -- A handshake record of length 0.
    assert(conn:write("\22\3\1\0\0"))
    assert(read_all(conn) == "\21\3\3\0\2\2\40")
    local _, _ = conn:close()
    assert(#lines_with(rig, "refused a malformed TLS ClientHello") == 1, table.concat(rig.log, "\n"))
    assert(server.received == "")
    finish(rig, server)
  end)
end

local function test_a_hello_with_no_name_is_refused_on_a_tls_port_only(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen, "ack")
    end)
    local port = server.port
    local nameless = Fixture.records(Fixture.hello())
    -- The default TLS ports are 443 and 853: this one is not, and a nameless hello passes.
    local plain = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local open = connect_to(plain, "svc.test:" .. port)
    assert(open:write(nameless))
    assert(read_exact(open, 3) == "ack")
    local _, _ = open:close()
    finish(plain)
    -- Named a TLS port, the same hello is refused.
    local strict = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port }, tls_ports = { port } })
    local conn = connect_to(strict, "svc.test:" .. port)
    assert(conn:write(nameless))
    assert(read_all(conn) == "\21\3\3\0\2\2\40")
    assert(#lines_with(strict, "no server name on a TLS port") == 1, table.concat(strict.log, "\n"))
    local _, _ = conn:close()
    -- A connection to an address names no host to match: a nameless hello is what it sends.
    local literal = connect_to(strict, "127.0.0.1:" .. port)
    assert(literal:write(nameless))
    assert(read_exact(literal, 3) == "ack")
    local _, _ = literal:close()
    finish(strict, server)
  end)
end

local function test_a_hello_naming_a_host_for_an_address_is_refused(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen)
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "127.0.0.1:" .. port } })
    local conn = connect_to(rig, "127.0.0.1:" .. port)
    assert(conn:write(Fixture.records(Fixture.hello({ name = "svc.test" }))))
    assert(read_all(conn) == "\21\3\3\0\2\2\40")
    assert(#lines_with(rig, "naming svc.test for a connection to the address 127.0.0.1:" .. port) == 1, table.concat(rig.log, "\n"))
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_bytes_that_are_not_tls_pass_on_any_port(tmp: string)
  Poll.run(function()
    local server = origin(banner)
    local port = server.port
    -- Even where the port is named a TLS one: the first bytes are not a hello.
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port }, tls_ports = { port } })
    local conn = connect_to(rig, "svc.test:" .. port)
    -- A server that speaks first is not waited on for the client's hello.
    assert(read_exact(conn, 16) == "SSH-2.0-origin\r\n")
    assert(conn:write("SSH-2.0-client\r\n"))
    assert(Poll.delay(Clock.ms(30)))
    assert(server.received == "SSH-2.0-client\r\n", server.received)
    assert(conn:write("and plain bytes " .. ("\22\3\1"):rep(3)))
    until_it(function(): boolean return #server.received > 16 end)
    assert(#lines_with(rig, "refused") == 0, table.concat(rig.log, "\n"))
    local _, _ = conn:close()
    -- The first bytes the client sends are read as a hello, whenever they come.
    local late = connect_to(rig, "svc.test:" .. port)
    assert(read_exact(late, 16) == "SSH-2.0-origin\r\n")
    assert(late:write(Fixture.records(Fixture.hello({ name = "evil.test" }))))
    assert(read_all(late) == "\21\3\3\0\2\2\40")
    local _, _ = late:close()
    finish(rig, server)
  end)
end

local function test_a_client_that_waits_for_a_server_that_speaks_first_is_not_timed_out(tmp: string)
  Poll.run(function()
    local server = origin(banner)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, timeouts = { head = Clock.ms(150) } })
    local conn = connect_to(rig, "127.0.0.1:" .. server.port)
    assert(read_exact(conn, 16) == "SSH-2.0-origin\r\n")
    -- Silent for longer than the head timeout, as a client waiting on a prompt is.
    assert(Poll.delay(Clock.ms(450)))
    assert(rig.server:stats().open == 1, "still open")
    assert(conn:write("SSH-2.0-client\r\n"))
    until_it(function(): boolean return server.received == "SSH-2.0-client\r\n" end)
    assert(#lines_with(rig, "refused") == 0 and #lines_with(rig, "closed") == 0, table.concat(rig.log, "\n"))
    -- The clock starts at the first byte of a hello that then stops.
    local late = connect_to(rig, "127.0.0.1:" .. server.port)
    assert(Poll.delay(Clock.ms(300)))
    assert(late:write(Fixture.records(Fixture.hello({})):sub(1, 10)))
    assert(read_all(late):find("\21\3\3", 1, true) == 17, "a hello that stops is refused (after the banner)")
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_a_hello_sent_with_the_request_is_judged_and_passed(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen, "ack")
    end)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    local hello = Fixture.records(Fixture.hello({ name = "svc.test" }))
    local pipelined = dial(rig.http)
    assert(pipelined:write(Fixture.connect("svc.test:" .. port) .. hello))
    assert(status_line(read_head(pipelined)):find("^HTTP/1.1 200 "))
    assert(read_exact(pipelined, 3) == "ack")
    assert(server.received == hello)
    local _, _ = pipelined:close()
    local bad = dial(rig.http)
    assert(bad:write(Fixture.connect("svc.test:" .. port) .. Fixture.records(Fixture.hello({ name = "evil.test" }))))
    assert(status_line(read_head(bad)):find("^HTTP/1.1 200 "))
    assert(read_all(bad) == "\21\3\3\0\2\2\40")
    assert(server.received == hello, "nothing of the refused hello arrived")
    local _, _ = bad:close()
    -- SOCKS5: the request and the hello in one write after the greeting.
    local socks = dial(rig.socks)
    assert(socks:write("\5\1\0"))
    assert(read_exact(socks, 2) == "\5\0")
    assert(socks:write(Fixture.socks_request(1, 3, "\8svc.test", port) .. hello))
    assert(read_exact(socks, 10):byte(2) == 0)
    assert(read_exact(socks, 3) == "ack")
    local _, _ = socks:close()
    finish(rig, server)
  end)
end

local function test_a_grant_whose_port_is_not_a_plain_decimal_opens_nothing(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local bad = { "svc.test:0x" .. ("%x"):format(port), "svc.test:1e2", "svc.test:80.0", "svc.test:0", "svc.test:00",
      "svc.test:080", "svc.test:65536", "svc.test:+80", "svc.test:99999999", "::1:80", "2001:db8::1:443" }
    local rig = start(tmp, { grants = bad })
    assert(#lines_with(rig, "opens nothing") == #bad, table.concat(rig.log, "\n"))
    for _, target in ipairs({ "svc.test:80", "svc.test:" .. port, "svc.test:100", "svc.test:1" }) do
      local conn, head = connect_to(rig, target)
      assert(status_line(head):find("^HTTP/1.1 403 .*not granted"), head)
      local _, _ = conn:close()
    end
    finish(rig, server)
  end)
end

local function test_a_connection_made_after_stop_is_closed(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port },
      connector = function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
        assert(Poll.delay(Clock.ms(150)))
        return Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      end })
    local conn = dial(rig.http)
    assert(conn:write(Fixture.connect("127.0.0.1:" .. server.port)))
    assert(Poll.delay(Clock.ms(40)))
    rig.server:stop()
    until_it(function(): boolean return server.connections == 1 end)
    rig.server:wait()
    until_it(function(): boolean return server.eof end)
    local data, _ = conn:read()
    assert(data == nil, "no reply to a connection made after stop")
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_each_side_ending_what_it_sends_is_passed_on(tmp: string)
  Poll.run(function()
    local seen = origin(answers_after_eof)
    local greeter = origin(greets_then_half_closes)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. seen.port, "127.0.0.1:" .. greeter.port } })
    -- The program ends first: the server sees the end, and can still answer.
    local conn = connect_to(rig, "127.0.0.1:" .. seen.port)
    assert(conn:write("ping"))
    assert(conn:shutdown("write"))
    assert(read_all(conn) == "after-eof")
    assert(seen.received == "ping" and seen.eof, "the server saw the program's end")
    local _, _ = conn:close()
    -- The server ends first: the program reads the end, and can still send.
    local other = connect_to(rig, "127.0.0.1:" .. greeter.port)
    assert(read_exact(other, 5) == "greet")
    local data, why = other:read()
    assert(data == nil and why == "", "the end of what the server sends")
    assert(other:write("late"))
    assert(other:shutdown("write"))
    until_it(function(): boolean return greeter.eof end)
    assert(greeter.received == "late", greeter.received)
    local _, _ = other:close()
    finish(rig, seen, greeter)
  end)
end

local function test_a_tunnel_nothing_moves_in_ends_at_the_idle_timeout(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, timeouts = { idle = Clock.ms(250) } })
    local conn = connect_to(rig, "127.0.0.1:" .. server.port)
    local started = Clock.monotonic_ns()
    -- Bytes keep it open past the timeout.
    for _ = 1, 4 do
      assert(Poll.delay(Clock.ms(100)))
      assert(conn:write("x"))
      assert(read_exact(conn, 1) == "x")
    end
    assert(Clock.monotonic_ns() - started > Clock.ms(350))
    -- Then none do.
    local data, _ = conn:read()
    assert(data == nil, "the relay ended the idle tunnel")
    -- The relay closes the tunnel first and writes its line once both
    -- directions have stopped.
    until_it(function(): boolean
      return #lines_with(rig, "closed: idle for 250 milliseconds") > 0
    end)
    assert(#lines_with(rig, "closed: idle for 250 milliseconds") == 1, table.concat(rig.log, "\n"))
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_a_request_that_is_not_finished_is_refused_at_the_head_timeout(tmp: string)
  Poll.run(function()
    local rig = start(tmp, { grants = { "svc.test:80" }, timeouts = { head = Clock.ms(150) } })
    local conn = dial(rig.http)
    assert(conn:write("CONNECT svc.test:80 HT"))
    local head = read_head(conn)
    assert(status_line(head):find("^HTTP/1.1 408 request not received within 150 milliseconds"), head)
    local _, _ = conn:close()
    local silent = dial(rig.socks)
    assert(silent:write("\5\1"))
    assert(read_all(silent) == "", "a SOCKS client that does not finish is closed")
    assert(#lines_with(rig, "request not received within 150 milliseconds") == 2, table.concat(rig.log, "\n"))
    local _, _ = silent:close()
    finish(rig)
  end)
end

local function test_a_hello_that_is_not_finished_is_refused_at_the_head_timeout(tmp: string)
  Poll.run(function()
    local server = origin(function(conn: Net.Conn, seen: Origin)
      drain(conn, seen)
    end)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, timeouts = { head = Clock.ms(150) } })
    local conn = connect_to(rig, "127.0.0.1:" .. server.port)
    local hello = Fixture.records(Fixture.hello({}))
    assert(conn:write(hello:sub(1, 10)))
    assert(read_all(conn) == "\21\3\3\0\2\2\40")
    assert(#lines_with(rig, "ClientHello not complete within 150 milliseconds") == 1, table.concat(rig.log, "\n"))
    assert(server.received == "")
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_too_many_open_connections_are_refused_saying_so(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local grants = { "127.0.0.1:" .. server.port }
    local rig = start(tmp, { grants = grants, limits = { connections = 1 } })
    local first = connect_to(rig, "127.0.0.1:" .. server.port)
    local second, head = connect_to(rig, "127.0.0.1:" .. server.port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 503 ") and line:find("too many open connections: at most 1 at once", 1, true), line)
    local _, _ = second:close()
    local socks, code = socks_to(rig, "svc.test", server.port)
    assert(code == 1, "a general failure for the SOCKS5 client: " .. code)
    local _, _ = socks:close()
    assert(#lines_with(rig, "too many open connections") == 2, table.concat(rig.log, "\n"))
    -- Room again once the first is closed.
    local _, _ = first:close()
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    local again, answer = connect_to(rig, "127.0.0.1:" .. server.port)
    assert(status_line(answer):find("^HTTP/1.1 200 "), answer)
    local _, _ = again:close()
    assert(rig.server:stats().refused == 2)
    finish(rig, server)
  end)
end

local function test_connections_past_the_total_are_refused_saying_so(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, limits = { total = 2 } })
    for _ = 1, 2 do
      local conn, head = connect_to(rig, "127.0.0.1:" .. server.port)
      assert(status_line(head):find("^HTTP/1.1 200 "), head)
      local _, _ = conn:close()
    end
    local conn, head = connect_to(rig, "127.0.0.1:" .. server.port)
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 503 ") and line:find("connection budget spent: this sandbox's relay serves at most 2 connections", 1, true), line)
    local _, _ = conn:close()
    assert(rig.server:stats().accepted == 3)
    finish(rig, server)
  end)
end

local function test_a_request_head_past_the_cap_is_refused_saying_so(tmp: string)
  Poll.run(function()
    local rig = start(tmp, { grants = { "127.0.0.1:80" }, limits = { header_bytes = 64 } })
    local conn = dial(rig.http)
    assert(conn:write(Fixture.connect("127.0.0.1:80", { "X: " .. ("a"):rep(200) })))
    local head = read_head(conn)
    assert(status_line(head):find("^HTTP/1.1 431 request head longer than 64 bytes %(the relay's cap%)"), head)
    local _, _ = conn:close()
    -- A head that fits is read.
    local fits, answer = connect_to(rig, "127.0.0.1:80")
    assert(not status_line(answer):find("431"), answer)
    local _, _ = fits:close()
    finish(rig)
  end)
end

--- A server that is a CONNECT proxy: it notes the request it is sent,
--- answers with `status`, and for a 200 serves the tunnel by echoing.
local record Proxy
  head: string
  server: Origin
end

local function proxy(status: string): Proxy
  local state: Proxy = { head = "" }
  state.server = origin(function(conn: Net.Conn, seen: Origin)
    local text = ""
    while not text:find("\r\n\r\n", 1, true) do
      local data, _ = conn:read()
      if data == nil then
        return
      end
      text = text .. data
    end
    state.head = text
    if status ~= "200" then
      local _, _ = conn:write("HTTP/1.1 " .. status .. "\r\nContent-Length: 0\r\n\r\n")
      return
    end
    local _, _ = conn:write("HTTP/1.1 200 Connection established\r\n\r\n")
    echo(conn, seen)
  end)
  return state
end

local function test_a_connect_goes_through_the_upstream_proxy_which_resolves(tmp: string)
  Poll.run(function()
    local through = proxy("200")
    local up: Relay.Upstream = {
      host = "127.0.0.1", port = through.server.port, authorization = "Basic dTpw", no_proxy = { "direct.test" },
    }
    local grants = { "api.test:443", "direct.test:9", "a.localhost:443" }
    local rig = start(tmp, { grants = grants, upstream = up })
    assert(#lines_with(rig, "upstream proxy 127.0.0.1:" .. through.server.port ..
        ": it resolves the names it is asked for, so the relay's address checks do not apply") == 1,
      table.concat(rig.log, "\n"))
    -- The name is in no hosts file: the upstream is the one that resolves it.
    local conn, head = connect_to(rig, "api.test:443")
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    assert(conn:write("tunnelled"))
    assert(read_exact(conn, 9) == "tunnelled")
    assert(through.head:find("^CONNECT api.test:443 HTTP/1.1\r\nHost: api.test:443\r\nProxy%-Authorization: Basic dTpw\r\n\r\n"),
      through.head)
    assert(rig.asked[1] == "127.0.0.1:" .. through.server.port and #rig.asked == 1, table.concat(rig.asked, ","))
    assert(#lines_with(rig, "allowed through the upstream proxy") == 1, table.concat(rig.log, "\n"))
    local _, _ = conn:close()
    -- The name checks apply first: an ungranted name never reaches the upstream.
    local before = through.server.connections
    local refused, answer = connect_to(rig, "evil.test:443")
    assert(status_line(answer):find("^HTTP/1.1 403 .*not granted: %-%-connect evil.test:443"), answer)
    local _, _ = refused:close()
    assert(through.server.connections == before)
    -- A host no_proxy names is reached directly, and resolved and checked here: loopback, so refused.
    local direct, refusal = connect_to(rig, "direct.test:9")
    assert(status_line(refusal):find("^HTTP/1.1 403 .*is a loopback address"), refusal)
    local _, _ = direct:close()
    -- The upstream's own address needs no grant, and the program is not granted it.
    local literal, ok = connect_to(rig, "127.0.0.1:" .. through.server.port)
    assert(status_line(ok):find("^HTTP/1.1 403 .*not granted: %-%-connect 127.0.0.1:" .. through.server.port), ok)
    local _, _ = literal:close()
    -- A name for the proxy's own host is not the sandbox's to ask for.
    local named, local_answer = connect_to(rig, "a.localhost:443")
    assert(status_line(local_answer):find("^HTTP/1.1 403 .*is not relayed through the upstream proxy"), local_answer)
    local _, _ = named:close()
    finish(rig, through.server)
  end)
end

--- A relay that resolves no name still reaches an upstream proxy named by
--- its numeric address, which needs no lookup.
local function test_a_numeric_upstream_is_reached_by_a_relay_that_resolves_no_name(tmp: string)
  Poll.run(function()
    local through = proxy("200")
    local up: Relay.Upstream = { host = "127.0.0.1", port = through.server.port, no_proxy = {} }
    local rig = start(tmp, { grants = { "api.test:443" }, upstream = up, unresolved = "no name servers here" })
    local conn, head = connect_to(rig, "api.test:443")
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    assert(conn:write("tunnelled"))
    assert(read_exact(conn, 9) == "tunnelled")
    local _, _ = conn:close()
    finish(rig, through.server)
  end)
end

local function test_the_upstreams_own_address_needs_no_grant_and_is_the_programs_to_ask_for_only_if_granted(tmp: string)
  Poll.run(function()
    local through = proxy("200")
    local up: Relay.Upstream = { host = "127.0.0.1", port = through.server.port, no_proxy = {} }
    local rig = start(tmp, { grants = { "api.test:443", "localhost:443" }, upstream = up })
    local conn, head = connect_to(rig, "api.test:443")
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    local _, _ = conn:close()
    -- Without the upstream a name is judged by what it resolves to: loopback is refused.
    local local_name, answer = connect_to(rig, "localhost:443")
    assert(status_line(answer):find("^HTTP/1.1 403 .*is not relayed through the upstream proxy"), answer)
    assert(through.server.connections == 1)
    local _, _ = local_name:close()
    finish(rig, through.server)
  end)
end

local function test_an_upstream_proxy_is_reached_at_the_next_of_its_addresses(tmp: string)
  Poll.run(function()
    local through = proxy("200")
    local asked, given: {string}, {integer} = {}, {}
    local up: Relay.Upstream = { host = "proxy.test", port = through.server.port, no_proxy = {},
      addresses = { "192.0.2.1", "127.0.0.1" } }
    local rig = start(tmp, { grants = { "api.test:443" }, upstream = up,
      connector = function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
        asked[#asked + 1] = address
        given[#given + 1] = timeout_ns
        if address == "192.0.2.1" then return nil, "No route to host" end
        return Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      end })
    local conn, head = connect_to(rig, "api.test:443")
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    assert(conn:write("proxied"))
    assert(read_exact(conn, 7) == "proxied")
    assert(table.concat(asked, ",") == "192.0.2.1,127.0.0.1", table.concat(asked, ","))
    local _, _ = conn:close()
    finish(rig, through.server)
  end)
end

local function test_an_upstream_proxy_none_of_whose_addresses_answer_is_refused_once(tmp: string)
  Poll.run(function()
    local up: Relay.Upstream = { host = "proxy.test", port = 3128, no_proxy = {}, addresses = { "192.0.2.1", "192.0.2.2" } }
    local asked: {string} = {}
    local rig = start(tmp, { grants = { "api.test:443" }, upstream = up,
      connector = function(address: string, _port: integer, _timeout_ns: integer): Net.Conn | nil, string
        asked[#asked + 1] = address
        return nil, "Connection refused"
      end })
    local conn, head = connect_to(rig, "api.test:443")
    local line = status_line(head)
    assert(line:find("^HTTP/1.1 502 ") and
        line:find("could not connect to the upstream proxy proxy.test:3128: none of its addresses answered", 1, true), line)
    assert(#asked == 2, table.concat(asked, ","))
    local _, _ = conn:close()
    finish(rig)
  end)
end

local function test_an_upstream_that_refuses_is_told_to_the_program(tmp: string)
  Poll.run(function()
    for _, case in ipairs({ { "407 Proxy Authentication Required", "set https_proxy with user:password@" },
        { "403 Forbidden", "the upstream proxy refused the CONNECT: HTTP/1.1 403 Forbidden" } }) do
      local through = proxy(case[1])
      local up: Relay.Upstream = { host = "127.0.0.1", port = through.server.port, no_proxy = {} }
      local rig = start(tmp, { grants = { "api.test:443", "127.0.0.1:" .. through.server.port }, upstream = up })
      local conn, head = connect_to(rig, "api.test:443")
      local line = status_line(head)
      assert(line:find("^HTTP/1.1 502 ") and line:find(case[2], 1, true), line)
      local _, _ = conn:close()
      local socks, code = socks_to(rig, "api.test", 443)
      assert(code == 1, code)
      local _, _ = socks:close()
      finish(rig, through.server)
    end
  end)
end

local function test_no_proxy_names_the_hosts_reached_directly(tmp: string)
  Poll.run(function()
    local through = proxy("200")
    local server = origin(echo)
    local up: Relay.Upstream = {
      host = "127.0.0.1", port = through.server.port,
      no_proxy = { "direct.test", ".sub.test", "svc.test:" .. server.port, "other.test:1" },
    }
    local rig = start(tmp, { grants = { "127.0.0.1:" .. through.server.port, "127.0.0.1:" .. server.port,
      "svc.test:" .. server.port, "other.test:" .. server.port }, upstream = up })
    -- svc.test on this port is named, so it is reached directly (and its loopback is granted).
    local direct, head = connect_to(rig, "svc.test:" .. server.port)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    assert(through.server.connections == 0)
    local _, _ = direct:close()
    -- other.test:1 is named for another port, so this one goes through the upstream.
    local via, answer = connect_to(rig, "other.test:" .. server.port)
    assert(status_line(answer):find("^HTTP/1.1 200 "), answer)
    assert(through.server.connections == 1)
    local _, _ = via:close()
    finish(rig, through.server, server)
  end)
end

local function test_every_connection_has_one_decision_line(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local port = server.port
    local rig = start(tmp, { grants = { "svc.test:" .. port, "127.0.0.1:" .. port } })
    for _, target in ipairs({ "svc.test:" .. port, "evil.test:" .. port, "127.0.0.2:" .. port, "svc.test:" .. port }) do
      local conn = connect_to(rig, target)
      local _, _ = conn:close()
    end
    local socks, code = socks_to(rig, "evil.test", port)
    assert(code == 2)
    local _, _ = socks:close()
    local bad = dial(rig.http)
    assert(bad:write("GET / HTTP/1.1\r\n\r\n"))
    local head = read_head(bad)
    assert(status_line(head):find("^HTTP/1.1 405 plain HTTP is not relayed"), head)
    local _, _ = bad:close()
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    local decided: {integer: integer} = {}
    for _, line in ipairs(rig.log) do
      local id = line:match("^#(%d+) ")
      if id ~= nil and (line:find(": allowed ", 1, true) or line:find(": refused: ", 1, true)) then
        decided[math.tointeger(tonumber(id))] = (decided[math.tointeger(tonumber(id))] or 0) + 1
      end
    end
    for id = 1, 6 do
      assert(decided[id] == 1, ("connection %d has %s decision lines: %s"):format(id, tostring(decided[id]), table.concat(rig.log, "\n")))
    end
    assert(#lines_with(rig, "#2 connect evil.test:" .. port .. ": refused: not granted: --connect evil.test:" .. port) == 1)
    assert(rig.server:stats().refused == 4)
    finish(rig, server)
  end)
end

local function test_stop_closes_open_tunnels(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port } })
    local conn = connect_to(rig, "127.0.0.1:" .. server.port)
    assert(conn:write("a"))
    assert(read_exact(conn, 1) == "a")
    rig.server:stop()
    local data, _ = conn:read()
    assert(data == nil, "the tunnel was closed")
    -- New connections are not taken.
    local late = Net.connect(rig.http, { timeout_ns = Clock.ms(200) })
    if late ~= nil then
      late:set_timeout(Clock.ms(200))
      local got, _ = late:read()
      assert(got == nil, "nothing serves a connection after stop")
      local _, _ = late:close()
    end
    local _, _ = conn:close()
    finish(rig, server)
  end)
end

local function test_stop_does_not_wait_for_a_request_that_is_not_finished(tmp: string)
  Poll.run(function()
    local rig = start(tmp, { grants = { "svc.test:80" } })
    local conn = dial(rig.http)
    assert(conn:write("CONNECT svc.te"))
    until_it(function(): boolean return rig.server:stats().open == 1 end)
    local started = Clock.monotonic_ns()
    finish(rig)
    assert(Clock.monotonic_ns() - started < Clock.seconds(3), "stop ended the half-read request, not the head timeout")
    local data, _ = conn:read()
    assert(data == nil)
    local _, _ = conn:close()
  end)
end

local function test_a_spec_that_is_no_spec_raises(tmp: string)
  local ok = pcall(Relay.start, { grants = {}, connector = function(): Net.Conn | nil, string
    return nil, ""
  end })
  assert(not ok, "start runs in a task")
  Poll.run(function()
    local listener = listen_here()
    local function connector(): Net.Conn | nil, string
      return nil, "unused"
    end
    local cases: {{Relay.Spec, string}} = {
      { { grants = {}, connector = connector }, "an http, a socks or a mixed listener" },
      { { http = listener, grants = {} }, "spec.connector" },
      { { http = listener, connector = connector } as Relay.Spec, "spec.grants" },
      { { http = listener, grants = { 1 as any as string }, connector = connector }, "spec.grants must hold strings" },
      { { http = listener, grants = {}, connector = connector, timeouts = { idle = 0 } }, "timeouts.idle must be an integer from 1" },
      { { http = listener, grants = {}, connector = connector, limits = { total = -1 } }, "limits.total must be an integer from 1" },
      { { http = listener, grants = {}, connector = connector, tls_ports = { 0 } }, "tls_ports" },
      { { http = listener, grants = {}, connector = connector, token = "" }, "spec.token must be a string of 16 to 255 bytes" },
      { { http = listener, grants = {}, connector = connector, token = ("t"):rep(15) }, "spec.token must be a string of 16" },
      { { http = listener, grants = {}, connector = connector, timeouts = { auth = 0 } }, "timeouts.auth must be an integer from 1" },
      { { http = listener, grants = {}, connector = connector, token = ("t"):rep(256) }, "spec.token must be a string" },
      { { http = listener, grants = {}, connector = connector, token = "a\nb" }, "spec.token must be a string" },
      { { http = listener, grants = {}, connector = connector, token = 5 as any as string }, "spec.token must be a string" },
      { { http = listener, grants = {}, connector = connector, limits = { pre_auth = 0 } }, "limits.pre_auth must be an integer from 1" },
      { { http = listener, grants = {}, connector = connector, own_addresses = { "nope" } }, "not numeric" },
      { { http = listener, grants = {}, connector = connector, timeouts = 5 as any as Relay.Timeouts }, "spec.timeouts must be a table" },
      { { http = listener, grants = {}, connector = connector, upstream = { host = "", port = 80, no_proxy = {} } }, "upstream.host" },
      { { http = listener, grants = {}, connector = connector, upstream = { host = "p", port = 0, no_proxy = {} } }, "upstream.port" },
      { { http = listener, grants = {}, connector = connector,
        upstream = { host = "p", port = 80, authorization = "x\r\nHost: y", no_proxy = {} } }, "upstream.authorization" },
      { { http = listener, grants = {}, connector = connector,
        upstream = { host = "p", port = 80, no_proxy = { 1 as any as string } } }, "upstream.no_proxy" },
    }
    for _, case in ipairs(cases) do
      local started, why = pcall(Relay.start, case[1])
      assert(not started and tostring(why):find(case[2], 1, true), tostring(why))
    end
    local _, _ = listener:close()
    assert(tmp ~= nil)
  end)
end

-- The per-sandbox token: a CONNECT's Basic credential and a SOCKS5 client's
-- RFC 1929 password, which a relay whose spec carries one requires.

local TOKEN <const> = "tok-9f3a1c7e-sandbox"

--- The `Proxy-Authorization` header line for `user` and `password`.
local function basic(user: string, password: string): string
  return "Proxy-Authorization: Basic " .. Codec.base64(user .. ":" .. password)
end

--- A SOCKS5 greeting offering `methods`, and the method answer.
local function socks_greet(conn: Net.Conn, methods: string): string
  assert(conn:write("\5" .. string.char(#methods) .. methods))
  return read_exact(conn, 2)
end

--- The username and password message for `user` and `password`.
local function auth_message(user: string, password: string): string
  return "\1" .. string.char(#user) .. user .. string.char(#password) .. password
end

--- Whether `conn` has ended what it sends, within a moment.
local function ended(conn: Net.Conn): boolean
  conn:set_timeout(Clock.seconds(5))
  local data, _ = conn:read(1)
  return data == nil
end

local function test_a_token_lets_a_connect_with_its_basic_credential_through(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local grants = { "127.0.0.1:" .. server.port }
    local rig = start(tmp, { grants = grants, token = TOKEN })
    -- Any user name does, and a password may hold a colon after the first.
    for _, user in ipairs({ "cosmic", "", "someone else" }) do
      local conn, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic(user, TOKEN) })
      assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
      assert(conn:write("ping"))
      assert(read_exact(conn, 4) == "ping")
      local _, _ = conn:close()
    end
    -- The scheme's name is no case.
    local lower, lowered = connect_to(rig, "127.0.0.1:" .. server.port,
      { "proxy-authorization: bAsIc " .. Codec.base64("u:" .. TOKEN) })
    assert(status_line(lowered) == "HTTP/1.1 200 Connection established", lowered)
    local _, _ = lower:close()
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    assert(rig.server:stats().accepted == 4, "each is counted once it has authenticated")
    assert(#lines_with(rig, "not authenticated") == 0, table.concat(rig.log, "\n"))
    finish(rig, server)
  end)
end

local function test_a_connect_without_the_token_gets_407_and_reaches_nothing(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local grants = { "127.0.0.1:" .. server.port }
    local rig = start(tmp, { grants = grants, token = TOKEN })
    local wrong = "WRONG-secret-9"
    local cases: {{string}} = {
      {},
      { basic("u", wrong) },
      { basic("u", TOKEN:sub(1, -2)) },
      { basic("u", TOKEN .. "x") },
      { basic("u", "") },
      { "Proxy-Authorization: Bearer " .. TOKEN },
      { "Proxy-Authorization: Basic !!not-base64!!" },
      { "Proxy-Authorization: Basic " .. Codec.base64(TOKEN) },
      { "Proxy-Authorization: Basic" },
      { "Authorization: Basic " .. Codec.base64("u:" .. TOKEN) },
    }
    local replies: {string} = {}
    for _, headers in ipairs(cases) do
      local conn, head = connect_to(rig, "127.0.0.1:" .. server.port, headers)
      replies[#replies + 1] = head
      assert(status_line(head) == "HTTP/1.1 407 Proxy Authentication Required", head)
      assert(head:find('Proxy-Authenticate: Basic realm="cosmic sandbox"\r\n', 1, true), head)
      assert(ended(conn), "the relay closes after the 407")
      local _, _ = conn:close()
    end
    assert(server.connections == 0 and #rig.asked == 0, "nothing reached the upstream")
    assert(#lines_with(rig, "allowed") == 0, "an unauthenticated attempt is no flow")
    assert(#lines_with(rig, "refused: not authenticated") == #cases, table.concat(rig.log, "\n"))
    -- No credential, right or wrong, is in a reply or a line.
    local everything = table.concat(rig.log, "\n") .. table.concat(replies)
    for _, secret in ipairs({ TOKEN, wrong, Codec.base64("u:" .. wrong), Codec.base64("u:" .. TOKEN),
        Codec.base64(TOKEN) }) do
      assert(not everything:find(secret, 1, true), "a credential was echoed: " .. secret:sub(1, 4) .. "...")
    end
    local stats = rig.server:stats()
    assert(stats.accepted == 0 and stats.open == 0 and stats.refused == #cases, "none of them is counted as served")
    finish(rig, server)
  end)
end

local function test_a_socks5_client_with_the_password_goes_through(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN })
    -- Offering "no authentication" too, the relay still selects the password.
    local conn = dial(rig.socks)
    assert(socks_greet(conn, "\0\2") == "\5\2")
    assert(conn:write(auth_message("whoever", TOKEN)))
    assert(read_exact(conn, 2) == "\1\0")
    assert(conn:write(Fixture.socks_request(1, 1, "\127\0\0\1", server.port)))
    assert(read_exact(conn, 10):byte(2) == 0, "the request is served")
    assert(conn:write("socks"))
    assert(read_exact(conn, 5) == "socks")
    -- The whole exchange in one write, and the request's first byte split off.
    local pipelined = dial(rig.socks)
    local request = Fixture.socks_request(1, 1, "\127\0\0\1", server.port)
    assert(pipelined:write("\5\1\2"))
    assert(read_exact(pipelined, 2) == "\5\2")
    assert(pipelined:write(auth_message("u", TOKEN) .. request:sub(1, 1)))
    assert(read_exact(pipelined, 2) == "\1\0")
    assert(pipelined:write(request:sub(2) .. "tail"))
    assert(read_exact(pipelined, 10):byte(2) == 0)
    assert(read_exact(pipelined, 4) == "tail")
    local _, _ = conn:close()
    local _, _ = pipelined:close()
    assert(#lines_with(rig, "not authenticated") == 0, table.concat(rig.log, "\n"))
    finish(rig, server)
  end)
end

--- One listener serves both protocols, each connection read as its first
--- byte says, behind the token: a CONNECT and a SOCKS5 client each reach a
--- granted server, a request in either without the token is refused, and
--- a connection that sends nothing is refused at the auth timeout.
local function test_a_mixed_listener_reads_each_connection_as_its_first_byte_says(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local grants = { "127.0.0.1:" .. server.port }
    local rig = start(tmp, { grants = grants, token = TOKEN, mixed = true,
      timeouts = { auth = Clock.ms(300) } })
    assert(rig.http.port == rig.socks.port)
    local conn, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic("cosmic", TOKEN) })
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    assert(conn:write("over-connect"))
    assert(read_exact(conn, 12) == "over-connect")
    local _, _ = conn:close()
    local socks = dial(rig.socks)
    assert(socks_greet(socks, "\2") == "\5\2")
    assert(socks:write(auth_message("cosmic", TOKEN)))
    assert(read_exact(socks, 2) == "\1\0")
    assert(socks:write(Fixture.socks_request(1, 1, "\127\0\0\1", server.port)))
    assert(read_exact(socks, 10):byte(2) == 0, "the request is served")
    assert(socks:write("over-socks"))
    assert(read_exact(socks, 10) == "over-socks")
    local _, _ = socks:close()
    local bare, refused = connect_to(rig, "127.0.0.1:" .. server.port)
    assert(status_line(refused) == "HTTP/1.1 407 Proxy Authentication Required", refused)
    local _, _ = bare:close()
    local unauthenticated = dial(rig.socks)
    assert(socks_greet(unauthenticated, "\0") == "\5\255")
    local _, _ = unauthenticated:close()
    local silent = dial(rig.http)
    assert(ended(silent), "a connection that sends nothing is closed")
    local _, _ = silent:close()
    until_it(function(): boolean
      return #lines_with(rig, "mixed: refused: nothing received") == 1
    end)
    assert(server.connections == 2, "only the two with the token reached the server")
    assert(#lines_with(rig, "connect 127.0.0.1:" .. server.port .. ": allowed") == 1, table.concat(rig.log, "\n"))
    assert(#lines_with(rig, "socks5 127.0.0.1:" .. server.port .. ": allowed") == 1, table.concat(rig.log, "\n"))
    finish(rig, server)
  end)
end

local function test_a_socks5_greeting_without_the_password_method_gets_no_acceptable_method(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN })
    for _, methods in ipairs({ "\0", "\0\1\3" }) do
      local conn = dial(rig.socks)
      assert(socks_greet(conn, methods) == "\5\255")
      assert(ended(conn))
      local _, _ = conn:close()
    end
    assert(#lines_with(rig, "refused: the sandbox's token needs username/password") == 2, table.concat(rig.log, "\n"))
    assert(server.connections == 0 and #rig.asked == 0)
    assert(rig.server:stats().accepted == 0)
    finish(rig, server)
  end)
end

local function test_a_socks5_client_with_a_wrong_password_fails_authentication(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN })
    local wrong = "WRONG-secret-9"
    local replies = ""
    local messages = {
      auth_message("u", wrong), auth_message("u", TOKEN:sub(1, -2)), auth_message("u", TOKEN .. "!"),
      "\2\1u\1p", "\1\0\1p", "\1\1u\0",
    }
    for _, message in ipairs(messages) do
      local conn = dial(rig.socks)
      assert(socks_greet(conn, "\2") == "\5\2")
      assert(conn:write(message))
      local answer = read_exact(conn, 2)
      replies = replies .. answer
      assert(answer == "\1\1", "authentication fails")
      assert(ended(conn), "and the relay closes")
      local _, _ = conn:close()
    end
    -- A request sent in place of the credentials is no credential.
    local early = dial(rig.socks)
    assert(socks_greet(early, "\2") == "\5\2")
    assert(early:write(Fixture.socks_request(1, 1, "\127\0\0\1", server.port)))
    assert(read_exact(early, 2) == "\1\1" and ended(early))
    local _, _ = early:close()
    assert(server.connections == 0 and #rig.asked == 0, "nothing reached the upstream")
    assert(#lines_with(rig, "allowed") == 0)
    local everything = table.concat(rig.log, "\n") .. replies
    assert(not everything:find(TOKEN, 1, true) and not everything:find(wrong, 1, true), "a credential was echoed")
    assert(rig.server:stats().accepted == 0)
    finish(rig, server)
  end)
end

local function test_connections_not_yet_authenticated_do_not_spend_the_cap(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN,
      limits = { connections = 1, total = 2 } })
    -- Connections that say nothing, and ones refused, on both listeners.
    local idle: {Net.Conn} = {}
    for _ = 1, 5 do
      idle[#idle + 1] = dial(rig.http)
      idle[#idle + 1] = dial(rig.socks)
    end
    for _ = 1, 3 do
      local refused, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", "no") })
      assert(status_line(head):find("^HTTP/1.1 407 "), head)
      local _, _ = refused:close()
    end
    -- One authenticated connection is within `connections`, the next is not,
    -- and `total` is not spent by any of the above.
    local first, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", TOKEN) })
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    local second, over = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", TOKEN) })
    assert(status_line(over):find("^HTTP/1.1 503 too many open connections: at most 1 at once", 1), over)
    local _, _ = second:close()
    until_it(function(): boolean return rig.server:stats().open == 1 end)
    local stats = rig.server:stats()
    assert(stats.accepted == 2, ("accepted %d"):format(stats.accepted))
    local _, _ = first:close()
    for _, conn in ipairs(idle) do local _, _ = conn:close() end
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    finish(rig, server)
  end)
end

local function test_connections_not_yet_authenticated_are_bounded_in_number_and_in_time(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN,
      limits = { pre_auth = 1 }, timeouts = { auth = Clock.ms(300), head = Clock.seconds(30) } })
    local silent = dial(rig.http)
    -- A second connection is not served while the first holds the one slot.
    local waiting = dial(rig.http)
    assert(waiting:write(Fixture.connect("127.0.0.1:" .. server.port, { basic("u", TOKEN) })))
    waiting:set_timeout(Clock.ms(100))
    local early, why = waiting:read(1)
    assert(early == nil and why == Poll.TIMEOUT, "it waits for a slot")
    -- The auth timeout ends the silent one, and the waiting one is served.
    waiting:set_timeout(Clock.seconds(5))
    local head = read_head(waiting)
    assert(status_line(head):find("^HTTP/1.1 200 "), head)
    assert(#lines_with(rig, "request and credential not received within 300 milliseconds") == 1, table.concat(rig.log, "\n"))
    assert(read_all(silent):find("408 request and credential not received", 1, true), "the silent connection was refused and closed")
    local _, _ = silent:close()
    local _, _ = waiting:close()
    finish(rig, server)
  end)
end

local function test_without_a_token_no_credential_is_asked_or_read(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port } })
    -- A credential that is sent is not looked at.
    local conn, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", "anything") })
    assert(status_line(head) == "HTTP/1.1 200 Connection established", head)
    local _, _ = conn:close()
    -- A SOCKS5 client offering both methods gets no authentication, and one
    -- offering only a password gets none acceptable.
    local socks = dial(rig.socks)
    assert(socks_greet(socks, "\0\2") == "\5\0")
    assert(socks:write(Fixture.socks_request(1, 1, "\127\0\0\1", server.port)))
    assert(read_exact(socks, 10):byte(2) == 0)
    local _, _ = socks:close()
    local only = dial(rig.socks)
    assert(socks_greet(only, "\2") == "\5\255")
    local _, _ = only:close()
    until_it(function(): boolean return rig.server:stats().open == 0 end)
    assert(rig.server:stats().accepted == 3, "every connection is counted as it is accepted")
    finish(rig, server)
  end)
end

local function test_a_token_with_colons_is_matched_as_the_whole_password(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local colons = "a:b::c:0123456789abcdef"
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = colons })
    local conn, head = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u:v", colons) })
    -- The user ends at the first colon, so "u:v" with this token is the password "v:" .. token.
    assert(status_line(head):find("^HTTP/1.1 407 "), head)
    local _, _ = conn:close()
    local good, answer = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", colons) })
    assert(status_line(answer):find("^HTTP/1.1 200 "), answer)
    local _, _ = good:close()
    local partial, refused = connect_to(rig, "127.0.0.1:" .. server.port, { basic("u", "b::c:0123456789abcdef") })
    assert(status_line(refused):find("^HTTP/1.1 407 "), refused)
    local _, _ = partial:close()
    local socks = dial(rig.socks)
    assert(socks_greet(socks, "\2") == "\5\2")
    assert(socks:write(auth_message("u", colons)))
    assert(read_exact(socks, 2) == "\1\0")
    local _, _ = socks:close()
    finish(rig, server)
  end)
end

local function test_authenticating_has_its_own_short_wait_and_the_request_its_own_after_it(tmp: string)
  Poll.run(function()
    local server = origin(echo)
    local rig = start(tmp, { grants = { "127.0.0.1:" .. server.port }, token = TOKEN,
      timeouts = { auth = Clock.ms(200), head = Clock.seconds(30) } })
    -- A SOCKS5 client that greets and then stalls is closed after the auth wait.
    local stalled = dial(rig.socks)
    assert(socks_greet(stalled, "\2") == "\5\2")
    local started = Clock.monotonic_ns()
    assert(read_all(stalled) == "", "closed without a reply")
    assert(Clock.monotonic_ns() - started < Clock.seconds(5), "long before the head timeout")
    assert(#lines_with(rig, "greeting and credential not received within 200 milliseconds") == 1,
      table.concat(rig.log, "\n"))
    local _, _ = stalled:close()
    -- A CONNECT head dribbled past it is refused with a 408.
    local slow = dial(rig.http)
    assert(slow:write("CONNECT 127.0.0.1:80 HTTP/1.1\r\n"))
    assert(read_all(slow):find("408 request and credential not received within 200 milliseconds", 1, true))
    local _, _ = slow:close()
    -- A client that authenticates in time may take longer than the auth wait over its request.
    local late = dial(rig.socks)
    assert(socks_greet(late, "\2") == "\5\2")
    assert(late:write(auth_message("u", TOKEN)))
    assert(read_exact(late, 2) == "\1\0")
    assert(Poll.delay(Clock.ms(500)))
    assert(late:write(Fixture.socks_request(1, 1, "\127\0\0\1", server.port)))
    assert(read_exact(late, 10):byte(2) == 0, "the request has the head wait")
    local _, _ = late:close()
    finish(rig, server)
  end)
end
