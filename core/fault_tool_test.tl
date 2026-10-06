--- The case of core/fault_test.tl that walks a fault in a fresh
--- process: the multi handle is made by a process's first request, so
--- its failure is reached only by starting this program again on a
--- fixture. It declares `tool` because it starts this program.
---
--- Only the checked core has fault points, and CI runs this suite on
--- it; any other core has no instrument to arm one with.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local testing = require("cosmic.internal.testing")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which the fixture runs.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local checked = testing.configuration == "sanitized"

--- The multi handle is made by the first request of a process, so its
--- failure is walked in a fresh one: a failed curl_multi_init answers
--- that request, and the next request makes it again and succeeds.
local function test_a_failed_multi_init_does_not_poison_the_next_request(tmp: string)
  if not checked then Test.skip("only the checked core carries the instrument it uses") end
  local fixture = tmp .. "/multi_init.tl"
  assert(Fs.write(fixture, [[
local Http = require("cosmic.http")
local testing = require("cosmic.internal.testing")
local reply = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
return function(): integer
  testing.fail_at("curl_multi_init")
  local first, trouble = Http.open("http://cosmic.test/", { script = { reply } })
  if first ~= nil or not trouble:find("curl_multi_init", 1, true) then return 11 end
  if testing.fail_at() then return 12 end
  local _, heap_blocks = testing.c_heap()
  local second = Http.open("http://cosmic.test/", { script = { reply } })
  if second == nil then return 13 end
  if second:read() ~= "hello" then return 14 end
  second:close()
  collectgarbage("collect")
  if testing.live_transfers() ~= 0 then return 15 end
  -- The multi handle's own state is curl's; the core's C holds only
  -- what it held before the second request.
  local _, blocks = testing.c_heap()
  if blocks ~= heap_blocks then return 16 end
  return 0
end
]]))
  local started = this_program.program({ fixture }, { stdout = "capture", stderr = "capture" })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, "the fixture exited " .. tostring(result.code) .. ": " ..
      tostring(result.stderr))
end
