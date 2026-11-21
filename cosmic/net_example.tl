--- Worked examples for [`cosmic.net`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

--- The TCP and UDP examples bind on the worker's own loopback.
Test.policy{ loopback = { "127.0.0.1" } }

local Example = {} -- checked: literal_needs_type

--- A server on the loopback at a port the kernel chose: `close` (here, the
--- `<close>` variable going out of scope) closes its listener. Every wait is
--- bounded by `timeout_ns`, which a connection accepted inherits. A socket
--- file is made by [`Net.unix`]'s address instead.
function Example.listen()
  do
    local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
    local client <close> = assert(Net.connect(server.address))
    local conn <close> = assert(server:accept())
    assert(client:write("ping\n"))
    local line = assert(Stream.lines(conn):read())
    print(line)
    assert(line == "ping", line)
  end
end

--- A request and its answer: `shutdown("write")` tells the server the
--- request is whole while the client still reads what comes back. This
--- suits a request that ends at end of file. After a framed request (HTTP,
--- a length prefix) do not half-close: a server may take the half-close as
--- the client closing and answer nothing. For HTTP over a unix socket use
--- [`Http.request`] with `via`. The server's end is closed when its block
--- ends, which the client's read of the answer waits for.
function Example.connect()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
  assert(client:write("status"))
  assert(client:shutdown("write"))
  do
    local conn <close> = assert(server:accept())
    local request = assert(Stream.read_all(conn))
    assert(conn:write(if request == "status" then "ok" else "unknown" end))
  end
  local answer = assert(Stream.read_all(client))
  print(answer)
  assert(answer == "ok", answer)
end

--- A TCP server on the loopback at a port the kernel chose, which the
--- listener's `address` names for a client to connect to.
function Example.tcp()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  print(assert(server.address.port) > 0)
  local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
  local conn <close> = assert(server:accept())
  assert(client:write("hello"))
  assert(assert(conn:read()) == "hello")
end

--- UDP: [`Net.datagram`] binds a socket, and each `send` and `receive`
--- is one whole datagram, to or from an address of its own. Nothing is
--- connected, so the receiver answers the address its packet came from.
function Example.datagram()
  local server <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
  local client <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
  assert(client:send("ping", server.address))
  local question = assert(server:receive(Clock.seconds(5)))
  assert(server:send("pong", question.address))
  local answer = assert(client:receive(Clock.seconds(5)))
  print(question.data, answer.data)
  assert(question.data == "ping" and answer.data == "pong")
end

--- The loopback interface's IPv4 address, which names it as the `via`
--- of an IPv4 group, from [`Net.interfaces`].
local function loopback_address(): string
  for _, interface in ipairs((assert(Net.interfaces()))) do
    if interface.loopback and interface.up then
      for _, address in ipairs(interface.addresses) do
        if address.family == "ipv4" then return address.address end
      end
    end
  end
  error("no loopback interface has an IPv4 address")
end

--- [`Net.interfaces`] lists the machine's interfaces, to pick the `via`
--- of a multicast call from: an IPv4 group takes one of the interface's
--- IPv4 addresses, an IPv6 group its `index`.
function Example.interfaces()
  for _, interface in ipairs((assert(Net.interfaces()))) do
    print(interface.name, interface.index, interface.up, interface.multicast, #interface.addresses)
  end
  local via = loopback_address()
  print(via)
  assert(via:find("127.", 1, true) == 1, via)
end

--- Multicast: a socket that joins a group receives what any socket
--- sends to the group at its port. Bound to the group and `shared`, it
--- leaves the port to the other members on the machine. The sender needs
--- no membership, only `set_multicast` to say which interface its
--- datagrams leave by, here the loopback, and how far they go.
function Example.multicast()
  local via = loopback_address()
  local group = "239.255.77.99"
  local member <close> = assert(Net.datagram(Net.udp(group, 0), { shared = true }))
  assert(member:join(group, via))
  local sender <close> = assert(Net.datagram(Net.udp(via, 0)))
  assert(sender:set_multicast({ via = via, hops = 1 }))
  assert(sender:send("hello, group", Net.udp(group, assert(member.address.port))))
  local packet = assert(member:receive(Clock.seconds(5)))
  print(packet.data)
  assert(packet.data == "hello, group")
  assert(member:leave(group, via))
end

--- A server that serves each connection in a task of its own, in a
--- task of [`Poll.run`]: while one connection waits to be read, the
--- others are served.
function Example.accept()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  Poll.run(function()
    Poll.spawn(function()
      for _ = 1, 2 do
        local conn = assert(server:accept())
        Poll.spawn(function()
          local name = assert(Stream.lines(conn):read())
          assert(conn:write("hello, " .. name .. "\n"))
          assert(conn:close())
        end)
      end
    end)
    local quiet <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
    local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
    assert(client:write("world\n"))
    local greeting = assert(Stream.lines(client):read())
    print(greeting)
    assert(greeting == "hello, world")
    assert(quiet:write("quiet\n"))
    assert(Stream.lines(quiet):read() == "hello, quiet")
  end)
end

--- A line-echo server on the loopback, each connection served in a
--- task of its own until [`Server.stop`]: here `on_ready`, called once
--- the server listens, is its client, and stops it once answered.
function Example.serve()
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    limits = { connections = 64 },
    timeout_ns = Clock.seconds(5),
    grace_ns = Clock.seconds(1),
    serve = function(conn: Net.Conn)
      local lines = Stream.lines(conn)
      for line in lines:each() do assert(conn:write(line .. "\n")) end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local client <close> = assert(Net.connect(assert(addresses[1]), { timeout_ns = Clock.seconds(5) }))
      assert(client:write("hello\n"))
      local answer = assert(Stream.lines(client):read())
      print(answer)
      assert(answer == "hello", answer)
      server:stop()
    end,
  })
end

--- A line-echo server at a port of the loopback for as long as its
--- client runs: the second function is the client, given the port, and
--- the server is gone once it returns.
function Example.with_loopback()
  Net.with_loopback(function(conn: Net.Conn)
    for line in Stream.lines(conn):each() do assert(conn:write(line .. "\n")) end
  end, function(port: integer)
    local client <close> = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(5) }))
    assert(client:write("hello\n"))
    local answer = assert(Stream.lines(client):read())
    print(answer)
    assert(answer == "hello", answer)
  end)
end

return Example -- checked: export_not_declared
