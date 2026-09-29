local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

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
local function test_a_port_held_is_refused_and_one_closed_refuses(tmp: string)
  local _ = tmp
  local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = server.address.port
  local again, taken = Net.listen(Net.tcp("127.0.0.1", port))
  assert(again == nil and taken == "127.0.0.1:" .. port .. ": Address in use", taken)
  assert(server:close())
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ms = 5000 })
  assert(conn == nil and why == "127.0.0.1:" .. port .. ": Connection refused", why)
  local reopened <close> = assert(Net.listen(Net.tcp("127.0.0.1", port)))
  assert(reopened.address.port == port)
end

--- A host is a numeric address: a name is refused, saying so, and a
--- port out of range is no address at all.
local function test_a_host_that_is_no_address_is_refused()
  local conn, why = Net.connect(Net.tcp("localhost", 80))
  assert(conn == nil and why:find("localhost:80: Invalid argument (a host is a numeric", 1,
    true) == 1, why)
  local server, listen_why = Net.listen(Net.tcp("::zz", 0))
  assert(server == nil and listen_why:find("[::zz]:0: Invalid argument", 1, true) == 1,
    listen_why)
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", 65536)))
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", -1)))
  assert(not pcall(Net.connect, { kind = "tcp", port = 1 } as Net.Address))
end
