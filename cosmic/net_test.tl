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

local function test_a_read_with_nothing_sent_times_out_and_stays_failed(tmp: string)
  local p <close> = pair(tmp)
  local client, accepted = p.client, p.accepted
  accepted.timeout_ms = 20
  local data, why = accepted:read()
  assert(data == nil and why == "timed out", why)
  assert(client:write("late"))
  local again, sticky = accepted:read()
  assert(again == nil and sticky == "timed out", sticky)
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

--- A write to a peer that has gone fails rather than ending the process
--- with SIGPIPE.
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
  assert(accepted:shutdown("both"))
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

--- A path the platform cannot hold whole fails rather than naming a
--- shorter one, and so does one with a NUL in it; an empty one is no
--- address at all.
local function test_a_path_that_names_no_socket_file_is_refused(tmp: string)
  local long = tmp .. "/" .. string.rep("x", 120)
  local server, why = Net.listen(Net.unix(long))
  assert(server == nil and why == long .. ": Filename too long", why)
  local conn, conn_why = Net.connect(Net.unix(long))
  assert(conn == nil and conn_why == long .. ": Filename too long", conn_why)
  local nul = tmp .. "/a\0b"
  local held, held_why = Net.listen(Net.unix(nul))
  assert(held == nil and held_why == nul .. ": Invalid argument", held_why)
  assert(Fs.stat(tmp .. "/a") == nil, "a shorter name was bound")
  assert(not pcall(Net.listen, Net.unix("")))
  assert(not pcall(Net.connect, Net.unix("")))
  assert(not pcall(Net.listen, Net.unix(tmp .. "/b.sock"), { backlog = 0 }))
end
