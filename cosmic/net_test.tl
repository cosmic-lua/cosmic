local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

--- A listener at a fresh socket file, and a connection to it from each
--- end, all closed with it.
local record Pair
  server: Net.Listener
  client: Net.Conn
  accepted: Net.Conn
  metamethod __close: function(Pair)
end

local pair_mt: metatable<Pair> = {
  __close = function(self: Pair)
    local _, _ = self.accepted:close()
    local _, _ = self.client:close()
    local _, _ = self.server:close()
  end,
}

local function pair(tmp: string): Pair
  local server = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ns = Time.seconds(5) }))
  local client = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) }))
  local accepted = assert(server:accept())
  return setmetatable({ server = server, client = client, accepted = accepted }, pair_mt)
end

local function test_a_connection_carries_bytes_both_ways_to_the_end(tmp: string)
  local p <close> = pair(tmp)
  local server, client, accepted = p.server, p.client, p.accepted
  assert(client:write("hello\nworld\n"))
  assert(client:shutdown("write"))
  local lines = Stream.lines(accepted)
  assert(lines:read() == "hello")
  assert(lines:read() == "world")
  local last, why = lines:read()
  assert(last == nil and why == "", why)
  assert(accepted:write("answered"))
  assert(accepted:close())
  assert(assert(Stream.read_all(client)) == "answered")
  assert(server.address.kind == "unix" and server.address.path == tmp .. "/s.sock")
end

--- A write larger than the socket holds goes out whole, waiting as the
--- peer takes it; one the peer never takes waits out its time.
local function test_a_write_waits_while_the_peer_does_not_read(tmp: string)
  local p <close> = pair(tmp)
  local client, accepted = p.client, p.accepted
  client:set_timeout(Time.ms(50))
  local ok, why = client:write(string.rep("x", 16 * 1024 * 1024))
  assert(not ok and why == Poll.TIMEOUT, why)
  local again, sticky = client:write("more")
  assert(not again and sticky == Poll.TIMEOUT, sticky)
  local got = assert(accepted:read(10))
  assert(got == string.rep("x", #got) and #got <= 10)
end

--- A read that times out takes nothing, so a later one still reads,
--- and writing is left be. The accepted connection has its listener's
--- timeout.
local function test_a_read_that_times_out_leaves_the_connection_usable(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ns = Time.ms(20) }))
  local client <close> = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) }))
  local accepted <close> = assert(server:accept())
  local data, why = accepted:read()
  assert(data == nil and why == Poll.TIMEOUT, why)
  assert(accepted:write("still here"))
  assert(assert(client:read()) == "still here")
  assert(client:write("late"))
  assert(assert(accepted:read()) == "late")
end

--- A timeout no wait can last is refused where it is set, naming the
--- field and the caller's line, for a connection and for a listener;
--- the timeout it had stays.
local function test_a_timeout_out_of_range_is_refused(tmp: string)
  local p <close> = pair(tmp)
  for _, bad in ipairs({ -5, Poll.MOST_NS + 1, 1.5 } as {number}) do
    local ok, why: boolean, any = pcall(function() p.client:set_timeout(bad as integer) end)
    assert(not ok and tostring(why):find("^cosmic%.net_test:%d+: net: timeout_ns must be nil or an integer from 0 to",
      1) ~= nil, tostring(why))
    local listener_ok, listener_why: boolean, any = pcall(function()
      p.server:set_timeout(bad as integer)
    end)
    assert(not listener_ok and tostring(listener_why):find("^cosmic%.net_test:%d+: net: timeout_ns must be", 1) ~= nil,
      tostring(listener_why))
  end
  local accepting, accept_why: boolean, any = pcall(function() local _, _ = p.server:accept(-1) end)
  assert(not accepting and tostring(accept_why):find("^cosmic%.net_test:%d+: net: timeout_ns must be", 1) ~= nil,
    tostring(accept_why))
  p.client:set_timeout(Time.ms(10))
  assert(not pcall(function() p.client:set_timeout(-1) end))
  local data, read_why = p.client:read()
  assert(data == nil and read_why == Poll.TIMEOUT, read_why)
  assert(not pcall(Net.connect, p.server.address, { timeout_ns = -1 }))
  assert(not pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { timeout_ns = Poll.MOST_NS + 1 }))
  assert(not pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { timeout_ns = 1 << 62 }))
end

--- A timeout is nanoseconds: a read, an accept and a connection's wait
--- end after about the time given, in a run and out of one.
local function test_a_timeout_waits_the_nanoseconds_it_is_given(tmp: string)
  local p <close> = pair(tmp)
  p.accepted:set_timeout(Time.ms(100))
  local function bounded(took: integer, what: string)
    assert(took >= Time.ms(90) and took < Time.seconds(10),
      what .. " waited " .. tostring(took // Time.ms(1)) .. " ms, not about 100")
  end
  local began = Time.monotonic_ns()
  local data, why = p.accepted:read()
  assert(data == nil and why == Poll.TIMEOUT, why)
  bounded(Time.monotonic_ns() - began, "a read")
  began = Time.monotonic_ns()
  local conn, accept_why = p.server:accept(Time.ms(100))
  assert(conn == nil and accept_why == Poll.TIMEOUT, accept_why)
  bounded(Time.monotonic_ns() - began, "an accept")
  Poll.run(function()
    local at = Time.monotonic_ns()
    local got, got_why = p.accepted:read()
    assert(got == nil and got_why == Poll.TIMEOUT, got_why)
    bounded(Time.monotonic_ns() - at, "a read in a run")
    at = Time.monotonic_ns()
    local taken, taken_why = p.server:accept(Time.ms(100))
    assert(taken == nil and taken_why == Poll.TIMEOUT, taken_why)
    bounded(Time.monotonic_ns() - at, "an accept in a run")
  end)
  -- A nanosecond rounds up to a wait of a millisecond, which ends.
  p.accepted:set_timeout(1)
  local brief, brief_why = p.accepted:read()
  assert(brief == nil and brief_why == Poll.TIMEOUT, brief_why)
end

--- A unix listener whose backlog is full, no one accepting.
local record Full
  server: Net.Listener
  held: {Net.Conn}
  metamethod __close: function(Full)
end

local full_mt: metatable<Full> = {
  __close = function(self: Full)
    for _, conn in ipairs(self.held) do local _, _ = conn:close() end
    local _, _ = self.server:close()
  end,
}

local function full(path: string): Full
  local server = assert(Net.listen(Net.unix(path), { backlog = 1 }))
  local held: {Net.Conn} = {}
  for _ = 1, 16 do
    local conn = Net.connect(server.address, { timeout_ns = 0 })
    if conn == nil then break end
    held[#held + 1] = conn
  end
  return setmetatable({ server = server, held = held }, full_mt)
end

--- What connecting to a full listener at `path` fails with: on Linux,
--- saying the listener is busy, told from "Connection refused", which
--- a listener gone answers; macOS cannot tell the two apart.
local function busy(path: string): string
  if assert(sys.uname()).sysname == "Darwin" then return path .. ": Connection refused" end
  return path .. ": Resource temporarily unavailable (the listener is busy: its backlog is full)"
end

--- A connection to a unix listener whose backlog is full fails at once,
--- however long it may wait, rather than waiting for room.
local function test_connecting_to_a_full_backlog_fails_at_once(tmp: string)
  local path = tmp .. "/s.sock"
  local _full <close> = full(path)
  local began = Time.monotonic_ns()
  local conn, why = Net.connect(Net.unix(path), { timeout_ns = Time.seconds(20) })
  assert(Time.monotonic_ns() - began < Time.seconds(10), "the connection waited for room")
  assert(conn == nil and why == busy(path), why)
end

local function test_accept_with_no_one_connecting_times_out(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ns = Time.seconds(60) }))
  local conn, why = server:accept(Time.ms(20))
  assert(conn == nil and why == Poll.TIMEOUT, why)
  server:set_timeout(0)
  conn, why = server:accept()
  assert(conn == nil and why == Poll.TIMEOUT, why)
end

--- A signal a guard catches ends a wait at once, as it ends
--- [`cosmic.http`]'s.
local function test_a_caught_signal_ends_a_wait(tmp: string)
  local p <close> = pair(tmp)
  local server, client, accepted = p.server, p.client, p.accepted
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local conn, why = server:accept()
  local data, read_why = accepted:read()
  local caught = assert(guard:release())
  assert(caught == sys.SIGINT, tostring(caught))
  assert(conn == nil and why == "interrupted", why)
  assert(data == nil and read_why == "interrupted", read_why)
  assert(client:close())
end

--- A write to a peer that has gone fails, and keeps failing. That it
--- does so rather than ending the process with SIGPIPE is
--- cosmic/net_tool_test.tl's, in a process that starts with SIGPIPE at
--- its default, where this worker's may be ignored.
local function test_a_write_to_a_closed_peer_fails(tmp: string)
  local p <close> = pair(tmp)
  local client, accepted = p.client, p.accepted
  assert(accepted:close())
  local ok, why = client:write(string.rep("x", 1024 * 1024))
  assert(not ok and why ~= "", why)
  local again, sticky = client:write("x")
  assert(not again and sticky == why, sticky)
end

local function test_a_closed_connection_says_so_and_closes_again(tmp: string)
  local p <close> = pair(tmp)
  local client, accepted = p.client, p.accepted
  assert(accepted:shutdown("read"))
  assert(client:shutdown("both"))
  assert(client:abort())
  assert(client:close())
  local data, why = client:read()
  assert(data == nil and why == "net: the connection is closed", why)
  local ok, trouble = client:write("x")
  assert(not ok and trouble == "net: the connection is closed", trouble)
  local shut, shut_trouble = client:shutdown("write")
  assert(not shut and shut_trouble == "net: the connection is closed", shut_trouble)
end

--- A `max_bytes` below 1 and a `how` of none of the three raise, at the line
--- that called, in the module's own style.
local function test_a_degenerate_read_or_shutdown_raises_at_the_caller(tmp: string)
  local p <close> = pair(tmp)
  local accepted = p.accepted
  for _, max_bytes in ipairs({ 0, -1 }) do
    local ok, why: boolean, any = pcall(function() local _, _ = accepted:read(max_bytes) end)
    assert(not ok and tostring(why):find("^cosmic%.net_test:%d+: net: max_bytes must be positive$") ~= nil,
      tostring(why))
  end
  local shut, shut_why: boolean, any = pcall(function()
    local _, _ = accepted:shutdown("sideways")
  end)
  assert(not shut and tostring(shut_why):find(
    '^cosmic%.net_test:%d+: net: how must be "read", "write" or "both"$') ~= nil, tostring(shut_why))
  assert(accepted:shutdown("read"), "a refused call must not end the direction")
end

--- `reclaim` is gone: a listen that sets it raises, naming the removal,
--- rather than listen without it.
local function test_listen_refuses_the_removed_reclaim_option(tmp: string)
  local options: any = { reclaim = true }
  local address = Net.unix(tmp .. "/s.sock")
  local ok, why: boolean, any = pcall(function()
    local _, _ = Net.listen(address, options as Net.ListenOptions)
  end)
  assert(not ok and tostring(why):find("^cosmic%.net_test:%d+: net: ListenOptions.reclaim is gone: ") ~= nil,
    tostring(why))
  assert(Fs.stat(tmp .. "/s.sock") == nil and Fs.stat(tmp .. "/s.sock.lock") == nil)
end

--- A listener's `address` is the one given, built again by [`Net.unix`]:
--- a unix one keeps its path and nothing else.
local function test_a_unix_listeners_address_is_built_again_from_its_path(tmp: string)
  local given = { kind = "unix", path = tmp .. "/s.sock", host = "unused", port = 9 }
  local server <close> = assert(Net.listen(given))
  local address = server.address
  assert(address.kind == "unix" and address.path == tmp .. "/s.sock", address.path)
  assert(address.host == nil and address.port == nil, "a field past the kind's own was kept")
  assert(address ~= given, "the listener holds the caller's table")
  local client <close> = assert(Net.connect(address, { timeout_ns = Time.seconds(5) }))
  assert(client:close())
end

--- A listener at a relative path removes its own socket file at close
--- wherever the process has moved since.
local function test_close_removes_a_relative_socket_file_after_a_chdir(tmp: string)
  local was = assert(sys.getcwd())
  assert(sys.chdir(tmp))
  local server, trouble = Net.listen(Net.unix("rel.sock"))
  assert(sys.chdir(was))
  assert(server ~= nil, trouble)
  assert(Fs.stat(tmp .. "/rel.sock") ~= nil, "no socket file")
  assert(server:close())
  assert(Fs.stat(tmp .. "/rel.sock") == nil, "the socket file was left")
end

local function test_close_removes_the_socket_file_it_made(tmp: string)
  local path = tmp .. "/s.sock"
  local server = assert(Net.listen(Net.unix(path)))
  assert(Fs.stat(path) ~= nil, "no socket file")
  assert(server:close())
  assert(Fs.stat(path) == nil, "the socket file was left")
  assert(server:close())
  local conn, why = server:accept()
  assert(conn == nil and why == "net: the listener is closed", why)
end

--- A name another file took since the listener made its own is not the
--- listener's to remove. Its socket file, moved aside, is left behind
--- with nothing listening: connecting there is refused, and listening
--- there fails rather than take the name.
local function test_a_socket_file_left_behind_is_refused_and_kept(tmp: string)
  local path = tmp .. "/s.sock"
  local moved = tmp .. "/moved.sock"
  do
    local _server <close> = assert(Net.listen(Net.unix(path)))
    assert(sys.rename(path, moved))
    assert(Fs.write(path, "someone else's"))
  end
  assert(Fs.read(path) == "someone else's")
  assert(Fs.stat(moved) ~= nil, "the moved socket file was removed")
  local conn, why = Net.connect(Net.unix(moved))
  assert(conn == nil and why == moved .. ": Connection refused", why)
  local again, taken = Net.listen(Net.unix(moved))
  assert(again == nil and taken == moved .. ": Address in use", taken)
  local over, file = Net.listen(Net.unix(path))
  assert(over == nil and file == path .. ": Address in use", file)
  assert(Fs.read(path) == "someone else's")
end

local function test_connecting_where_there_is_no_socket_file_fails(tmp: string)
  local path = tmp .. "/none.sock"
  local conn, why = Net.connect(Net.unix(path))
  assert(conn == nil and why == path .. ": No such file or directory", why)
end

--- A socket file's own name the platform cannot hold fails rather than
--- naming a shorter one, saying the bound; so does a path with a NUL in
--- it, and one that names a directory; an empty one is no address.
local function test_a_path_that_names_no_socket_file_is_refused(tmp: string)
  local too_long = ": Filename too long (a socket file's own name may be at most "
  for _, long in ipairs({ tmp .. "/" .. string.rep("x", 120), string.rep("y", 120) }) do
    local server, why = Net.listen(Net.unix(long))
    assert(server == nil and why:find(long .. too_long, 1, true) == 1, why)
    local conn, conn_why = Net.connect(Net.unix(long))
    assert(conn == nil and conn_why:find(long .. too_long, 1, true) == 1, conn_why)
  end
  local directory = tmp .. "/" .. string.rep("d", 120) .. "/"
  assert(Fs.mkdirs(directory))
  local ended, ended_why = Net.listen(Net.unix(directory))
  assert(ended == nil and ended_why == directory .. ": Is a directory", ended_why)
  local nul = tmp .. "/a\0b"
  local held, held_why = Net.listen(Net.unix(nul))
  assert(held == nil and held_why == nul .. ": Invalid argument", held_why)
  assert(Fs.stat(tmp .. "/a") == nil, "a shorter name was bound")
  for _, address in ipairs({ Net.unix(""), Net.tcp("127.0.0.1", 65536), { kind = "pipe" } as Net.Address }) do
    local listen_ok, listen_why = pcall(Net.listen, address)
    assert(not listen_ok and tostring(listen_why):find("net: address must be ", 1, true) == 1,
      tostring(listen_why))
    local connect_ok, connect_why = pcall(Net.connect, address)
    assert(not connect_ok and tostring(connect_why):find("net: address must be ", 1, true) == 1,
      tostring(connect_why))
  end
  local listened, backlog_why = pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { backlog = 0 })
  assert(not listened and tostring(backlog_why):find("net: backlog must be at least 1", 1, true),
    tostring(backlog_why))
end

--- A path past the platform's bound on a socket address is reached
--- from its directory, absolute or relative: only the file's own name
--- is bounded, and the working directory is where it was after.
local function test_a_long_path_is_reached_from_its_directory(tmp: string)
  local deep = tmp .. "/" .. string.rep("d", 100) .. "/" .. string.rep("e", 100)
  assert(Fs.mkdirs(deep))
  local was = assert(sys.getcwd())
  local path = deep .. "/" .. string.rep("s", 100)
  do
    local server <close> = assert(Net.listen(Net.unix(path), { timeout_ns = Time.seconds(5) }))
    assert(sys.getcwd() == was)
    local client <close> = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) }))
    local accepted <close> = assert(server:accept())
    assert(client:write("far"))
    assert(assert(accepted:read()) == "far")
    assert(sys.getcwd() == was)
  end
  assert(Fs.stat(path) == nil, "the socket file was left")
  local missing = tmp .. "/" .. string.rep("m", 120) .. "/s.sock"
  local conn, why = Net.connect(Net.unix(missing))
  assert(conn == nil and why == missing .. ": No such file or directory", why)
  assert(sys.chdir(tmp))
  local relative = string.rep("d", 100) .. "/" .. string.rep("e", 100) .. "/r.sock"
  local server, trouble = Net.listen(Net.unix(relative))
  assert(sys.chdir(was))
  assert(server ~= nil, trouble)
  assert(Fs.stat(deep .. "/r.sock") ~= nil, "no socket file")
  assert(server:close())
  assert(Fs.stat(deep .. "/r.sock") == nil, "the socket file was left")
end

local DEEP_PART <const> = string.rep("d", 200)
local DEEP_LEVELS <const> = 24

--- A directory under `tmp` whose whole path is past any platform's
--- PATH_MAX, made and entered one component at a time, since no call
--- can name it whole.
local function enter_deep(tmp: string)
  assert(sys.chdir(tmp))
  for _ = 1, DEEP_LEVELS do
    local made, why, errno = sys.mkdir(DEEP_PART)
    assert(made or errno == sys.EEXIST, why)
    assert(sys.chdir(DEEP_PART))
  end
end

--- Removes what [`enter_deep`] made, deepest first, which the harness
--- could not: its own removal names each path whole.
local function remove_deep(tmp: string)
  enter_deep(tmp)
  sys.unlink("s.sock")
  for _ = 1, DEEP_LEVELS do
    assert(sys.chdir(".."))
    assert(sys.rmdir(DEEP_PART))
  end
end

--- A relative name listened at from a working directory past PATH_MAX
--- needs no whole path: the listener serves there, and close removes
--- its file from wherever the process has moved to.
local function test_a_listener_past_path_max_serves_and_removes_its_file(tmp: string)
  local was = assert(sys.getcwd())
  local ok, failure: boolean, any = pcall(function()
    enter_deep(tmp)
    local server, trouble = Net.listen(Net.unix("s.sock"), { timeout_ns = Time.seconds(5) })
    local client, connect_trouble = Net.connect(Net.unix("s.sock"), { timeout_ns = Time.seconds(5) })
    assert(sys.chdir(was))
    assert(server ~= nil, trouble)
    assert(client ~= nil, connect_trouble)
    local accepted = assert(server:accept())
    assert(client:write("deep"))
    assert(assert(accepted:read()) == "deep")
    assert(accepted:close())
    assert(client:close())
    assert(server:close())
    enter_deep(tmp)
    local left = sys.lstat("s.sock")
    assert(sys.chdir(was))
    assert(left == nil, "the socket file was left")
  end)
  local removed, trouble: boolean, any = pcall(remove_deep, tmp)
  assert(sys.chdir(was))
  assert(ok, tostring(failure))
  assert(removed, tostring(trouble))
end

--- In a task of Poll.run, a server serves each connection in a task of
--- its own: three clients hold their connections open at once, and the
--- server answers the last to connect first, which a server whose reads
--- held the thread could never do.
local function test_in_a_run_a_server_serves_connections_at_once(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ns = Time.seconds(5) }))
  local answered: {string} = {}
  Poll.run(function()
    Poll.spawn(function()
      for _ = 1, 3 do
        local conn = assert(server:accept())
        Poll.spawn(function()
          local line = assert(Stream.lines(conn):read())
          assert(conn:write("re " .. line .. "\n"))
          assert(conn:close())
        end)
      end
    end)
    local clients: {Net.Conn} = {}
    for i = 1, 3 do clients[i] = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) })) end
    for i = 3, 1, -1 do
      assert(clients[i]:write("c" .. i .. "\n"))
      answered[#answered + 1] = assert(Stream.lines(clients[i]):read())
      assert(clients[i]:close())
    end
  end)
  assert(table.concat(answered, ",") == "re c3,re c2,re c1", table.concat(answered, ","))
end

--- In a run, a read that waits lets the other tasks run, and ends
--- "cancelled" once its task is cancelled; out of one, it waits alone.
local function test_in_a_run_a_waiting_read_ends_when_its_task_is_cancelled(tmp: string)
  local p <close> = pair(tmp)
  local answer = ""
  local others = 0
  Poll.run(function()
    local reader = Poll.spawn(function()
      local data, why = p.accepted:read()
      assert(data == nil)
      answer = why
    end)
    for _ = 1, 3 do
      assert(Poll.delay(Time.ms(1)))
      others = others + 1
    end
    reader:cancel()
    assert(reader:join())
  end)
  assert(others == 3 and answer == Poll.CANCELLED, answer)
  assert(p.client:write("after"))
  assert(p.accepted:read() == "after", "the connection is usable after the run")
end

--- A read waiting in a task whose connection another task closes ends
--- "net: the connection is closed", even where a new connection has taken the
--- same descriptor number with data waiting, which it leaves alone.
local function test_in_a_run_a_read_on_a_connection_closed_under_it_ends(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ns = Time.seconds(5) }))
  local _first_client <close> = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) }))
  local first = assert(server:accept())
  local answer = ""
  local later = ""
  Poll.run(function()
    local reader = Poll.spawn(function()
      local data, why = first:read()
      assert(data == nil, "the closed connection answered " .. tostring(data))
      answer = why
    end)
    assert(Poll.delay(0))
    assert(first:close())
    local second_client <close> = assert(Net.connect(server.address, { timeout_ns = Time.seconds(5) }))
    local second = assert(server:accept())
    assert(second_client:write("second's"))
    assert(reader:join(Time.seconds(5)))
    later = assert(second:read())
    assert(second:close())
  end)
  assert(answer == "net: the connection is closed", answer)
  assert(later == "second's", later)
end

--- A write in a task that fills the peer's buffer waits for it to be
--- drained by another task, and every byte arrives.
local function test_in_a_run_a_write_waits_while_another_task_drains(tmp: string)
  local p <close> = pair(tmp)
  local size = 4 * 1024 * 1024
  local got = 0
  Poll.run(function()
    Poll.spawn(function()
      assert(p.client:write(string.rep("x", size)))
      assert(p.client:shutdown("write"))
    end)
    Poll.spawn(function()
      while true do
        local data, why = p.accepted:read()
        if data == nil then
          assert(why == "", why)
          break
        end
        got = got + #data
      end
    end)
  end)
  assert(got == size, "got " .. got .. " of " .. size .. " bytes")
end

--- In a task, a wait past its timeout fails with Poll.TIMEOUT, as it does out
--- of one.
local function test_in_a_run_waits_time_out_as_they_do_out_of_one(tmp: string)
  local p <close> = pair(tmp)
  Poll.run(function()
    local conn, why = p.server:accept(Time.ms(10))
    assert(conn == nil and why == Poll.TIMEOUT, why)
    p.accepted:set_timeout(Time.ms(10))
    local data, read_why = p.accepted:read()
    assert(data == nil and read_why == Poll.TIMEOUT, read_why)
  end)
end

--- In a task, a connection to a unix listener whose backlog is full
--- fails at once, as one out of a run does.
local function test_in_a_run_a_connect_to_a_full_backlog_fails_at_once(tmp: string)
  local path = tmp .. "/s.sock"
  local _full <close> = full(path)
  local conn: Net.Conn
  local why = ""
  local began = Time.monotonic_ns()
  Poll.run(function()
    conn, why = Net.connect(Net.unix(path), { timeout_ns = Time.seconds(20) })
  end)
  assert(Time.monotonic_ns() - began < Time.seconds(10), "the connection waited for room")
  assert(conn == nil and why == busy(path), why)
end
