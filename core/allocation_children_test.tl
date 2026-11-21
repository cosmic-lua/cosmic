--- The allocation-failure walk for the Linux children list, apart from
--- core/allocation_test.tl because it needs a children file in this
--- process's mounted /proc as well as the checked core's instruments.

local AllocationFixture = require("build.allocation_fixture")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{
  requires = { "checked", "path:/proc/thread-self/children" },
  profiles = { "proc" },
}

local process = require("cosmic.internal.process")

--- Asserts the core's own C heap holds what it held when `c_heap`
--- answered `before_bytes` and `before_blocks`: a block a refusal path
--- forgot to free shows here.
local function assert_c_heap(before_bytes: integer, before_blocks: integer, what: string)
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  assert(bytes == before_bytes and blocks == before_blocks,
    what .. " left " .. tostring((blocks - before_blocks)) .. " blocks (" ..
      tostring((bytes - before_bytes)) .. " bytes) on the C heap")
end

--- `children` reads its list into a block of the core's C heap, and
--- closes the list's descriptor, whichever allocation is refused. The
--- checked core that walks it is Linux's.
local function test_children_releases_its_block_whenever_an_allocation_fails(tmp: string)
  local before = AllocationFixture.next_descriptor(tmp)
  local bytes, blocks = testing.c_heap()
  local ended = AllocationFixture.under_every_failure(function()
    assert(process.children())
  end)
  assert(ended > 0, "listing the children allocates")
  collectgarbage("collect")
  assert(AllocationFixture.next_descriptor(tmp) == before, "a refused allocation left descriptor " .. tostring(before) .. " open")
  assert_c_heap(bytes, blocks, "children under refusal")
end
