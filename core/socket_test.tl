--- The raw socket table's `Socket`: it owns its descriptor, and a unix
--- listener's socket file, from the moment the call makes them, so one
--- dropped before [`cosmic.net`] has wrapped it leaks neither.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local sys = require("cosmic.sys")
local type _net = require("cosmic.net")
local type raw_socket = require("cosmic.internal.socket")

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands [`cosmic.net`]'s loader.
local function socket_table(): raw_socket
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.net")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_socket -- cast: the table core/socket.h declares
    end
  end
  error("cosmic.net is handed no raw table")
end

local raw = socket_table()

--- A TCP socket refused on the worker's own loopback.
Test.policy{ loopback = { "127.0.0.1" } }

--- The descriptor the next open is handed: the lowest free one, so one
--- left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

--- Each sample includes the same temporary directory descriptor used
--- to list it. Compare counts in this worker, never a host-wide baseline.
local function descriptor_count(): integer
  local path = assert(sys.uname()).sysname == "Darwin" and "/dev/fd" or "/proc/self/fd"
  local count = 0
  for name in pairs((assert(sys.readdir(path)))) do
    if name:match("^%d+$") ~= nil then count = count + 1 end
  end
  return count
end

local function unix(path: string): raw_socket.Address
  return { kind = "unix", path = path }
end

--- A listener on the loopback at a port the kernel chose, for a case that
--- is about the socket and not the socket file.
local function tcp_listener(): raw_socket.Socket
  return (assert(raw.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1)))
end

--- A listener, a connection to it and the one it accepted over the loopback,
--- dropped unclosed, are closed by the collector.
local function test_a_tcp_socket_dropped_unclosed_is_closed_by_the_collector(tmp: string)
  local before = next_descriptor(tmp)
  do
    local listener = tcp_listener()
    local bound = assert(raw.bound(listener:fd()))
    local client = assert(raw.connect({ kind = "tcp", host = "127.0.0.1", port = bound.port }, 5000))
    assert(raw.wait(listener:fd(), false, 5000))
    local accepted = assert(raw.accept(listener:fd()))
    assert(accepted:fd() ~= client:fd() and client:fd() ~= listener:fd())
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(next_descriptor(tmp) == before, "a dropped socket left descriptor " .. before .. " open")
end

--- A listener, a connection to it and the one it accepted, dropped
--- unclosed, are closed by the collector, and the listener's socket
--- file removed.
local function test_a_socket_dropped_unclosed_is_closed_by_the_collector(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local before = next_descriptor(tmp)
  do
    local listener = assert(raw.listen(unix(path), 1))
    local client = assert(raw.connect(unix(path), 5000))
    assert(raw.wait(listener:fd(), false, 5000))
    local accepted = assert(raw.accept(listener:fd()))
    assert(accepted:fd() ~= client:fd() and client:fd() ~= listener:fd())
  end
  assert(Fs.stat(path) ~= nil, "no socket file")
  collectgarbage("collect")
  collectgarbage("collect")
  assert(next_descriptor(tmp) == before, "a dropped socket left descriptor " .. before .. " open")
  assert(Fs.stat(path) == nil, "a dropped listener left its socket file")
end

--- A name another file has taken since the listener made its own is
--- not the listener's to remove, whether it is closed or collected.
local function test_a_file_that_took_the_name_is_left_alone(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  for _, collected in ipairs({ false, true }) do
    local moved = tmp .. "/moved-" .. tostring(collected) .. ".sock"
    do
      local listener = assert(raw.listen(unix(path), 1))
      assert(sys.rename(path, moved))
      assert(Fs.write(path, "someone else's"))
      if not collected then assert(listener:close()) end
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert(Fs.read(path) == "someone else's", "the file that took the name was removed")
    assert(Fs.stat(moved) ~= nil, "the moved socket file was removed")
    assert(sys.unlink(path))
  end
end

--- A relative path's socket file is removed from where it was made,
--- wherever the process has moved to since.
local function test_a_relative_socket_file_is_removed_after_a_chdir(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local was = assert(sys.getcwd())
  assert(sys.chdir(tmp))
  local listener, trouble = raw.listen(unix("rel.sock"), 1)
  assert(sys.chdir(was))
  assert(listener ~= nil, trouble)
  assert(Fs.stat(tmp .. "/rel.sock") ~= nil, "no socket file")
  assert(listener:close())
  assert(Fs.stat(tmp .. "/rel.sock") == nil, "the socket file was left")
end

--- A closed socket closes again, and has no descriptor to give; one
--- held `<close>` is closed as its block ends.
local function test_a_closed_socket_closes_again_and_has_no_descriptor(tmp: string)
  local before = next_descriptor(tmp)
  do
    local _held <close> = tcp_listener()
  end
  assert(next_descriptor(tmp) == before, "a socket held <close> was left open")
  local listener = tcp_listener()
  assert(listener:close())
  assert(listener:close())
  local ok, why = pcall(listener.fd, listener)
  assert(not ok and tostring(why):find("the socket is closed", 1, true) ~= nil, tostring(why))
end

--- A unix listener held `<close>` leaves no socket file as its block ends.
local function test_a_unix_socket_held_close_leaves_no_socket_file(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  do
    local _held <close> = assert(raw.listen(unix(path), 1))
    assert(Fs.stat(path) ~= nil, "no socket file")
  end
  assert(Fs.stat(path) == nil, "a socket held <close> left its socket file")
  local again = assert(raw.listen(unix(path), 1))
  assert(again:close())
  assert(Fs.stat(path) == nil, "a closed listener left its socket file")
end

--- An address whose `path` answers once and then nil -- read twice,
--- a second read would find none -- is read once: the listener binds
--- and removes the file of that one read.
local function test_an_address_is_read_once(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local reads = 0
  local fickle: metatable<raw_socket.Address> = {
    __index = function(_: raw_socket.Address, key: string): any
      if key == "kind" then return "unix" end
      if key ~= "path" then return nil end
      reads = reads + 1
      return reads == 1 and path or nil
    end,
  }
  local listener = assert(raw.listen(setmetatable({} as raw_socket.Address, fickle), 1))
  assert(reads == 1, "the path was read " .. reads .. " times")
  assert(Fs.stat(path) ~= nil, "no socket file")
  assert(listener:close())
  assert(Fs.stat(path) == nil, "the socket file was left")
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

--- A listener at a path past PATH_MAX -- a name bound from a working
--- directory that deep -- removes its socket file when closed and when
--- collected, wherever the process has moved to since.
local function test_a_socket_file_past_path_max_is_removed(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local was = assert(sys.getcwd())
  local ok, failure: boolean, any = pcall(function()
    for _, collected in ipairs({ false, true }) do
      enter_deep(tmp)
      local listener, trouble = raw.listen(unix("s.sock"), 1)
      assert(sys.chdir(was))
      assert(listener ~= nil, trouble)
      if collected then
        listener = nil
        collectgarbage("collect")
        collectgarbage("collect")
      else
        assert(listener:close())
      end
      enter_deep(tmp)
      local left = sys.lstat("s.sock")
      assert(sys.chdir(was))
      assert(left == nil, "the socket file was left, collected: " .. tostring(collected))
    end
  end)
  local removed, trouble: boolean, any = pcall(remove_deep, tmp)
  assert(sys.chdir(was))
  assert(ok, tostring(failure))
  assert(removed, tostring(trouble))
end

--- A send starts at the first byte, or at the byte it is given: one
--- past the last sends nothing, and one outside the string raises.
local function test_a_send_from_a_byte_sends_the_rest()
  local listener <close> = tcp_listener()
  local bound = assert(raw.bound(listener:fd()))
  local client <close> = assert(raw.connect({ kind = "tcp", host = "127.0.0.1", port = bound.port }, 5000))
  assert(raw.wait(listener:fd(), false, 5000))
  local accepted <close> = assert(raw.accept(listener:fd()))
  assert(assert(raw.send(client:fd(), "ab")) == 2)
  assert(assert(raw.send(client:fd(), "abcdef", 4)) == 3)
  assert(assert(raw.send(client:fd(), "abcdef", 7)) == 0)
  local got = ""
  -- The sends may arrive as more than one segment, and the socket does not
  -- block: wait before each read, not just the first.
  while #got < 5 do
    assert(raw.wait(accepted:fd(), false, 5000))
    local chunk = assert(sys.read(accepted:fd(), 16))
    assert(#chunk > 0, "the connection ended early")
    got = got .. chunk
  end
  assert(got == "abdef", got)
  for _, from in ipairs({ 0, 8, math.mininteger, math.maxinteger }) do
    local ok, err = pcall(raw.send, client:fd(), "abcdef", from)
    assert(not ok and tostring(err):find("out of range", 1, true) ~= nil, tostring(err))
  end
end

--- A unix listener whose backlog is full refuses a further connection
--- at once, however long it may wait, whether started or connected:
--- EAGAIN on Linux, kept apart from ECONNREFUSED, which a listener gone
--- answers; macOS cannot tell the two apart, and answers ECONNREFUSED.
local function test_a_full_unix_backlog_refuses_a_connection_at_once(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/s.sock"
  local _listener <close> = assert(raw.listen(unix(path), 1))
  local held: {raw_socket.Socket} = {}
  for _ = 1, 16 do
    local client = raw.connect(unix(path), 0)
    if client == nil then break end
    held[#held + 1] = client
  end
  local want = assert(sys.uname()).sysname == "Darwin" and raw.ECONNREFUSED or raw.EAGAIN
  local began = Clock.monotonic_ns()
  local client, why, errno = raw.connect(unix(path), 20000)
  assert(Clock.monotonic_ns() - began < Clock.seconds(10), "the connection waited for room")
  assert(client == nil and errno == want, why)
  local started, start_why, start_errno = raw.start(unix(path))
  assert(started == nil and start_errno == want, start_why)
  for _, conn in ipairs(held) do assert(conn:close()) end
end

--- Rights travel over a channel reserved for batches, independent of the
--- listening socket the relay receives.
local function rights_pair(path: string): raw_socket.Socket, raw_socket.Socket
  local listener <close> = assert(raw.listen(unix(path), 1))
  local sender = assert(raw.connect(unix(path), 5000))
  assert(raw.wait(listener:fd(), false, 5000))
  return sender, (assert(raw.accept(listener:fd())))
end

local function test_descriptor_passing_preserves_files_and_listener_ownership(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local raw_sender, raw_receiver = rights_pair(tmp .. "/rights.sock")
  local sender <close> = raw_sender
  local receiver <close> = raw_receiver
  local original <close> = tcp_listener()
  assert(Fs.write(tmp .. "/passed", "passed file"))
  local file = assert(sys.open(tmp .. "/passed", sys.O_RDONLY))
  assert(raw.sendfds(sender:fd(), { original:fd(), file }))
  assert(raw.wait(receiver:fd(), false, 5000))
  local passed = assert(raw.recvfds(receiver:fd(), 2))
  local listening <close> = passed[1]
  local reading <close> = passed[2]
  assert(listening:fd() ~= original:fd() and reading:fd() ~= file)
  assert(assert(sys.fd_flags(reading:fd())) & sys.FD_CLOEXEC ~= 0)
  assert(assert(sys.fd_flags(listening:fd())) & sys.FD_CLOEXEC ~= 0)
  assert(sys.close(file))
  assert(original:close())
  assert(sys.read(reading:fd(), 32) == "passed file")
  local bound = assert(raw.bound(listening:fd()))
  local client <close> = assert(raw.connect(bound, 5000))
  assert(raw.wait(listening:fd(), false, 5000))
  local accepted <close> = assert(raw.accept(listening:fd()))
  assert(raw.send(client:fd(), "listener") == 8)
  assert(raw.wait(accepted:fd(), false, 5000))
  assert(sys.read(accepted:fd(), 16) == "listener")
end

local function test_descriptor_passing_closes_extras_truncation_and_bad_frames(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local original <close> = tcp_listener()
  local raw_sender, raw_receiver = rights_pair(tmp .. "/rights.sock")
  local sender <close> = raw_sender
  local receiver <close> = raw_receiver
  collectgarbage("collect")
  local before = descriptor_count()
  for _, count in ipairs({ 2, 16 }) do
    local descriptors: {integer} = {}
    for _ = 1, count do descriptors[#descriptors + 1] = original:fd() end
    assert(raw.sendfds(sender:fd(), descriptors))
    assert(raw.wait(receiver:fd(), false, 5000))
    local got, why, errno = raw.recvfds(receiver:fd(), 1)
    assert(got == nil and why ~= "" and errno == raw.EPROTO)
    assert(descriptor_count() == before, "a refused batch leaked a descriptor")
  end
  for _, bad in ipairs({ "x", "\0" }) do
    assert(raw.send(sender:fd(), bad) == 1)
    assert(raw.wait(receiver:fd(), false, 5000))
    local got, _, errno = raw.recvfds(receiver:fd(), 1)
    assert(got == nil and errno == raw.EPROTO)
    assert(descriptor_count() == before, "a bad frame leaked a descriptor")
  end
  assert(raw.sendfds(sender:fd(), { original:fd() }))
  assert(raw.wait(receiver:fd(), false, 5000))
  local passed = assert(raw.recvfds(receiver:fd(), 1))
  assert(passed[1]:close())
  assert(descriptor_count() == before)
end

local function test_descriptor_passing_runtime_failures_and_argument_checks(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local raw_sender, raw_receiver = rights_pair(tmp .. "/rights.sock")
  local sender <close> = raw_sender
  local receiver <close> = raw_receiver
  local original <close> = tcp_listener()
  local got, _, errno = raw.recvfds(receiver:fd(), 1)
  assert(got == nil and errno == raw.EAGAIN)
  local sent, _, send_errno = raw.sendfds(sender:fd(), { -1 })
  assert(sent == false and send_errno == sys.EBADF)
  local file = assert(sys.open(tmp .. "/closed", sys.O_CREAT | sys.O_RDWR, 420))
  assert(sys.close(file))
  local closed, _, closed_errno = raw.sendfds(sender:fd(), { file })
  assert(closed == false and closed_errno == sys.EBADF)
  local wrong, _, wrong_errno = raw.sendfds(original:fd(), { sender:fd() })
  assert(wrong == false and wrong_errno == sys.EAFNOSUPPORT)
  local wrong_read, _, wrong_read_errno = raw.recvfds(original:fd(), 1)
  assert(wrong_read == nil and wrong_read_errno == sys.EAFNOSUPPORT)
  for _, count in ipairs({ 0, 17, math.maxinteger }) do
    local ok, why = pcall(raw.recvfds, receiver:fd(), count)
    assert(not ok and tostring(why) ~= "")
  end
  local no_descriptors: {integer} = {}
  assert(not pcall(raw.sendfds, sender:fd(), no_descriptors))
  assert(not pcall(raw.sendfds, sender:fd(), { math.maxinteger }))
  assert(receiver:close())
  local ended, _, ended_errno = raw.sendfds(sender:fd(), { original:fd() })
  assert(ended == false and ended_errno == sys.EPIPE)
end

local function test_received_descriptor_is_closed_by_collection(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local raw_sender, raw_receiver = rights_pair(tmp .. "/rights.sock")
  local sender <close> = raw_sender
  local receiver <close> = raw_receiver
  local original <close> = tcp_listener()
  local before = next_descriptor(tmp)
  assert(raw.sendfds(sender:fd(), { original:fd() }))
  do
    local passed = assert(raw.recvfds(receiver:fd(), 1))
    assert(passed[1]:fd() ~= original:fd())
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(next_descriptor(tmp) == before, "a collected receiver leaked a descriptor")
  assert(raw.bound(original:fd()) ~= nil, "collection closed the sender's original")
end

local function test_udp_raw_calls_keep_packet_boundaries_and_refuse_stream_descriptors()
  local sender <close> = assert(raw.datagram({ kind = "udp", host = "127.0.0.1", port = 0 }))
  local receiver <close> = assert(raw.datagram({ kind = "udp", host = "127.0.0.1", port = 0 }))
  local destination = assert(raw.bound(receiver:fd()))
  local empty, _, nothing = raw.recvfrom(receiver:fd(), 16)
  assert(empty == nil and nothing == raw.EAGAIN)
  assert(raw.sendto(sender:fd(), "raw", destination))
  assert(raw.wait(receiver:fd(), false, 5000))
  local packet = assert(raw.recvfrom(receiver:fd(), 16))
  assert(packet.data == "raw" and packet.address.port == assert(raw.bound(sender:fd())).port)
  local listener <close> = tcp_listener()
  local sent, send_why = raw.sendto(listener:fd(), "x", destination)
  assert(not sent and send_why == "Protocol wrong type for socket", send_why)
  local received, receive_why = raw.recvfrom(listener:fd(), 16)
  assert(received == nil and receive_why == "Protocol wrong type for socket", receive_why)
end

local function test_udp_dropped_unclosed_is_closed_by_the_collector(tmp: string)
  local before = next_descriptor(tmp)
  do
    local bound = assert(raw.datagram({ kind = "udp", host = "127.0.0.1", port = 0 }))
    assert(bound:fd() >= before)
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(next_descriptor(tmp) == before, "a dropped UDP socket left a descriptor open")
end
