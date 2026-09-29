--- The raw socket table's `Socket`: it owns its descriptor, and a unix
--- listener's socket file, from the moment the call makes them, so one
--- dropped before `cosmic.net` has wrapped it leaks neither.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local type _net = require("cosmic.net")
local type raw_socket = require("cosmic.internal.socket")

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `cosmic.net`'s loader.
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

--- The descriptor the next open is handed: the lowest free one, so one
--- left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

local function unix(path: string): raw_socket.Address
  return { kind = "unix", path = path }
end

--- A listener, a connection to it and the one it accepted, dropped
--- unclosed, are closed by the collector, and the listener's socket
--- file removed.
local function test_a_socket_dropped_unclosed_is_closed_by_the_collector(tmp: string)
  local path = tmp .. "/s.sock"
  local before = next_descriptor(tmp)
  do
    local listener = assert(raw.listen(unix(path), 1))
    local client = assert(raw.connect(unix(path), 5000))
    assert(raw.wait(listener:fd(), false, 5000))
    local accepted = assert(raw.accept(listener:fd()))
    assert(accepted:fd() > client:fd() and client:fd() > listener:fd())
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
  local path = tmp .. "/s.sock"
  local before = next_descriptor(tmp)
  do
    local _held <close> = assert(raw.listen(unix(path), 1))
  end
  assert(next_descriptor(tmp) == before, "a socket held <close> was left open")
  assert(Fs.stat(path) == nil, "a socket held <close> left its socket file")
  local listener = assert(raw.listen(unix(path), 1))
  assert(listener:close())
  assert(listener:close())
  local ok, why = pcall(listener.fd, listener)
  assert(not ok and tostring(why):find("the socket is closed", 1, true) ~= nil, tostring(why))
end
