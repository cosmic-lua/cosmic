--- The case of core/fault_test.tl that walks a fault in a fresh
--- process: the multi handle is made by a process's first request, so
--- its failure is reached only by starting this program again on a
--- fixture. It declares `tool` because it starts this program.
---
--- Only the checked core has fault points, and CI runs this suite on
--- it; any other core has no instrument to arm one with.

local Child = require("cosmic.child")
local Http = require("cosmic.http")
local testing = require("cosmic.internal.testing")
local test_child = require("build.test_child")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which the fixture runs.
Test.policy{ requires = { "checked" }, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The multi handle is made by the first request of a process, so its
--- failure is walked in a fresh one: a failed curl_multi_init answers
--- that request, and the next request makes it again and succeeds.
test_child.register("multi_init", function(_args: {string}): integer
  local reply = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
  testing.fail_at("curl_multi_init")
  -- Http.open gives no shape for which step failed, only a message, which is not parsed: the fault
  -- being spent (`fail_at()` answers false below) is what says the failure was curl_multi_init's.
  local first, _ = Http.open("http://cosmic.test/", { script = { reply } })
  if first ~= nil then return 11 end
  if testing.fail_at() then return 12 end
  local _, heap_blocks = testing.c_heap()
  local second, _ = Http.open("http://cosmic.test/", { script = { reply } })
  if second == nil then return 13 end
  local body, _ = second:read()
  if body ~= "hello" then return 14 end
  local closed, _ = second:close()
  if not closed then return 17 end
  collectgarbage("collect")
  if testing.live_transfers() ~= 0 then return 15 end
  -- The multi handle's own state is curl's; the core's C holds only
  -- what it held before the second request.
  local _, blocks = testing.c_heap()
  if blocks ~= heap_blocks then return 16 end
  return 0
end)

local function test_a_failed_multi_init_does_not_poison_the_next_request(tmp: string)
  local started = this_program.program(test_child.words(tmp, "core.fault_tool_test", "multi_init"),
    { stdout = "capture", stderr = "capture" })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "the fixture exited " .. tostring(result.code) .. ": " ..
      tostring(result.stderr))
end
