--- The raw `lookup` and its `Lookup` (core/socket.h): stepped by hand,
--- the way cosmic/internal/relay_resolv.tl runs one, against a hosts file
--- and a name server that never answers.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local socket = require("cosmic.internal.socket")

local function test_a_hosts_entry_and_a_numeric_address_answer_without_a_socket(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, "192.0.2.1 a.example.test\n"))
  local lookup <close> = assert(socket.lookup("a.example.test", 1000, nil, hosts))
  local done, fds, events, timer = lookup:step(nil, nil)
  assert(done and #fds == 0 and #events == 0 and timer == -1)
  local found = assert(lookup:result())
  local entry = found[1]
  assert(#found == 1 and entry ~= nil and entry.address == "192.0.2.1" and entry.family == "ipv4")
  local literal <close> = assert(socket.lookup("2001:db8::1", 1000, nil, nil))
  assert(literal:step(nil, nil))
  local literal_entry = assert(assert(literal:result())[1], "a numeric address answers")
  assert(literal_entry.address == "2001:db8::1")
end

local function test_a_lookup_not_done_has_no_answer_and_a_closed_one_raises(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, ""))
  -- A socket nothing reads: the query is sent and never answered.
  local silent <close> = assert(socket.datagram({ kind = "udp", host = "127.0.0.1", port = 0 }))
  local port = assert(assert(socket.bound(silent:fd())).port)
  local lookup = assert(socket.lookup("pending.example.test", 1000, "127.0.0.1:" .. tostring(port), hosts))
  local done, fds, events = lookup:step(nil, nil)
  assert(not done and #fds == #events)
  local none, _, errno = lookup:result()
  assert(none == nil and errno == socket.ETIMEDOUT)
  assert(not pcall(lookup.step, lookup, {}, nil)) -- checked: overload_none
  assert(not pcall(lookup.step, lookup, {}, { 1 })) -- checked: overload_none
  assert(lookup:wait(50))
  lookup:close()
  lookup:close()
  assert(not pcall(lookup.step, lookup, nil, nil)) -- checked: overload_none
end
