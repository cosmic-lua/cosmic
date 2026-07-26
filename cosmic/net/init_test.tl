#!/usr/bin/env cosmic
local check = require("cosmic.check")
local net = require("cosmic.net")
local proc = require("cosmic.proc")

local function test_socket_creation()
  -- Test TCP socket creation
  local tcp = check.must(net.socket())
  assert(tcp.fd > 0, "expected valid fd, got " .. tostring(tcp.fd))
  tcp:close()

  -- Test UDP socket creation
  local udp = check.must(net.socket(net.AF_INET, net.SOCK_DGRAM))
  udp:close()
end
test_socket_creation()

local function test_socketpair()
  local raw_sock1, sock2, err = net.socketpair()
  assert(raw_sock1 ~= nil and sock2 ~= nil, "socketpair failed: " .. tostring(err))
  local sock1 = check.must(raw_sock1)

  -- Test sending data between the pair
  local sent, send_err = sock1:send("hello")
  assert(sent == 5, "expected 5 bytes sent, got " .. tostring(sent) .. ": " .. tostring(send_err))

  local data, recv_err = sock2:recv(100)
  assert(data == "hello", "expected 'hello', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  sock1:close()
  sock2:close()
end
test_socketpair()

local function test_send_to_closed_peer_returns_error()
  -- Regression: sending to a peer that has closed must return nil, err --
  -- NOT kill the process with SIGPIPE (which surfaces as exit 141, an
  -- unambiguous red before send() ORed in MSG_NOSIGNAL).
  local raw_a, b, err = net.socketpair()
  assert(raw_a ~= nil and b ~= nil, "socketpair failed: " .. tostring(err))
  local a = check.must(raw_a)
  b:close()

  -- Loop so a kernel that accepts the first write into the buffer before
  -- reporting EPIPE still exercises the error path; without the fix the
  -- first EPIPE-triggering write signals SIGPIPE and the test never returns.
  local n, serr: number | nil, string
  for _ = 1, 1000 do
    n, serr = a:send("data")
    if n == nil then break end
  end
  assert(n == nil, "send to closed peer should return nil, got " .. tostring(n))
  assert(serr and serr:match("EPIPE"), "send error should name EPIPE, got: " .. tostring(serr))
  a:close()
end
test_send_to_closed_peer_returns_error()

local function test_bind_and_getsockname()
  local sock = check.must(net.socket())

  -- Bind to ephemeral port on all interfaces
  local ok, bind_err = sock:bind("0.0.0.0", 0)
  assert(ok, "bind failed: " .. tostring(bind_err))

  local addr, port, name_err = sock:getsockname()
  assert(addr ~= nil, "getsockname failed: " .. tostring(name_err))
  assert(check.must(addr).family == "inet", "local address must be a typed Addr")
  assert(port > 0, "expected non-zero port, got " .. tostring(port))

  sock:close()
end
test_bind_and_getsockname()

local function test_listen_accept_connect()
  -- Create server socket
  local server = check.must(net.socket())

  local ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(err))

  ok, err = server:bind("0.0.0.0", 0)
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = proc.fork()
  if pid == 0 then
    -- Child: connect to server
    local raw_client = net.socket()
    if not raw_client then
      os.exit(1)
    end
    local client = check.must(raw_client)
    -- Connect to localhost
    local connect_ok = client:connect("127.0.0.1", server_port) -- 127.0.0.1
    if not connect_ok then
      os.exit(2)
    end
    local sent = client:send("hello from client")
    if not sent then
      os.exit(3)
    end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, client_ip, client_port, accept_err = server:accept()
  assert(raw_client ~= nil, "accept failed: " .. tostring(accept_err))
  assert(client_ip ~= nil, "expected raw_client IP")
  assert(client_ip.family == "inet", "peer address must be a typed Addr")
  assert(client_ip:is_loopback(), "peer should be loopback, got " .. client_ip:format())
  assert(client_port ~= nil and client_port > 0, "expected raw_client port")
  local client = check.must(raw_client)

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from client", "expected 'hello from client', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  -- Get peer name
  local peer_ip, peer_port, peer_err = client:getpeername()
  assert(peer_ip ~= nil, "getpeername failed: " .. tostring(peer_err))
  assert(peer_port == client_port, "peer port mismatch")

  client:close()
  server:close()

  -- Wait for child
  proc.wait(pid)
end
test_listen_accept_connect()

local function test_gethostname()
  local name, err = net.gethostname()
  assert(name ~= nil, "gethostname failed: " .. tostring(err))
  assert(#name > 0, "expected non-empty hostname")
end
test_gethostname()

local function test_shutdown()
  local raw_sock1, sock2, err = net.socketpair()
  assert(raw_sock1 ~= nil and sock2 ~= nil, "socketpair failed: " .. tostring(err))
  local sock1 = check.must(raw_sock1)

  -- Shutdown write side of sock1
  local ok, shutdown_err = sock1:shutdown(net.SHUT_WR)
  assert(ok, "shutdown failed: " .. tostring(shutdown_err))

  -- sock2 should now get end-of-stream when reading: bare nil, no error
  local data, recv_err = sock2:recv()
  assert(data == nil, "expected nil after shutdown, got '" .. tostring(data) .. "'")
  assert(recv_err == nil, "EOF must carry no error, got: " .. tostring(recv_err))

  sock1:close()
  sock2:close()
end
test_shutdown()

local function test_poll_readiness()
  -- net.poll was a duplicate of cosmic.poll and is gone; sockets compose
  -- with the Poller directly via their fd.
  local poll = require("cosmic.poll")
  local raw_sock1, sock2, err = net.socketpair()
  assert(raw_sock1 ~= nil and sock2 ~= nil, "socketpair failed: " .. tostring(err))
  local sock1 = check.must(raw_sock1)

  -- Send data on sock1
  sock1:send("hello")

  local poller = poll.new()
  poller:add(sock2.fd, poll.POLLIN)
  local ready, poll_err = poller:poll(1000)
  assert(ready == 1, "expected one ready fd: " .. tostring(poll_err))
  local ev = check.must(poller:events(sock2.fd))
  assert(ev.readable, "expected socket to be readable")

  sock1:close()
  sock2:close()
end
test_poll_readiness()

local function test_udp_sendto_recvfrom()
  -- Create two UDP sockets
  local sender = check.must(net.socket(net.AF_INET, net.SOCK_DGRAM))

  local receiver = check.must(net.socket(net.AF_INET, net.SOCK_DGRAM))

  -- Bind receiver to ephemeral port
  local ok, bind_err = receiver:bind("127.0.0.1", 0)
  assert(ok, "bind failed: " .. tostring(bind_err))

  local _, recv_port = receiver:getsockname()
  assert(recv_port > 0, "expected non-zero port")

  -- Send datagram
  local sent, send_err = sender:sendto("hello udp", "127.0.0.1", recv_port)
  assert(sent == 9, "expected 9 bytes sent, got " .. tostring(sent) .. ": " .. tostring(send_err))

  -- Receive datagram: the sender address arrives as a typed ip.Addr
  local data, from_ip, from_port, recv_err = receiver:recvfrom(100)
  assert(data == "hello udp", "expected 'hello udp', got '" .. tostring(data) .. "': " .. tostring(recv_err))
  assert(from_ip ~= nil, "expected sender IP")
  assert(from_ip.family == "inet", "sender address must be a typed Addr")
  assert(from_ip:format() == "127.0.0.1", "expected loopback sender, got " .. from_ip:format())
  assert(from_port ~= nil and from_port > 0, "expected sender port")

  sender:close()
  receiver:close()
end
test_udp_sendto_recvfrom()

local function test_socket_options()
  local sock = check.must(net.socket())

  -- Set TCP_NODELAY
  local ok, setopt_err = sock:setsockopt(net.SOL_TCP, net.TCP_NODELAY, true)
  assert(ok, "setsockopt TCP_NODELAY failed: " .. tostring(setopt_err))

  -- Get TCP_NODELAY. Pledge's getsockopt allowlist omits TCP_NODELAY
  -- (setsockopt allows it), so the sandboxed test lane skips
  -- this readback on denial; the enforce lane runs it for real.
  local val, getopt_err = sock:getsockopt(net.SOL_TCP, net.TCP_NODELAY)
  if val == nil and tostring(getopt_err):find("EPERM") then
    check.skip("getsockopt TCP_NODELAY denied by sandbox")
    sock:close()
    return
  end
  assert(val ~= nil, "getsockopt TCP_NODELAY failed: " .. tostring(getopt_err))
  -- Value should be truthy (1 or true)
  assert(val == 1 or val == true, "expected TCP_NODELAY to be set")

  sock:close()
end
test_socket_options()

local function test_constants_exist()
  -- Address families
  assert(net.AF_INET ~= nil, "AF_INET not defined")
  assert(net.AF_UNIX ~= nil, "AF_UNIX not defined")
  assert(net.AF_UNSPEC ~= nil, "AF_UNSPEC not defined")

  -- Socket types
  assert(net.SOCK_STREAM ~= nil, "SOCK_STREAM not defined")
  assert(net.SOCK_DGRAM ~= nil, "SOCK_DGRAM not defined")

  -- Protocols
  assert(net.IPPROTO_TCP ~= nil, "IPPROTO_TCP not defined")
  assert(net.IPPROTO_UDP ~= nil, "IPPROTO_UDP not defined")

  -- Socket levels
  assert(net.SOL_SOCKET ~= nil, "SOL_SOCKET not defined")
  assert(net.SOL_TCP ~= nil, "SOL_TCP not defined")

  -- Socket options
  assert(net.SO_REUSEADDR ~= nil, "SO_REUSEADDR not defined")
  assert(net.TCP_NODELAY ~= nil, "TCP_NODELAY not defined")

  -- Shutdown modes
  assert(net.SHUT_RD ~= nil, "SHUT_RD not defined")
  assert(net.SHUT_WR ~= nil, "SHUT_WR not defined")
  assert(net.SHUT_RDWR ~= nil, "SHUT_RDWR not defined")

  -- Poll events
  assert(net.POLLIN ~= nil, "POLLIN not defined")
  assert(net.POLLOUT ~= nil, "POLLOUT not defined")

  -- Message flags
  assert(net.MSG_PEEK ~= nil, "MSG_PEEK not defined")
  assert(net.MSG_WAITALL ~= nil, "MSG_WAITALL not defined")
end
test_constants_exist()

local function test_socket_closed_method()
  local sock = check.must(net.socket())

  -- Socket should not be closed initially
  assert(sock:closed() == false, "expected socket to not be closed initially")

  -- Close the socket
  sock:close()

  -- Socket should be closed now
  assert(sock:closed() == true, "expected socket to be closed after close()")

  -- Closing again should be idempotent
  local ok = sock:close()
  assert(ok == true, "expected close() to be idempotent")
  assert(sock:closed() == true, "expected socket to remain closed")
end
test_socket_closed_method()

local function test_socket_methods_after_close()
  local sock = check.must(net.socket())
  sock:close()

  -- Every operation on a closed socket must return its error shape, never
  -- throw from the C binding (unix.send(nil, ...) etc.).
  local n, serr = sock:send("x")
  assert(n == nil and serr == "socket closed", "send: " .. tostring(serr))
  local d, rerr = sock:recv()
  assert(d == nil and rerr == "socket closed", "recv: " .. tostring(rerr))
  local addr, port, gerr = sock:getsockname()
  assert(addr == nil and port == nil and gerr == "socket closed",
    "getsockname: " .. tostring(gerr))
  local bok, berr = sock:bind()
  assert(bok == false and berr == "socket closed", "bind: " .. tostring(berr))
  local lok, lerr = sock:listen()
  assert(lok == false and lerr == "socket closed", "listen: " .. tostring(lerr))
  local shok, sherr = sock:shutdown()
  assert(shok == false and sherr == "socket closed", "shutdown: " .. tostring(sherr))
end
test_socket_methods_after_close()

local function test_socket_has_close_metamethod()
  -- Verify socket has __close metamethod for Lua 5.4 to-be-closed support
  local sock = check.must(net.socket())

  -- Get the metatable and verify __close exists
  local mt = getmetatable(sock)
  assert(mt ~= nil, "expected socket to have a metatable")
  assert(mt.__close ~= nil, "expected socket metatable to have __close")
  assert(type(mt.__close) == "function", "expected __close to be a function")

  -- Test that __close calls close(): leaving a <close> scope closes it
  assert(sock:closed() == false, "expected socket to not be closed")
  do
    local _ < close > = sock
  end
  assert(sock:closed() == true, "expected socket to be closed after __close")

  -- __close should be idempotent (via close())
  do
    local _ < close > = sock
  end
  assert(sock:closed() == true, "expected socket to remain closed")
end
test_socket_has_close_metamethod()

local function test_socketpair_has_close_metamethod()
  -- Verify socketpair sockets also have __close
  local raw_sock1, sock2, err = net.socketpair()
  assert(raw_sock1 ~= nil and sock2 ~= nil, "socketpair failed: " .. tostring(err))
  local sock1 = check.must(raw_sock1)

  local mt1 = getmetatable(sock1)
  local mt2 = getmetatable(sock2)
  assert(mt1 ~= nil and mt1.__close ~= nil, "expected sock1 to have __close")
  assert(mt2 ~= nil and mt2.__close ~= nil, "expected sock2 to have __close")

  sock1:close()
  sock2:close()
end
test_socketpair_has_close_metamethod()

local function test_accept_socket_has_close_metamethod()
  -- Create server socket
  local server = check.must(net.socket())

  local ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(err))

  ok, err = server:bind("0.0.0.0", 0)
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = proc.fork()
  if pid == 0 then
    local raw_client = net.socket()
    if not raw_client then os.exit(1) end
    local client = check.must(raw_client)
    local connect_ok = client:connect("127.0.0.1", server_port)
    if not connect_ok then os.exit(2) end
    client:send("test")
    client:close()
    os.exit(0)
  end

  -- Accept and verify __close exists on accepted socket
  local raw_client, _, _, accept_err = server:accept()
  assert(raw_client ~= nil, "accept failed: " .. tostring(accept_err))
  local client = check.must(raw_client)

  local mt = getmetatable(client)
  assert(mt ~= nil and mt.__close ~= nil, "expected accepted socket to have __close")

  local data = client:recv()
  assert(data == "test", "expected 'test', got '" .. tostring(data) .. "'")

  client:close()
  server:close()
  proc.wait(pid)
end
test_accept_socket_has_close_metamethod()

local function test_listen_tcp_ephemeral_port()
  -- listen_tcp with port 0 should return a listening socket and a port > 0
  local raw_srv, port, err = net.listen_tcp("127.0.0.1", 0)
  assert(raw_srv ~= nil, "listen_tcp failed: " .. tostring(err))
  assert(port ~= nil and port > 0, "expected non-zero port, got " .. tostring(port))
  local srv = check.must(raw_srv)
  srv:close()
end
test_listen_tcp_ephemeral_port()

local function test_listen_tcp_connect_to_returned_port()
  -- bind on 127.0.0.1:0, then connect_tcp to the returned port
  local raw_srv, port, serr = net.listen_tcp("127.0.0.1", 0)
  assert(raw_srv ~= nil, "listen_tcp failed: " .. tostring(serr))
  assert(port > 0, "expected non-zero port")
  local srv = check.must(raw_srv)

  -- Fork: child connects and sends, parent accepts and reads
  local pid = proc.fork()
  if pid == 0 then
    local raw_csock = net.connect_tcp("127.0.0.1", port)
    if not raw_csock then
      os.exit(1)
    end
    local csock = check.must(raw_csock)
    csock:send("hi")
    csock:close()
    os.exit(0)
  end

  local raw_conn, _, _, aerr = srv:accept()
  assert(raw_conn ~= nil, "accept failed: " .. tostring(aerr))
  local conn = check.must(raw_conn)
  local data = conn:recv()
  assert(data == "hi", "expected 'hi', got '" .. tostring(data) .. "'")
  conn:close()
  srv:close()
  proc.wait(pid)
end
test_listen_tcp_connect_to_returned_port()

local function test_listen_tcp_double_bind_same_port_fails()
  -- Bind a specific port, then try to bind the same port again without
  -- REUSEPORT; the second listen_tcp should fail.
  local raw_srv, port, serr = net.listen_tcp("127.0.0.1", 0)
  assert(raw_srv ~= nil, "first listen_tcp failed: " .. tostring(serr))
  assert(port > 0, "expected non-zero port")
  local srv = check.must(raw_srv)

  -- Second bind to the same explicit port should fail (SO_REUSEADDR alone
  -- does not allow two listeners on the same port simultaneously)
  local srv2, _, serr2 = net.listen_tcp("127.0.0.1", port)
  assert(srv2 == nil, "expected second listen_tcp to fail on same port")
  assert(serr2 ~= nil, "expected error message from second listen_tcp")

  srv:close()
end
test_listen_tcp_double_bind_same_port_fails()

local function test_listen_tcp_invalid_ip_bind_fails()
  -- Attempt to bind to a non-local IP should fail
  local srv, _, serr = net.listen_tcp("1.2.3.4", 0) -- not a local address
  assert(srv == nil, "expected listen_tcp to fail on non-local IP")
  assert(serr ~= nil, "expected error message")
end
test_listen_tcp_invalid_ip_bind_fails()
