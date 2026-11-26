--- The allocation-failure walk for `maps_id`, apart from
--- core/allocation_test.tl because only Linux takes its path: off Linux it
--- allocates nothing, and there is nothing to walk. It needs the checked
--- core's instruments as well.

local AllocationFixture = require("build.allocation_fixture")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{ requires = { "checked", "os:linux" } }

local process = require("cosmic.internal.process")
local assert_c_heap = AllocationFixture.assert_c_heap

--- `maps_id` reads each map into a block of the core's C heap, and
--- closes the map's descriptor, whichever allocation is refused. A
--- refused block fails the call, which then raises, since every
--- allocation past the first refused is refused too, its failure's
--- message among them; so the walk checks what is left behind, not
--- the ENOMEM no caller here can see.
local function test_maps_id_releases_its_block_whenever_an_allocation_fails(tmp: string)
  local before = AllocationFixture.next_descriptor(tmp)
  local bytes, blocks = testing.c_heap()
  local ended = AllocationFixture.under_every_failure(function()
    local ok, why, errno = process.maps_id(0)
    assert(ok or errno == sys.EINVAL, why)
  end)
  assert(ended > 0, "reading the maps allocates")
  collectgarbage("collect")
  assert(AllocationFixture.next_descriptor(tmp) == before, "a refused allocation left descriptor " .. tostring(before) .. " open")
  assert_c_heap(bytes, blocks, "maps_id under refusal")
end
