--- The allocation-failure walk for the Linux children list, apart from
--- core/allocation_test.tl because it needs a children file in this
--- process's mounted /proc as well as the checked core's instruments.

local _ = require("cosmic.child") -- in the closure: [`process_table`] searches for it by hand
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local type raw_process = require("cosmic.internal.process")
local Test = require("cosmic.test")

Test.policy{
  requires = { "checked", "path:/proc/thread-self/children" },
  grants = { { path = "/proc", letters = "r" } },
}

local type Searcher = function(string): any, any

--- The raw process table, as the store's searcher hands it to
--- [`cosmic.child`]'s loader.
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

--- Asserts the core's own C heap holds what it held when `c_heap`
--- answered `before_bytes` and `before_blocks`: a block a refusal path
--- forgot to free shows here.
local function assert_c_heap(before_bytes: integer, before_blocks: integer, what: string)
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  assert(bytes == before_bytes and blocks == before_blocks,
    what .. " left " .. (blocks - before_blocks) .. " blocks (" ..
      (bytes - before_bytes) .. " bytes) on the C heap")
end

--- `children` reads its list into a block of the core's C heap, and
--- closes the list's descriptor, whichever allocation is refused. Off
--- Linux it allocates nothing, and there is nothing to walk.
local function test_children_releases_its_block_whenever_an_allocation_fails(tmp: string)
  local before = next_descriptor(tmp)
  local bytes, blocks = testing.c_heap()
  local ended = under_every_failure(function()
    assert(process.children())
  end)
  assert(ended > 0, "listing the children allocates")
  collectgarbage("collect")
  assert(next_descriptor(tmp) == before, "a refused allocation left descriptor " .. before .. " open")
  assert_c_heap(bytes, blocks, "children under refusal")
end
