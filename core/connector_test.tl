--- The connector's actual kernel filter and repeated TCP handoffs.
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local Relay = require("cosmic.relay")
local sys = require("cosmic.sys")
local DENIED <const> = 65536 -- a refusal by the lists, past any errno
Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" } }
local type Searcher = function(string): any, any
local function table_for(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a loader's extra is the raw table
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("no raw table")
end
local process = table_for("cosmic.child") as raw_process -- cast: core/process.h's table
local socket = table_for("cosmic.net") as raw_socket -- cast: core/socket.h's table
local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end
local function read_whole(fd: integer, count: integer): string
  local out = ""
  while #out < count do
    local bytes = assert(sys.read(fd, count - #out))
    assert(bytes ~= "", "connector ended before replying")
    out = out .. bytes
  end
  return out
end

--- Reads the connector's hello from `fd`, as every client does first.
local function greeted(fd: integer)
  assert(string.unpack(">I4", read_whole(fd, 4)) == socket.CONNECTOR_HELLO, "the connector said no hello")
end

--- A table request of `tag` for endpoint `index` at `port`, with the
--- connector's own wait.
local function table_request(tag: integer, index: integer, port: integer): string
  return string.pack(">I4I4I4I4I4", tag, index, port, 0, 0) .. string.rep("\0", 16)
end

--- Asks `fd` with `request` and answers the reply's errno, checking it
--- carries the request's tag.
local function asked(fd: integer, request: string): integer
  assert(sys.write(fd, request) == #request)
  local tag, errno = string.unpack(">I4I4", read_whole(fd, 8))
  assert(tag == string.unpack(">I4", request), "the reply carries another tag: " .. tag)
  return errno
end
local function test_live_filter_refuses_mutation_other_destinations_and_ipc_replacement()
  require_native_connector()
  local endpoint: raw_process.ConnectorEndpoint = { host = "127.0.0.1", port = 9 }
  for _, operation in ipairs({ "pointer", "length", "mprotect", "remap", "dup", "recvmsg",
      "sendto", "sendmsg", "udp", "open", "exec", "fork" }) do
    local result, why = process.connector_probe(endpoint, operation)
    assert(result == 1, operation .. ": " .. tostring(result) .. " " .. (why or ""))
  end
  assert(process.connector_probe(endpoint, "mutation") == -11, "a read-only address table must fault")
  assert(process.connector_probe(endpoint, "close_control") == -31, "closing protected IPC must kill the broker")
end
local function test_repeated_connections_use_only_the_granted_address_and_port()
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local bound = assert(socket.bound(listener:fd()))
  local pair = assert(process.connector_pair())
  local child, why = process.connector_start({ { host = "127.0.0.1", port = bound.port } }, pair[2], 500, nil)
  assert(sys.close(pair[2]))
  assert(child, why)
  local ok, failure = pcall(function()
    greeted(pair[1])
    for tag, request in ipairs({ { 0, bound.port }, { 2, bound.port }, { 1, 0 }, { 1, 65536 },
        { 1, bound.port == 65535 and 1 or bound.port + 1 } }) do
      assert(asked(pair[1], table_request(tag, request[1], request[2])) == sys.EPERM)
    end
    -- A table request that carries a family or an address is malformed.
    assert(asked(pair[1], string.pack(">I4I4I4I4I4", 9, 1, bound.port, 0, 4) .. string.rep("\0", 16)) == sys.EINVAL)
    assert(asked(pair[1], table_request(10, 1, bound.port):sub(1, 35) .. "\1") == sys.EINVAL)
    for tag = 1, 3 do
      assert(asked(pair[1], table_request(tag, 1, bound.port)) == 0)
      -- Reading the marker rather than recvmsg makes the kernel discard
      -- its passed descriptor; the accepted connection still proves the
      -- broker reached the origin. Descriptor ownership is fdpass's test.
      assert(read_whole(pair[1], 1) == "\0")
      assert(socket.wait(listener:fd(), false, 500))
      local accepted <close> = assert(socket.accept(listener:fd()))
      local seen = assert(socket.bound(accepted:fd()))
      assert(seen.port == bound.port)
    end
  end)
  assert(sys.close(pair[1]))
  local ended = assert(process.waitpid(child, false))
  assert(ended.code == 0)
  assert(ok, failure)
end
local function test_wildcard_ports_remain_fixed_to_the_granted_numeric_address()
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local bound = assert(socket.bound(listener:fd()))
  local pair = assert(process.connector_pair())
  local child = assert(process.connector_start({ { host = "127.0.0.1", port = 0 } }, pair[2], 500, nil))
  assert(sys.close(pair[2]))
  greeted(pair[1])
  assert(asked(pair[1], table_request(1, 1, bound.port)) == 0)
  assert(read_whole(pair[1], 1) == "\0")
  assert(socket.wait(listener:fd(), false, 500))
  local accepted <close> = assert(socket.accept(listener:fd()))
  assert(accepted:fd() >= 0)
  assert(sys.close(pair[1]))
  local ended = assert(process.waitpid(child, false))
  assert(ended.code == 0)
end
local function test_invalid_numeric_endpoints_cannot_start_a_connector()
  local pair = assert(process.connector_pair())
  for _, endpoint in ipairs({ { host = "localhost", port = 80 }, { host = "127.1", port = 80 },
      { host = "0177.0.0.1", port = 80 }, { host = "127.0.0.1\0evil", port = 80 },
      { host = "fe80::1%lo", port = 80 }, { host = "*", port = 80 }, { host = "127.0.0.1", port = -1 } }) do
    local ok = pcall(process.connector_start, { endpoint }, pair[2], 500, nil)
    assert(not ok)
  end
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
end

--- The reply to a public request for `address` at `port`: the errno, and
--- (for a connection made) nothing past it, which the caller reads.
local function public_ask(fd: integer, address: string, port: integer, family?: integer, tail?: string): integer
  local bytes = assert(Relay.Address.parse(address))
  local padded = tail or string.rep("\0", 16 - #bytes)
  return asked(fd, string.pack(">I4I4I4I4I4", 77, 0xffffffff, port, 0, family or (#bytes == 4 and 4 or 6)) ..
      string.char(table.unpack(bytes)) .. padded)
end

--- Starts a connector with a public mode over `public` and an empty table.
local function start_public(public: raw_process.ConnectorPublic, timeout: integer): {integer}, integer
  local pair = assert(process.connector_pair())
  local child, why = process.connector_start({}, pair[2], timeout, public)
  assert(sys.close(pair[2]))
  assert(child, why)
  greeted(pair[1])
  return pair, child
end

local function finish(pair: {integer}, child: integer)
  assert(sys.close(pair[1]))
  local ended = assert(process.waitpid(child, false))
  assert(ended.code == 0, "the connector ended abnormally")
end

local function test_the_scratch_page_is_held_by_the_filter()
  require_native_connector()
  local endpoint: raw_process.ConnectorEndpoint = { host = "127.0.0.1", port = 9 }
  -- Each is refused by the filter (EPERM): the page cannot be reprotected
  -- or remapped, a copy or another offset or length of a slot is no slot,
  -- and a slot is not another family's.
  for _, operation in ipairs({ "scratch_mprotect", "scratch_remap", "scratch_pointer", "scratch_length",
      "scratch_offset", "scratch_past", "scratch_swapped" }) do
    local result, why = process.connector_probe(endpoint, operation)
    assert(result == sys.EPERM, operation .. ": " .. tostring(result) .. " " .. tostring(why))
  end
end

local function test_a_public_connector_connects_to_an_address_its_table_lacks()
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local bound = assert(socket.bound(listener:fd()))
  -- No test reaches a public host: the deny list is empty, so loopback is allowed.
  local pair, child = start_public({ deny = {} }, 500)
  for _ = 1, 3 do
    assert(public_ask(pair[1], "127.0.0.1", bound.port) == 0)
    assert(read_whole(pair[1], 1) == "\0")
    assert(socket.wait(listener:fd(), false, 500))
    local accepted <close> = assert(socket.accept(listener:fd()))
    local seen = assert(socket.bound(accepted:fd()))
    assert(seen.port == bound.port)
  end
  finish(pair, child)
end

local function test_a_public_connector_refuses_what_its_lists_hold_without_connecting()
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local bound = assert(socket.bound(listener:fd()))
  local lists: {raw_process.ConnectorPublic} = { { deny = { "127.0.0.0/8" } }, { deny = {}, own = { "127.0.0.1" } },
    { deny = {}, own = { "::ffff:127.0.0.1" } }, { deny = { "127.0.0.1/32" } }, { deny = { "126.0.0.0/7" } } }
  for _, public in ipairs(lists) do
    local pair, child = start_public(public, 500)
    assert(public_ask(pair[1], "127.0.0.1", bound.port) == DENIED)
    assert(not socket.wait(listener:fd(), false, 20), "a refused address was connected to")
    -- A neighbour of an address is refused only by a prefix that holds it,
    -- and the stream is in step.
    local wide = public.deny[1] == "126.0.0.0/7" or public.deny[1] == "127.0.0.0/8"
    assert(public_ask(pair[1], "127.0.0.2", 0) == (wide and DENIED or 0))
    finish(pair, child)
  end
end

local function test_public_requests_are_checked_for_their_form()
  require_native_connector()
  local pair, child = start_public({ deny = Relay.Address.deny_cidrs() }, 500)
  -- Port 0 asks only for the decision: no socket, no descriptor.
  assert(public_ask(pair[1], "8.8.8.8", 0) == 0)
  assert(public_ask(pair[1], "2606:4700::1111", 0) == 0)
  for _, address in ipairs({ "10.0.0.1", "169.254.169.254", "::1", "fe80::1", "fd00:ec2::254", "2001:db8::1",
      "2002::1", "2001::1", "4000::1", "1fff::1", "::ffff:8.8.8.8", "::ffff:10.0.0.1",
      "64:ff9b::808:808", "64:ff9b::a00:1", "64:ff9b:1::808:808", "::8.8.8.8" }) do
    assert(public_ask(pair[1], address, 0) == DENIED, address)
  end
  assert(public_ask(pair[1], "8.8.8.8", 0, 5) == sys.EINVAL)
  -- The same four bytes as an IPv6 address are 808:808::, outside 2000::/3.
  assert(public_ask(pair[1], "8.8.8.8", 0, 6) == DENIED)
  assert(public_ask(pair[1], "8.8.8.8", 0, 4, "\0\0\0\0\0\0\0\0\0\0\0\1") == sys.EINVAL)
  assert(public_ask(pair[1], "8.8.8.8", 65536) == sys.EINVAL)
  assert(public_ask(pair[1], "8.8.8.8", 0) == 0)
  finish(pair, child)
end

local function test_a_connector_that_is_not_public_refuses_a_public_request_and_stays_in_step()
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local bound = assert(socket.bound(listener:fd()))
  local pair = assert(process.connector_pair())
  local child = assert(process.connector_start({ { host = "127.0.0.1", port = bound.port } }, pair[2], 500, nil))
  assert(sys.close(pair[2]))
  greeted(pair[1])
  assert(public_ask(pair[1], "127.0.0.1", bound.port) == sys.EPERM)
  assert(public_ask(pair[1], "8.8.8.8", 0) == sys.EPERM)
  assert(asked(pair[1], table_request(1, 1, bound.port)) == 0)
  assert(read_whole(pair[1], 1) == "\0")
  assert(socket.wait(listener:fd(), false, 500))
  finish(pair, child)
end

local function test_public_lists_that_are_no_prefixes_cannot_start_a_connector()
  local pair = assert(process.connector_pair())
  local many: {string} = {}
  for i = 1, 129 do many[i] = "10.0." .. (i - 1) .. ".0/24" end
  local owns: {string} = {}
  for i = 1, 257 do owns[i] = "10.1." .. (i // 256) .. "." .. (i % 256) end
  local lists: {raw_process.ConnectorPublic} = { { deny = { "10.0.0.0" } }, { deny = { "10.0.0.0/33" } }, { deny = { "::/129" } },
    { deny = { "10.0.0.0/" } }, { deny = { "10.0.0.0/8x" } }, { deny = { "10.0.0.0/0008" } },
    { deny = { "localhost/8" } }, { deny = { "010.0.0.0/8" } }, { deny = { "10.0.0.0/8\0" } },
    { deny = { "fe80::1%lo/10" } }, { deny = many }, { deny = {}, own = { "10.0.0.0/8" } },
    { deny = {}, own = { "localhost" } }, { deny = {}, own = owns } }
  for _, public in ipairs(lists) do
    local ok = pcall(process.connector_start, {}, pair[2], 500, public)
    assert(not ok)
  end
  -- A table that is empty is for a public connector alone.
  assert(not pcall(process.connector_start, {}, pair[2], 500, nil))
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
end

local function test_index_zero_is_refused_by_every_connector()
  require_native_connector()
  for _, public in ipairs({ false, true }) do
    local pair = assert(process.connector_pair())
    local child = assert(process.connector_start(public and {} or { { host = "127.0.0.1", port = 9 } },
      pair[2], 500, public and { deny = {} } or nil))
    assert(sys.close(pair[2]))
    greeted(pair[1])
    for tag = 1, 2 do
      assert(asked(pair[1], table_request(tag, 0, 80)) == sys.EPERM)
    end
    finish(pair, child)
  end
end

local function test_a_table_only_connector_has_no_scratch_slot_to_connect_through()
  require_native_connector()
  local result, why = process.connector_probe({ host = "127.0.0.1", port = 9 }, "unscratched")
  assert(result == sys.EPERM, tostring(result) .. " " .. tostring(why))
end

--- A listener whose queue is full, so that a connect to it hangs: its
--- port, and what holds it full. Skips where this kernel answers anyway.
local function hung_port(): integer, {raw_socket.Socket}
  local listener = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local port = assert(socket.bound(listener:fd())).port
  local held: {raw_socket.Socket} = { listener }
  for _ = 1, 6 do
    held[#held + 1] = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
  end
  local probe = assert(socket.start({ kind = "tcp", host = "127.0.0.1", port = port }))
  held[#held + 1] = probe
  if socket.wait(probe:fd(), true, 200) then
    Test.skip("this kernel completes a connect to a listener whose queue is full")
  end
  return port, held
end

--- A table request of `tag` for endpoint `index` at `port`, waiting `wait`
--- milliseconds at most.
local function waiting_request(tag: integer, index: integer, port: integer, wait: integer): string
  return string.pack(">I4I4I4I4I4", tag, index, port, wait, 0) .. string.rep("\0", 16)
end

--- The next reply on `fd`: its tag and errno, and, after a success, the
--- marker read (its descriptor discarded by the kernel).
local function reply(fd: integer): integer, integer
  local tag, errno = string.unpack(">I4I4", read_whole(fd, 8))
  if errno == 0 then assert(read_whole(fd, 1) == "\0") end
  return tag, errno
end

--- One connector makes several connects at once: one whose target hangs
--- holds up none asked after it, whose replies come first, each with its
--- own tag, and it ends at its own request's wait, not the connector's.
local function test_a_hung_connect_holds_up_no_other_and_replies_come_as_connects_end()
  require_native_connector()
  local hung, held = hung_port()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local open = assert(socket.bound(listener:fd())).port
  local pair = assert(process.connector_pair())
  local child = assert(process.connector_start({ { host = "127.0.0.1", port = 0 } }, pair[2], 10000, nil))
  assert(sys.close(pair[2]))
  greeted(pair[1])
  local began = Clock.monotonic_ns()
  assert(sys.write(pair[1], waiting_request(1, 1, hung, 400)) == 36)
  for tag = 2, 4 do assert(sys.write(pair[1], waiting_request(tag, 1, open, 0)) == 36) end
  local order: {integer} = {}
  for _ = 2, 4 do
    local tag, errno = reply(pair[1])
    assert(errno == 0, "tag " .. tag .. ": errno " .. errno)
    order[#order + 1] = tag
  end
  assert(Clock.monotonic_ns() - began < Clock.ms(300), "the others waited for the hung connect")
  table.sort(order)
  assert(table.concat(order, ",") == "2,3,4", table.concat(order, ","))
  local tag, errno = reply(pair[1])
  local took = Clock.monotonic_ns() - began
  assert(tag == 1 and errno == socket.ETIMEDOUT, tag .. " " .. errno)
  -- The connector counts whole milliseconds, so it may end a little short.
  assert(took >= Clock.ms(390) and took < Clock.seconds(5), "the hung connect ended after " .. took // Clock.ms(1) .. " ms")
  finish(pair, child)
  for _, each in ipairs(held) do assert(each:close()) end
end

--- A request that comes in pieces is served once whole, while another
--- connect is in flight: the connector reads what the stream has, never
--- waiting on it with a connect pending.
local function test_a_request_in_pieces_holds_up_no_connect()
  require_native_connector()
  local hung, held = hung_port()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local open = assert(socket.bound(listener:fd())).port
  local pair = assert(process.connector_pair())
  local child = assert(process.connector_start({ { host = "127.0.0.1", port = 0 } }, pair[2], 10000, nil))
  assert(sys.close(pair[2]))
  greeted(pair[1])
  assert(sys.write(pair[1], waiting_request(1, 1, hung, 300)) == 36)
  -- Half a request, and the hung connect still ends at its wait.
  local second = waiting_request(2, 1, open, 0)
  assert(sys.write(pair[1], second:sub(1, 13)) == 13)
  local tag, errno = reply(pair[1])
  assert(tag == 1 and errno == socket.ETIMEDOUT, tag .. " " .. errno)
  assert(sys.write(pair[1], second:sub(14)) == 23)
  tag, errno = reply(pair[1])
  assert(tag == 2 and errno == 0, tag .. " " .. errno)
  finish(pair, child)
  for _, each in ipairs(held) do assert(each:close()) end
end

--- A connector makes at most CONNECTOR_FLIGHT connects at once: a request
--- for another is answered CONNECTOR_BUSY at once, a decision alone is
--- still answered, and the stream stays in step, so once a connect ends
--- there is room again.
local function test_a_connect_past_the_flight_is_answered_busy()
  require_native_connector()
  local hung, held = hung_port()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 8))
  local open = assert(socket.bound(listener:fd())).port
  local pair, child = start_public({ deny = {} }, 10000)
  local flight = socket.CONNECTOR_FLIGHT
  assert(flight == 64)
  local requests: {string} = {}
  for tag = 1, flight do
    requests[tag] = string.pack(">I4I4I4I4I4", tag, 0xffffffff, hung, 1000, 4) .. string.char(127, 0, 0, 1) ..
      string.rep("\0", 12)
  end
  assert(sys.write(pair[1], table.concat(requests)) == 36 * flight)
  local began = Clock.monotonic_ns()
  local past = string.pack(">I4I4I4I4I4", 1000, 0xffffffff, open, 0, 4) .. string.char(127, 0, 0, 1) ..
    string.rep("\0", 12)
  assert(asked(pair[1], past) == socket.CONNECTOR_BUSY)
  assert(public_ask(pair[1], "127.0.0.1", 0) == 0)
  assert(Clock.monotonic_ns() - began < Clock.ms(500), "the refusal waited")
  for _ = 1, flight do
    local tag, errno = reply(pair[1])
    assert(tag >= 1 and tag <= flight and errno == socket.ETIMEDOUT, tag .. " " .. errno)
  end
  assert(asked(pair[1], past) == 0)
  assert(read_whole(pair[1], 1) == "\0")
  finish(pair, child)
  for _, each in ipairs(held) do assert(each:close()) end
end
