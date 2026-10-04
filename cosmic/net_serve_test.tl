local Child = require("cosmic.child")
local unix_socket = require("build.unix_socket")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

--- Answers each line with itself until the peer ends what it sends.
local function echo(conn: Net.Conn)
  local lines = Stream.lines(conn)
  for line in lines:each() do assert(conn:write(line .. "\n")) end
  assert(lines:failure() == "", lines:failure())
end

--- A client of `address`, and the lines it reads.
local record Client
  conn: Net.Conn
  lines: Stream.Lines
  metamethod __close: function(Client)
end

local client_mt: metatable<Client> = {
  __close = function(self: Client)
    local _, _ = self.conn:close()
  end,
}

local function client(address: Net.Address): Client
  local conn = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
  return setmetatable({ conn = conn, lines = Stream.lines(conn) }, client_mt)
end

--- Connections are served at once, each in a task of its own: the last
--- to connect is answered while the first still waits to be read.
local function test_several_connections_are_served_at_once(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local answers: {string} = {}
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    serve = echo,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local first <close> = client(addresses[1])
      local second <close> = client(addresses[1])
      local third <close> = client(addresses[1])
      for i, c in ipairs({ third, second, first }) do
        assert(c.conn:write("line " .. i .. "\n"))
        answers[#answers + 1] = assert(c.lines:read())
      end
      server:stop()
    end,
  })
  assert(table.concat(answers, ",") == "line 1,line 2,line 3", table.concat(answers, ","))
end

--- What a protocol raises closes its own connection alone: it goes to
--- on_error with where it was raised, and the others, and the
--- listener, are served on.
local function test_an_error_in_one_connection_leaves_the_others_served(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local troubles: {string} = {}
  local later = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local lines = Stream.lines(conn)
      for line in lines:each() do
        if line == "boom" then error("the protocol failed") end
        assert(conn:write(line .. "\n"))
      end
    end,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local steady <close> = client(addresses[1])
      local failing <close> = client(addresses[1])
      assert(failing.conn:write("boom\n"))
      local gone, why = failing.lines:read()
      assert(gone == nil and why == "", why)
      assert(steady.conn:write("still\n"))
      assert(steady.lines:read() == "still")
      local fresh <close> = client(addresses[1])
      assert(fresh.conn:write("after\n"))
      later = assert(fresh.lines:read())
      server:stop()
    end,
  })
  assert(later == "after", later)
  assert(#troubles == 1, tostring(#troubles))
  assert(troubles[1]:find("net_serve_test:%d+: the protocol failed") ~= nil, troubles[1])
  assert(troubles[1]:find("stack traceback", 1, true) ~= nil, troubles[1])
end

--- At the limit the server accepts nothing more: a second client waits
--- in the backlog, neither answered nor closed, until the first
--- closes, and is then served.
local function test_at_the_connection_limit_accepting_waits(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local accepted = 0
  local waiting_why = ""
  local answer = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    limits = { connections = 1 },
    serve = function(conn: Net.Conn)
      accepted = accepted + 1
      echo(conn)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local second: Client
      do
        local first <close> = client(addresses[1])
        assert(first.conn:write("one\n"))
        assert(first.lines:read() == "one")
        second = client(addresses[1])
        assert(second.conn:write("two\n"))
        second.conn:set_timeout(Clock.ms(100))
        local nothing: string
        nothing, waiting_why = second.conn:read()
        assert(nothing == nil)
        assert(accepted == 1, tostring(accepted))
        second.conn:set_timeout(Clock.seconds(5))
      end
      answer = assert(second.lines:read())
      local _, _ = second.conn:close()
      server:stop()
    end,
  })
  assert(waiting_why == Poll.TIMEOUT, waiting_why)
  assert(answer == "two", answer)
  assert(accepted == 2, tostring(accepted))
end

--- A connection's reads and writes wait at most the spec's timeout_ns.
local function test_timeout_ns_bounds_each_connection(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local why = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    timeout_ns = Clock.ms(20),
    serve = function(conn: Net.Conn)
      local data: string
      data, why = conn:read()
      assert(data == nil)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local idle <close> = client(addresses[1])
      local ended, reason = idle.lines:read()
      assert(ended == nil and reason == "", reason)
      server:stop()
    end,
  })
  assert(why == Poll.TIMEOUT, why)
end

--- Stopping closes the listener, removing its socket file, at once; a
--- connection in flight finishes, and one still open at grace_ns has
--- its task killed, its protocol never resumed, before Net.serve
--- returns.
local function test_stop_drains_then_kills_after_grace_ns(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local started = 0
  local stuck_why = ""
  local answer = ""
  local stopped_at, returned_at = 0, 0
  local stuck: Client
  assert(Net.serve{
    listeners = { Net.unix(path) },
    grace_ns = Clock.ms(200),
    serve = function(conn: Net.Conn)
      started = started + 1
      local lines = Stream.lines(conn)
      local line, why = lines:read()
      if line == nil then
        stuck_why = why
        return
      end
      assert(Poll.delay(Clock.ms(50)))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local slow <close> = client(addresses[1])
      stuck = client(addresses[1])
      assert(slow.conn:write("slow\n"))
      while started < 2 do assert(Poll.delay(Clock.ms(1))) end
      stopped_at = Clock.monotonic_ns()
      server:stop()
      assert(Fs.stat(path) == nil, "the socket file was left")
      local refused, why = Net.connect(addresses[1])
      assert(refused == nil and why:find("No such file", 1, true) ~= nil, why)
      answer = assert(slow.lines:read())
    end,
  })
  returned_at = Clock.monotonic_ns()
  local ended, why = stuck.lines:read()
  assert(ended == nil and why == "", why)
  local _, _ = stuck.conn:close()
  assert(answer == "slow", answer)
  assert(stuck_why == "", stuck_why)
  assert(returned_at - stopped_at >= Clock.ms(200), tostring(returned_at - stopped_at))
end

--- A listener that cannot listen fails the whole server, having closed
--- the ones that could and called nothing.
local function test_a_listener_that_cannot_listen_fails_the_server(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local called = false
  local ok, why = Net.serve{
    listeners = { Net.unix(tmp .. "/a.sock"), Net.unix(tmp .. "/missing/b.sock") },
    serve = echo,
    on_ready = function() called = true end,
  }
  assert(not ok and why:find(tmp .. "/missing/b.sock: ", 1, true) == 1, why)
  assert(not called)
  assert(Fs.stat(tmp .. "/a.sock") == nil, "the first listener's file was left")
end

--- A spec of the wrong shape raises, naming the field; so does a
--- server started in a task of another run.
local function test_a_spec_of_the_wrong_shape_raises_naming_the_field(tmp: string)
  local address = Net.unix(tmp .. "/s.sock")
  local function refused(spec: any, field: string)
    local ok, why = pcall(Net.serve, spec as Net.ServeSpec)
    assert(not ok and tostring(why):find("net: " .. field, 1, true) ~= nil, tostring(why))
  end
  refused({ serve = echo }, "spec.listeners must be")
  refused({ listeners = {}, serve = echo }, "spec.listeners must be")
  refused({ listeners = { "s.sock" }, serve = echo }, "spec.listeners[1] must be")
  refused({ listeners = { address, Net.unix("") }, serve = echo },
    "spec.listeners[2] must be a unix address whose path")
  refused({ listeners = { { kind = "tcp", host = "127.0.0.1", port = "80" } }, serve = echo },
    "spec.listeners[1] must be a tcp address")
  refused({ listeners = { Net.tcp("127.0.0.1", 65536) }, serve = echo },
    "spec.listeners[1] must be a tcp address")
  refused({ listeners = { address } }, "spec.serve must be")
  refused({ listeners = { address }, serve = echo, limits = { connections = 0 } },
    "spec.limits.connections must be")
  refused({ listeners = { address }, serve = echo, limits = { conections = 1 } },
    "spec.limits has no field conections")
  refused({ listeners = { address }, serve = echo, grace_ns = -1 }, "spec.grace_ns must be")
  refused({ listeners = { address }, serve = echo, timeout_ns = 1.5 }, "spec.timeout_ns must be")
  refused({ listeners = { address }, serve = echo, grace_ns = Poll.MOST_NS + 1 },
    "spec.grace_ns must be")
  refused({ listeners = { address }, serve = echo, timeout_ms = 5 }, "spec has no field timeout_ms")
  refused({ listeners = { address }, serve = echo, grace_ms = 5 }, "spec has no field grace_ms")
  refused({ listeners = { address }, serve = echo, on_ready = true }, "spec.on_ready must be")
  refused({ listeners = { address }, serve = echo, on_stop = true }, "spec.on_stop must be")
  refused({ listeners = { address }, serve = echo, grace = 10 }, "spec has no field grace")
  Poll.run(function()
    local ok, why = pcall(Net.serve, { listeners = { address }, serve = echo } as Net.ServeSpec)
    assert(not ok and tostring(why):find("net: serve runs a Poll.run of its own", 1, true) ~= nil,
      tostring(why))
  end)
  assert(Fs.stat(tmp .. "/s.sock") == nil)
end

local record Closer
  metamethod __close: function(Closer)
end

--- A protocol that ignores every failure and waits on, on its
--- connection or on time, is killed at grace_ns, and Net.serve returns:
--- its `<close>` variables are closed, its connection with them, and
--- nothing is reported of it.
local function test_a_protocol_ignoring_failures_is_killed_at_grace_ns(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local failures: {string} = {}
  local errors: {string} = {}
  local started, closed = 0, 0
  local closer_mt: metatable<Closer> = { __close = function() closed = closed + 1 end }
  local held: {Client} = {}
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = Clock.ms(20),
    serve = function(conn: Net.Conn)
      local _ <close> = setmetatable({} as Closer, closer_mt)
      started = started + 1
      local reads = started == 1
      while true do
        local _, why: any, string
        if reads then _, why = conn:read() else _, why = Poll.delay(Clock.seconds(60)) end
        failures[#failures + 1] = why
        -- A bound, so a regression fails the assertion below rather
        -- than looping until the test times out.
        if #failures == 100 then return end
      end
    end,
    on_error = function(trouble: string) errors[#errors + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      held[1] = client(addresses[1])
      held[2] = client(addresses[1])
      while started < 2 do assert(Poll.delay(Clock.ms(1))) end
      server:stop()
    end,
  })
  for _, c in ipairs(held) do
    local ended, why = c.lines:read()
    assert(ended == nil and why == "", why)
    local _, _ = c.conn:close()
  end
  assert(closed == 2, "closed " .. closed .. " of 2")
  assert(#failures == 0, table.concat(failures, ","))
  assert(#errors == 0, table.concat(errors, "\n"))
end

--- What a killed protocol's `<close>` handler raises is reported, and
--- the rest are served on to their end.
local function test_a_killed_protocols_close_error_is_reported(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local errors: {string} = {}
  local started = false
  local raiser_mt: metatable<Closer> = { __close = function() error("broken close", 0) end }
  local held: Client
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = 0,
    serve = function(_conn: Net.Conn)
      local _ <close> = setmetatable({} as Closer, raiser_mt)
      started = true
      assert(Poll.delay(Clock.seconds(60)))
    end,
    on_error = function(trouble: string) errors[#errors + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      held = client(addresses[1])
      while not started do assert(Poll.delay(Clock.ms(1))) end
      server:stop()
    end,
  })
  local ended, why = held.lines:read()
  assert(ended == nil and why == "", why)
  local _, _ = held.conn:close()
  assert(#errors == 1 and errors[1] == "broken close", table.concat(errors, "\n"))
end

--- A killed protocol's `<close>` handler meets its connection closed:
--- a write there fails at once, where it would otherwise wait on a peer
--- that reads nothing, and another wait raises, reported; Net.serve
--- returns soon after grace_ns.
local function test_a_killed_protocols_close_cannot_wait(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local errors: {string} = {}
  local wrote = ""
  local started = false
  local stopped_at, returned_at = 0, 0
  local held: Client
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = Clock.ms(50),
    serve = function(conn: Net.Conn)
      local farewell_mt: metatable<Closer> = { __close = function()
        local _, why = conn:write(string.rep("x", 8 * 1024 * 1024))
        wrote = why
        assert(Poll.delay(0))
      end }
      local _ <close> = setmetatable({} as Closer, farewell_mt)
      started = true
      while true do local _, _ = Poll.delay(Clock.seconds(60)) end
    end,
    on_error = function(trouble: string) errors[#errors + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      held = client(addresses[1])
      while not started do assert(Poll.delay(Clock.ms(1))) end
      stopped_at = Clock.monotonic_ns()
      server:stop()
    end,
  })
  returned_at = Clock.monotonic_ns()
  local _, _ = held.conn:close()
  assert(wrote == "net: the connection is closed", wrote)
  assert(#errors == 1 and errors[1]:find("while its task is killed", 1, true),
    table.concat(errors, "\n"))
  assert(returned_at - stopped_at < Clock.seconds(5), tostring(returned_at - stopped_at))
end

--- The limit counts connections across listeners: while one listener's
--- connection holds the only place, another listener accepts nothing.
local function test_the_connection_limit_is_shared_by_every_listener(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local waiting_why = ""
  local answer = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/a.sock"), Net.unix(tmp .. "/b.sock") },
    limits = { connections = 1 },
    serve = echo,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local second: Client
      do
        local first <close> = client(addresses[1])
        assert(first.conn:write("one\n"))
        assert(first.lines:read() == "one")
        second = client(addresses[2])
        assert(second.conn:write("two\n"))
        second.conn:set_timeout(Clock.ms(100))
        local nothing: string
        nothing, waiting_why = second.conn:read()
        assert(nothing == nil)
        second.conn:set_timeout(Clock.seconds(5))
      end
      answer = assert(second.lines:read())
      local _, _ = second.conn:close()
      server:stop()
    end,
  })
  assert(waiting_why == Poll.TIMEOUT, waiting_why)
  assert(answer == "two", answer)
end

--- A connection's protocol may stop the server it is served by, and
--- still finish its own answer.
local function test_a_protocol_stops_its_server(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local answer = ""
  local serving: Net.Server
  assert(Net.serve{
    listeners = { Net.unix(path) },
    serve = function(conn: Net.Conn)
      if assert(Stream.lines(conn):read()) == "stop" then serving:stop() end
      assert(conn:write("bye\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      serving = server
      local c <close> = client(addresses[1])
      assert(c.conn:write("stop\n"))
      answer = assert(c.lines:read())
    end,
  })
  assert(answer == "bye", answer)
  assert(Fs.stat(path) == nil, "the socket file was left")
end

--- A server stopped before it accepts anything returns at once, its
--- protocol never run; stopping it again does nothing.
local function test_a_server_stopped_twice_before_accepting_returns(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local served = false
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    serve = function(_conn: Net.Conn) served = true end,
    on_ready = function(_addresses: {Net.Address}, server: Net.Server)
      server:stop()
      server:stop()
    end,
  })
  assert(not served)
  assert(Fs.stat(tmp .. "/s.sock") == nil, "the socket file was left")
end

--- Waits, in a task, until `path` is gone -- the server that listened
--- there has stopped -- failing after five seconds.
local function until_gone(path: string)
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  while Fs.stat(path) ~= nil do
    assert(Clock.monotonic_ns() < deadline, "the server did not stop")
    assert(Poll.delay(Clock.ms(1)))
  end
end

--- SIGTERM stops a server as `stop` does: the listener closes at once,
--- and the connection in flight finishes before Net.serve returns true.
--- The server releases its guard, so the signal is not delivered again;
--- a guard of the caller's around the call sees it.
local function test_sigterm_stops_the_server_and_it_drains(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local started = false
  local answer = ""
  -- Closed only where an assertion fails first, which delivers the
  -- signal: released below otherwise.
  local outer <close> = assert(Child.guard())
  local ok, why = Net.serve{
    listeners = { Net.unix(path) },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      started = true
      assert(Poll.delay(Clock.ms(50)))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      local c <close> = client(addresses[1])
      assert(c.conn:write("slow\n"))
      while not started do assert(Poll.delay(Clock.ms(1))) end
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
      until_gone(path)
      answer = assert(c.lines:read())
    end,
  }
  assert(ok and why == "", why)
  assert(answer == "slow", answer)
  assert(outer:cancelled() == sys.SIGTERM)
  assert(outer:release() == sys.SIGTERM)
end

--- A second signal while the server drains ends the grace at once,
--- though it has no bound: the connection still open is killed. The
--- first is SIGINT, to stop on either kind: a worker started with
--- SIGINT ignored, whose guard leaves it so, fails this case.
local function test_a_second_signal_ends_the_grace(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local started = false
  local stuck_why = ""
  local stuck: Client
  -- Closed only where an assertion fails first: released below otherwise.
  local outer <close> = assert(Child.guard())
  assert(Net.serve{
    listeners = { Net.unix(path) },
    serve = function(conn: Net.Conn)
      started = true
      local line, why = conn:read()
      if line == nil then stuck_why = why end
    end,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      stuck = client(addresses[1])
      while not started do assert(Poll.delay(Clock.ms(1))) end
      assert(sys.kill(sys.getpid(), sys.SIGINT))
      until_gone(path)
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
    end,
  })
  local _, _ = stuck.conn:close()
  assert(stuck_why == "", stuck_why)
  assert(outer:release() == sys.SIGTERM)
end

--- `workers` is gone, whatever its value: the spec is refused, naming the
--- removal and what to do instead, before anything listens.
local function test_workers_is_refused_naming_the_removal(tmp: string)
  for _, workers in ipairs({ 0, 1, 2, true } as {any}) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = Net.serve({ listeners = { Net.unix(tmp .. "/s.sock") }, serve = echo,
        workers = workers } as Net.ServeSpec)
    end)
    local text = tostring(why)
    assert(not ok and text:find("^cosmic%.net_serve_test:%d+: net: spec has no field workers: ") ~= nil,
      text)
    assert(text:find("workers = 0 asked for and is now the default, so drop the key", 1, true) ~= nil,
      text)
    assert(text:find("to serve in several, start each " ..
        "(Proc.relaunch gives the command, Child.start runs it)", 1, true) ~= nil, text)
  end
  assert(Fs.stat(tmp .. "/s.sock") == nil)
end

--- The longest `grace_ns` a wait can last drains as a short one does:
--- the connection open finishes, and the server returns true.
local function test_the_longest_grace_drains_the_connections_open(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local answer = ""
  local ok, why = Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = Poll.MOST_NS,
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      assert(Poll.delay(Clock.ms(50)))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local c <close> = client(addresses[1])
      assert(c.conn:write("slow\n"))
      assert(Poll.delay(Clock.ms(10)))
      server:stop()
      answer = assert(c.lines:read())
    end,
  }
  assert(ok and why == "", why)
  assert(answer == "slow", answer)
end

--- on_stop is called once, however often the server is stopped, in a
--- task of the run with the server, once the listener is closed and
--- before the connection in flight has finished.
local function test_on_stop_runs_once_at_stop(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local calls = 0
  local finished = false
  local seen: {string} = {}
  local serving: Net.Server
  assert(Net.serve{
    listeners = { Net.unix(path) },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      serving:stop()
      assert(Poll.delay(Clock.ms(50)))
      assert(conn:write(line .. "\n"))
      finished = true
    end,
    on_stop = function(server: Net.Server)
      calls = calls + 1
      seen[#seen + 1] = tostring(server == serving)
      seen[#seen + 1] = tostring(Poll.in_task())
      seen[#seen + 1] = tostring(Fs.stat(path) == nil)
      seen[#seen + 1] = tostring(finished)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      serving = server
      local c <close> = client(addresses[1])
      assert(c.conn:write("slow\n"))
      assert(c.lines:read() == "slow")
      server:stop()
    end,
  })
  assert(calls == 1, tostring(calls))
  assert(table.concat(seen, ",") == "true,true,true,false", table.concat(seen, ","))
end

--- SIGTERM calls on_stop as `stop` does, once.
local function test_on_stop_runs_once_at_sigterm(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local calls = 0
  -- Closed only where an assertion fails first: released below otherwise.
  local outer <close> = assert(Child.guard())
  assert(Net.serve{
    listeners = { Net.unix(path) },
    serve = echo,
    on_stop = function(_server: Net.Server) calls = calls + 1 end,
    on_ready = function(_addresses: {Net.Address}, server: Net.Server)
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
      until_gone(path)
      server:stop()
    end,
  })
  assert(calls == 1, tostring(calls))
  assert(outer:release() == sys.SIGTERM)
end

--- How long a server takes to return once stopped with one client
--- connected and idle, its protocol tracking the connections waiting
--- for a line and, where `closing`, closing them in on_stop; and what
--- the idle client read at the end.
local function stopped_with_an_idle_client(tmp: string, closing: boolean,
                                           grace_ns: integer): integer, string
  local idle: {Net.Conn: boolean} = {}
  local stopped_at = 0
  local idle_client: Client
  local spec: Net.ServeSpec = {
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = grace_ns,
    serve = function(conn: Net.Conn)
      local lines = Stream.lines(conn)
      while true do
        idle[conn] = true
        local line = lines:read()
        idle[conn] = nil
        if line == nil then return end
        assert(conn:write(line .. "\n"))
      end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      idle_client = client(addresses[1])
      assert(idle_client.conn:write("hello\n"))
      assert(idle_client.lines:read() == "hello")
      stopped_at = Clock.monotonic_ns()
      server:stop()
    end,
  }
  if closing then
    spec.on_stop = function(_server: Net.Server)
      for conn in pairs(idle) do local _, _ = conn:close() end
    end
  end
  assert(Net.serve(spec))
  local took = Clock.monotonic_ns() - stopped_at
  local ended, why = idle_client.lines:read()
  local _, _ = idle_client.conn:close()
  return took, tostring(ended) .. "," .. why
end

--- A protocol that closes its idle connections in on_stop lets the
--- server return at once with an idle client connected, though its
--- grace is long; without it the idle client holds the drain for all
--- of grace_ns.
local function test_on_stop_closing_idle_connections_ends_the_drain_at_once(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local took, ended = stopped_with_an_idle_client(tmp, true, Clock.seconds(10))
  assert(took < Clock.seconds(2), tostring(took))
  assert(ended == "nil,", ended)
  took, ended = stopped_with_an_idle_client(tmp, false, Clock.ms(200))
  assert(took >= Clock.ms(200), tostring(took))
  assert(ended == "nil,", ended)
end

--- What on_stop raises goes to on_error, with its stack, and the
--- server stops all the same.
local function test_a_raising_on_stop_reaches_on_error_and_the_server_stops(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local troubles: {string} = {}
  local ok, why = Net.serve{
    listeners = { Net.unix(path) },
    serve = echo,
    on_stop = function(_server: Net.Server) error("on_stop failed") end,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    on_ready = function(_addresses: {Net.Address}, server: Net.Server) server:stop() end,
  }
  assert(ok and why == "", why)
  assert(#troubles == 1, tostring(#troubles))
  assert(troubles[1]:find("net_serve_test:%d+: on_stop failed") ~= nil, troubles[1])
  assert(troubles[1]:find("stack traceback", 1, true) ~= nil, troubles[1])
  assert(Fs.stat(path) == nil, "the socket file was left")
end

--- A second signal cancels a wait on_stop makes, as it ends the grace,
--- and the server returns.
local function test_a_second_signal_cancels_on_stops_wait(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local waited = ""
  -- Closed only where an assertion fails first: released below otherwise.
  local outer <close> = assert(Child.guard())
  assert(Net.serve{
    listeners = { Net.unix(path) },
    serve = echo,
    on_stop = function(_server: Net.Server)
      local _, why = Poll.delay(Clock.seconds(30))
      waited = why
    end,
    on_ready = function(_addresses: {Net.Address}, _server: Net.Server)
      assert(sys.kill(sys.getpid(), sys.SIGINT))
      until_gone(path)
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
    end,
  })
  assert(waited == Poll.CANCELLED, waited)
  assert(outer:release() == sys.SIGTERM)
end

--- A server with on_stop stops from a coroutine a task made, as one
--- without does: on_stop is called and Net.serve returns.
local function test_on_stop_runs_when_stopped_from_a_coroutine(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local calls = 0
  local stopped = ""
  local serving: Net.Server
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local _ = assert(Stream.lines(conn):read())
      local ok, why: boolean, any = pcall(coroutine.wrap(function() serving:stop() end))
      stopped = tostring(ok) .. "," .. tostring(why)
    end,
    on_stop = function(_server: Net.Server) calls = calls + 1 end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      serving = server
      Poll.spawn(function()
        local c <close> = client(addresses[1])
        assert(c.conn:write("stop\n"))
        local _, _ = c.lines:read()
      end)
    end,
  })
  assert(stopped == "true,nil", stopped)
  assert(calls == 1, tostring(calls))
end

--- The grace begins once on_stop returns: a connection that finishes
--- after on_stop's wait, within the grace from there, is not killed,
--- though it outlasts the grace counted from the stop.
local function test_the_grace_begins_once_on_stop_returns(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local answer = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ns = Clock.ms(400),
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      assert(Poll.delay(Clock.ms(500)))
      assert(conn:write(line .. "\n"))
    end,
    on_stop = function(_server: Net.Server) assert(Poll.delay(Clock.ms(300))) end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      Poll.spawn(function()
        local c <close> = client(addresses[1])
        assert(c.conn:write("slow\n"))
        assert(Poll.delay(Clock.ms(10)))
        server:stop()
        answer = assert(c.lines:read())
      end)
    end,
  })
  assert(answer == "slow", answer)
end
