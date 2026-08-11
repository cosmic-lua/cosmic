#!/usr/bin/env cosmic
--- Network connect and interface tests.
local net = require("cosmic.net")
local fs = require("cosmic.fs")
local ip = require("cosmic.ip")
local proc = require("cosmic.proc")
local check = require("cosmic.check")
local time = require("cosmic.time")

local function test_interfaces()
  -- SIOCGIFCONF has no pledge promise (inet allows only SIOCATMARK), so
  -- the sandboxed test lane cannot exercise it; skip on denial
  -- like the netns tests. The enforce lane still runs it for real.
  local probe, ierr = net.interfaces()
  if not probe then
    check.enforce_skip("interfaces() denied by sandbox: " .. tostring(ierr))
    return
  end
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
      assert(iface.ip == ip.from_int(0x7f000001),
        "loopback should have 127.0.0.1, got " .. iface.ip:format())
    end
  end
  assert(has_loopback, "should have loopback interface")
end
test_interfaces()

local function test_interfaces_format()
  -- Test that we can format interface IPs (skips under sandbox like
  -- test_interfaces above: SIOCGIFCONF has no pledge promise)
  local probe = net.interfaces()
  if not probe then
    check.enforce_skip("interfaces() denied by sandbox")
    return
  end
  local ifaces = check.must(net.interfaces())
  for _, iface in ipairs(ifaces) do
    local ip_str = iface.ip:format()
    assert(ip_str:match("^%d+%.%d+%.%d+%.%d+$"), "expected dotted IP format, got " .. ip_str)
  end
end
test_interfaces_format()

-- Socket dirs come from TMPDIR, not TEST_TMPDIR and not a literal
-- /tmp: sun_path caps a unix socket path at ~108 bytes, TEST_TMPDIR's
-- per-test scratch runs right up against that in CI, and the fence
-- does not grant the system scratch. TMPDIR is the driver's short pin.
local sock_base = os.getenv("TMPDIR") or "/tmp"

local function test_unix_domain_socket_bind_connect()
  local tmpdir = assert(fs.temp_dir(fs.join(sock_base, "cosmic_net_XXXXXX")))
  local path = tmpdir .. "/test.sock"

  -- Create server socket
  local server = check.must(net.socket({family = net.AF_UNIX}))

  -- Bind to path
  local ok, err = server:bind_unix(path)
  assert(ok, "bind_unix failed: " .. tostring(err))

  -- Listen
  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.socket({family = net.AF_UNIX}))
    local connect_ok = client:connect_unix(path)
    if not connect_ok then os.exit(check.EXIT_SKIP) end
    local sent = client:send("hello from unix client")
    if not sent then os.exit(3) end
    assert(client:close())
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from unix client", "expected 'hello from unix client', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  assert(client:close())
  assert(server:close())
  check.reap(pid, "the unix-socket client")
  assert(os.remove(path))
  assert(os.remove(tmpdir))
end
test_unix_domain_socket_bind_connect()

local function test_listen_unix_dial_unix()
  local tmpdir = assert(fs.temp_dir(fs.join(sock_base, "cosmic_net_XXXXXX")))
  local path = tmpdir .. "/test.sock"

  -- Use module-level listen_unix helper, with its options record
  local server = check.must(net.listen_unix(path, {backlog = 8}))

  -- Fork to create a client using module-level dial_unix helper
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.dial_unix(path))
    local sent = client:send("hello from dial_unix")
    if not sent then os.exit(check.EXIT_SKIP) end
    assert(client:close())
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from dial_unix", "expected 'hello from connect_unix', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  -- Verify accepted socket has __close
  local mt = getmetatable(client)
  assert(mt ~= nil and mt.__close ~= nil, "expected accepted unix socket to have __close")

  assert(client:close())
  assert(server:close())
  check.reap(pid, "the unix-socket client")
  assert(os.remove(path))
  assert(os.remove(tmpdir))
end
test_listen_unix_dial_unix()

local function test_connect_with_timeout_loopback()
  -- ConnectOptions.timeout_ms: connect with a bound, get back a
  -- BLOCKING socket.
  local server = check.must(net.listen_tcp("127.0.0.1", 0))
  local server_port = check.must(server:local_endpoint()).port

  local client = check.must(net.dial("127.0.0.1", server_port,
      {timeout_ms = 5000}))

  local raw_accepted, accept_err = server:accept()
  local accepted = check.must(raw_accepted, "accept failed: " .. tostring(accept_err))

  -- The connection works, and the socket is blocking again: a plain
  -- send/recv round-trip needs no readiness dance.
  local sent, send_err = client:send("nb_hello")
  assert(sent == 8, "expected 8 bytes sent, got " .. tostring(sent) .. ": " .. tostring(send_err))

  local data, recv_err = accepted:recv(100)
  assert(data == "nb_hello", "expected 'nb_hello', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  assert(client:close())
  assert(accepted:close())
  assert(server:close())
end
test_connect_with_timeout_loopback()

local function test_connect_with_timeout_refused()
  -- Connect to localhost port 1 — should be refused, inside the bound
  local sock, conn_err = net.dial("127.0.0.1", 1, {timeout_ms = 2000})
  assert(sock == nil, "expected connect to fail on refused port")
  assert(conn_err ~= nil, "expected error message from refused connect")
end
test_connect_with_timeout_refused()

-- connect() to the broadcast address fails SYNCHRONOUSLY with ENETUNREACH
-- (no EINPROGRESS at all — unlike a refused port, which the kernel usually
-- reports async). The timeout path must return that error immediately
-- rather than treating the failure as "still connecting" and polling for
-- up to timeout_ms: assert on elapsed time, not just the outcome, so a
-- regression back to "poll no matter what" is caught even though it would
-- eventually return the same error, just slowly.
local function test_connect_timeout_synchronous_failure_is_immediate()
  local t0 = time.monotonic()
  local sock, err = net.dial("255.255.255.255", 80, {timeout_ms = 5000})
  local t1 = time.monotonic()

  assert(sock == nil, "connect to the broadcast address should fail")
  assert(err ~= nil and err:match("ENETUNREACH"),
    "expected ENETUNREACH, got: " .. tostring(err))
  assert(t1 - t0 < 1, "a synchronous connect failure must not wait out"
    .. " the poll timeout, took " .. tostring(t1 - t0) .. "s")
end
test_connect_timeout_synchronous_failure_is_immediate()

-- Error fidelity: socket()/socket_pair()/hostname() must surface the
-- binding's real errno, not a generic "X creation failed" string.
local function test_socket_error_names_errno()
  local sock, err = net.socket({family = -1})
  assert(sock == nil, "socket with an invalid family should fail")
  assert(err ~= nil and err:match("E%u+"),
    "socket error should name the errno, got: " .. tostring(err))
end
test_socket_error_names_errno()

local function test_socket_pair_error_names_errno()
  -- socket_pair() only supports AF_UNIX; AF_INET fails synchronously.
  local sp, err = net.socket_pair({family = net.AF_INET})
  assert(sp == nil, "socket_pair with AF_INET should fail")
  assert(err ~= nil and err:match("E%u+"),
    "socket_pair error should name the errno, got: " .. tostring(err))
end
test_socket_pair_error_names_errno()

local function test_dial_tcp()
  -- Create a listening socket
  local server = check.must(net.socket())

  local ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed: " .. tostring(err))

  ok, err = server:bind("127.0.0.1", 0)
  assert(ok, "bind failed: " .. tostring(err))

  local server_port = check.must(server:local_endpoint()).port
  assert(server_port > 0, "expected non-zero port")

  ok, err = server:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork to create a client using dial
  local pid = proc.fork()
  if pid == 0 then
    local client = check.must(net.dial("127.0.0.1", server_port))
    local sent = client:send("hello from dial")
    if not sent then os.exit(check.EXIT_SKIP) end
    assert(client:close())
    os.exit(0)
  end

  -- Parent: accept connection
  local raw_client, accept_err = server:accept()
  local client = check.must(raw_client, "accept failed: " .. tostring(accept_err))

  -- Read data from client
  local data, recv_err = client:recv()
  assert(data == "hello from dial", "expected 'hello from dial', got '" .. tostring(data) .. "': " .. tostring(recv_err))

  assert(client:close())
  assert(server:close())
  check.reap(pid, "the tcp client")
end
test_dial_tcp()

local function test_dial_accepts_string_and_addr()
  local raw_server, lerr = net.listen_tcp("127.0.0.1", 0)
  local server = check.must(raw_server,
    "listen_tcp with string address failed: " .. tostring(lerr))
  local port = check.must(server:local_endpoint()).port

  -- connect by dotted-quad string
  local c1 = check.must(net.dial("127.0.0.1", port))
  local a1 = check.must(server:accept())
  assert(c1:close())
  assert(a1:close())

  -- connect by typed ip.Addr
  local addr = ip.from_int(0x7f000001)
  local c2 = check.must(net.dial(addr, port))
  local a2 = check.must(server:accept())
  assert(c2:close())
  assert(a2:close())

  assert(server:close())
end
test_dial_accepts_string_and_addr()

local function test_dial_rejects_ipv6_literals()
  -- A colon marks an address literal, not a DNS name: dial reports why
  -- the literal was rejected rather than spending a lookup on it.
  local sock6, err6 = net.dial("::1", 80)
  assert(sock6 == nil, "IPv6 must be rejected")
  assert(err6 ~= nil and err6:find("IPv6 not supported", 1, true) ~= nil,
    "expected 'IPv6 not supported', got: " .. tostring(err6))
end
test_dial_rejects_ipv6_literals()

local function test_connect_error_message()
  -- Connect to a port with no listener — should get a descriptive error, not just "connect failed"
  local sock = check.must(net.socket())

  local ok, conn_err = sock:connect("127.0.0.1", 1) -- localhost port 1
  assert(not ok, "expected connect to fail")
  assert(conn_err ~= nil, "expected error message")
  -- Should start with "connect: " prefix (Errno pattern) rather than generic "connect failed"
  assert(conn_err:sub(1, 9) == "connect: ", "expected 'connect: ' prefix, got: " .. conn_err)

  assert(sock:close())
end
test_connect_error_message()

print("All net tests passed")

-- Error fidelity: bind errors carry the errno name.
local function test_bind_error_names_errno()
  -- Binding a second socket to an in-use address must name EADDRINUSE.
  local first = check.must(net.socket({family = net.AF_INET}))
  assert(first:bind("127.0.0.1", 0))
  assert(first:listen())
  local port = check.must(first:local_endpoint()).port
  local second = check.must(net.socket({family = net.AF_INET}))
  local ok, berr = second:bind("127.0.0.1", port)
  assert(ok == false, "second bind to same port should fail")
  assert(berr:match("EADDRINUSE"), "bind error should name EADDRINUSE, got: " .. berr)
  assert(second:close())
  assert(first:close())
end
test_bind_error_names_errno()

local function test_dial()
  -- dial is the stable name-and-shape entry point (from):
  -- resolution happens inside, for literals and DNS names alike.
  local srv, serr = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed: " .. tostring(serr))
  local port = check.must(s:local_endpoint()).port

  local c1 = check.must(net.dial("127.0.0.1", port))
  local a1 = check.must(s:accept())
  assert(c1:close())
  assert(a1:close())

  local c2 = check.must(net.dial("localhost", port))
  local a2 = check.must(s:accept())
  assert(c2:close())
  assert(a2:close())
  assert(s:close())

  local bad, berr = net.dial("this.host.does.not.exist.invalid", 80)
  assert(bad == nil, "dial to unresolvable host must fail")
  assert(berr ~= nil and berr:find("dial", 1, true) ~= nil,
    "dial failure names the operation: " .. tostring(berr))
end
test_dial()

-- listen_tcp socket options are configurable — SO_REUSEADDR stays
-- the default but can be opted out, and SO_REUSEPORT can be opted in.
local function test_listen_tcp_socket_options()
  local s1, derr = net.listen_tcp("127.0.0.1", 0)
  local d = check.must(s1, "listen_tcp failed: " .. tostring(derr))
  local port = check.must(d:local_endpoint()).port
  assert(port > 0, "expected a bound port")
  local ra = d:getsockopt(net.SOL_SOCKET, net.SO_REUSEADDR)
  assert(ra == true or ra == 1,
    "SO_REUSEADDR should default on, got " .. tostring(ra))
  assert(d:close())

  local s2, oerr = net.listen_tcp("127.0.0.1", 0, {reuse_addr = false})
  local o = check.must(s2, "listen_tcp with reuse_addr=false failed: " .. tostring(oerr))
  local ra2 = o:getsockopt(net.SOL_SOCKET, net.SO_REUSEADDR)
  assert(ra2 == false or ra2 == 0,
    "reuse_addr=false should leave SO_REUSEADDR off, got " .. tostring(ra2))
  assert(o:close())

  local s3, perr = net.listen_tcp("127.0.0.1", 0, {reuse_port = true})
  local p = check.must(s3, "listen_tcp with reuse_port failed: " .. tostring(perr))
  local rp = p:getsockopt(net.SOL_SOCKET, net.SO_REUSEPORT)
  assert(rp == true or rp == 1,
    "reuse_port=true should set SO_REUSEPORT, got " .. tostring(rp))
  assert(p:close())
end
test_listen_tcp_socket_options()

-- dial_unix takes ConnectOptions, so a unix-domain connect can be
-- bounded too; connect_unix had no options and thus no bound at all.
local function test_dial_unix_with_timeout()
  local tmpdir = assert(fs.temp_dir(fs.join(sock_base, "cosmic_net_XXXXXX")))
  local path = tmpdir .. "/timeout.sock"
  local server = check.must(net.listen_unix(path))

  local client = check.must(net.dial_unix(path, {timeout_ms = 5000}))
  local raw_accepted, accept_err = server:accept()
  local accepted = check.must(raw_accepted, "accept failed: " .. tostring(accept_err))

  -- The bounded path connects non-blocking and restores blocking mode,
  -- so a plain round-trip needs no readiness dance.
  assert(client:send_all("bounded unix"))
  assert(accepted:recv() == "bounded unix", "expected the payload")

  assert(client:close())
  assert(accepted:close())
  assert(server:close())
  assert(os.remove(path))
  assert(os.remove(tmpdir))
end
test_dial_unix_with_timeout()

local function test_dial_unix_missing_path_fails()
  local sock, err = net.dial_unix(sock_base .. "/cosmic-no-such-socket", {timeout_ms = 1000})
  assert(sock == nil, "dial_unix to a nonexistent path should fail")
  assert(err ~= nil, "expected an error message")
end
test_dial_unix_missing_path_fails()
