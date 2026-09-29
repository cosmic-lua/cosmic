local Child = require("cosmic.child")
local Net = require("cosmic.net")
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
