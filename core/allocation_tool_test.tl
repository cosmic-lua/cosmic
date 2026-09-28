--- A child's status, walked the way core/allocation_test.tl walks the
--- paths a C binding takes when an allocation fails: the one of its
--- walks that starts the program again, apart so the rest stand while
--- the tree moves. Only the checked core can refuse an allocation
--- (core/testing.h), and CI runs this suite on it; on any other the
--- walk returns at once.

local _ = require("cosmic.child") -- in the closure: `process_table` searches for it by hand
local Proc = require("cosmic.proc")
local testing = require("cosmic.internal.testing")
local type raw_process = require("cosmic.internal.process")
local Test = require("cosmic.test")

--- The program itself, which the checked core starts again in
--- `test_waitpid_never_loses_a_status_to_a_failed_allocation` (the
--- spawn refusal names it, and never starts it).
Test.needs{ tool = true }

local type Searcher = function(string): any, any

--- The raw process table, as the store's searcher hands it to
--- `cosmic.child`'s loader.
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

local process = process_table()

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

--- A child is reaped only once its answer can be made: a refusal before
--- it leaves the child to wait for again, never its status lost.
local function test_waitpid_never_loses_a_status_to_a_failed_allocation()
  if not checked then return end
  -- This program again, past its launcher, as build.this_program's `program`
  -- starts it, handed a chunk that exits 7: a real status to reap. A
  -- test's worker always runs from a portable artifact.
  local relaunch = assert(Proc.relaunch())
  local argv: {string} = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "return 7"
  local pid = assert(process.spawn(argv[1], argv, relaunch.env, nil, nil, nil, nil, false,
    relaunch.fds))
  local received: raw_process.ChildStatus
  local reaped: raw_process.ChildStatus
  under_every_failure(function()
    if reaped == nil then received = process.waitpid(pid, false) end
  end, function()
    if received ~= nil then
      reaped = received
      received = nil
    end
  end)
  assert(reaped ~= nil, "the child's status was lost to a refused allocation")
  assert(reaped.pid == pid and reaped.code == 7 and reaped.signal == -1)
end
