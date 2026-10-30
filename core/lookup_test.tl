--- The raw `lookup` and its `Lookup` (core/socket.h): stepped by hand,
--- the way cosmic/internal/relay_resolv.tl runs one, against a hosts file and
--- against connects parked for a socket the test supplies.

local RawTables = require("build.raw_tables")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local socket = RawTables.socket()

local function require_linux()
  if assert(sys.uname()).sysname ~= "Linux" then
    Test.skip("a lookup through a connector is Linux only, as the connector is")
  end
end

local function test_a_hosts_entry_and_a_numeric_address_answer_without_a_socket(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, "192.0.2.1 a.example.test\n"))
  local lookup <close> = assert(socket.lookup("a.example.test", 1000, nil, hosts, nil))
  local done, fds, events, timer, wants = lookup:step(nil, nil)
  assert(done and #fds == 0 and #events == 0 and timer == -1 and #wants == 0)
  local found = assert(lookup:result())
  local entry = found[1]
  assert(#found == 1 and entry ~= nil and entry.address == "192.0.2.1" and entry.family == "ipv4")
  local literal <close> = assert(socket.lookup("2001:db8::1", 1000, nil, nil, nil))
  assert(literal:step(nil, nil))
  local literal_entry = assert(assert(literal:result())[1], "a numeric address answers")
  assert(literal_entry.address == "2001:db8::1")
end

local function test_a_lookup_not_done_has_no_answer_and_a_closed_one_raises(tmp: string)
  require_linux()
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local lookup = assert(socket.lookup("pending.example.test", 1000, nil, hosts,
    { { host = "127.0.0.1", port = 53, index = 1 } }))
  local done, _, _, _, wants = lookup:step(nil, nil)
  local want = wants[1]
  assert(not done and #wants == 1 and want ~= nil and want.index == 1 and want.port == 53)
  -- A connect is told once.
  local _, _, _, _, again = lookup:step(nil, nil)
  assert(#again == 0)
  local none, _, errno = lookup:result()
  assert(none == nil and errno == socket.ETIMEDOUT)
  assert(not pcall(lookup.step, lookup, {}, nil))
  assert(not pcall(lookup.step, lookup, {}, { 1 }))
  -- Supplying none fails that server, and the lookup, which asks no other.
  assert(lookup:supply(want.id, nil, 0))
  local ok, _, missing = lookup:supply(want.id, nil, 0)
  assert(not ok and missing == sys.ENOENT)
  assert(lookup:wait(50))
  lookup:close()
  lookup:close()
  assert(not pcall(lookup.step, lookup, nil, nil))
end

local function test_a_supplied_socket_replaces_the_stand_in(tmp: string)
  require_linux()
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = 5000000000 }))
  local port = assert(server.address.port, "the server listens on a port")
  local lookup <close> = assert(socket.lookup("supplied.example.test", 5000, nil, hosts,
    { { host = "127.0.0.1", port = port, index = 1 } }))
  local _, _, _, _, wants = lookup:step(nil, nil)
  local supplied = wants[1]
  assert(#wants == 1 and supplied ~= nil)
  local conn <close> = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
  assert(lookup:supply(supplied.id, conn:fd(), nil))
  -- The socket is c-ares's now: it watches it, and writes its query to it.
  local _, fds, events = lookup:step(nil, nil)
  assert(#fds == 1 and fds[1] ~= conn:fd() and #events == 1)
  assert(lookup:wait(1000))
  local accepted <close> = assert(server:accept())
  local sent = assert(accepted:read(2))
  assert(#sent == 2)
  lookup:close()
end
