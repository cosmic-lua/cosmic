local Child = require("cosmic.child")
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
  local conn = assert(Net.connect(address, { timeout_ms = 5000 }))
  return setmetatable({ conn = conn, lines = Stream.lines(conn) }, client_mt)
end

local function now_ms(): integer
  return assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) // 1000000
end

--- Connections are served at once, each in a task of its own: the last
--- to connect is answered while the first still waits to be read.
local function test_several_connections_are_served_at_once(tmp: string)
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
        second.conn.timeout_ms = 100
        local nothing: string
        nothing, waiting_why = second.conn:read()
        assert(nothing == nil)
        assert(accepted == 1, tostring(accepted))
        second.conn.timeout_ms = 5000
      end
      answer = assert(second.lines:read())
      local _, _ = second.conn:close()
      server:stop()
    end,
  })
  assert(waiting_why == "timed out", waiting_why)
  assert(answer == "two", answer)
  assert(accepted == 2, tostring(accepted))
end

--- A connection's reads and writes wait at most the spec's timeout_ms.
local function test_timeout_ms_bounds_each_connection(tmp: string)
  local why = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    timeout_ms = 20,
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
  assert(why == "timed out", why)
end

--- Stopping closes the listener, removing its socket file, at once; a
--- connection in flight finishes, and one still open at grace_ms is
--- cancelled, before Net.serve returns.
local function test_stop_drains_then_cancels_after_grace_ms(tmp: string)
  local path = tmp .. "/s.sock"
  local started = 0
  local stuck_why = ""
  local answer = ""
  local stopped_at, returned_at = 0, 0
  local stuck: Client
  assert(Net.serve{
    listeners = { Net.unix(path) },
    grace_ms = 200,
    serve = function(conn: Net.Conn)
      started = started + 1
      local lines = Stream.lines(conn)
      local line, why = lines:read()
      if line == nil then
        stuck_why = why
        return
      end
      assert(Poll.delay(50))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local slow <close> = client(addresses[1])
      stuck = client(addresses[1])
      assert(slow.conn:write("slow\n"))
      while started < 2 do assert(Poll.delay(1)) end
      stopped_at = now_ms()
      server:stop()
      assert(Fs.stat(path) == nil, "the socket file was left")
      local refused, why = Net.connect(addresses[1])
      assert(refused == nil and why:find("No such file", 1, true) ~= nil, why)
      answer = assert(slow.lines:read())
    end,
  })
  returned_at = now_ms()
  local ended, why = stuck.lines:read()
  assert(ended == nil and why == "", why)
  local _, _ = stuck.conn:close()
  assert(answer == "slow", answer)
  assert(stuck_why == Poll.CANCELLED, stuck_why)
  assert(returned_at - stopped_at >= 200, tostring(returned_at - stopped_at))
end

--- A listener that cannot listen fails the whole server, having closed
--- the ones that could and called nothing.
local function test_a_listener_that_cannot_listen_fails_the_server(tmp: string)
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
    assert(not ok and tostring(why):find(field, 1, true) ~= nil, tostring(why))
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
  refused({ listeners = { address }, serve = echo, grace_ms = -1 }, "spec.grace_ms must be")
  refused({ listeners = { address }, serve = echo, timeout_ms = 1.5 }, "spec.timeout_ms must be")
  refused({ listeners = { address }, serve = echo, on_ready = true }, "spec.on_ready must be")
  refused({ listeners = { address }, serve = echo, grace = 10 }, "spec has no field grace")
  Poll.run(function()
    refused({ listeners = { address }, serve = echo }, "cannot be called in a task")
  end)
  assert(Fs.stat(tmp .. "/s.sock") == nil)
end

--- A protocol that goes on after its reads fail still ends: at
--- grace_ms its connection is closed as well as cancelled, so a read
--- after the cancelled one fails "connection is closed". Were it only
--- cancelled, every read would fail "cancelled" and the loop never end.
local function test_a_protocol_ignoring_failures_ends_once_its_connection_is_closed(tmp: string)
  local failures: {string} = {}
  local started = false
  local held: Client
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    grace_ms = 20,
    serve = function(conn: Net.Conn)
      started = true
      while true do
        local data, why = conn:read()
        if data == nil then
          failures[#failures + 1] = why
          -- A bound, so a regression fails the assertion below rather
          -- than looping until the test times out.
          if why == "connection is closed" or #failures == 4 then return end
        end
      end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      held = client(addresses[1])
      while not started do assert(Poll.delay(1)) end
      server:stop()
    end,
  })
  local _, _ = held.conn:close()
  assert(table.concat(failures, ",") == "cancelled,connection is closed",
    table.concat(failures, ","))
end

--- The limit counts connections across listeners: while one listener's
--- connection holds the only place, another listener accepts nothing.
local function test_the_connection_limit_is_shared_by_every_listener(tmp: string)
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
        second.conn.timeout_ms = 100
        local nothing: string
        nothing, waiting_why = second.conn:read()
        assert(nothing == nil)
        second.conn.timeout_ms = 5000
      end
      answer = assert(second.lines:read())
      local _, _ = second.conn:close()
      server:stop()
    end,
  })
  assert(waiting_why == "timed out", waiting_why)
  assert(answer == "two", answer)
end

--- A connection's protocol may stop the server it is served by, and
--- still finish its own answer.
local function test_a_protocol_stops_its_server(tmp: string)
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
  local deadline = now_ms() + 5000
  while Fs.stat(path) ~= nil do
    assert(now_ms() < deadline, "the server did not stop")
    assert(Poll.delay(1))
  end
end

--- SIGTERM stops a server as `stop` does: the listener closes at once,
--- and the connection in flight finishes before Net.serve returns true.
--- The server releases its guard, so the signal is not delivered again;
--- a guard of the caller's around the call sees it.
local function test_sigterm_stops_the_server_and_it_drains(tmp: string)
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
      assert(Poll.delay(50))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      local c <close> = client(addresses[1])
      assert(c.conn:write("slow\n"))
      while not started do assert(Poll.delay(1)) end
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
--- though it has no bound: the connection still open is cancelled. The
--- first is SIGINT, to stop on either kind: a worker started with
--- SIGINT ignored, whose guard leaves it so, fails this case.
local function test_a_second_signal_ends_the_grace(tmp: string)
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
      while not started do assert(Poll.delay(1)) end
      assert(sys.kill(sys.getpid(), sys.SIGINT))
      until_gone(path)
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
    end,
  })
  local _, _ = stuck.conn:close()
  assert(stuck_why == Poll.CANCELLED, stuck_why)
  assert(outer:release() == sys.SIGTERM)
end
