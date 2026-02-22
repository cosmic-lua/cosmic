#!/usr/bin/env cosmic
--- Network connect and interface tests.
local net = require("cosmic.net")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local function test_interfaces()
  local ifaces, err = net.interfaces()
  assert(ifaces ~= nil, "interfaces() failed: " .. tostring(err))
  assert(type(ifaces) == "table", "expected table, got " .. type(ifaces))

  -- Should have at least the loopback interface
  local has_loopback = false
  for _, iface in ipairs(ifaces) do
    assert(iface.name ~= nil, "interface should have name")
    assert(iface.ip ~= nil, "interface should have ip")
    if iface.name == "lo" then
      has_loopback = true
      -- Loopback should be 127.0.0.1 (0x7f000001)
      assert(iface.ip == 0x7f000001, "loopback should have 127.0.0.1, got " .. net.formatip(iface.ip))
    end
  end
  assert(has_loopback, "should have loopback interface")
end
test_interfaces()

local function test_interfaces_formatip()
  -- Test that we can format interface IPs
  local ifaces = net.interfaces()
  if ifaces then
    for _, iface in ipairs(ifaces) do
      local ip_str = net.formatip(iface.ip)
      assert(ip_str:match("^%d+%.%d+%.%d+%.%d+$"), "expected dotted IP format, got " .. ip_str)
    end
  end
end
test_interfaces_formatip()

local function test_unix_domain_socket_bind_connect()
  local tmpdir = assert(fs.mkdtemp("/tmp/cosmic_net_test_XXXXXX"))
  local path = tmpdir .. "/test.sock"

  -- Create server socket
  local server, err = net.socket(net.AF_UNIX, net.SOCK_STREAM, 0)
  assert(server ~= nil, "unix server socket creation failed: " .. tostring(err))

  -- Bind to path
  local ok, bind_err = server:bind_unix(path)
  assert(ok, "bind_unix failed: " .. tostring(bind_err))

  -- Listen
  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = child.fork()
  if pid == 0 then
    local client = net.socket(net.AF_UNIX, net.SOCK_STREAM, 0)
    if not client then os.exit(1) end
    local connect_ok = client:connect_unix(path)
    if not connect_ok then os.exit(2) end
    local sent = client:send("hello from unix client")
    if not sent then os.exit(3) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local client, _, _, accept_err = server:accept()
  assert(client ~= nil, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from unix client", "expected 'hello from unix client', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  client:close()
  server:close()
  child.wait(pid)
  os.remove(path)
  os.remove(tmpdir)
end
test_unix_domain_socket_bind_connect()

local function test_listen_unix_connect_unix()
  local tmpdir = assert(fs.mkdtemp("/tmp/cosmic_net_test_XXXXXX"))
  local path = tmpdir .. "/test.sock"

  -- Use module-level listen_unix helper
  local server, err = net.listen_unix(path)
  assert(server ~= nil, "listen_unix failed: " .. tostring(err))

  -- Fork to create a client using module-level connect_unix helper
  local pid = child.fork()
  if pid == 0 then
    local client, cerr = net.connect_unix(path)
    if not client then
      io.stderr:write("connect_unix failed: " .. tostring(cerr) .. "\n")
      os.exit(1)
    end
    local sent = client:send("hello from connect_unix")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local client, _, _, accept_err = server:accept()
  assert(client ~= nil, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from connect_unix", "expected 'hello from connect_unix', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  -- Verify accepted socket has __close
  local mt = getmetatable(client)
  assert(mt ~= nil and mt.__close ~= nil, "expected accepted unix socket to have __close")

  client:close()
  server:close()
  child.wait(pid)
  os.remove(path)
  os.remove(tmpdir)
end
test_listen_unix_connect_unix()

local function test_nb_connect_loopback()
  -- Create a listening socket
  local server, err = net.socket()
  assert(server ~= nil, "server socket creation failed: " .. tostring(err))

  local ok, setopt_err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(setopt_err))

  ok, err = server:bind(0x7f000001, 0) -- 127.0.0.1
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Create a non-blocking client socket
  local client, cerr = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0)
  assert(client ~= nil, "client socket creation failed: " .. tostring(cerr))

  -- nb_connect to the listening server
  ok, err = net.nb_connect(client, 0x7f000001, server_port, 5000)
  assert(ok, "nb_connect failed: " .. tostring(err))

  -- Accept the connection on the server side
  local accepted, _, _, accept_err = server:accept()
  assert(accepted ~= nil, "accept failed: " .. tostring(accept_err))

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
  local client, err = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0)
  assert(client ~= nil, "client socket creation failed: " .. tostring(err))

  -- Connect to localhost port 1 — should be refused
  local ok, conn_err = net.nb_connect(client, 0x7f000001, 1, 2000)
  assert(not ok, "expected nb_connect to fail on refused port")
  assert(conn_err ~= nil, "expected error message from nb_connect")

  client:close()
end
test_nb_connect_refused()

local function test_connect_tcp()
  -- Create a listening socket
  local server, err = net.socket()
  assert(server ~= nil, "server socket creation failed: " .. tostring(err))

  local ok, setopt_err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(setopt_err))

  ok, err = server:bind(0x7f000001, 0)
  assert(ok, "bind failed: " .. tostring(err))

  local _, server_port = server:getsockname()
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client using connect_tcp
  local pid = child.fork()
  if pid == 0 then
    local client, cerr = net.connect_tcp(0x7f000001, server_port)
    if not client then
      io.stderr:write("connect_tcp failed: " .. tostring(cerr) .. "\n")
      os.exit(1)
    end
    local sent = client:send("hello from connect_tcp")
    if not sent then os.exit(2) end
    client:close()
    os.exit(0)
  end

  -- Parent: accept connection
  local client, _, _, accept_err = server:accept()
  assert(client ~= nil, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from connect_tcp", "expected 'hello from connect_tcp', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  client:close()
  server:close()
  child.wait(pid)
end
test_connect_tcp()

local function test_connect_error_message()
  -- Connect to a port with no listener — should get a descriptive error, not just "connect failed"
  local sock, err = net.socket()
  assert(sock ~= nil, "socket creation failed: " .. tostring(err))

  local ok, conn_err = sock:connect(0x7f000001, 1) -- localhost port 1
  assert(not ok, "expected connect to fail")
  assert(conn_err ~= nil, "expected error message")
  -- Should start with "connect: " prefix (Errno pattern) rather than generic "connect failed"
  assert(conn_err:sub(1, 9) == "connect: ", "expected 'connect: ' prefix, got: " .. conn_err)

  sock:close()
end
test_connect_error_message()

print("All net tests passed")
