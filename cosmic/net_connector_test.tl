--- [`Net.listener_from`] and [`Net.connector`]: a listening socket
--- another process or an earlier call made, taken as a listener, and the
--- confined native connector (core/connector.c) as a connection maker.
local Clock = require("cosmic.clock")
local Connector = require("cosmic.internal.connector")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local Relay = require("cosmic.relay")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")

Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" } }

local type Searcher = function(string): any, any

--- The raw table `require` hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.internal.connector") as raw_process -- cast: holds the table core/process.h declares, beside the socket table
local socket = raw_behind("cosmic.net") as raw_socket -- cast: the table core/socket.h declares

--- How many connections one connector process makes at once, as the core says.
local FLIGHT <const> = socket.CONNECTOR_FLIGHT

--- Connects `connector` to the tcp address `host`:`port`, waiting `wait`.
local function dial(connector: Net.Connector, host: string, port: integer, wait?: integer): Net.Conn | nil, string
  return connector:connect(Net.tcp(host, port), { timeout_ns = wait })
end

--- The descriptors this worker holds, the one listing them included in
--- every sample: compare counts, never a host-wide baseline.
local function descriptor_count(): integer
  local path = assert(sys.uname()).sysname == "Darwin" and "/dev/fd" or "/proc/self/fd"
  local count = 0
  for name in pairs((assert(sys.readdir(path)))) do
    if name:match("^%d+$") ~= nil then count = count + 1 end
  end
  return count
end

local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end

--- A loopback echo server in the run's tasks: its address, and the task to cancel.
local function echo_server(): Net.Listener, Poll.Task
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local task = Poll.spawn(function()
    while true do
      local conn = listener:accept()
      if conn == nil then return end
      Poll.spawn(function()
        while true do
          local data, _ = conn:read()
          if data == nil then break end
          local _, _ = conn:write(data)
        end
        local _, _ = conn:close()
      end)
    end
  end)
  return listener, task
end

--- Echoes `text` through `conn` and closes it.
local function echo_through(conn: Net.Conn, text: string)
  conn:set_timeout(Clock.seconds(5))
  assert(conn:write(text))
  assert(assert(conn:read()) == text)
  assert(conn:close())
end

--- A listener whose queue is full, so that a connect to it hangs: its
--- port, and what holds it full. Skips where this kernel answers anyway.
local function hung_port(): integer, {raw_socket.Socket}
  local listener = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local port = assert(socket.bound(listener:fd())).port
  local held: {raw_socket.Socket} = { listener }
  for n = 1, 6 do
    held[#held + 1] = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
    assert(n > 0)
  end
  local probe = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
  held[#held + 1] = probe
  local ready = socket.wait(probe:fd(), true, 200)
  if ready then Test.skip("this kernel completes a connect to a listener whose queue is full") end
  return port, held
end

--- A stream socketpair, by the connector's own maker, which a test may use as one.
local function stream_pair(): {integer}
  return (assert(process.connector_pair()))
end

local function test_a_listener_received_over_a_socketpair_accepts_a_loopback_connection()
  local before = descriptor_count()
  local original = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local pair = stream_pair()
  assert(socket.sendfds(pair[1], { original:fd() }))
  local received = assert(socket.recvfds(pair[2], 1))
  Poll.run(function()
    local listener = assert(Net.listener_from(received[1]:fd(), { timeout_ns = Clock.seconds(5) }))
    local bound = assert(socket.bound(original:fd()))
    assert(listener.address.kind == "tcp" and listener.address.host == "127.0.0.1" and
        listener.address.port == bound.port, "the adopted listener names the socket's own address")
    local task = Poll.spawn(function()
      local conn = assert(listener:accept())
      conn:set_timeout(Clock.seconds(5))
      assert(conn:write((assert(conn:read()))))
      local _, _ = conn:close()
    end)
    local client = assert(Net.connect(listener.address, { timeout_ns = Clock.seconds(5) }))
    assert(client:write("through an adopted listener"))
    local echoed = assert(client:read())
    assert(echoed == "through an adopted listener", echoed)
    local _, _ = client:close()
    task:cancel()
    -- Closing the adopted listener leaves the one it was copied from listening.
    assert(listener:close())
    local again = assert(Net.connect(Net.tcp("127.0.0.1", bound.port), { timeout_ns = Clock.seconds(5) }))
    assert(socket.wait(original:fd(), false, 5000))
    local accepted = assert(socket.accept(original:fd()))
    assert(accepted:close())
    assert(again:close())
  end)
  assert(received[1]:close())
  assert(original:close())
  assert(sys.close(pair[1]) and sys.close(pair[2]))
  assert(descriptor_count() == before, "adopting a listener left a descriptor open")
end

local function test_a_listener_adopted_from_a_blocking_socket_does_not_block_accept()
  local original = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  assert(sys.set_nonblocking(original:fd(), false))
  local listener = assert(Net.listener_from(original:fd()))
  local waited = Clock.monotonic_ns()
  local conn, why = listener:accept(Clock.ms(50))
  assert(conn == nil and why == Poll.TIMEOUT, "accept waits through the timeout: " .. tostring(why))
  assert(Clock.monotonic_ns() - waited < Clock.seconds(2))
  assert(listener:close())
  assert(original:close())
end

local function test_listener_from_refuses_what_is_no_listening_tcp_socket(tmp: string)
  local before = descriptor_count()
  local function refuses(fd: integer, what: string, fragments: {string})
    local listener, why = Net.listener_from(fd)
    assert(listener == nil, what .. " was adopted")
    assert(why:find("descriptor " .. fd .. " is no listening TCP socket", 1, true) ~= nil, why)
    local found = false
    for _, fragment in ipairs(fragments) do
      found = found or why:find(fragment, 1, true) ~= nil
    end
    assert(found, what .. ": " .. why)
  end
  -- A regular file.
  local file = assert(sys.open(tmp .. "/regular", sys.O_CREAT | sys.O_RDWR, 420))
  refuses(file, "a regular file", { "Not a socket", "non-socket" })
  assert(sys.close(file))
  -- A pipe.
  local ends = assert(process.pipe())
  refuses(ends.reader, "a pipe's reader", { "Not a socket", "non-socket" })
  refuses(ends.writer, "a pipe's writer", { "Not a socket", "non-socket" })
  assert(sys.close(ends.reader) and sys.close(ends.writer))
  -- A stream socket that is connected, not listening.
  local server = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local bound = assert(socket.bound(server:fd()))
  local client = assert(socket.connect({ kind = "tcp", host = "127.0.0.1", port = bound.port }, 5000))
  refuses(client:fd(), "a connected socket", { "not listening" })
  -- A datagram socket.
  local datagram = assert(socket.datagram({ kind = "udp", host = "127.0.0.1", port = 0 }))
  refuses(datagram:fd(), "a datagram socket", { "wrong type" })
  -- A closed descriptor.
  local number = client:fd()
  assert(client:close())
  refuses(number, "a closed descriptor", { "Bad file descriptor" })
  assert(datagram:close())
  assert(server:close())
  -- A listening unix socket: not TCP.
  local unix = assert(socket.listen({ kind = "unix", path = tmp .. "/listener.sock" }, 1))
  refuses(unix:fd(), "a unix listener", { "not supported" })
  assert(unix:close())
  -- Not an fd at all.
  local ok, why = pcall(Net.listener_from, -1)
  assert(not ok and tostring(why):find("fd must be an integer from 0", 1, true) ~= nil, tostring(why))
  assert(descriptor_count() == before, "a refused adoption left a descriptor open")
end

--- The table matches a requested address by what it is, not how it is
--- spelled, and the entry's port still limits it. Nothing listens on ::1
--- here, so a match shows as the kernel's refusal and a miss as the
--- table's (or, in public mode, the deny list's).
local function test_a_table_connector_matches_an_address_however_it_is_spelled()
  require_native_connector()
  local function matched(table_host: string, asked: string, port: integer, public: boolean): boolean, string
    local connector = assert(Net.connector({ { host = table_host, port = 54321 } },
      { public = public and { deny = { "::/0" } } or nil }))
    local conn, why = dial(connector, asked, port, Clock.seconds(5))
    assert(connector:close())
    assert(conn == nil)
    local missed = why:find("not in the connector's table", 1, true) ~= nil or
      why:find("deny list", 1, true) ~= nil
    return not missed, why
  end
  for _, public in ipairs({ false, true }) do
    for _, pair in ipairs({
        { "0:0:0:0:0:0:0:1", "::1" }, { "::1", "0:0:0:0:0:0:0:1" }, { "2001:DB8::A", "2001:db8:0:0:0:0:0:a" },
        { "2001:db8::a", "2001:0DB8::000A" },
    }) do
      local ok, why = matched(pair[1], pair[2], 54321, public)
      assert(ok, pair[1] .. " asked as " .. pair[2] .. ": " .. why)
    end
    -- Another address, or an ungranted port, is still refused.
    local other, other_why = matched("::1", "::2", 54321, public)
    assert(not other, other_why)
    local port, port_why = matched("0:0:0:0:0:0:0:1", "::1", 54322, public)
    assert(not port, port_why)
  end
end

local function test_a_table_connector_connects_to_its_endpoints_and_refuses_the_rest()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector({
      { host = "127.0.0.1", port = port },
      { host = "127.0.0.2", port = 0 },
      { host = "::1", port = 80 },
    }, { timeout_ns = Clock.seconds(5) }))
    -- Twice through the same process.
    for n = 1, 2 do
      local conn = assert(dial(connector, "127.0.0.1", port, Clock.seconds(5)))
      conn:set_timeout(Clock.seconds(5))
      assert(conn:write("hello " .. n))
      assert(assert(conn:read()) == "hello " .. n)
      assert(conn:close())
    end
    -- What the table does not name: another port or address.
    local function refused(host: string, at: integer, fragment: string)
      local conn, why = dial(connector, host, at, Clock.seconds(5))
      assert(conn == nil and why:find(fragment, 1, true) ~= nil, host .. ":" .. at .. " " .. tostring(why))
    end
    refused("127.0.0.1", port == 65535 and 1 or port + 1, "is not in the connector's table")
    refused("127.0.0.3", port, "is not in the connector's table")
    refused("localhost", port, "is not in the connector's table")
    -- A wildcard port at its own address is allowed, and the port nothing listens at is refused by the kernel.
    local conn, why = dial(connector, "127.0.0.2", port, Clock.seconds(5))
    assert(conn == nil and why ~= "" and why:find("not in the connector", 1, true) == nil, tostring(why))
    -- A wildcard port: any nonzero port at that address, here the echo server's own.
    local wildcard = assert(Net.connector({ { host = "127.0.0.1", port = 0 } }))
    local wild = assert(dial(wildcard, "127.0.0.1", port, Clock.seconds(5)))
    assert(wild:close())
    local none, nothing = dial(wildcard, "127.0.0.1", 0, Clock.seconds(5))
    assert(none == nil and nothing:find("not in the connector's table", 1, true) ~= nil, tostring(nothing))
    assert(wildcard:close())
    -- The process answered every one of those and still serves.
    local after = assert(dial(connector, "127.0.0.1", port, Clock.seconds(5)))
    assert(after:close())
    assert(connector:close())
    assert(connector:close())
    local closed, trouble = dial(connector, "127.0.0.1", port, Clock.seconds(5))
    assert(closed == nil and trouble:find("closed", 1, true) ~= nil, tostring(trouble))
    task:cancel()
    assert(listener:close())
  end)
  assert(descriptor_count() == before, "a closed connector left a descriptor open")
end

local function test_a_table_connector_serves_tasks_at_once()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
    local done = 0
    local tasks: {Poll.Task} = {}
    for n = 1, 4 do
      tasks[n] = Poll.spawn(function()
        local conn = assert(dial(connector, "127.0.0.1", port, Clock.seconds(5)))
        conn:set_timeout(Clock.seconds(5))
        assert(conn:write(tostring(n)))
        assert(assert(conn:read()) == tostring(n))
        assert(conn:close())
        done = done + 1
      end)
    end
    for n = 1, 4 do assert(tasks[n]:join()) end
    assert(done == 4)
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end

--- Authority is explicit: a connector made with neither endpoints nor a
--- public list is refused, and an empty table is public-only.
local function test_a_connector_without_authority_is_refused()
  local make = Net.connector as function(any...): (any...) -- cast: arguments the signature refuses
  local function refused(...: any)
    local ok, why = pcall(make, ...)
    assert(not ok and tostring(why):find("needs endpoints, opts.public, or both", 1, true) ~= nil, tostring(why))
  end
  refused()
  refused(nil)
  refused({})
  refused({}, { timeout_ns = Clock.seconds(1) })
end

--- A fixed connector reaches its endpoints and nothing else, even an
--- address a public one would reach.
local function test_a_fixed_connector_reaches_only_its_endpoints()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local other, other_task = echo_server()
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = listener.address.port } }))
    echo_through(assert(dial(connector, "127.0.0.1", listener.address.port, Clock.seconds(5))), "fixed")
    local conn, why = dial(connector, "127.0.0.1", other.address.port, Clock.seconds(5))
    assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
    assert(connector:close())
    task:cancel()
    other_task:cancel()
    assert(listener:close())
    assert(other:close())
  end)
end

local function test_a_public_only_connector_reaches_public_addresses_through_its_lists()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector({}, { public = { deny = {} } }))
    for n = 1, 3 do
      echo_through(assert(dial(connector, "127.0.0.1", port, Clock.seconds(5))), "n" .. n)
    end
    -- A port that was free a moment ago: the connector's errno is the reason.
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local closed = free.address.port
    assert(free:close())
    local conn, why = dial(connector, "127.0.0.1", closed, Clock.seconds(5))
    assert(conn == nil and why:find("refused", 1, true) ~= nil, tostring(why))
    local named, why_named = dial(connector, "localhost", port, Clock.seconds(5))
    assert(named == nil and why_named:find("not a numeric address", 1, true) ~= nil, tostring(why_named))
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
  assert(descriptor_count() == before, "a public connector left a descriptor open")
end

--- A connect waits min(opts.timeout_ns, ceiling), and no per-call
--- timeout waits the ceiling: a ceiling of 1 ms bounds a call that asks
--- for 5 seconds, public-only as well as fixed.
local function test_a_connect_waits_at_most_the_ceiling()
  require_native_connector()
  Poll.run(function()
    local port, held = hung_port()
    local fixed = assert(Net.connector({ { host = "127.0.0.1", port = port } }, { timeout_ns = Clock.ms(1) }))
    local public = assert(Net.connector({}, { timeout_ns = Clock.ms(1), public = { deny = {} } }))
    for name, connector in pairs({ fixed = fixed, public = public }) do
      -- A call asking for 5 seconds, and one asking for nothing.
      for _, asked in ipairs({ "5 s", "no timeout" }) do
        local started = Clock.monotonic_ns()
        local conn, why = dial(connector, "127.0.0.1", port, asked == "5 s" and Clock.seconds(5) or nil)
        local elapsed = Clock.monotonic_ns() - started
        assert(conn == nil and why == Poll.TIMEOUT, name .. ": " .. tostring(why))
        assert(elapsed < Clock.seconds(2), name .. " asked for " .. asked .. " and waited " .. elapsed // Clock.ms(1) .. " ms")
        assert(not connector:ended())
      end
      assert(connector:close())
    end
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

--- The connection's later read and write wait is the call's timeout_ns,
--- as Net.connect's, and none where it has none.
local function test_a_connection_waits_as_its_call_asked()
  require_native_connector()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
    local waiting = assert(dial(connector, "127.0.0.1", port, Clock.ms(200)))
    local started = Clock.monotonic_ns()
    local data, why = waiting:read()
    assert(data == nil and why == Poll.TIMEOUT, tostring(why))
    assert(Clock.monotonic_ns() - started < Clock.seconds(2))
    assert(waiting:close())
    assert(connector:close())
    assert(listener:close())
  end)
end

--- A call that is no tcp address, or whose timeout is out of range, raises.
local function test_connect_refuses_what_is_no_tcp_address_or_timeout()
  require_native_connector()
  local connector = assert(Net.connector({ { host = "127.0.0.1", port = 9 } }))
  local connect = connector.connect as function(any...): (any...) -- cast: arguments the signature refuses
  local ok, why = pcall(connect, connector, "127.0.0.1")
  assert(not ok and tostring(why):find("address must be", 1, true) ~= nil, tostring(why))
  ok, why = pcall(connect, connector, Net.unix("/tmp/x"))
  assert(not ok and tostring(why):find("tcp addresses", 1, true) ~= nil, tostring(why))
  ok, why = pcall(connect, connector, Net.tcp("127.0.0.1", 9), { timeout_ns = -1 })
  assert(not ok and tostring(why):find("timeout_ns must be", 1, true) ~= nil, tostring(why))
  assert(connector:close())
end

local function test_a_connector_dropped_unclosed_is_ended_when_collected()
  require_native_connector()
  local before = descriptor_count()
  local pid: integer
  do
    local started = assert(Connector.start({ { host = "127.0.0.1", port = 9 } }, 1000))
    pid = started.pid
    assert(sys.kill(pid, 0), "the connector is running")
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(descriptor_count() == before, "a dropped connector left its control stream open")
  -- Reaped, not a zombie: nothing answers a signal 0 to its pid.
  assert(not sys.kill(pid, 0), "a dropped connector's process was not ended and reaped")
  local dropped = assert(Net.connector({ { host = "127.0.0.1", port = 9 } }))
  assert(dropped:close())
end

--- One connector, several connects at once: a connect that hangs holds
--- up none of the others, each answered as it is made, out of the order
--- they were asked in, and times out at its own time, leaving the stream
--- in step.
local function test_a_hung_connect_holds_up_no_other()
  require_native_connector()
  Poll.run(function()
    local port, held = hung_port()
    local listener, task = echo_server()
    local echo = listener.address.port
    local connector = assert(Net.connector({
      { host = "127.0.0.1", port = port }, { host = "127.0.0.1", port = echo },
    }, { timeout_ns = Clock.seconds(30) }))
    local hung: string
    local started = Clock.monotonic_ns()
    local hanging = Poll.spawn(function()
      local _, why = dial(connector, "127.0.0.1", port, Clock.ms(800))
      hung = why
    end)
    assert(Poll.delay(Clock.ms(50)))
    local tasks: {Poll.Task} = {}
    local done: {integer} = {}
    for n = 1, 8 do
      tasks[n] = Poll.spawn(function()
        local conn = assert(dial(connector, "127.0.0.1", echo, Clock.seconds(5)))
        conn:set_timeout(Clock.seconds(5))
        assert(conn:write("n" .. n))
        assert(assert(conn:read()) == "n" .. n)
        assert(conn:close())
        done[#done + 1] = n
      end)
    end
    for n = 1, 8 do assert(tasks[n]:join()) end
    local others = Clock.monotonic_ns() - started
    assert(#done == 8 and hung == nil, "the others finished first")
    assert(others < Clock.ms(700), "the others waited for the hung connect: " .. others // Clock.ms(1) .. " ms")
    assert(hanging:join())
    local elapsed = Clock.monotonic_ns() - started
    assert(hung == Poll.TIMEOUT, tostring(hung))
    assert(elapsed >= Clock.ms(790) and elapsed < Clock.seconds(3), elapsed // Clock.ms(1) .. " ms")
    -- The hung connect's reply came whole: the same stream serves on.
    assert(not connector:ended())
    local conn = assert(dial(connector, "127.0.0.1", echo, Clock.seconds(5)))
    assert(conn:close())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

--- A connector makes at most 64 connections at once,
--- and a request it gave up on, its task killed, counts until the process
--- answers it: a request past them waits for room within its own time,
--- and is made once one of them is answered.
local function test_requests_past_the_flight_wait_for_room()
  require_native_connector()
  assert(FLIGHT == 64)
  Poll.run(function()
    local port, held = hung_port()
    local listener, task = echo_server()
    local echo = listener.address.port
    local connector = assert(Net.connector({
      { host = "127.0.0.1", port = port }, { host = "127.0.0.1", port = echo },
    }, { timeout_ns = Clock.seconds(30) }))
    local hanging: {Poll.Task} = {}
    for n = 1, FLIGHT do
      hanging[n] = Poll.spawn(function()
        local _, _ = dial(connector, "127.0.0.1", port, Clock.seconds(2))
      end)
    end
    assert(Poll.delay(Clock.ms(100)))
    local killed_at = Clock.monotonic_ns()
    for _, each in ipairs(hanging) do each:kill() end
    -- No room while the process still makes them, given up on or not.
    local none, why = dial(connector, "127.0.0.1", echo, Clock.ms(300))
    assert(none == nil and why == Poll.TIMEOUT, tostring(why))
    local conn = assert(dial(connector, "127.0.0.1", echo, Clock.seconds(10)))
    local waited = Clock.monotonic_ns() - killed_at
    assert(waited >= Clock.ms(1500), "a request past the flight was made at once: " .. waited // Clock.ms(1) .. " ms")
    assert(waited < Clock.seconds(5), waited // Clock.ms(1) .. " ms")
    assert(conn:close())
    assert(not connector:ended())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

--- Makes `count` connections at once with `connect`, each within 500 ms:
--- how many were made, closed again.
local function made_at_once(count: integer, connect: function(): Net.Conn | nil, string): integer
  local made = 0
  local tasks: {Poll.Task} = {}
  for i = 1, count do
    tasks[i] = Poll.spawn(function()
      local conn = connect()
      if conn ~= nil then
        made = made + 1
        assert(conn:close())
      end
    end)
  end
  for _, task in ipairs(tasks) do assert(task:join()) end
  return made
end

--- A connector with a table and public lists shares its flights between
--- the two kinds of request, and keeps 16 for each against the other: a
--- flood of `flooded` ("table" or "public"), even given up on (it counts
--- until answered), leaves the other kind 16 at once, and the flooded kind
--- its own 48 and no more.
local function keeps_flights_against(flooded: string)
  require_native_connector()
  Poll.run(function()
    local table_hung, held = hung_port()
    local public_hung, more = hung_port()
    for _, each in ipairs(more) do held[#held + 1] = each end
    local table_echo, table_task = echo_server()
    local public_echo, public_task = echo_server()
    -- Entry 2 hangs; the public requests go to addresses no entry holds at that port.
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = table_echo.address.port },
      { host = "127.0.0.1", port = table_hung } }, { timeout_ns = Clock.seconds(30), public = { deny = {} } }))
    -- The stalled connects end at the process after STALL, a flood request
    -- as soon as its own wait does.
    local STALL <const> = Clock.ms(600)
    local function hangs(wait: integer): Net.Conn | nil, string
      if flooded == "table" then return dial(connector, "127.0.0.1", table_hung, wait) end
      return dial(connector, "127.0.0.1", public_hung, wait)
    end
    local function other(): Net.Conn | nil, string
      if flooded == "table" then
        return dial(connector, "127.0.0.1", public_echo.address.port, Clock.ms(500))
      end
      return dial(connector, "127.0.0.1", table_echo.address.port, Clock.ms(500))
    end
    local hanging: {Poll.Task} = {}
    for n = 1, FLIGHT do
      hanging[n] = Poll.spawn(function()
        local _, _ = hangs(STALL)
      end)
    end
    assert(Poll.delay(Clock.ms(100)))
    -- Given up on, and so still counted until the process answers each.
    for _, each in ipairs(hanging) do each:kill() end
    assert(made_at_once(16, other) == 16, "the other kind waited behind the " .. flooded .. " flood")
    -- The flooded kind has the rest of its 48, and no more.
    local none, why = hangs(Clock.ms(200))
    assert(none == nil and why == Poll.TIMEOUT, flooded .. ": " .. tostring(why))
    -- Once the stalled connects end at the process, the kind is served again.
    assert(Poll.delay(STALL + Clock.ms(500)))
    assert(made_at_once(1, flooded == "table" and function(): Net.Conn | nil, string
      return dial(connector, "127.0.0.1", table_echo.address.port, Clock.ms(500))
    end or function(): Net.Conn | nil, string
      return dial(connector, "127.0.0.1", public_echo.address.port, Clock.ms(500))
    end) == 1)
    assert(connector:close())
    table_task:cancel()
    public_task:cancel()
    assert(table_echo:close())
    assert(public_echo:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

local function test_a_table_flood_leaves_public_requests_their_flights()
  keeps_flights_against("table")
end

local function test_a_public_flood_leaves_table_requests_their_flights()
  keeps_flights_against("public")
end

local function test_closing_a_connector_wakes_a_request_in_flight()
  require_native_connector()
  Poll.run(function()
    local port, held = hung_port()
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = port } },
      { timeout_ns = Clock.seconds(30) }))
    local answer: string
    local started = Clock.monotonic_ns()
    local waiting = Poll.spawn(function()
      local _, why = dial(connector, "127.0.0.1", port, Clock.seconds(20))
      answer = why
    end)
    assert(Poll.delay(Clock.ms(100)))
    assert(connector:close())
    assert(waiting:join(Clock.seconds(5)), "the request was left parked")
    assert(answer:find("closed", 1, true) ~= nil, tostring(answer))
    assert(Clock.monotonic_ns() - started < Clock.seconds(3))
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

local function test_a_killed_request_leaves_the_connector_free()
  require_native_connector()
  Poll.run(function()
    local port, held = hung_port()
    local listener, task = echo_server()
    local echo = listener.address.port
    local connector = assert(Net.connector({
      { host = "127.0.0.1", port = port }, { host = "127.0.0.1", port = echo },
    }, { timeout_ns = Clock.seconds(30) }))
    local waiting = Poll.spawn(function()
      local _, _ = dial(connector, "127.0.0.1", port, Clock.seconds(20))
    end)
    assert(Poll.delay(Clock.ms(100)))
    waiting:kill()
    -- Not held by the dead task, nor given its unread reply.
    local conn = assert(dial(connector, "127.0.0.1", echo, Clock.seconds(5)))
    assert(conn:close())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

local function test_a_connectors_table_is_a_copy()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local given: {Net.Endpoint} = { { host = "127.0.0.1", port = port } }
    local connector = assert(Net.connector(given))
    given[1].host = "127.0.0.9"
    local conn, why = dial(connector, "127.0.0.9", port, Clock.seconds(5))
    assert(conn == nil and why:find("not in the connector's table", 1, true) ~= nil, tostring(why))
    local ok = assert(dial(connector, "127.0.0.1", port, Clock.seconds(5)))
    assert(ok:close())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end

local function test_a_connector_refuses_what_a_host_cannot_confine_or_a_table_that_is_no_table()
  local make = Net.connector as function(any...): (any...) -- cast: tables that are no tables of endpoints
  local ok, why = pcall(make, {})
  assert(not ok and tostring(why):find("needs endpoints, opts.public, or both", 1, true) ~= nil, tostring(why))
  -- An empty table is public-only; it needs a host that confines the process.
  if ok == false then
    local public, trouble = Net.connector({}, { public = { deny = {} } })
    if public ~= nil then
      assert(public:close())
    else
      assert(trouble:find("child: ", 1, true) == 1, trouble)
    end
  end
  local many: {Net.Endpoint} = {}
  for port = 1, 129 do many[port] = { host = "127.0.0.1", port = port } end
  ok, why = pcall(make, many)
  assert(not ok and tostring(why):find("endpoints must be from 1 to 128", 1, true) ~= nil, tostring(why))
  local malformed: any = { { host = 1, port = 1 } }
  ok, why = pcall(make, malformed)
  assert(not ok and tostring(why):find("endpoints[1] must be a host and a port", 1, true) ~= nil, tostring(why))
  ok, why = pcall(make, { { host = "127.0.0.1", port = 65536 } })
  assert(not ok and tostring(why):find("endpoints[1]", 1, true) ~= nil, tostring(why))
  ok, why = pcall(make, { { host = "127.0.0.1", port = 9 } }, { timeout_ns = 0 })
  assert(not ok and tostring(why):find("timeout_ns must be", 1, true) ~= nil, tostring(why))
  -- A host that is no numeric address raises, as the core's does.
  ok, why = pcall(make, { { host = "localhost", port = 80 } })
  assert(not ok, "a name is no endpoint")
  -- Where the connector cannot be confined it says so, whatever the table.
  local result, trouble = Connector.start({ { host = "127.0.0.1", port = 80 } }, 1000)
  if result == nil then
    assert(trouble:find("child: ", 1, true) == 1, trouble)
  else
    assert(result:close())
    assert(result:close())
  end
end

local function test_a_public_connector_connects_to_an_address_its_table_lacks()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    -- No test reaches a public host, so loopback stands in with an empty deny list.
    local bare = assert(Net.connector({}, { public = { deny = {} } }))
    echo_through(assert(dial(bare, "127.0.0.1", port, Clock.seconds(5))), "public")
    for _, target in ipairs({ "localhost", "127.1", "::ffff:127.0.0.1" }) do
      local conn, why = dial(bare, target, port, Clock.seconds(5))
      assert(conn == nil and why:find(target .. " is not a numeric address", 1, true) ~= nil or
          why:find("refused by the connector's deny list", 1, true) ~= nil, target .. ": " .. tostring(why))
    end
    local no_port, why_port = dial(bare, "127.0.0.1", 0, Clock.seconds(5))
    assert(no_port == nil and why_port:find("port must be from 1 to 65535", 1, true) ~= nil, tostring(why_port))
    assert(bare:close())
    -- A table beside it: the table's entries by address, the rest public.
    local both = assert(Net.connector({ { host = "127.0.0.1", port = port } }, { public = { deny = {} } }))
    echo_through(assert(dial(both, "127.0.0.1", port, Clock.seconds(5))), "by address")
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local other = free.address.port
    assert(free:close())
    local conn, why = dial(both, "127.0.0.1", other, Clock.seconds(5))
    assert(conn == nil and why:find("refused", 1, true) ~= nil, tostring(why))
    assert(both:close())
    task:cancel()
    assert(listener:close())
  end)
  assert(descriptor_count() == before, "a public connector left a descriptor open")
end

--- A full table of 128 endpoints still leaves room for the public lists:
--- the one process holds both.
local function test_a_full_table_and_the_public_lists_share_one_process()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local other, other_task = echo_server()
    local rows: {Net.Endpoint} = { { host = "127.0.0.1", port = listener.address.port } }
    for i = 2, 128 do rows[i] = { host = "10.0.0." .. i, port = 80 } end
    local connector = assert(Net.connector(rows, { public = { deny = {} } }))
    echo_through(assert(dial(connector, "127.0.0.1", listener.address.port, Clock.seconds(5))), "table")
    echo_through(assert(dial(connector, "127.0.0.1", other.address.port, Clock.seconds(5))), "public")
    assert(connector:close())
    task:cancel()
    other_task:cancel()
    assert(listener:close())
    assert(other:close())
  end)
end

local function test_a_public_connector_refuses_what_its_lists_hold()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    for _, public in ipairs({ { deny = { "127.0.0.0/8" } }, { deny = {}, own = { "127.0.0.1" } },
        { deny = Relay.Address.deny_cidrs() } } as {Net.PublicOptions}) do
      local connector = assert(Net.connector({}, { public = public }))
      local conn, why = dial(connector, "127.0.0.1", port, Clock.seconds(5))
      assert(conn == nil and why == "net: 127.0.0.1 is refused by the connector's deny list", tostring(why))
      -- The process answered and still serves.
      local again, why_again = dial(connector, "127.0.0.1", port, Clock.seconds(5))
      assert(again == nil and why_again == why)
      assert(connector:close())
    end
    task:cancel()
    assert(listener:close())
  end)
end

local function test_a_public_connector_is_asked_nothing_it_was_not_started_for()
  require_native_connector()
  local ok, why = pcall(Net.connector, {}, { public = { deny = "10.0.0.0/8" } as any as Net.PublicOptions })
  assert(not ok and tostring(why):find("net: public must hold a deny list", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Net.connector, {}, { public = { deny = { "10.0.0.0" } } })
  assert(not ok, "a prefix with no length")
  -- A table connector with no public mode asks only its table.
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
    local conn, trouble = dial(connector, "127.0.0.2", port, Clock.seconds(5))
    assert(conn == nil and trouble:find("is not in the connector's table", 1, true) ~= nil, tostring(trouble))
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end
