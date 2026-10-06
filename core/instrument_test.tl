--- What the core says of itself and what its instruments answer where the
--- core is not the checked build: they raise (the five raw namespace
--- calls are no instruments, and are real in every core), so no core that ships has an
--- allocator or a fault a program can make fail. The tests that use the
--- instruments on the checked core, which require `checked`, are
--- core/allocation_test.tl's and its neighbours'.

local testing = require("cosmic.internal.testing")

local checked = testing.configuration == "sanitized"

--- Every core says what it is and has every instrument, but only the
--- checked one's instrument: in any other each raises, so no core that
--- ships has an allocator a program can make fail.
local function test_only_the_checked_core_instruments()
  assert(type(testing.configuration) == "string" and testing.configuration ~= "")
  local instruments: {string: function()} = {
    fail_allocations = function()
      testing.fail_allocations(1 << 40)
      testing.allow_allocations()
    end,
    allow_allocations = function() testing.allow_allocations() end,
    open_statements = function() testing.open_statements() end,
    c_heap = function() testing.c_heap() end,
    fail_at = function() testing.fail_at() end,
    live_transfers = function() testing.live_transfers() end,
    executable_path = function() testing.executable_path(4096) end,
    mountinfo_local_flock = function() testing.mountinfo_local_flock("", "0:1") end,
  }
  for name, use in pairs(instruments) do
    local ok, err: boolean, any = pcall(use)
    if checked then
      assert(ok, name .. ": " .. tostring(err))
    else
      assert(not ok and tostring(err):find(name .. ": only the checked core", 1, true),
        name .. " must raise on the " .. testing.configuration .. " core: " .. tostring(err))
    end
  end
end
