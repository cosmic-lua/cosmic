local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

--- How long a client here waits for what the server never fails to do.
local WAIT <const> = Clock.seconds(20)

local function dial(port: integer): Net.Conn
  local conn = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = WAIT }))
  return conn
end

--- Answers each line with "re " before it.
local function answering(conn: Net.Conn)
  for line in Stream.lines(conn):each() do assert(conn:write("re " .. line .. "\n")) end
end

--- Sends `line` and reads the line that answers it.
local function asked(conn: Net.Conn, line: string): string
  assert(conn:write(line .. "\n"))
  local answer = assert(Stream.lines(conn):read())
  return answer
end

--- Outside a run the call is a run of its own: three clients hold
--- their connections at once and the last to connect is answered first,
--- which a server of one task could not do.
local function test_each_connection_is_served_in_a_task_of_its_own()
  local answers: mut {string} = {}
  local port_given: integer = 0
  Net.with_loopback(answering, function(port: integer)
    port_given = port
    local clients <const> = { dial(port), dial(port), dial(port) }
    for i = 3, 1, -1 do
      local client = assert(clients[i])
      local answer = asked(client, "c" .. tostring(i))
      answers[#answers + 1] = answer
    end
    for _, client in ipairs(clients) do assert(client:close()) end
  end)
  assert(port_given > 0 and port_given <= 65535, tostring(port_given))
  assert(table.concat(answers, ",") == "re c3,re c2,re c1", table.concat(answers, ","))
  assert(not Poll.in_task(), "the run outlived the call")
end

--- Once the body returns nothing listens at the port, and a connection
--- the server still held is closed, its task ended where it read: the
--- client reads the end, and the handler never returns from its read.
local function test_the_server_ends_with_the_body()
  local port_given: integer = 0
  local kept: Net.Conn? = nil
  local returned: boolean = false
  Net.with_loopback(function(conn: Net.Conn)
    assert(conn:write("held\n"))
    local _, _ = conn:read()
    returned = true
  end, function(port: integer)
    port_given = port
    local client = dial(port)
    -- Read from the handler, so the connection is one the server holds,
    -- not one left in the backlog.
    assert(Stream.lines(client):read() == "held")
    kept = client
  end)
  local client = assert(kept)
  local data, why = client:read()
  assert(data == nil and why == "", tostring(data) .. " " .. why)
  assert(client:close())
  assert(not returned, "a handler went on past the end of the server")
  local conn, refused = Net.connect(Net.tcp("127.0.0.1", port_given), { timeout_ns = WAIT })
  assert(conn == nil and refused:find("Connection refused", 1, true) ~= nil, refused)
end

--- In a task the body runs in the caller's run, and the call returns
--- there with the server's tasks ended: the run ends, which a task left
--- accepting would hold for ever.
local function test_in_a_task_the_body_runs_in_the_callers_run()
  local answer: string = ""
  local beside: boolean = false
  Poll.run(function()
    local other = Poll.spawn(function()
      assert(Poll.delay(0))
      beside = true
    end)
    Net.with_loopback(answering, function(port: integer)
      assert(Poll.in_task())
      local client <close> = dial(port)
      answer = asked(client, "in a run")
    end)
    assert(other:join())
  end)
  assert(answer == "re in a run", answer)
  assert(beside, "the caller's other task did not run")
end

--- What the body raises is raised, in a task as it was raised and
--- outside a run as a run raises it, the server ended either way.
local function test_what_the_body_raises_is_raised_once_the_server_has_ended()
  local port_given: integer = 0
  local why = Test.raises(function()
    Net.with_loopback(answering, function(port: integer)
      port_given = port
      local client <close> = dial(port)
      assert(asked(client, "first") == "re first")
      error("the body failed")
    end)
  end, "the body failed")
  assert(why:find("stack traceback:", 1, true) ~= nil, why)
  local conn, refused = Net.connect(Net.tcp("127.0.0.1", port_given), { timeout_ns = WAIT })
  assert(conn == nil and refused:find("Connection refused", 1, true) ~= nil, refused)
  local caught: string = ""
  Poll.run(function()
    local ok, err: boolean, any = pcall(Net.with_loopback, answering, function(port: integer)
      port_given = port
      local client <close> = dial(port)
      assert(asked(client, "second") == "re second")
      error("the body failed again", 0)
    end)
    assert(not ok)
    caught = tostring(err)
    local again, trouble = Net.connect(Net.tcp("127.0.0.1", port_given), { timeout_ns = WAIT })
    assert(again == nil and trouble:find("Connection refused", 1, true) ~= nil, trouble)
  end)
  assert(caught == "the body failed again", caught)
end

--- What a handler raises is no connection's own failure, as it is under
--- Net.serve: it ends the run, and the call raises it.
local function test_what_a_handler_raises_ends_the_run()
  local why = Test.raises(function()
    Net.with_loopback(function(_conn: Net.Conn)
      error("the handler failed")
    end, function(port: integer)
      local client <close> = dial(port)
      local _, _ = client:read()
    end)
  end, "the handler failed")
  assert(why:find("stack traceback:", 1, true) ~= nil, why)
  assert(not Poll.in_task(), "the run outlived its error")
end

--- The server closes a connection whose handler returned, so its client
--- reads the end without the handler closing anything.
local function test_a_connection_is_closed_once_its_handler_returns()
  local read: string = "unread"
  local ended: string = "unread"
  Net.with_loopback(function(conn: Net.Conn)
    assert(conn:write("bye"))
  end, function(port: integer)
    local client <close> = dial(port)
    read = assert(Stream.read_all(client))
    local _, why = client:read()
    ended = why
  end)
  assert(read == "bye", read)
  assert(ended == "", ended)
end

--- A `<close>` local of a handler: it records its closing, and raises
--- there where `fails` is set.
local class Held
  mut closed: boolean
  fails: boolean

  function __close(self)
    self.closed = true
    if self.fails then error("the handler's close failed", 0) end
  end
end

--- A handler that holds `held`, says so, and reads until its connection ends.
local function holding(held: Held): function(conn: Net.Conn)
  return function(conn: Net.Conn)
    local _held <close> = held
    assert(conn:write("held\n"))
    local _, _ = conn:read()
  end
end

--- A handler killed as the body returns has its `<close>` locals closed,
--- and what one of them raises there the call raises.
local function test_what_a_killed_handlers_close_raises_is_raised()
  local held: Held = { closed = false, fails = true }
  local kept: Net.Conn? = nil
  local why = Test.raises(function()
    Net.with_loopback(holding(held), function(port: integer)
      local client = dial(port)
      assert(Stream.lines(client):read() == "held")
      kept = client
    end)
  end, "the handler's close failed")
  assert(held.closed, why)
  assert(assert(kept):close())
end

--- A caller killed while its body waits can kill nothing itself: the
--- server still stops listening, and the handler, its connection closed
--- and its task cancelled, ends at its read, so the run ends.
local function test_a_caller_killed_in_its_body_still_ends_the_server()
  local held: Held = { closed = false, fails = false }
  local port_given: integer = 0
  local reached: boolean = false
  local returned: boolean = false
  Poll.run(function()
    local caller = Poll.spawn(function()
      Net.with_loopback(holding(held), function(port: integer)
        port_given = port
        local client <close> = dial(port)
        assert(Stream.lines(client):read() == "held")
        reached = true
        local _, _ = Poll.delay(Poll.MOST_NS)
        returned = true
      end)
    end)
    while not reached do assert(Poll.delay(0)) end
    caller:kill()
    local ended, _ = caller:join()
    assert(not ended, "the caller was not killed")
  end)
  assert(not returned, "the body went on past its kill")
  assert(held.closed, "the handler outlived the run")
  local conn, refused = Net.connect(Net.tcp("127.0.0.1", port_given), { timeout_ns = WAIT })
  assert(conn == nil and refused:find("Connection refused", 1, true) ~= nil, refused)
end
