local Fs = require("cosmic.fs")
local reboot = require("build.reboot")
local Test = require("cosmic.test")

Test.policy { profiles = { "system" } }

--- A program that stands in for the rebuilt tool, which a shell script
--- can be: `body` is its code.
local function script_at(path: string, body: string)
  assert(Fs.write(path, "#!/bin/sh\n" .. body .. "\n", 0x1ed))
end

--- The start check lets a tool through that prints `cosmic <digest>`, and
--- refuses one that raises, one that prints something else and one that
--- cannot be run, each with what it said, so the tool in place stays.
local function test_the_start_check_refuses_a_tool_that_does_not_start(tmp: string)
  local good = tmp .. "/good"
  script_at(good, "echo 'cosmic 00'")
  assert(reboot.start_check(good) == nil)

  local raises = tmp .. "/raises"
  script_at(raises, "echo 'sqlite: parameter 1 has no value' >&2; exit 1")
  local why = reboot.start_check(raises)
  assert(why ~= nil and why:find("failed its start check", 1, true) ~= nil, tostring(why))
  assert(why:find("exited 1", 1, true) ~= nil, tostring(why))
  assert(why:find("parameter 1 has no value", 1, true) ~= nil, tostring(why))
  assert(why:find("the tool in place stays", 1, true) ~= nil, tostring(why))

  local silent = tmp .. "/silent"
  script_at(silent, "exit 0")
  assert(reboot.start_check(silent) ~= nil, "a tool that printed no digest started")

  local absent = reboot.start_check(tmp .. "/absent")
  assert(absent ~= nil and absent:find("did not start", 1, true) ~= nil, tostring(absent))
end
