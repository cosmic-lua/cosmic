--- `build/verify_codesign.tl` on any host: the skip everywhere but
--- macOS, and on macOS, over a stand-in for codesign, both of its calls
--- and a failing one's status.
local Fs = require("cosmic.fs")
local VerifyCodesign = require("build.verify_codesign")

--- A codesign that appends its arguments to `log` and exits `status`.
local function fake_codesign(dir: string, status: integer): string, string
  local path, log = dir .. "/codesign", dir .. "/calls"
  assert(Fs.write(path, "#!/bin/sh\necho \"$*\" >> '" .. log .. "'\nexit " .. status .. "\n", 0x1ed))
  return path, log
end

local function test_every_other_host_skips(dir: string)
  local codesign, log = fake_codesign(dir, 0)
  assert(VerifyCodesign.verify("Linux", "core", codesign) == 0)
  assert(not Fs.exists(log))
end

local function test_macos_verifies_then_displays(dir: string)
  local codesign, log = fake_codesign(dir, 0)
  assert(VerifyCodesign.verify("Darwin", "core", codesign) == 0)
  assert(Fs.read(log) == "--verify --strict --verbose=2 core\n--display --verbose=4 core\n")
end

local function test_a_failed_verification_is_its_status(dir: string)
  local codesign, log = fake_codesign(dir, 3)
  assert(VerifyCodesign.verify("Darwin", "core", codesign) == 3)
  assert(Fs.read(log) == "--verify --strict --verbose=2 core\n")
end

local function test_a_codesign_ended_by_a_signal_is_128_past_it(dir: string)
  local path = dir .. "/codesign"
  assert(Fs.write(path, "#!/bin/sh\nkill -TERM $$\n", 0x1ed))
  assert(VerifyCodesign.verify("Darwin", "core", path) == 143)
end

local function test_a_codesign_that_cannot_start_is_127(dir: string)
  assert(VerifyCodesign.verify("Darwin", "core", dir .. "/missing") == 127)
end
