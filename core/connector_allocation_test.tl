--- Startup failure paths must leave no descriptors, child or mappings.
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" }, requires = { "checked" } }
local type Searcher = function(string): any, any
local function table_for(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: the loader's extra is its raw table
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("no raw table")
end
local process = table_for("cosmic.child") as raw_process -- cast: core/process.h declares this table
local socket = table_for("cosmic.net") as raw_socket -- cast: core/socket.h declares this table
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  assert(sys.close(fd))
  return fd
end
local function test_pair_allocation_refusals_leave_no_descriptors(tmp: string)
  local before = next_descriptor(tmp)
  local refused_count = 0
  local pair: {integer}
  local function work(): any
    pair = assert(process.connector_pair())
    return true
  end
  for after = 0, 1000 do
    pair = nil
    testing.fail_allocations(after)
    local ok, failure = pcall(work)
    local refused = testing.allow_allocations()
    if pair ~= nil then
      assert(sys.close(pair[1]))
      assert(sys.close(pair[2]))
    end
    collectgarbage("collect")
    assert(next_descriptor(tmp) == before, "pair allocation refusal leaked a descriptor")
    if refused == 0 then
      assert(ok, tostring(failure))
      assert(refused_count > 0)
      return
    end
    refused_count = refused_count + 1
  end
  error("pair allocation walk did not finish")
end
local function test_startup_faults_close_the_status_pipe_and_release_the_address_table(tmp: string)
  local result, probe_why, probe_number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (probe_number == sys.ENOSYS or probe_number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. probe_why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (probe_why or ""))
  local pair = assert(process.connector_pair())
  local before = next_descriptor(tmp)
  for _, point in ipairs({ "connector_mmap", "connector_mprotect", "connector_pipe", "connector_fork",
      "connector_close_range", "connector_filter" }) do
    testing.fail_at(point)
    local pid, why, number = process.connector_start({ { host = "127.0.0.1", port = 9 } }, pair[2], 100, nil)
    assert(not testing.fail_at(), point .. " did not fire")
    assert(pid == nil and why ~= "" and number ~= 0, point .. " did not return a value failure")
    collectgarbage("collect")
    assert(next_descriptor(tmp) == before, point .. " leaked a descriptor")
  end
  -- A public connector also maps its scratch page, with an empty table or
  -- one: each start that fails after it is mapped releases both pages.
  for _, table_ in ipairs({ {}, { { host = "127.0.0.1", port = 9 } } } as {{raw_process.ConnectorEndpoint}}) do
    for _, point in ipairs({ "connector_scratch", "connector_pipe", "connector_fork",
        "connector_close_range", "connector_filter" }) do
      testing.fail_at(point)
      local pid, why, number = process.connector_start(table_, pair[2], 100, { deny = { "10.0.0.0/8" } })
      assert(not testing.fail_at(), point .. " did not fire for a public connector")
      assert(pid == nil and why ~= "" and number ~= 0, point .. " did not return a value failure")
      collectgarbage("collect")
      assert(next_descriptor(tmp) == before, point .. " leaked a descriptor of a public connector")
    end
  end
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
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
--- A table the kernel maps across a 4 GiB boundary, which the filter's
--- 32-bit comparisons cannot hold, is placed past the boundary: the start
--- succeeds, and a port of the wildcard endpoint is reached through it.
local function test_a_table_mapped_across_a_4_gib_boundary_is_placed_past_it()
  local result, probe_why, probe_number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (probe_number == sys.ENOSYS or probe_number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. probe_why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (probe_why or ""))
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local bound = assert(socket.bound(listener:fd()))
  local pair = assert(process.connector_pair())
  testing.fail_at("connector_straddle")
  local child, why = process.connector_start({ { host = "127.0.0.1", port = 0 } }, pair[2], 500, nil)
  assert(not testing.fail_at(), "connector_straddle did not fire")
  assert(sys.close(pair[2]))
  assert(child ~= nil, "a table mapped across a 4 GiB boundary: " .. tostring(why))
  assert(string.unpack(">I4", read_whole(pair[1], 4)) == 0x434e4302, "the connector said no hello")
  assert(sys.write(pair[1], string.pack(">I4I4I4I4I4", 1, 1, bound.port, 0, 0) .. string.rep("\0", 16)) == 36)
  assert(string.pack(">I4I4", 1, 0) == read_whole(pair[1], 8))
  assert(read_whole(pair[1], 1) == "\0")
  assert(socket.wait(listener:fd(), false, 500))
  local accepted <close> = assert(socket.accept(listener:fd()))
  assert(accepted:fd() >= 0)
  assert(sys.close(pair[1]))
  local ended = assert(process.waitpid(child, false))
  assert(ended.code == 0)
end
