--- The native connector's client protocol, spoken to stand-in processes: a
--- connector over an inherited control stream ([`Connector.adopted`]),
--- replies out of order or from the wrong protocol, and a stream that
--- falls out of step. The connector [`Net.connector`] starts is in
--- cosmic/net_connector_test.tl.
local Clock = require("cosmic.clock")
local Connector = require("cosmic.internal.connector")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
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

--- A stream socketpair, by the connector's own maker, which a test may use as one.
local function stream_pair(): {integer}
  return (assert(process.connector_pair()))
end

local function test_adopted_connector_wraps_an_inherited_control_stream_without_a_process()
  require_native_connector()
  local before = descriptor_count()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({ { host = "127.0.0.1", port = port } }, pair[2], 1000,
      { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = port } }, true))
    echo_through(assert(dial(connector, "127.0.0.1", port, Clock.seconds(5))), "table")
    local free = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local other = free.address.port
    assert(free:close())
    local gone, why = dial(connector, "127.0.0.1", other, Clock.seconds(5))
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

local function test_adopted_connector_asks_a_public_process_for_an_address_its_table_lacks()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({}, pair[2], 1000, { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Connector.adopted(pair[1], nil, true))
    echo_through(assert(dial(connector, "127.0.0.1", port, Clock.seconds(5))), "public")
    assert(connector:close())
    assert(assert(process.waitpid(child, false)).code == 0)
    -- Not told it is public, it is asked nothing of the kind.
    local second = stream_pair()
    local other = assert(process.connector_start({}, second[2], 1000, { deny = {} }))
    assert(sys.close(second[2]))
    local plain = assert(Connector.adopted(second[1]))
    local conn, why = dial(plain, "127.0.0.1", port, Clock.seconds(5))
    assert(conn == nil and why:find("is not in the connector's table", 1, true) ~= nil, tostring(why))
    assert(plain:close())
    assert(assert(process.waitpid(other, false)).code == 0)
    task:cancel()
    assert(listener:close())
  end)
end

local function test_adopted_connector_is_not_started_again_when_its_process_ends()
  require_native_connector()
  Poll.run(function()
    local listener, task = echo_server()
    local port = listener.address.port
    local pair = stream_pair()
    local child = assert(process.connector_start({}, pair[2], 1000, { deny = {} }))
    assert(sys.close(pair[2]))
    local connector = assert(Connector.adopted(pair[1], nil, true))
    assert(sys.kill(child, sys.SIGKILL))
    assert(process.waitpid(child, false))
    local conn, why = dial(connector, "127.0.0.1", port, Clock.seconds(5))
    assert(conn == nil and why ~= "", tostring(why))
    local again, trouble = dial(connector, "127.0.0.1", port, Clock.seconds(5))
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
local function test_adopted_connector_serves_on_after_a_socket_reset_as_it_was_made()
  Poll.run(function()
    local pair = stream_pair()
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 } }, true,
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
    local targets: {string} = { "127.0.0.1", "127.0.0.2" }
    for _, target in ipairs(targets) do
      local conn, why = dial(connector, target, 9, Clock.seconds(1))
      assert(conn == nil and why:find("ended as it was made", 1, true) ~= nil, tostring(why))
      assert(not connector:ended(), "the connector serves on after " .. tostring(target))
    end
    refuse = true
    local refused, refusal = dial(connector, "127.0.0.1", 9, Clock.seconds(1))
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
local function test_adopted_connector_gives_up_a_stream_that_passes_the_wrong_descriptor()
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
      local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
        Clock.seconds(1)))
      local serving = stand_in(pair[2], function(tag: integer, _: string)
        assert(sys.write(pair[2], string.pack(">I4I4", tag, 0)) == 8)
        assert(socket.sendfds(pair[2], { case[1] as integer }))
      end)
      local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(1))
      assert(conn == nil and why:find(case[2] as string, 1, true) ~= nil, tostring(why))
      assert(connector:ended(), "the connector is given up after: " .. why)
      local again, trouble = dial(connector, "127.0.0.1", 9, Clock.seconds(1))
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
    local endpoints: {raw_process.ConnectorEndpoint} = {}
    for i = 1, 3 do endpoints[i] = { host = "127.0.0." .. i, port = 9 } end
    local connector = assert(Connector.adopted(pair[1], endpoints, false, Clock.seconds(5)))
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
        local conn, why = dial(connector, "127.0.0." .. i, 9, Clock.seconds(5))
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
    local endpoints: {raw_process.ConnectorEndpoint} = { { host = "127.0.0.1", port = 9 } }
    local connector = assert(Connector.adopted(pair[1], endpoints, false, Clock.seconds(5)))
    local count = 0
    local serving = stand_in(pair[2], function(tag: integer, _: string)
      count = count + 1
      if count == 1 then
        assert(sys.write(pair[2], string.pack(">I4I4", tag, socket.CONNECTOR_BUSY)) == 8)
      elseif count == 4 then
        assert(sys.write(pair[2], string.pack(">I4I4", 999, 0)) == 8)
      end
    end)
    local busy, busy_why = dial(connector, "127.0.0.1", 9, Clock.seconds(5))
    assert(busy == nil and busy_why:find("the connector is busy", 1, true) ~= nil, tostring(busy_why))
    assert(not connector:ended(), "a refusal for want of room leaves the stream in step")
    local answers: {string} = {}
    local tasks: {Poll.Task} = {}
    for i = 1, 3 do
      tasks[i] = Poll.spawn(function()
        local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(5))
        assert(conn == nil)
        answers[i] = why
      end)
    end
    for i = 1, 3 do assert(tasks[i]:join()) end
    for i = 1, 3 do
      assert(answers[i] == "net: the connector replied to a request it was not asked (tag 999)", answers[i])
    end
    assert(connector:ended())
    local again, trouble = dial(connector, "127.0.0.1", 9, Clock.seconds(1))
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
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 },
      { host = "127.0.0.2", port = 9 } }, false, Clock.seconds(5)))
    local first_tag: integer
    local serving = stand_in(pair[2], function(tag: integer, request: string)
      if string.unpack(">I4", request, 5) == 1 then first_tag = tag end
    end)
    local started = Clock.monotonic_ns()
    local first: string
    local took: integer
    local asking = Poll.spawn(function()
      local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(3))
      assert(conn == nil)
      first, took = why, Clock.monotonic_ns() - started
    end)
    assert(Poll.delay(Clock.ms(100)))
    assert(first_tag ~= nil, "the first request was not asked")
    -- Its reply, and then a request of this task's, whose read takes it.
    assert(sys.write(pair[2], string.pack(">I4I4", first_tag, socket.ECONNREFUSED)) == 8)
    local conn, why = dial(connector, "127.0.0.2", 9, Clock.ms(100))
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
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(5)))
    local count = 0
    local serving = stand_in(pair[2], function(_: integer, _: string)
      count = count + 1
      if count == FLIGHT then
        assert(sys.write(pair[2], string.pack(">I4I4", 999, 0)) == 8)
      end
    end)
    local taken: {integer}
    local tasks: {Poll.Task} = {}
    for i = 1, FLIGHT do
      tasks[i] = Poll.spawn(function()
        local conn, _ = dial(connector, "127.0.0.1", 9, Clock.seconds(3))
        assert(conn == nil)
        -- The first to learn of the loss opens a pair, which takes the
        -- lowest numbers free: the stream's closed one among them.
        if taken == nil then taken = stream_pair() end
      end)
    end
    local past: string
    local waiting = Poll.spawn(function()
      local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(3))
      assert(conn == nil)
      past = why
    end)
    for i = 1, FLIGHT do assert(tasks[i]:join(Clock.seconds(5))) end
    assert(waiting:join(Clock.seconds(5)))
    assert(past == "net: the connector replied to a request it was not asked (tag 999)", tostring(past))
    assert(count == FLIGHT, count .. " requests were sent")
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
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(30)))
    local tags: {integer} = {}
    local serving = stand_in(pair[2], function(tag: integer, _: string) tags[#tags + 1] = tag end)
    local tasks: {Poll.Task} = {}
    for i = 1, FLIGHT do
      tasks[i] = Poll.spawn(function()
        local _, _ = dial(connector, "127.0.0.1", 9, Clock.seconds(3))
      end)
    end
    local cancelled: string
    local waiting = Poll.spawn(function()
      local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(3))
      assert(conn == nil)
      cancelled = why
    end)
    assert(Poll.delay(Clock.ms(50)))
    assert(#tags == FLIGHT, #tags .. " requests were asked")
    -- Room for two, and the waiting task cancelled before it looks again.
    assert(sys.write(pair[2], string.pack(">I4I4I4I4", tags[1], socket.ECONNREFUSED, tags[2],
      socket.ECONNREFUSED)) == 16)
    waiting:cancel()
    local conn, why = dial(connector, "127.0.0.1", 9, Clock.ms(50))
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(waiting:join(Clock.seconds(5)))
    assert(cancelled == Poll.CANCELLED, tostring(cancelled))
    assert(#tags == FLIGHT + 1, "the cancelled task asked: " .. #tags .. " requests")
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
    local connector = assert(Connector.adopted(pair[1], { { host = "127.0.0.1", port = 9 } }, false,
      Clock.seconds(1)))
    local asked = 0
    local serving = stand_in(pair[2], function(_: integer, _: string) asked = asked + 1 end, 0x434e4301)
    local conn, why = dial(connector, "127.0.0.1", 9, Clock.seconds(1))
    assert(conn == nil and why == "net: the connector speaks another protocol than this program's: " ..
        "it said 0x434e4301, not 0x434e4302", tostring(why))
    assert(connector:ended())
    assert(asked == 0, "a request was sent before the hello was checked")
    serving:cancel()
    assert(connector:close())
    assert(sys.close(pair[2]))
  end)
end

local function test_adopted_connector_refuses_what_is_no_descriptor_or_table()
  local ok, why = pcall(Connector.adopted, -1)
  assert(not ok and tostring(why):find("fd must be a descriptor", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Connector.adopted, "3" as any as integer)
  assert(not ok and tostring(why):find("fd must be a descriptor", 1, true) ~= nil, tostring(why))
  local pair = stream_pair()
  ok, why = pcall(Connector.adopted, pair[1], { { host = "127.0.0.1" } } as {raw_process.ConnectorEndpoint})
  assert(not ok and tostring(why):find("endpoints[1] must be a host and a port", 1, true) ~= nil, tostring(why))
  assert(sys.close(pair[1]) and sys.close(pair[2]))
  -- A descriptor that is open but no stream cannot be made nonblocking where it is not open.
  local none, trouble = Connector.adopted(1000000)
  assert(none == nil and trouble:find("child: ", 1, true) == 1, tostring(trouble))
end
