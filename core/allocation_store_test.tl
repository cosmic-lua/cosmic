--- An attached database, walked the way core/allocation_test.tl walks
--- the paths a C binding takes when an allocation fails: the one of its
--- walks that counts the store's databases, apart so the rest stand
--- while the tree moves. Only the checked core can refuse an allocation
--- (core/testing.h), and CI runs this suite on it; on any other the
--- walk returns at once.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

--- [`test_attach_leaves_no_connection_whenever_an_allocation_fails`] counts
--- the store's databases, which a test sees only when it declares the store.
Test.needs{ store = true }

local checked = testing.configuration == "sanitized"

--- Runs `work` once per allocation it makes, refusing that allocation,
--- and a last time with none refused; answers how many runs a refusal
--- ended. A run that nothing was refused in must succeed.
---
--- `settle`, when given, runs after each run with allocations granted
--- again, to release what the run was handed. The work cannot release it
--- itself: a worker's coverage hook runs Lua between any two lines, and
--- can itself be refused, so a refusal can fall between a binding's
--- return and the line that would have released what it returned.
local function under_every_failure(work: function(), settle?: function()): integer
  local ended = 0
  for after = 0, 1000000 do
    testing.fail_allocations(after)
    local ok, failure = pcall(work as function(): any)
    local refused = testing.allow_allocations()
    if settle ~= nil then settle() end
    collectgarbage("collect")
    if refused == 0 then
      assert(ok, "the work failed with every allocation granted: " .. tostring(failure))
      return ended
    end
    ended = ended + 1
  end
  error("the work never ran with every allocation granted")
end

--- The descriptor the next open is handed: the lowest free one, so an
--- earlier one left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

--- An attached database is held by the store or closed: a refusal
--- leaves no connection -- and no descriptor under it -- behind.
local function test_attach_leaves_no_connection_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  local path = tmp .. "/project.db"
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, kind TEXT, " ..
    "source TEXT, file TEXT); CREATE TABLE meta (key TEXT, value TEXT)"))
  assert(db:close())
  local before = next_descriptor(tmp)
  local searched = #Store.databases()
  local ended = under_every_failure(function()
    Store.attach(path)
  end)
  assert(ended > 0, "attaching allocates")
  -- A run can attach and still count a refusal Lua shrugged off (a
  -- string table it could not grow), so the store may hold more than
  -- one: each holds its one descriptor, and nothing else does.
  local held = #Store.databases() - searched
  assert(held >= 1, "the last run attached")
  local after = next_descriptor(tmp)
  assert(after == before + held, "descriptors from " .. before .. " to " .. after ..
    " for " .. held .. " attached: a refused attach left a connection open")
end
