local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local testing = require("cosmic.internal.testing")

-- The real lookup consults the host's account service.
Test.policy{ profiles = { "system" } }

local checked = testing.configuration == "sanitized"

local function test_user_library_failure_is_not_a_missing_account()
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  testing.fail_at("getpwnam_r")
  local user, reason = Proc.user("root")
  local armed = testing.fail_at()
  assert(not armed and user == nil and reason == "I/O error")
  assert(assert(Proc.user("root")).uid == 0)
end

local function test_user_missing_is_nil_with_an_empty_reason()
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  testing.fail_at("getpwnam_r(missing)")
  local result = table.pack(Proc.user("root"))
  local armed = testing.fail_at()
  assert(not armed and result.n == 2 and result[1] == nil and result[2] == "")
end

local function test_user_refuses_an_entry_larger_than_the_buffer_limit()
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  testing.fail_at("getpwnam_r(oversize)")
  local user, reason = Proc.user("root")
  local armed = testing.fail_at()
  assert(not armed and user == nil and reason == "Result not representable")
  collectgarbage("collect")
  local after_bytes, after_blocks = testing.c_heap()
  assert(after_bytes == bytes and after_blocks == blocks)
end

local function test_user_grows_after_a_short_buffer_and_releases_it()
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  testing.fail_at("getpwnam_r(ERANGE)")
  local user, reason = Proc.user("root")
  local armed = testing.fail_at()
  assert(not armed and user ~= nil, reason)
  assert(user.uid == 0)
  collectgarbage("collect")
  local after_bytes, after_blocks = testing.c_heap()
  assert(after_bytes == bytes and after_blocks == blocks)
end

--- Refusals cover the guard, initial buffer, growth, result table and
--- its fields. Collection also exercises the guard's last-resort owner.
local function test_user_releases_buffers_under_every_allocation_refusal()
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  local cases = {
    { name = "root", point = "", found = true },
    { name = "root", point = "getpwnam_r(ERANGE)", found = true },
    { name = "root", point = "getpwnam_r", found = false },
    { name = "root", point = "getpwnam_r(missing)", found = false },
    { name = "root", point = "getpwnam_r(oversize)", found = false },
  }
  for _, case in ipairs(cases) do
    collectgarbage("collect")
    local bytes, blocks = testing.c_heap()
    local completed = false
    for after = 0, 10000 do
      if case.point ~= "" then testing.fail_at(case.point) end
      testing.fail_allocations(after)
      local ok, user = pcall(Proc.user, case.name)
      local refused = testing.allow_allocations()
      local _ = testing.fail_at()
      collectgarbage("collect")
      local after_bytes, after_blocks = testing.c_heap()
      assert(after_bytes == bytes and after_blocks == blocks, "lookup left its buffer allocated")
      if refused == 0 then
        assert(ok and (user ~= nil) == case.found)
        if user ~= nil then assert(user.uid == 0) end
        assert(after > 0, "lookup allocates")
        completed = true
        break
      end
    end
    assert(completed, "lookup never completed with allocations granted")
  end
end
