local Signal = require("cosmic.signal")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local sys = require("cosmic.sys")
local Clock = require("cosmic.clock")

--- Each listener here is on the worker's own loopback, and 127.0.0.2 is
--- where [`unanswered_or_skip`] looks for an address nothing answers.
Test.policy{ loopback = { "127.0.0.1", "127.0.0.2" } }

local function test_a_tcp_listener_at_port_zero_names_the_port_it_has()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  local address = server.address
  assert(address.kind == "tcp" and address.host == "127.0.0.1", address.host)
  local listening = assert(address.port)
  assert(listening > 0 and listening <= 65535, tostring(listening))
  local client <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
  local accepted <close> = assert(server:accept())
  assert(client:write("ping"))
  assert(client:shutdown("write"))
  assert(assert(Stream.read_all(accepted)) == "ping")
  assert(accepted:write("pong"))
  assert(accepted:close())
  assert(assert(Stream.read_all(client)) == "pong")
end

--- A TCP listener's `address` is built again by [`Net.tcp`]: the host as
--- given and the port the kernel chose, with no field of a unix one.
local function test_a_tcp_listeners_address_is_built_again_from_its_host_and_port()
  local given = { kind = "tcp", host = "127.0.0.1", port = 0, path = "unused" } -- checked: arms_differ
  local server <close> = assert(Net.listen(given))
  local address = server.address
  assert(address.kind == "tcp" and address.host == "127.0.0.1" and assert(address.port) > 0)
  assert(address.path == nil, "a field past the kind's own was kept")
  assert(address ~= given, "the listener holds the caller's table")
end

--- A port one listener holds is not another's; once it closes, nothing
--- listens there, and connecting is refused.
local function test_a_port_held_is_refused_and_one_closed_refuses()
  local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = assert(server.address.port)
  local again, taken = Net.listen(Net.tcp("127.0.0.1", port))
  assert(again == nil and taken == "127.0.0.1:" .. tostring(port) .. ": Address in use", taken)
  assert(server:close())
  local conn, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(5) })
  assert(conn == nil and why == "127.0.0.1:" .. tostring(port) .. ": Connection refused", why)
end

--- A host is a numeric address: a name is refused, saying so, and a
--- port out of range is no address at all.
local function test_a_host_that_is_no_address_is_refused()
  local conn, why = Net.connect(Net.tcp("localhost", 80))
  assert(conn == nil and why:find("localhost:80: Invalid argument (not a numeric", 1,
    true) == 1, why)
  local server, listen_why = Net.listen(Net.tcp("::zz", 0))
  assert(server == nil and listen_why:find("[::zz]:0: Invalid argument", 1, true) == 1,
    listen_why)
  local nul, nul_why = Net.connect(Net.tcp("127.0.0.1\0junk", 1))
  assert(nul == nil and nul_why:find("Invalid argument", 1, true) ~= nil, nul_why)
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", 65536))) -- checked: alternatives_as_value
  assert(not pcall(Net.connect, Net.tcp("127.0.0.1", -1))) -- checked: alternatives_as_value
  local no_host: Net.Address = { kind = "tcp", port = 1 }
  Test.raises(function() Net.connect(no_host) end)
end

--- The words of a failure `why` at `address`.
local function at(address: Net.Address, why: string): string
  return assert(address.host) .. ":" .. tostring(assert(address.port)) .. ": " .. why
end

--- How many connections [`full_backlog`] asks of a listener that queues
--- one.
local ASKED <const> = 16

--- What a connection the kernel reset says.
local RESET <const> = "Connection reset by peer"

--- A TCP listener whose backlog is full, no one accepting, and what a
--- connection past it met: [`Poll.TIMEOUT`] where it was left waiting,
--- which Linux must, or `RESET`, whether it failed so or was made and
--- then read so. `held` gets a closer for the listener and for each
--- connection made.
local function full_backlog(held: mut {function()}): Net.Address, string
  local server = assert(Net.listen(Net.tcp("127.0.0.1", 0), { backlog = 1 }))
  held[#held + 1] = function() assert(server:close()) end
  local why = ""
  local last: Net.Conn? = nil
  for _ = 1, ASKED do
    local conn, trouble = Net.connect(server.address, { timeout_ns = Clock.ms(50) })
    if conn == nil then
      why = trouble
      break
    end
    -- A connection the kernel reset may say so again as it closes.
    held[#held + 1] = function() local _, _ = conn:close() end
    last = conn
  end
  if why == "" then
    -- Every one was made: a kernel that answers past the backlog made
    -- the last and reset it, which reading it tells from one queued.
    local made = assert(last)
    made:set_timeout(Clock.seconds(5))
    local data, trouble = made:read()
    assert(data == nil and trouble == RESET,
      "a backlog of 1 took " .. tostring(ASKED) .. " connections: reading the last, " .. tostring(data or trouble))
    why = at(server.address, RESET)
  end
  assert(why == at(server.address, Poll.TIMEOUT) or why == at(server.address, RESET), why)
  if assert(sys.uname()).sysname == "Linux" then
    assert(why == at(server.address, Poll.TIMEOUT), why)
  end
  return server.address, why
end

--- A TCP address where a connection is left unanswered, so that
--- connecting waits: a listener whose backlog is full where the kernel
--- drops what comes past it (Linux, macOS 15.8), and 127.0.0.2 where
--- the kernel resets that instead (macOS 27.2) and drops what is sent
--- to a loopback address the host does not have. `held` gets the
--- closers of what [`full_backlog`] opened. Skips where neither leaves a
--- connection waiting.
local function unanswered_or_skip(held: mut {function()}): Net.Address
  local full, why = full_backlog(held)
  if why == at(full, Poll.TIMEOUT) then return full end
  local absent = Net.tcp("127.0.0.2", assert(full.port))
  local conn, trouble = Net.connect(absent, { timeout_ns = Clock.ms(50) })
  if trouble == at(absent, Poll.TIMEOUT) then return absent end
  if conn ~= nil then assert(conn:close()) end
  for _, close in ipairs(held) do close() end
  Test.skip("no connection is left waiting here: a full backlog resets one, and 127.0.0.2 answers " ..
      (if conn ~= nil then "by taking it" else trouble end))
  return absent
end

--- A connection past a TCP listener's full backlog is not taken: it
--- waits as long as its timeout, as Linux has it, or, where the kernel
--- answers it (macOS 27.2), is reset: it fails so, or is made and its
--- first read fails so.
local function test_a_connection_to_a_full_backlog_waits_or_is_reset()
  local held: mut {function()} = {}
  local full, why = full_backlog(held)
  if why == at(full, RESET) then
    for _ = 1, 32 do
      local conn, trouble = Net.connect(full, { timeout_ns = Clock.seconds(5) })
      if conn == nil then
        assert(trouble == at(full, RESET), trouble)
      else
        local data, read_why = conn:read()
        local _, _ = conn:close()
        assert(data == nil and read_why == RESET, tostring(data or read_why))
      end
    end
  end
  for _, close in ipairs(held) do close() end
end

--- A connection nothing answers waits as long as its timeout, or until
--- a guard catches a signal.
local function test_an_unanswered_connection_times_out_or_is_interrupted()
  local held: mut {function()} = {}
  local silent = unanswered_or_skip(held)
  local began = Clock.monotonic_ns()
  local late, why = Net.connect(silent, { timeout_ns = Clock.ms(50) })
  assert(late == nil and why == at(silent, Poll.TIMEOUT), why)
  assert(Clock.monotonic_ns() - began >= Clock.ms(50), "it failed before its time ran out")
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local conn, interrupted = Net.connect(silent)
  assert(assert(guard:release()) == sys.SIGINT)
  assert(conn == nil and interrupted == at(silent, "interrupted"), interrupted)
  for _, close in ipairs(held) do close() end
end

--- In a task, a TCP connection waits to be made through the run: the
--- other tasks go on while one waits on a connection nothing answers,
--- until its time runs out. One that is refused says so.
local function test_in_a_run_a_tcp_connect_waits_through_the_run()
  local held: mut {function()} = {}
  local silent = unanswered_or_skip(held)
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  local ticks: integer = 0
  local ticks_at_end: integer = -1
  local why: string = ""
  Poll.run(function()
    local first = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
    held[#held + 1] = function() assert(first:close()) end
    local accepted = assert(server:accept())
    held[#held + 1] = function() assert(accepted:close()) end
    local waiting = Poll.spawn(function()
      local conn, trouble = Net.connect(silent, { timeout_ns = Clock.ms(200) })
      if conn ~= nil then assert(conn:close()) end
      why = trouble
      ticks_at_end = ticks
    end)
    while ticks_at_end < 0 do
      assert(Poll.delay(Clock.ms(5)))
      ticks = ticks + 1
    end
    assert(waiting:join())
  end)
  for _, close in ipairs(held) do close() end
  assert(why == at(silent, Poll.TIMEOUT), why)
  assert(ticks_at_end > 0, "no other task ran while a connection waited")
  local port = assert(server.address.port)
  assert(server:close())
  local refused: Net.Conn? = nil
  Poll.run(function()
    refused, why = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(5) })
  end)
  assert(refused == nil and why == "127.0.0.1:" .. tostring(port) .. ": Connection refused", why)
end

--- One protocol serves every listener, a TCP one and a unix one alike,
--- and on_ready is told the port the kernel chose for one at port 0.
local function test_a_server_names_what_it_bound_and_serves_every_listener(tmp: string)
  unix_socket.skip_if_refused(tmp)
  local bound = {} as {Net.Address} -- checked: cast_refused, literal_needs_type
  local answers: mut {string} = {}
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0), Net.unix(tmp .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      assert(conn:write(line:upper() .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      bound = addresses
      assert(server.addresses == addresses)
      for _, address in ipairs(addresses) do
        local conn <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
        assert(conn:write(address.kind .. "\n"))
        local appended = assert(Stream.lines(conn):read())
        answers[#answers + 1] = appended
      end
      server:stop()
    end,
  })
  assert(bound[1].kind == "tcp" and bound[1].host == "127.0.0.1", bound[1].host)
  local first_port = assert(bound[1].port)
  assert(first_port > 0 and first_port <= 65535, tostring(first_port))
  assert(bound[2].kind == "unix" and bound[2].path == tmp .. "/s.sock", bound[2].path)
  assert(table.concat(answers, ",") == "TCP,UNIX", table.concat(answers, ","))
end

--- The same for two TCP listeners, which need no socket file.
local function test_a_server_names_what_it_bound_and_serves_two_tcp_listeners()
  local bound = {} as {Net.Address} -- checked: cast_refused, literal_needs_type
  local answers: mut {string} = {}
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0), Net.tcp("127.0.0.1", 0) },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      assert(conn:write(line:upper() .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      bound = addresses
      assert(server.addresses == addresses)
      for _, address in ipairs(addresses) do
        local conn <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
        assert(conn:write(address.kind .. "\n"))
        local appended = assert(Stream.lines(conn):read())
        answers[#answers + 1] = appended
      end
      server:stop()
    end,
  })
  for i = 1, 2 do
    assert(bound[i].kind == "tcp" and bound[i].host == "127.0.0.1", bound[i].host)
    local listening = assert(bound[i].port)
    assert(listening > 0 and listening <= 65535, tostring(listening))
  end
  assert(bound[1].port ~= bound[2].port)
  assert(table.concat(answers, ",") == "TCP,TCP", table.concat(answers, ","))
end
