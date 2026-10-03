--- Every refused allocation must release descriptors, backing references and
--- statements, including successful SQLite opens followed by Lua failures.
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local fixture = require("build.sql_artifact_fixture")

local function next_fd(path: string): integer
  local fd = assert(sys.open(path, sys.O_RDONLY))
  assert(sys.close(fd))
  return fd
end

local function test_artifact_open_and_attach_leave_no_resource_under_allocation_failure(tmp: string)
  if testing.configuration ~= "sanitized" then return end
  local path = fixture.write(tmp, "a", "one")
  collectgarbage("collect")
  local descriptor = next_fd(path)
  local bytes, blocks = testing.c_heap()
  local statements = testing.open_statements()
  local function work(): boolean
    local a = assert(Sqlite.artifact(path))
    local b = assert(Sqlite.artifact(path))
    local db = assert(a:open())
    assert(db:attach_artifact(b, "other"))
    local statement = assert(db:prepare("SELECT source FROM other.modules"))
    assert(statement:step() == "row")
    assert(a:close())
    assert(b:close())
    statement:finalize()
    assert(db:exec("DETACH other"))
    assert(db:close())
    return true
  end
  local finished = false
  for after = 0, 10000 do
    testing.fail_allocations(after)
    local ok, why = pcall(work)
    local refused = testing.allow_allocations()
    collectgarbage("collect")
    local now_bytes, now_blocks = testing.c_heap()
    assert(now_bytes == bytes and now_blocks == blocks, "inspection backing leaked")
    assert(next_fd(path) == descriptor, "artifact descriptor leaked")
    assert(testing.open_statements() == statements, "inspection statement leaked")
    if refused == 0 then
      assert(ok, tostring(why))
      assert(after > 0)
      finished = true
      break
    end
  end
  assert(finished, "refusal walk never completed")
  work() -- a failed call must not strand a permit or poison the next open.
end
