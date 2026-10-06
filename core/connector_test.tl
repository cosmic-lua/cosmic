--- The connector's actual kernel filter and repeated TCP handoffs.
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
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
  local child, why = process.connector_start({ { host = "127.0.0.1", port = bound.port } }, pair[2], 500)
  assert(sys.close(pair[2]))
  assert(child, why)
  local ok, failure = pcall(function()
    for _, request in ipairs({ { 0, bound.port }, { 2, bound.port }, { 1, 0 }, { 1, 65536 },
        { 1, bound.port == 65535 and 1 or bound.port + 1 } }) do
      assert(sys.write(pair[1], string.pack(">I4I4", request[1], request[2])) == 8)
      assert(string.unpack(">I4", read_whole(pair[1], 4)) == 1)
    end
    for _ = 1, 3 do
      assert(sys.write(pair[1], string.pack(">I4I4", 1, bound.port)) == 8)
      assert(string.unpack(">I4", read_whole(pair[1], 4)) == 0)
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
  local child = assert(process.connector_start({ { host = "127.0.0.1", port = 0 } }, pair[2], 500))
  assert(sys.close(pair[2]))
  assert(sys.write(pair[1], string.pack(">I4I4", 1, bound.port)) == 8)
  assert(string.unpack(">I4", read_whole(pair[1], 4)) == 0)
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
    local ok = pcall(process.connector_start, { endpoint }, pair[2], 500)
    assert(not ok)
  end
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
end
