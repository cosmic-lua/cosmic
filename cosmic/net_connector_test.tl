--- [`Net.listener_from`] and [`Net.connector`]: a listening socket
--- another process or an earlier call made, taken as a listener, and the
--- confined native connector (core/connector.c) as a connection maker.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
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

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares
local socket = raw_behind("cosmic.net") as raw_socket -- cast: the table core/socket.h declares

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
    local conn, why = connector:connect(asked, port, Clock.seconds(5))
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
    -- By address, by index, and again through the same process.
    local targets: {integer | string} = { "127.0.0.1", 1 }
    for _, target in ipairs(targets) do
      local conn = assert(connector:connect(target, port, Clock.seconds(5)))
      conn:set_timeout(Clock.seconds(5))
      assert(conn:write("hello " .. tostring(target)))
      assert(assert(conn:read()) == "hello " .. tostring(target))
      assert(conn:close())
    end
    -- What the table does not name: another port, address or index.
    local function refused(target: integer | string, at: integer, fragment: string)
      local conn, why = connector:connect(target, at, Clock.seconds(5))
      assert(conn == nil and why:find(fragment, 1, true) ~= nil, tostring(target) .. ":" .. at .. " " .. tostring(why))
    end
    refused("127.0.0.1", port == 65535 and 1 or port + 1, "is not in the connector's table")
    refused("127.0.0.3", port, "is not in the connector's table")
    refused("localhost", port, "is not in the connector's table")
    refused(4, port, "has no endpoint 4")
    refused(0, port, "has no endpoint 0")
    refused(1, port + 1, "is not endpoint 1's")
    -- A wildcard port at its own address is allowed, and the port nothing listens at is refused by the kernel.
    local conn, why = connector:connect("127.0.0.2", port, Clock.seconds(5))
    assert(conn == nil and why ~= "" and why:find("not in the connector", 1, true) == nil, tostring(why))
    -- A wildcard port: any nonzero port at that address, here the echo server's own.
    local wildcard = assert(Net.connector({ { host = "127.0.0.1", port = 0 } }))
    local wild = assert(wildcard:connect(1, port, Clock.seconds(5)))
    assert(wild:close())
    local none, nothing = wildcard:connect("127.0.0.1", 0, Clock.seconds(5))
    assert(none == nil and nothing:find("not in the connector's table", 1, true) ~= nil, tostring(nothing))
    assert(wildcard:close())
    -- The process answered every one of those and still serves.
    local after = assert(connector:connect("127.0.0.1", port, Clock.seconds(5)))
    assert(after:close())
    assert(connector:close())
    assert(connector:close())
    local closed, trouble = connector:connect("127.0.0.1", port, Clock.seconds(5))
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
        local conn = assert(connector:connect("127.0.0.1", port, Clock.seconds(5)))
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

local function test_a_connector_without_a_table_starts_a_process_for_each_connection()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector())
    local connect = connector:as_function()
    for n = 1, 3 do
      local conn = assert(connect("127.0.0.1", port, Clock.seconds(5)))
      conn:set_timeout(Clock.seconds(5))
      assert(conn:write("n" .. n))
      assert(assert(conn:read()) == "n" .. n)
      assert(conn:close())
    end
    -- A port that was free a moment ago: the connector's errno is the reason.
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local closed = free.address.port
    assert(free:close())
    local conn, why = connect("127.0.0.1", closed, Clock.seconds(5))
    assert(conn == nil and why:find("refused", 1, true) ~= nil, tostring(why))
    -- An index names nothing here, and a name is no address.
    local none, trouble = connector:connect(1, port, Clock.seconds(5))
    assert(none == nil and trouble:find("numeric address", 1, true) ~= nil, tostring(trouble))
    local named, why_named = connect("localhost", port, Clock.seconds(5))
    assert(named == nil and why_named:find("not a numeric address", 1, true) ~= nil, tostring(why_named))
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
  assert(descriptor_count() == before, "a connector for each connection left a descriptor open")
end

local function test_a_connector_dropped_unclosed_is_ended_when_collected()
  require_native_connector()
  local before = descriptor_count()
  local pid: integer
  do
    local started = assert(Child.start_connector({ { host = "127.0.0.1", port = 9 } }, 1000))
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
      local _, why = connector:connect(1, port, Clock.ms(800))
      hung = why
    end)
    assert(Poll.delay(Clock.ms(50)))
    local tasks: {Poll.Task} = {}
    local done: {integer} = {}
    for n = 1, 8 do
      tasks[n] = Poll.spawn(function()
        local conn = assert(connector:connect(2, echo, Clock.seconds(5)))
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
    local conn = assert(connector:connect(2, echo, Clock.seconds(5)))
    assert(conn:close())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
end

--- A connector makes at most Net.CONNECTOR_FLIGHT connections at once,
--- and a request it gave up on, its task killed, counts until the process
--- answers it: a request past them waits for room within its own time,
--- and is made once one of them is answered.
local function test_requests_past_the_flight_wait_for_room()
  require_native_connector()
  assert(Net.CONNECTOR_FLIGHT == 64)
  Poll.run(function()
    local port, held = hung_port()
    local listener, task = echo_server()
    local echo = listener.address.port
    local connector = assert(Net.connector({
      { host = "127.0.0.1", port = port }, { host = "127.0.0.1", port = echo },
    }, { timeout_ns = Clock.seconds(30) }))
    local hanging: {Poll.Task} = {}
    for n = 1, Net.CONNECTOR_FLIGHT do
      hanging[n] = Poll.spawn(function()
        local _, _ = connector:connect(1, port, Clock.seconds(2))
      end)
    end
    assert(Poll.delay(Clock.ms(100)))
    local killed_at = Clock.monotonic_ns()
    for _, each in ipairs(hanging) do each:kill() end
    -- No room while the process still makes them, given up on or not.
    local none, why = connector:connect(2, echo, Clock.ms(300))
    assert(none == nil and why == Poll.TIMEOUT, tostring(why))
    local conn = assert(connector:connect(2, echo, Clock.seconds(10)))
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
--- flood of one kind, even given up on (it counts until answered), leaves
--- the other 16 at once, and the flooded kind its own 48 and no more.
local function test_each_kind_of_request_keeps_flights_against_the_other()
  require_native_connector()
  Poll.run(function()
    local table_hung, held = hung_port()
    local public_hung, more = hung_port()
    for _, each in ipairs(more) do held[#held + 1] = each end
    local table_echo, table_task = echo_server()
    local public_echo, public_task = echo_server()
    -- Entry 2 hangs; the public ones go to addresses no entry holds at that port.
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = table_echo.address.port },
      { host = "127.0.0.1", port = table_hung } }, { timeout_ns = Clock.seconds(30), public = { deny = {} } }))
    local function table_call(): Net.Conn | nil, string
      return connector:connect(1, table_echo.address.port, Clock.ms(500))
    end
    local function public_call(): Net.Conn | nil, string
      return connector:connect("127.0.0.1", public_echo.address.port, Clock.ms(500))
    end
    local function table_hangs(): Net.Conn | nil, string
      return connector:connect(2, table_hung, Clock.seconds(2))
    end
    local function public_hangs(): Net.Conn | nil, string
      return connector:connect("127.0.0.1", public_hung, Clock.seconds(2))
    end
    local floods = {
      { name = "table", flood = table_hangs, other = public_call },
      { name = "public", flood = public_hangs, other = table_call },
    }
    for _, case in ipairs(floods) do
      local hanging: {Poll.Task} = {}
      for n = 1, Net.CONNECTOR_FLIGHT do
        hanging[n] = Poll.spawn(function()
          local _, _ = case.flood()
        end)
      end
      assert(Poll.delay(Clock.ms(100)))
      -- Given up on, and so still counted until the process answers each.
      for _, each in ipairs(hanging) do each:kill() end
      assert(made_at_once(16, case.other) == 16, "the other kind waited behind the " .. case.name .. " flood")
      -- The flooded kind has the rest of its 48, and no more.
      local none, why = case.flood()
      assert(none == nil and why == Poll.TIMEOUT, case.name .. ": " .. tostring(why))
      -- Wait out the stalled connects, which the process ends at its wait.
      assert(Poll.delay(Clock.seconds(3)))
      assert(made_at_once(1, case.flood == table_hangs and table_call or public_call) == 1)
    end
    assert(connector:close())
    table_task:cancel()
    public_task:cancel()
    assert(table_echo:close())
    assert(public_echo:close())
    for _, each in ipairs(held) do assert(each:close()) end
  end)
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
      local _, why = connector:connect(1, port, Clock.seconds(20))
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
      local _, _ = connector:connect(1, port, Clock.seconds(20))
    end)
    assert(Poll.delay(Clock.ms(100)))
    waiting:kill()
    -- Not held by the dead task, nor given its unread reply.
    local conn = assert(connector:connect(2, echo, Clock.seconds(5)))
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
    local conn, why = connector:connect("127.0.0.9", port, Clock.seconds(5))
    assert(conn == nil and why:find("not in the connector's table", 1, true) ~= nil, tostring(why))
    local ok = assert(connector:connect("127.0.0.1", port, Clock.seconds(5)))
    assert(ok:close())
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end

local function test_a_connector_refuses_what_a_host_cannot_confine_or_a_table_that_is_no_table()
  local make = Net.connector as function(any...): (any...) -- cast: tables that are no tables of endpoints
  local ok, why = pcall(make, {})
  assert(not ok and tostring(why):find("endpoints must be from 1 to 128", 1, true) ~= nil, tostring(why))
  local malformed: any = { { host = 1, port = 1 } }
  ok, why = pcall(make, malformed)
  assert(not ok and tostring(why):find("endpoints[1] must be a host and a port", 1, true) ~= nil, tostring(why))
  ok, why = pcall(make, { { host = "127.0.0.1", port = 65536 } })
  assert(not ok and tostring(why):find("endpoints[1]", 1, true) ~= nil, tostring(why))
  ok, why = pcall(make, nil, { timeout_ns = 0 })
  assert(not ok and tostring(why):find("timeout_ns must be", 1, true) ~= nil, tostring(why))
  -- A host that is no numeric address raises, as the core's does.
  ok, why = pcall(make, { { host = "localhost", port = 80 } })
  assert(not ok, "a name is no endpoint")
  -- Where the connector cannot be confined it says so, whatever the table.
  local result, trouble = Child.start_connector({ { host = "127.0.0.1", port = 80 } }, 1000)
  if result == nil then
    assert(trouble:find("child: ", 1, true) == 1, trouble)
  else
    assert(result:close())
    assert(result:close())
  end
end

--- Echoes `text` through `conn` and closes it.
local function echoed(conn: Net.Conn, text: string)
  conn:set_timeout(Clock.seconds(5))
  assert(conn:write(text))
  assert(assert(conn:read()) == text)
  assert(conn:close())
end

local function test_a_public_connector_connects_to_an_address_its_table_lacks()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    -- No test reaches a public host, so loopback stands in with an empty deny list.
    local bare = assert(Net.connector(nil, { public = { deny = {} } }))
    echoed(assert(bare:connect("127.0.0.1", port, Clock.seconds(5))), "public")
    echoed(assert(bare:as_function()("127.0.0.1", port, Clock.seconds(5))), "as a function")
    for _, target in ipairs({ "localhost", "127.1", "::ffff:127.0.0.1" }) do
      local conn, why = bare:connect(target, port, Clock.seconds(5))
      assert(conn == nil and why:find(target .. " is not a numeric address", 1, true) ~= nil or
          why:find("refused by the connector's deny list", 1, true) ~= nil, target .. ": " .. tostring(why))
    end
    local no_port, why_port = bare:connect("127.0.0.1", 0, Clock.seconds(5))
    assert(no_port == nil and why_port:find("port must be from 1 to 65535", 1, true) ~= nil, tostring(why_port))
    assert(bare:close())
    -- A table beside it: the table's entries by address or index, the rest public.
    local both = assert(Net.connector({ { host = "127.0.0.1", port = port } }, { public = { deny = {} } }))
    echoed(assert(both:connect(1, port, Clock.seconds(5))), "by index")
    echoed(assert(both:connect("127.0.0.1", port, Clock.seconds(5))), "by address")
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local other = free.address.port
    assert(free:close())
    local conn, why = both:connect("127.0.0.1", other, Clock.seconds(5))
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
    echoed(assert(connector:connect("127.0.0.1", listener.address.port, Clock.seconds(5))), "table")
    echoed(assert(connector:connect("127.0.0.1", other.address.port, Clock.seconds(5))), "public")
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
      local connector = assert(Net.connector(nil, { public = public }))
      local conn, why = connector:connect("127.0.0.1", port, Clock.seconds(5))
      assert(conn == nil and why == "net: 127.0.0.1 is refused by the connector's deny list", tostring(why))
      -- The process answered and still serves.
      local again, why_again = connector:connect("127.0.0.1", port, Clock.seconds(5))
      assert(again == nil and why_again == why)
      assert(connector:close())
    end
    task:cancel()
    assert(listener:close())
  end)
end

local function test_a_public_connector_is_asked_nothing_it_was_not_started_for()
  require_native_connector()
  local ok, why = pcall(Net.connector, nil, { public = { deny = "10.0.0.0/8" } as any as Net.PublicOptions })
  assert(not ok and tostring(why):find("net: public must hold a deny list", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Net.connector, nil, { public = { deny = { "10.0.0.0" } } })
  assert(not ok, "a prefix with no length")
  -- A table connector with no public mode asks only its table.
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local connector = assert(Net.connector({ { host = "127.0.0.1", port = port } }))
    local conn, trouble = connector:connect("127.0.0.2", port, Clock.seconds(5))
    assert(conn == nil and trouble:find("is not in the connector's table", 1, true) ~= nil, tostring(trouble))
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end

local function test_connector_from_wraps_an_inherited_control_stream_without_a_process()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({ { host = "127.0.0.1", port = port } }, pair[2], 1000,
      { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = port } }, true))
    echoed(assert(connector:connect(1, port, Clock.seconds(5))), "table")
    echoed(assert(connector:connect("127.0.0.1", port, Clock.seconds(5))), "by address")
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local other = free.address.port
    assert(free:close())
    local gone, why = connector:connect("127.0.0.1", other, Clock.seconds(5))
    assert(gone == nil and why:find("refused", 1, true) ~= nil, tostring(why))
    -- Closing it closes the stream only: the process sees the end of it and exits by itself.
    assert(connector:close())
    assert(connector:close())
    local ended = assert(process.waitpid(child, false))
    assert(ended.code == 0)
    task:cancel()
    assert(listener:close())
  end)
  assert(descriptor_count() == before, "an adopted connector left a descriptor open")
end

local function test_connector_from_asks_a_public_process_for_an_address_its_table_lacks()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({}, pair[2], 1000, { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Net.connector_from(pair[1], nil, true))
    echoed(assert(connector:connect("127.0.0.1", port, Clock.seconds(5))), "public")
    assert(connector:close())
    assert(assert(process.waitpid(child, false)).code == 0)
    -- Not told it is public, it is asked nothing of the kind.
    local second = stream_pair()
    local other = assert(process.connector_start({}, second[2], 1000, { deny = {} }))
    assert(sys.close(second[2]))
    local plain = assert(Net.connector_from(second[1]))
    local conn, why = plain:connect("127.0.0.1", port, Clock.seconds(5))
    assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
    assert(plain:close())
    assert(assert(process.waitpid(other, false)).code == 0)
    task:cancel()
    assert(listener:close())
  end)
end

local function test_connector_from_is_not_started_again_when_its_process_ends()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({}, pair[2], 1000, { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Net.connector_from(pair[1], nil, true))
    assert(sys.kill(child, sys.SIGKILL))
    assert(process.waitpid(child, false))
    local conn, why = connector:connect("127.0.0.1", port, Clock.seconds(5))
    assert(conn == nil and why ~= "", tostring(why))
    local again, trouble = connector:connect("127.0.0.1", port, Clock.seconds(5))
    assert(again == nil and trouble == "net: the connector has ended", tostring(trouble))
    assert(connector:close())
    task:cancel()
    assert(listener:close())
  end)
end

--- A socket refused at once, by a loopback port nothing listens at: its
--- peer reset it, so it has none, as a socket whose server resets it as it
--- is made has none by the time the connector's reply is read.
local function reset_socket(): raw_socket.Socket
  local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = free.address.port
  assert(free:close())
  local made = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
  assert(Poll.writable(made:fd(), Clock.seconds(5)))
  return made
end

--- A stand-in for a connector process on `fd`, the other end of a stream
--- a connector adopted: it says `hello` (the protocol's own by default),
--- then, in a task of the run, hands each request it reads, whole, to
--- `on_request` with its tag, which replies as it will. The task, to
--- cancel.
local function stand_in(fd: integer, on_request: function(tag: integer, request: string), hello?: integer): Poll.Task
  assert(sys.set_nonblocking(fd, true))
  assert(sys.write(fd, string.pack(">I4", hello or socket.CONNECTOR_HELLO)) == 4)
  return Poll.spawn(function()
    local held = ""
    while true do
      local data, _, errno = sys.read(fd, socket.CONNECTOR_REQUEST_BYTES - #held)
      if data == "" or (data == nil and errno ~= sys.EAGAIN) then return end
      if data == nil then
        if not Poll.readable(fd) then return end
      else
        held = held .. data
        if #held == socket.CONNECTOR_REQUEST_BYTES then
          local request = held
          held = ""
          on_request((string.unpack(">I4", request)), request)
        end
      end
    end
  end)
end

--- A reply that came whole leaves an inherited connector in step though the
--- socket it passes is no connection any more: that request fails alone,
--- whether it named a table's endpoint or a public address, and the next is
--- asked of the same stream.
local function test_connector_from_serves_on_after_a_socket_reset_as_it_was_made()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 } }, true,
      Clock.seconds(1)))
    local asked: {string} = {}
    local refuse = false
    local serving = stand_in(pair[2], function(tag: integer, request: string)
      asked[#asked + 1] = request
      if refuse then
        assert(sys.write(pair[2], string.pack(">I4I4", tag, socket.ECONNREFUSED)) == 8)
        return
      end
      local reset = reset_socket()
      assert(sys.write(pair[2], string.pack(">I4I4", tag, 0)) == 8)
      assert(socket.sendfds(pair[2], { reset:fd() }))
      assert(reset:close())
    end)
    local targets: {integer | string} = { 1, "127.0.0.2" }
    for _, target in ipairs(targets) do
      local conn, why = connector:connect(target, 9, Clock.seconds(1))
      assert(conn == nil and why:find("ended as it was made", 1, true) ~= nil, tostring(why))
      assert(not connector:ended(), "the connector serves on after " .. tostring(target))
    end
    refuse = true
    local refused, refusal = connector:connect(1, 9, Clock.seconds(1))
    assert(refused == nil and refusal:find("refused", 1, true) ~= nil, tostring(refusal))
    -- What the stand-in was asked: a table request, a public one, a table
    -- one, tagged in turn, each with its wait in milliseconds.
    assert(#asked == 3)
    assert(asked[1] == string.pack(">I4I4I4I4I4", 1, 1, 9, 1000, 0) .. string.rep("\0", 16), ("%q"):format(asked[1]))
    assert(asked[2] == string.pack(">I4I4I4I4I4", 2, 0xffffffff, 9, 1000, 4) .. string.char(127, 0, 0, 2) ..
        string.rep("\0", 12), ("%q"):format(asked[2]))
    assert(asked[3]:sub(1, 12) == string.pack(">I4I4I4", 3, 1, 9), ("%q"):format(asked[3]))
    serving:cancel()
    assert(connector:close())
    assert(connector:ended())
    assert(sys.close(pair[2]))
  end)
end

--- A reply that came whole with a socket connected elsewhere, or with a
--- descriptor that is no socket, is none a connector that works gives:
--- the request fails naming it, and the stream is given up, not asked
--- again, as one that misbehaves.
local function test_connector_from_gives_up_a_stream_that_passes_the_wrong_descriptor()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local port = listener.address.port
    local elsewhere = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
    assert(Poll.writable(elsewhere:fd(), Clock.seconds(5)))
    local null = assert(sys.open("/dev/null", sys.O_RDONLY))
    local cases: {{integer | string}} = {
      { elsewhere:fd(), "passed a socket connected to 127.0.0.1:" .. port .. ", not 127.0.0.1:9" },
      { null, "passed a descriptor that is no connected stream socket" },
    }
    for _, case in ipairs(cases) do
      local pair = stream_pair()
      local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
        Clock.seconds(1)))
      local serving = stand_in(pair[2], function(tag: integer, _: string)
        assert(sys.write(pair[2], string.pack(">I4I4", tag, 0)) == 8)
        assert(socket.sendfds(pair[2], { case[1] as integer }))
      end)
      local conn, why = connector:connect(1, 9, Clock.seconds(1))
      assert(conn == nil and why:find(case[2] as string, 1, true) ~= nil, tostring(why))
      assert(connector:ended(), "the connector is given up after: " .. why)
      local again, trouble = connector:connect(1, 9, Clock.seconds(1))
      assert(again == nil and trouble == "net: the connector has ended", tostring(trouble))
      serving:cancel()
      assert(connector:close())
      assert(sys.close(pair[2]))
    end
    assert(sys.close(null))
    assert(elsewhere:close())
    assert(listener:close())
  end)
end

--- Replies come in the order the connects end, not the order they were
--- asked in: each is handed to the request its tag names.
local function test_replies_out_of_order_reach_the_requests_their_tags_name()
  Poll.run(function()
    local pair = stream_pair()
    local endpoints: {Net.Endpoint} = {}
    for i = 1, 3 do endpoints[i] = { host = "127.0.0." .. i, port = 9 } end
    local connector = assert(Net.connector_from(pair[1], endpoints, false, Clock.seconds(5)))
    local tags: {integer: integer} = {}
    local count = 0
    -- Each endpoint's own refusal, so the answer shows whose it was.
    local errnos: {integer} = { socket.ECONNREFUSED, socket.ETIMEDOUT, sys.EPERM }
    local serving = stand_in(pair[2], function(tag: integer, request: string)
      local index = string.unpack(">I4", request, 5)
      tags[index] = tag
      count = count + 1
      if count < 3 then return end
      for i = 3, 1, -1 do
        assert(sys.write(pair[2], string.pack(">I4I4", tags[i], errnos[i])) == 8)
      end
    end)
    local answers: {integer: string} = {}
    local tasks: {Poll.Task} = {}
    for i = 1, 3 do
      tasks[i] = Poll.spawn(function()
        local conn, why = connector:connect(i, 9, Clock.seconds(5))
        assert(conn == nil)
        answers[i] = why
      end)
    end
    for i = 1, 3 do assert(tasks[i]:join()) end
    assert(answers[1]:find("refused", 1, true) ~= nil, answers[1])
    assert(answers[2] == Poll.TIMEOUT, answers[2])
    assert(answers[3] == sys.errno_message(sys.EPERM), answers[3])
    assert(not connector:ended())
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

--- A reply for a request no one asked, a framing error, puts the stream
--- out of step: every request waiting on it fails, and an adopted
--- connector has ended. A connector's refusal for want of room is said.
local function test_a_reply_no_request_was_tagged_with_fails_every_request_waiting()
  Poll.run(function()
    local pair = stream_pair()
    local endpoints: {Net.Endpoint} = { { host = "127.0.0.1", port = 9 } }
    local connector = assert(Net.connector_from(pair[1], endpoints, false, Clock.seconds(5)))
    local count = 0
    local serving = stand_in(pair[2], function(tag: integer, _: string)
      count = count + 1
      if count == 1 then
        assert(sys.write(pair[2], string.pack(">I4I4", tag, socket.CONNECTOR_BUSY)) == 8)
      elseif count == 4 then
        assert(sys.write(pair[2], string.pack(">I4I4", 999, 0)) == 8)
      end
    end)
    local busy, busy_why = connector:connect(1, 9, Clock.seconds(5))
    assert(busy == nil and busy_why:find("the connector is busy", 1, true) ~= nil, tostring(busy_why))
    assert(not connector:ended(), "a refusal for want of room leaves the stream in step")
    local answers: {string} = {}
    local tasks: {Poll.Task} = {}
    for i = 1, 3 do
      tasks[i] = Poll.spawn(function()
        local conn, why = connector:connect(1, 9, Clock.seconds(5))
        assert(conn == nil)
        answers[i] = why
      end)
    end
    for i = 1, 3 do assert(tasks[i]:join()) end
    for i = 1, 3 do
      assert(answers[i] == "net: the connector replied to a request it was not asked (tag 999)", answers[i])
    end
    assert(connector:ended())
    local again, trouble = connector:connect(1, 9, Clock.seconds(1))
    assert(again == nil and trouble == "net: the connector has ended", tostring(trouble))
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

--- A reply one task reads for another wakes the other: a request whose
--- reply comes while a second task asks is answered then, not when more
--- bytes come or its deadline passes. The second task's own request is
--- never answered, so nothing else wakes the first.
local function test_a_reply_another_task_reads_wakes_its_owner()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 },
      { host = "127.0.0.2", port = 9 } }, false, Clock.seconds(5)))
    local first_tag: integer
    local serving = stand_in(pair[2], function(tag: integer, request: string)
      if string.unpack(">I4", request, 5) == 1 then first_tag = tag end
    end)
    local started = Clock.monotonic_ns()
    local first: string
    local took: integer
    local asking = Poll.spawn(function()
      local conn, why = connector:connect(1, 9, Clock.seconds(3))
      assert(conn == nil)
      first, took = why, Clock.monotonic_ns() - started
    end)
    assert(Poll.delay(Clock.ms(100)))
    assert(first_tag ~= nil, "the first request was not asked")
    -- Its reply, and then a request of this task's, whose read takes it.
    assert(sys.write(pair[2], string.pack(">I4I4", first_tag, socket.ECONNREFUSED)) == 8)
    local conn, why = connector:connect(2, 9, Clock.ms(100))
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(asking:join(Clock.seconds(5)))
    assert(first ~= nil and first:find("refused", 1, true) ~= nil, tostring(first))
    assert(took < Clock.seconds(1), "the first request was answered after " .. took // Clock.ms(1) .. " ms")
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

--- A task waiting for room on a stream that is then lost sends nothing:
--- the descriptor's number, closed with the stream, may be another's by
--- the time it looks again.
local function test_a_lost_stream_sends_nothing_to_its_closed_descriptor()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(5)))
    local count = 0
    local serving = stand_in(pair[2], function(_: integer, _: string)
      count = count + 1
      if count == Net.CONNECTOR_FLIGHT then
        assert(sys.write(pair[2], string.pack(">I4I4", 999, 0)) == 8)
      end
    end)
    local taken: {integer}
    local tasks: {Poll.Task} = {}
    for i = 1, Net.CONNECTOR_FLIGHT do
      tasks[i] = Poll.spawn(function()
        local conn, _ = connector:connect(1, 9, Clock.seconds(3))
        assert(conn == nil)
        -- The first to learn of the loss opens a pair, which takes the
        -- lowest numbers free: the stream's closed one among them.
        if taken == nil then taken = stream_pair() end
      end)
    end
    local past: string
    local waiting = Poll.spawn(function()
      local conn, why = connector:connect(1, 9, Clock.seconds(3))
      assert(conn == nil)
      past = why
    end)
    for i = 1, Net.CONNECTOR_FLIGHT do assert(tasks[i]:join(Clock.seconds(5))) end
    assert(waiting:join(Clock.seconds(5)))
    assert(past == "net: the connector replied to a request it was not asked (tag 999)", tostring(past))
    assert(count == Net.CONNECTOR_FLIGHT, count .. " requests were sent")
    assert(taken ~= nil)
    assert(sys.set_nonblocking(taken[2], true))
    local leaked, _, errno = sys.read(taken[2], 4096)
    assert(leaked == nil and errno == sys.EAGAIN, "bytes went to the descriptor that took the closed number: " ..
        tostring(leaked and #leaked))
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]) and sys.close(taken[1]) and sys.close(taken[2]))
  end)
end

--- A task cancelled while it waits for room asks nothing, though room
--- comes as it is cancelled: a request sent then would be given up at
--- once, and the connector would make its connect and hold its slot all
--- the same.
local function test_a_task_cancelled_waiting_for_room_asks_nothing()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(30)))
    local tags: {integer} = {}
    local serving = stand_in(pair[2], function(tag: integer, _: string) tags[#tags + 1] = tag end)
    local tasks: {Poll.Task} = {}
    for i = 1, Net.CONNECTOR_FLIGHT do
      tasks[i] = Poll.spawn(function() local _, _ = connector:connect(1, 9, Clock.seconds(3)) end)
    end
    local cancelled: string
    local waiting = Poll.spawn(function()
      local conn, why = connector:connect(1, 9, Clock.seconds(3))
      assert(conn == nil)
      cancelled = why
    end)
    assert(Poll.delay(Clock.ms(50)))
    assert(#tags == Net.CONNECTOR_FLIGHT, #tags .. " requests were asked")
    -- Room for two, and the waiting task cancelled before it looks again.
    assert(sys.write(pair[2], string.pack(">I4I4I4I4", tags[1], socket.ECONNREFUSED, tags[2],
      socket.ECONNREFUSED)) == 16)
    waiting:cancel()
    local conn, why = connector:connect(1, 9, Clock.ms(50))
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(waiting:join(Clock.seconds(5)))
    assert(cancelled == Poll.CANCELLED, tostring(cancelled))
    assert(#tags == Net.CONNECTOR_FLIGHT + 1, "the cancelled task asked: " .. #tags .. " requests")
    for _, task in ipairs(tasks) do task:cancel() end
    for _, task in ipairs(tasks) do assert(task:join(Clock.seconds(5))) end
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

--- A connector of another protocol says another hello: it is asked
--- nothing, and the request fails saying so.
local function test_a_connector_of_another_protocol_is_asked_nothing()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Net.connector_from(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(1)))
    local asked = 0
    local serving = stand_in(pair[2], function(_: integer, _: string) asked = asked + 1 end, 0x434e4301)
    local conn, why = connector:connect(1, 9, Clock.seconds(1))
    assert(conn == nil and why == "net: the connector speaks another protocol than this program's: " ..
        "it said 0x434e4301, not 0x434e4302", tostring(why))
    assert(connector:ended())
    assert(asked == 0, "a request was sent before the hello was checked")
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

local function test_connector_from_refuses_what_is_no_descriptor_or_table()
  local ok, why = pcall(Net.connector_from, -1)
  assert(not ok and tostring(why):find("fd must be a descriptor", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Net.connector_from, "3" as any as integer)
  assert(not ok and tostring(why):find("fd must be a descriptor", 1, true) ~= nil, tostring(why))
  local pair = stream_pair()
  ok, why = pcall(Net.connector_from, pair[1], { { host = "127.0.0.1" } } as {Net.Endpoint})
  assert(not ok and tostring(why):find("endpoints[1] must be a host and a port", 1, true) ~= nil, tostring(why))
  assert(sys.close(pair[1]) and sys.close(pair[2]))
  -- A descriptor that is open but no stream cannot be made nonblocking where it is not open.
  local none, trouble = Net.connector_from(1000000)
  assert(none == nil and trouble:find("child: ", 1, true) == 1, tostring(trouble))
end
