--- Startup failure paths must leave no descriptors, child or mappings.
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" }, requires = { "checked" } }
local type Searcher = function(string): any, any
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: the loader's extra is its raw table
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: core/process.h declares this table
    end
  end
  error("no process table")
end
local process = process_table()
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
    local pid, why, number = process.connector_start({ { host = "127.0.0.1", port = 9 } }, pair[2], 100)
    assert(not testing.fail_at(), point .. " did not fire")
    assert(pid == nil and why ~= "" and number ~= 0, point .. " did not return a value failure")
    collectgarbage("collect")
    assert(next_descriptor(tmp) == before, point .. " leaked a descriptor")
  end
  assert(sys.close(pair[1]))
  assert(sys.close(pair[2]))
end
