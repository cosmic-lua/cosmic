local Child = require("cosmic.child")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

--- Each listener here is on the worker's own loopback.
Test.needs{ network = { "127.0.0.1" } }

local function test_a_tcp_listener_at_port_zero_names_the_port_it_has()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ms = 5000 }))
  local address = server.address
  assert(address.kind == "tcp" and address.host == "127.0.0.1", address.host)
  assert(address.port > 0 and address.port <= 65535, tostring(address.port))
  local client <close> = assert(Net.connect(address, { timeout_ms = 5000 }))
  local accepted <close> = assert(server:accept())
  assert(client:write("ping"))
  assert(client:shutdown("write"))
  assert(assert(Stream.read_all(accepted)) == "ping")
  assert(accepted:write("pong"))
  assert(accepted:close())
  assert(assert(Stream.read_all(client)) == "pong")
end

--- A port one listener holds is not another's; once it closes, nothing
--- listens there, and connecting is refused.
local function test_a_port_held_is_refused_and_one_closed_refuses()
  local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = server.address.port
  local again, taken = Net.listen(Net.tcp("127.0.0.1", port))
  assert(again == nil and taken == "127.0.0.1:" .. port .. ": Address in use", taken)
  assert(server:close())
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ms = 5000 })
  assert(conn == nil and why == "127.0.0.1:" .. port .. ": Connection refused", why)
end

--- A host is a numeric address: a name is refused, saying so, and a
--- port out of range is no address at all.
local function test_a_host_that_is_no_address_is_refused()
  local conn, why = Net.connect(Net.tcp("localhost", 80))
  assert(conn == nil and why:find("localhost:80: Invalid argument (not a numeric", 1,
    true) == 1, why)
  local server, listen_why = Net.listen(Net.tcp("::zz", 0))
  assert(server == nil and listen_why:find("[::zz]:0: Invalid argument", 1, true) == 1,
    listen_why)
  local nul, nul_why = Net.connect(Net.tcp("127.0.0.1\0junk", 1))
  assert(nul == nil and nul_why:find("Invalid argument", 1, true) ~= nil, nul_why)
  assert(not pcall(Net.connect, { kind = "tcp", host = "127.0.0.1", port = "1" } as Net.Address))
  assert(not pcall(Net.connect, { kind = "tcp", host = "127.0.0.1", port = 1.5 } as Net.Address))
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", 65536)))
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", -1)))
  assert(not pcall(Net.connect, { kind = "tcp", port = 1 } as Net.Address))
end

--- A connection waits for room at a listener whose backlog is full, as
--- long as its timeout, or until a guard catches a signal.
local function test_a_connection_to_a_full_backlog_times_out_or_is_interrupted()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { backlog = 1 }))
  local held: {Net.Conn} = {}
  local why = ""
  for _ = 1, 16 do
    local conn, trouble = Net.connect(server.address, { timeout_ms = 50 })
    if conn == nil then
      why = trouble
      break
    end
    held[#held + 1] = conn
  end
  local at = "127.0.0.1:" .. server.address.port .. ": "
  assert(why == at .. "timed out", why)
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local conn, interrupted = Net.connect(server.address)
  assert(assert(guard:release()) == sys.SIGINT)
  assert(conn == nil and interrupted == at .. "interrupted", interrupted)
  for _, held_conn in ipairs(held) do assert(held_conn:close()) end
end

--- In a task, a TCP connection waits to be made through the run: the
--- other tasks go on while one waits on a listener whose backlog is
--- full, until its time runs out. A connection that is made names its
--- peer, and one refused says so.
local function test_in_a_run_a_tcp_connect_waits_through_the_run()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0),
    { backlog = 1, timeout_ms = 5000 }))
  local held: {Net.Conn} = {}
  local ticks, ticks_at_end = 0, -1
  local why = ""
  Poll.run(function()
    local first = assert(Net.connect(server.address, { timeout_ms = 5000 }))
    held[#held + 1] = first
    local accepted = assert(server:accept())
    held[#held + 1] = accepted
    local client_peer = assert(first:peer())
    assert(client_peer.kind == "tcp" and client_peer.host == "127.0.0.1" and
      client_peer.port == server.address.port, tostring(client_peer.port))
    local accepted_peer = assert(accepted:peer())
    assert(accepted_peer.kind == "tcp" and accepted_peer.host == "127.0.0.1" and
      accepted_peer.port > 0 and accepted_peer.port ~= server.address.port,
      tostring(accepted_peer.port))
    local filling = Poll.spawn(function()
      for _ = 1, 16 do
        local conn, trouble = Net.connect(server.address, { timeout_ms = 200 })
        if conn == nil then
          why = trouble
          break
        end
        held[#held + 1] = conn
      end
      ticks_at_end = ticks
    end)
    while ticks_at_end < 0 do
      assert(Poll.delay(5))
      ticks = ticks + 1
    end
    assert(filling:join())
  end)
  for _, conn in ipairs(held) do assert(conn:close()) end
  assert(why == "127.0.0.1:" .. server.address.port .. ": timed out", why)
  assert(ticks_at_end > 0, "no other task ran while a connection waited")
  local port = server.address.port
  assert(server:close())
  local refused: Net.Conn
  Poll.run(function()
    refused, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ms = 5000 })
  end)
  assert(refused == nil and why == "127.0.0.1:" .. port .. ": Connection refused", why)
end

--- One protocol serves every listener, a TCP one and a unix one alike,
--- and on_ready is told the port the kernel chose for one at port 0.
local function test_a_server_names_what_it_bound_and_serves_every_listener(tmp: string)
  local bound: {Net.Address} = {}
  local answers: {string} = {}
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0), Net.unix(tmp .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      assert(conn:write(line:upper() .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      bound = addresses
      assert(server.addresses == addresses)
      for _, address in ipairs(addresses) do
        local conn <close> = assert(Net.connect(address, { timeout_ms = 5000 }))
        assert(conn:write(address.kind .. "\n"))
        answers[#answers + 1] = assert(Stream.lines(conn):read())
      end
      server:stop()
    end,
  })
  assert(bound[1].kind == "tcp" and bound[1].host == "127.0.0.1", bound[1].host)
  assert(bound[1].port > 0 and bound[1].port <= 65535, tostring(bound[1].port))
  assert(bound[2].kind == "unix" and bound[2].path == tmp .. "/s.sock", bound[2].path)
  assert(table.concat(answers, ",") == "TCP,UNIX", table.concat(answers, ","))
end
