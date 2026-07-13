#!/usr/bin/env cosmic
--- Network connect and interface tests.
local net = require("cosmic.net")
local fs = require("cosmic.fs")
local ip = require("cosmic.ip")
local proc = require("cosmic.proc")

local function test_interfaces()
  local raw_ifaces, err = net.interfaces()
  assert(raw_ifaces ~= nil, "interfaces() failed: " .. tostring(err))
  assert(type(raw_ifaces) == "table", "expected table, got " .. type(raw_ifaces))
  local ifaces = raw_ifaces as {net.Interface}

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
  local raw_ifaces = net.interfaces()
  if raw_ifaces then
    local ifaces = raw_ifaces as {net.Interface}
    for _, iface in ipairs(ifaces) do
      local ip_str = iface.ip:format()
      assert(ip_str:match("^%d+%.%d+%.%d+%.%d+$"), "expected dotted IP format, got " .. ip_str)
    end
  end
end
test_interfaces_format()

local function test_unix_domain_socket_bind_connect()
  local tmpdir = assert(fs.mkdtemp("/tmp/cosmic_net_test_XXXXXX"))
  local path = tmpdir .. "/test.sock"

  -- Create server socket
  local raw_server, err = net.socket(net.AF_UNIX, net.SOCK_STREAM, 0)
  assert(raw_server ~= nil, "unix raw_server socket creation failed: " .. tostring(err))
  local server = raw_server as net.Socket

  -- Bind to path
  local ok, bind_err = server:bind_unix(path)
  assert(ok, "bind_unix failed: " .. tostring(bind_err))

  -- Listen
  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = proc.fork()
  if pid == 0 then
    local raw_client = net.socket(net.AF_UNIX, net.SOCK_STREAM, 0)
    if not raw_client then os.exit(1) end
    local client = raw_client as net.Socket
    local connect_ok = client:connect_unix(path)
    if not connect_ok then os.exit(2) end
    local sent = client:send("hello from unix client")
    if not sent then os.exit(3) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  assert(raw_client ~= nil, "accept failed: " .. tostring(accept_err))
  local client = raw_client as net.Socket

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
  local raw_server, err = net.listen_unix(path)
  assert(raw_server ~= nil, "listen_unix failed: " .. tostring(err))
  local server = raw_server as net.Socket

  -- Fork to create a client using module-level connect_unix helper
  local pid = proc.fork()
  if pid == 0 then
    local raw_client, cerr = net.connect_unix(path)
    if not raw_client then
      io.stderr:write("connect_unix failed: " .. tostring(cerr) .. "\n")
      os.exit(1)
    end
    local client = raw_client as net.Socket
    local sent = client:send("hello from connect_unix")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  assert(raw_client ~= nil, "accept failed: " .. tostring(accept_err))
  local client = raw_client as net.Socket

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
  local raw_server, err = net.socket()
  assert(raw_server ~= nil, "raw_server socket creation failed: " .. tostring(err))
  local server = raw_server as net.Socket

  local ok, setopt_err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(setopt_err))

  ok, err = server:bind("127.0.0.1", 0) -- 127.0.0.1
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- A plain blocking socket: nb_connect switches it to non-blocking
  -- itself via Socket:set_nonblocking (it used to silently block when
  -- handed a blocking socket).
  local raw_client, cerr = net.socket()
  assert(raw_client ~= nil, "raw_client socket creation failed: " .. tostring(cerr))
  local client = raw_client as net.Socket

  -- nb_connect to the listening server, by dotted-quad string
  ok, err = net.nb_connect(client, "127.0.0.1", server_port, 5000)
  assert(ok, "nb_connect failed: " .. tostring(err))

  -- Accept the connection on the server side
  local raw_accepted, _, _, accept_err = server:accept()
  assert(raw_accepted ~= nil, "accept failed: " .. tostring(accept_err))
  local accepted = raw_accepted as net.Socket

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
  local raw_client, err = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0)
  assert(raw_client ~= nil, "raw_client socket creation failed: " .. tostring(err))
  local client = raw_client as net.Socket

  -- Connect to localhost port 1 — should be refused
  local ok, conn_err = net.nb_connect(client, "127.0.0.1", 1, 2000)
  assert(not ok, "expected nb_connect to fail on refused port")
  assert(conn_err ~= nil, "expected error message from nb_connect")

  client:close()
end
test_nb_connect_refused()

local function test_connect_tcp()
  -- Create a listening socket
  local raw_server, err = net.socket()
  assert(raw_server ~= nil, "raw_server socket creation failed: " .. tostring(err))
  local server = raw_server as net.Socket

  local ok, setopt_err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(setopt_err))

  ok, err = server:bind("127.0.0.1", 0)
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client using connect_tcp
  local pid = proc.fork()
  if pid == 0 then
    local raw_client, cerr = net.connect_tcp("127.0.0.1", server_port)
    if not raw_client then
      io.stderr:write("connect_tcp failed: " .. tostring(cerr) .. "\n")
      os.exit(1)
    end
    local client = raw_client as net.Socket
    local sent = client:send("hello from connect_tcp")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, _, _, accept_err = server:accept()
  assert(raw_client ~= nil, "accept failed: " .. tostring(accept_err))
  local client = raw_client as net.Socket

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
  assert(raw_server ~= nil, "listen_tcp with string address failed: " .. tostring(lerr))
  local server = raw_server as net.Socket

  -- connect by dotted-quad string
  local c1, e1 = net.connect_tcp("127.0.0.1", port)
  assert(c1 ~= nil, "connect_tcp by string failed: " .. tostring(e1))
  local c1s = c1 as net.Socket
  local a1 = server:accept() as net.Socket
  c1s:close()
  a1:close()

  -- connect by typed ip.Addr
  local addr = ip.addr(0x7f000001)
  local c2, e2 = net.connect_tcp(addr, port)
  assert(c2 ~= nil, "connect_tcp by Addr failed: " .. tostring(e2))
  local c2s = c2 as net.Socket
  local a2 = server:accept() as net.Socket
  c2s:close()
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
  local raw_sock, err = net.socket()
  assert(raw_sock ~= nil, "socket creation failed: " .. tostring(err))
  local sock = raw_sock as net.Socket

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
  local first = assert(net.socket(net.AF_INET, net.SOCK_STREAM)) as net.Socket
  assert(first:bind("127.0.0.1", 0))
  assert(first:listen())
  local _, port = first:getsockname()
  local second = assert(net.socket(net.AF_INET, net.SOCK_STREAM)) as net.Socket
  local ok, berr = second:bind("127.0.0.1", port as number)
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
  assert(srv ~= nil, "listen_tcp failed: " .. tostring(serr))
  local s = srv as net.Socket

  local c1, derr = net.dial("127.0.0.1", port)
  assert(c1 ~= nil, "dial literal failed: " .. tostring(derr))
  local a1 = s:accept() as net.Socket;
  (c1 as net.Socket):close()
  a1:close()

  local c2, herr = net.dial("localhost", port)
  assert(c2 ~= nil, "dial hostname failed: " .. tostring(herr))
  local a2 = s:accept() as net.Socket;
  (c2 as net.Socket):close()
  a2:close()
  s:close()

  local bad, berr = net.dial("this.host.does.not.exist.invalid", 80)
  assert(bad == nil, "dial to unresolvable host must fail")
  assert(berr ~= nil and berr:find("dial", 1, true) ~= nil,
    "dial failure names the operation: " .. tostring(berr))
end
test_dial()
