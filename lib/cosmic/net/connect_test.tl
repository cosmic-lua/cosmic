#!/usr/bin/env cosmic
--- Network connect and interface tests.
local net = require("cosmic.net")
local fs = require("cosmic.fs")
local ip = require("cosmic.ip")
local proc = require("cosmic.proc")
local check = require("cosmic.check")

local function test_interfaces()
  local ifaces = check.must(net.interfaces())
  assert(type(ifaces) == "table", "expected table, got " .. type(ifaces))

  -- Should have at least the loopback interface
  local has_loopback = false
  for _, iface in ipairs(ifaces) do
    assert(iface.name ~= nil, "interface should have name")
    assert(iface.ip ~= nil, "interface should have ip")
    if iface.name == "lo" then
      has_loopback = true
      -- Loopback should be 127.0.0.1; Addr compares by value (__eq)
      assert(iface.ip == ip.addr(0x7f000001),
        "loopback should have 127.0.0.1, got " .. iface.ip:format())
    end
  end
  assert(has_loopback, "should have loopback interface")
end
test_interfaces()

local function test_interfaces_format()
  -- Test that we can format interface IPs
  local ifaces = check.must(net.interfaces())
  for _, iface in ipairs(ifaces) do
    local ip_str = iface.ip:format()
    assert(ip_str:match("^%d+%.%d+%.%d+%.%d+$"), "expected dotted IP format, got " .. ip_str)
  end
end
test_interfaces_format()

local function test_unix_domain_socket_bind_connect()
  local tmpdir = assert(fs.mkdtemp("/tmp/cosmic_net_test_XXXXXX"))
  local path = tmpdir .. "/test.sock"

  -- Create server socket
  local server = check.must(net.socket(net.AF_UNIX, net.SOCK_STREAM, 0))

  -- Bind to path
  local ok, err = server:bind_unix(path)
  assert(ok, "bind_unix failed: " .. tostring(err))

  -- Listen
  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.socket(net.AF_UNIX, net.SOCK_STREAM, 0))
    local connect_ok = client:connect_unix(path)
    if not connect_ok then os.exit(2) end
    local sent = client:send("hello from unix client")
    if not sent then os.exit(3) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from unix client", "expected 'hello from unix client', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  client:close()
  server:close()
  proc.wait(pid)
  os.remove(path)
  os.remove(tmpdir)
end
test_unix_domain_socket_bind_connect()

local function test_listen_unix_connect_unix()
  local tmpdir = assert(fs.mkdtemp("/tmp/cosmic_net_test_XXXXXX"))
  local path = tmpdir .. "/test.sock"

  -- Use module-level listen_unix helper
  local server = check.must(net.listen_unix(path))

  -- Fork to create a client using module-level connect_unix helper
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.connect_unix(path))
    local sent = client:send("hello from connect_unix")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from connect_unix", "expected 'hello from connect_unix', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  -- Verify accepted socket has __close
  local mt = getmetatable(client)
  assert(mt ~= nil and mt.__close ~= nil, "expected accepted unix socket to have __close")

  client:close()
  server:close()
  proc.wait(pid)
  os.remove(path)
  os.remove(tmpdir)
end
test_listen_unix_connect_unix()

local function test_nb_connect_loopback()
  -- Create a listening socket
  local server = check.must(net.socket())

  local ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(err))

  ok, err = server:bind("127.0.0.1", 0) -- 127.0.0.1
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- A plain blocking socket: nb_connect switches it to non-blocking
  -- itself via Socket:set_nonblocking (it used to silently block when
  -- handed a blocking socket).
  local client = check.must(net.socket())

  -- nb_connect to the listening server, by dotted-quad string
  ok, err = net.nb_connect(client, "127.0.0.1", server_port, 5000)
  assert(ok, "nb_connect failed: " .. tostring(err))

  -- Accept the connection on the server side
  local raw_accepted, _, _, accept_err = server:accept()
  local accepted = check.must(raw_accepted, "accept failed: " .. tostring(accept_err))

  -- Verify the connection works by sending data
  local sent, send_err = client:send("nb_hello")
  assert(sent == 8, "expected 8 bytes sent, got " .. tostring(sent) .. ": " .. tostring(send_err))

  local data, recv_err = accepted:recv(100)
  assert(data == "nb_hello", "expected 'nb_hello', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  client:close()
  accepted:close()
  server:close()
end
test_nb_connect_loopback()

local function test_nb_connect_refused()
  -- Create a non-blocking socket and try to connect to a port with no listener
  local client = check.must(net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0))

  -- Connect to localhost port 1 — should be refused
  local ok, conn_err = net.nb_connect(client, "127.0.0.1", 1, 2000)
  assert(not ok, "expected nb_connect to fail on refused port")
  assert(conn_err ~= nil, "expected error message from nb_connect")

  client:close()
end
test_nb_connect_refused()

local function test_connect_tcp()
  -- Create a listening socket
  local server = check.must(net.socket())

  local ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(err))

  ok, err = server:bind("127.0.0.1", 0)
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client using connect_tcp
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.connect_tcp("127.0.0.1", server_port))
    local sent = client:send("hello from connect_tcp")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from connect_tcp", "expected 'hello from connect_tcp', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  client:close()
  server:close()
  proc.wait(pid)
end
test_connect_tcp()

local function test_connect_tcp_accepts_string_and_addr()
  local raw_server, port, lerr = net.listen_tcp("127.0.0.1", 0)
  local server = check.must(raw_server,
    "listen_tcp with string address failed: " .. tostring(lerr))

  -- connect by dotted-quad string
  local c1 = check.must(net.connect_tcp("127.0.0.1", port))
  local a1 = check.must((server:accept()))
  c1:close()
  a1:close()

  -- connect by typed ip.Addr
  local addr = ip.addr(0x7f000001)
  local c2 = check.must(net.connect_tcp(addr, port))
  local a2 = check.must((server:accept()))
  c2:close()
  a2:close()

  server:close()
end
test_connect_tcp_accepts_string_and_addr()

local function test_connect_tcp_rejects_bad_addresses()
  local sock, err = net.connect_tcp("not-an-ip", 80)
  assert(sock == nil, "hostname strings are not addresses")
  assert(err ~= nil, "expected an error message")

  local sock6, err6 = net.connect_tcp("::1", 80)
  assert(sock6 == nil, "IPv6 must be rejected")
  assert(err6 ~= nil and err6:find("IPv6 not supported") ~= nil,
    "expected 'IPv6 not supported', got: " .. tostring(err6))
end
test_connect_tcp_rejects_bad_addresses()

local function test_connect_error_message()
  -- Connect to a port with no listener — should get a descriptive error, not just "connect failed"
  local sock = check.must(net.socket())

  local ok, conn_err = sock:connect("127.0.0.1", 1) -- localhost port 1
  assert(not ok, "expected connect to fail")
  assert(conn_err ~= nil, "expected error message")
  -- Should start with "connect: " prefix (Errno pattern) rather than generic "connect failed"
  assert(conn_err:sub(1, 9) == "connect: ", "expected 'connect: ' prefix, got: " .. conn_err)

  sock:close()
end
test_connect_error_message()

print("All net tests passed")

-- Error fidelity (issue #529): bind errors carry the errno name.
local function test_bind_error_names_errno()
  -- Binding a second socket to an in-use address must name EADDRINUSE.
  local first = check.must(net.socket(net.AF_INET, net.SOCK_STREAM))
  assert(first:bind("127.0.0.1", 0))
  assert(first:listen())
  local _, port = first:getsockname()
  local second = check.must(net.socket(net.AF_INET, net.SOCK_STREAM))
  local ok, berr = second:bind("127.0.0.1", port)
  assert(ok == false, "second bind to same port should fail")
  assert(berr:match("EADDRINUSE"), "bind error should name EADDRINUSE, got: " .. berr)
  second:close()
  first:close()
end
test_bind_error_names_errno()

local function test_dial()
  -- dial is the stable name-and-shape entry point (#588, from #501):
  -- resolution happens inside, for literals and DNS names alike.
  local srv, port, serr = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed: " .. tostring(serr))

  local c1 = check.must(net.dial("127.0.0.1", port))
  local a1 = check.must((s:accept()))
  c1:close()
  a1:close()

  local c2 = check.must(net.dial("localhost", port))
  local a2 = check.must((s:accept()))
  c2:close()
  a2:close()
  s:close()

  local bad, berr = net.dial("this.host.does.not.exist.invalid", 80)
  assert(bad == nil, "dial to unresolvable host must fail")
  assert(berr ~= nil and berr:find("dial", 1, true) ~= nil,
    "dial failure names the operation: " .. tostring(berr))
end
test_dial()

-- #493: listen_tcp socket options are configurable — SO_REUSEADDR stays
-- the default but can be opted out, and SO_REUSEPORT can be opted in.
local function test_listen_tcp_socket_options()
  local s1, port, derr = net.listen_tcp("127.0.0.1", 0)
  local d = check.must(s1, "listen_tcp failed: " .. tostring(derr))
  assert(port > 0, "expected a bound port")
  local ra = d:getsockopt(net.SOL_SOCKET, net.SO_REUSEADDR)
  assert(ra == true or ra == 1,
    "SO_REUSEADDR should default on, got " .. tostring(ra))
  d:close()

  local s2, _, oerr = net.listen_tcp("127.0.0.1", 0, nil, {reuseaddr = false})
  local o = check.must(s2, "listen_tcp with reuseaddr=false failed: " .. tostring(oerr))
  local ra2 = o:getsockopt(net.SOL_SOCKET, net.SO_REUSEADDR)
  assert(ra2 == false or ra2 == 0,
    "reuseaddr=false should leave SO_REUSEADDR off, got " .. tostring(ra2))
  o:close()

  local s3, _, perr = net.listen_tcp("127.0.0.1", 0, nil, {reuseport = true})
  local p = check.must(s3, "listen_tcp with reuseport failed: " .. tostring(perr))
  local rp = p:getsockopt(net.SOL_SOCKET, net.SO_REUSEPORT)
  assert(rp == true or rp == 1,
    "reuseport=true should set SO_REUSEPORT, got " .. tostring(rp))
  p:close()
end
test_listen_tcp_socket_options()
