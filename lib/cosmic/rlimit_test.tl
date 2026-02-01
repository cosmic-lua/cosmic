#!/usr/bin/env cosmic
local rlimit = require("cosmic.rlimit")

-- Test module exports

local function test_module_exports()
  -- Functions
  assert(rlimit.getlimit ~= nil, "getlimit function should be exported")
  assert(rlimit.setlimit ~= nil, "setlimit function should be exported")
  assert(rlimit.nice ~= nil, "nice function should be exported")
  assert(rlimit.getpriority ~= nil, "getpriority function should be exported")
  assert(rlimit.setpriority ~= nil, "setpriority function should be exported")
  assert(rlimit.yield ~= nil, "yield function should be exported")
end
test_module_exports()

local function test_rlimit_constants()
  -- Resource limit constants
  assert(rlimit.RLIMIT_AS ~= nil, "RLIMIT_AS should be exported")
  assert(rlimit.RLIMIT_CPU ~= nil, "RLIMIT_CPU should be exported")
  assert(rlimit.RLIMIT_FSIZE ~= nil, "RLIMIT_FSIZE should be exported")
  assert(rlimit.RLIMIT_NPROC ~= nil, "RLIMIT_NPROC should be exported")
  assert(rlimit.RLIMIT_NOFILE ~= nil, "RLIMIT_NOFILE should be exported")
  assert(rlimit.RLIMIT_RSS ~= nil, "RLIMIT_RSS should be exported")

  -- All constants should be numbers
  assert(type(rlimit.RLIMIT_AS) == "number", "RLIMIT_AS should be a number")
  assert(type(rlimit.RLIMIT_CPU) == "number", "RLIMIT_CPU should be a number")
  assert(type(rlimit.RLIMIT_FSIZE) == "number", "RLIMIT_FSIZE should be a number")
  assert(type(rlimit.RLIMIT_NPROC) == "number", "RLIMIT_NPROC should be a number")
  assert(type(rlimit.RLIMIT_NOFILE) == "number", "RLIMIT_NOFILE should be a number")
  assert(type(rlimit.RLIMIT_RSS) == "number", "RLIMIT_RSS should be a number")
end
test_rlimit_constants()

local function test_priority_constants()
  -- Priority scope constants
  assert(rlimit.PRIO_PROCESS ~= nil, "PRIO_PROCESS should be exported")
  assert(rlimit.PRIO_PGRP ~= nil, "PRIO_PGRP should be exported")
  assert(rlimit.PRIO_USER ~= nil, "PRIO_USER should be exported")

  -- All constants should be numbers
  assert(type(rlimit.PRIO_PROCESS) == "number", "PRIO_PROCESS should be a number")
  assert(type(rlimit.PRIO_PGRP) == "number", "PRIO_PGRP should be a number")
  assert(type(rlimit.PRIO_USER) == "number", "PRIO_USER should be a number")
end
test_priority_constants()

-- Test resource limit functions

local function test_getlimit_returns_numbers()
  local soft, hard = rlimit.getlimit(rlimit.RLIMIT_NOFILE)
  assert(type(soft) == "number", "getlimit soft should return number, got " .. type(soft))
  assert(type(hard) == "number", "getlimit hard should return number, got " .. type(hard))
end
test_getlimit_returns_numbers()

local function test_getlimit_values()
  local soft, hard = rlimit.getlimit(rlimit.RLIMIT_NOFILE)
  assert(soft > 0, "soft limit should be positive")
  assert(hard > 0, "hard limit should be positive")
  assert(soft <= hard, "soft limit should not exceed hard limit")
end
test_getlimit_values()

local function test_getlimit_all_resources()
  -- Test that all resource types can be queried
  local resources = {
    {rlimit.RLIMIT_AS, "RLIMIT_AS"},
    {rlimit.RLIMIT_CPU, "RLIMIT_CPU"},
    {rlimit.RLIMIT_FSIZE, "RLIMIT_FSIZE"},
    {rlimit.RLIMIT_NPROC, "RLIMIT_NPROC"},
    {rlimit.RLIMIT_NOFILE, "RLIMIT_NOFILE"},
    {rlimit.RLIMIT_RSS, "RLIMIT_RSS"},
  }
  for _, r in ipairs(resources) do
    local soft, hard = rlimit.getlimit(r[1] as number)
    assert(type(soft) == "number", r[2] as string .. " soft should be number")
    assert(type(hard) == "number", r[2] as string .. " hard should be number")
  end
end
test_getlimit_all_resources()

local function test_setlimit()
  -- Get current limits for NOFILE
  local soft, hard = rlimit.getlimit(rlimit.RLIMIT_NOFILE)

  -- Try to set soft limit to a lower value (should succeed)
  if soft > 64 then
    local ok = rlimit.setlimit(rlimit.RLIMIT_NOFILE, 64, hard)
    assert(ok == true, "setlimit should succeed when lowering soft limit")

    -- Verify the change
    local new_soft, new_hard = rlimit.getlimit(rlimit.RLIMIT_NOFILE)
    assert(new_soft == 64, "soft limit should be updated to 64")
    assert(new_hard == hard, "hard limit should remain unchanged")

    -- Restore original limit
    rlimit.setlimit(rlimit.RLIMIT_NOFILE, soft, hard)
  end
end
test_setlimit()

-- Test priority functions

local function test_getpriority_returns_number()
  local prio = rlimit.getpriority(rlimit.PRIO_PROCESS, 0)
  assert(type(prio) == "number", "getpriority should return number, got " .. type(prio))
end
test_getpriority_returns_number()

local function test_getpriority_range()
  local prio = rlimit.getpriority(rlimit.PRIO_PROCESS, 0)
  -- Nice values range from -20 to 19
  assert(prio >= -20, "priority should be >= -20, got " .. tostring(prio))
  assert(prio <= 19, "priority should be <= 19, got " .. tostring(prio))
end
test_getpriority_range()

local function test_nice()
  -- Get current priority
  local before = rlimit.getpriority(rlimit.PRIO_PROCESS, 0)

  -- Increase nice value (lower priority) - this should always succeed
  local after = rlimit.nice(1)
  assert(type(after) == "number", "nice should return number")

  -- New priority should be higher (lower priority) or same (if already at max)
  local current = rlimit.getpriority(rlimit.PRIO_PROCESS, 0)
  assert(current >= before, "nice(1) should increase nice value")
end
test_nice()

local function test_setpriority()
  -- Get current priority
  local current = rlimit.getpriority(rlimit.PRIO_PROCESS, 0)

  -- Try to lower priority (increase nice value) - should succeed
  if current < 19 then
    local ok = rlimit.setpriority(rlimit.PRIO_PROCESS, 0, current + 1)
    assert(type(ok) == "boolean", "setpriority should return boolean")
    -- Note: may fail on some systems, so we just check the return type
  end
end
test_setpriority()

-- Test scheduling function

local function test_yield()
  -- yield() should not fail
  rlimit.yield()
  -- If we get here, yield worked
  assert(true, "yield should not throw")
end
test_yield()

local function test_yield_multiple()
  -- Multiple yields should work
  for _ = 1, 3 do
    rlimit.yield()
  end
  assert(true, "multiple yields should not throw")
end
test_yield_multiple()
