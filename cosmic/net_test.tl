local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

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
  local server = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ms = 5000 }))
  local client = assert(Net.connect(server.address, { timeout_ms = 5000 }))
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
  client.timeout_ms = 50
  local ok, why = client:write(string.rep("x", 16 * 1024 * 1024))
  assert(not ok and why == "timed out", why)
  local again, sticky = client:write("more")
  assert(not again and sticky == "timed out", sticky)
  local got = assert(accepted:read(10))
  assert(got == string.rep("x", #got) and #got <= 10)
end

--- A read that times out takes nothing, so a later one still reads,
--- and writing is left be. The accepted connection has its listener's
--- timeout.
local function test_a_read_that_times_out_leaves_the_connection_usable(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ms = 20 }))
  local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
  local accepted <close> = assert(server:accept())
  assert(accepted.timeout_ms == 20)
  local data, why = accepted:read()
  assert(data == nil and why == "timed out", why)
  assert(accepted:write("still here"))
  assert(assert(client:read()) == "still here")
  assert(client:write("late"))
  assert(assert(accepted:read()) == "late")
end

--- A timeout no wait can last is refused where it is read, naming the
--- field.
local function test_a_timeout_out_of_range_is_refused(tmp: string)
  local p <close> = pair(tmp)
  p.client.timeout_ms = -5
  local ok, why = pcall(p.client.read, p.client)
  assert(not ok and tostring(why):find("timeout_ms must be", 1, true) ~= nil, tostring(why))
  assert(not pcall(Net.connect, p.server.address, { timeout_ms = -1 }))
  assert(not pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { timeout_ms = 1 << 40 }))
end

--- A Writer that a wrapper closes ends only what is sent: the answer is
--- still there to read.
local function test_a_writer_closed_leaves_the_answer_to_read(tmp: string)
  local p <close> = pair(tmp)
  local writer = p.client:writer()
  assert(writer:write("request"))
  assert(writer:close())
  assert(assert(Stream.read_all(p.accepted)) == "request")
  assert(p.accepted:write("answer"))
  assert(p.accepted:close())
  assert(assert(Stream.read_all(p.client)) == "answer")
  assert(writer:close(), "a second close is harmless")
  local late, late_why = writer:write("more")
  assert(not late and late_why == "writer is closed", late_why)
  assert(p.client:writer():abort())
  local data, why = p.client:read()
  assert(data == nil and why == "connection is closed", why)
end

--- A listener whose backlog is full is waited on for room on Linux,
--- which the time runs out on here, no one accepting; macOS refuses the
--- connection at once.
local function test_connecting_to_a_full_backlog(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { backlog = 1 }))
  local held: {Net.Conn} = {}
  local why = ""
  for _ = 1, 16 do
    local conn, trouble = Net.connect(server.address, { timeout_ms = 20 })
    if conn == nil then
      why = trouble
      break
    end
    held[#held + 1] = conn
  end
  local darwin = assert(sys.uname()).sysname == "Darwin"
  local want = tmp .. "/s.sock: " .. (darwin and "Connection refused" or "timed out")
  assert(why == want, why)
  -- A signal a guard catches ends the wait for room, which has no limit
  -- of its own here, rather than asking again for good.
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local conn, interrupted = Net.connect(server.address)
  assert(assert(guard:release()) == sys.SIGINT)
  if conn ~= nil then assert(conn:close()) end
  want = tmp .. "/s.sock: " .. (darwin and "Connection refused" or "interrupted")
  assert(conn == nil and interrupted == want, interrupted)
  for _, held_conn in ipairs(held) do assert(held_conn:close()) end
end

local function test_accept_with_no_one_connecting_times_out(tmp: string)
  local server <close> = assert(Net.listen(Net.unix(tmp .. "/s.sock"), { timeout_ms = 60000 }))
  local conn, why = server:accept(20)
  assert(conn == nil and why == "timed out", why)
  server.timeout_ms = 0
  conn, why = server:accept()
  assert(conn == nil and why == "timed out", why)
end

--- A signal a guard catches ends a wait at once, as it ends
--- `cosmic.http`'s.
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
  assert(data == nil and why == "connection is closed", why)
  local ok, trouble = client:write("x")
  assert(not ok and trouble == "connection is closed", trouble)
  local shut, shut_trouble = client:shutdown("write")
  assert(not shut and shut_trouble == "connection is closed", shut_trouble)
  assert(not pcall(accepted.shutdown, accepted, "sideways"))
  assert(not pcall(accepted.read, accepted, 0))
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
  assert(conn == nil and why == "listener is closed", why)
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
  assert(not pcall(Net.listen, Net.unix("")))
  assert(not pcall(Net.connect, Net.unix("")))
  assert(not pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { backlog = 0 }))
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
    local server <close> = assert(Net.listen(Net.unix(path), { timeout_ms = 5000 }))
    assert(sys.getcwd() == was)
    local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
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

--- `reclaim` takes over a socket file a listener left behind, and
--- nothing else: a live listener's file, and a file that is no socket,
--- are left alone.
local function test_reclaim_takes_over_only_a_socket_file_left_behind(tmp: string)
  local path = tmp .. "/s.sock"
  local moved = tmp .. "/moved.sock"
  -- Moved aside while it listened, and back once it closed: a socket
  -- file with nothing listening, as one a killed listener leaves.
  do
    local _gone <close> = assert(Net.listen(Net.unix(path)))
    assert(sys.rename(path, moved))
  end
  assert(sys.rename(moved, path))
  local refused, why = Net.listen(Net.unix(path))
  assert(refused == nil and why == path .. ": Address in use", why)
  local server <close> = assert(Net.listen(Net.unix(path), { reclaim = true, timeout_ms = 5000 }))
  local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
  local accepted <close> = assert(server:accept())
  assert(client:write("here"))
  assert(assert(accepted:read()) == "here")
  local again, live = Net.listen(Net.unix(path), { reclaim = true })
  assert(again == nil and live == path .. ": Address in use", live)
  assert(client:write("still"))
  assert(assert(accepted:read()) == "still")
  local plain = tmp .. "/plain"
  assert(Fs.write(plain, "mine"))
  local over, taken = Net.listen(Net.unix(plain), { reclaim = true })
  assert(over == nil and taken == plain .. ": Address in use", taken)
  assert(Fs.read(plain) == "mine")
end

--- A live listener whose backlog is full keeps its file: on Linux the
--- connection that asks waits for room, and its time runs out rather
--- than its being refused. (macOS refuses it, as `reclaim`'s doc says.)
local function test_reclaim_leaves_a_full_live_listener_alone(tmp: string)
  if assert(sys.uname()).sysname == "Darwin" then return end
  local path = tmp .. "/s.sock"
  local server <close> = assert(Net.listen(Net.unix(path), { backlog = 1 }))
  local held: {Net.Conn} = {}
  for _ = 1, 16 do
    local conn, _ = Net.connect(server.address, { timeout_ms = 20 })
    if conn == nil then break end
    held[#held + 1] = conn
  end
  local again, live = Net.listen(Net.unix(path), { reclaim = true })
  assert(again == nil and live == path .. ": Address in use", live)
  assert(Fs.stat(path) ~= nil, "the live listener's file was taken")
  for _, conn in ipairs(held) do assert(conn:close()) end
end
