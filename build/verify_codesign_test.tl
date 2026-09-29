--- `build/verify_codesign.tl` on any host: the skip everywhere but
--- macOS, and on macOS, over a stand-in for codesign, both of its calls
--- and a failing one's status.
local Fs = require("cosmic.fs")
local VerifyCodesign = require("build.verify_codesign")
local stand_in = require("build.stand_in")
local sys = require("cosmic.sys")

--- A stand-in program built under `dir`, outside the PATH it searches.
local function stand_in_under(dir: string): string
  return (assert(stand_in.build(dir .. "/stand-in")))
end

--- A codesign in `dir`, the PATH each test searches, that appends its
--- arguments to `log` and exits `status`.
local function fake_codesign(probe: string, dir: string, status: integer): string
  local log = dir .. "/calls"
  assert(stand_in.place(probe, dir .. "/codesign",
    "append " .. log .. " $@\nexit " .. status))
  return log
end

--- A codesign that cannot start, which no stand-in need be built for:
--- running it would answer 127.
local function unstartable_codesign(dir: string, mode: integer)
  assert(Fs.write(dir .. "/codesign", "#!/nonexistent/interpreter\n", mode))
end

local function test_every_other_host_skips(dir: string)
  unstartable_codesign(dir, 0x1ed)
  assert(VerifyCodesign.verify("Linux", "core", dir) == 0)
end

local function test_macos_verifies_then_displays(dir: string)
  local log = fake_codesign(stand_in_under(dir), dir, 0)
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 0)
  assert(Fs.read(log) == "--verify --strict --verbose=2 core\n--display --verbose=4 core\n")
end

local function test_a_failed_verification_is_its_status(dir: string)
  local log = fake_codesign(stand_in_under(dir), dir, 3)
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 3)
  assert(Fs.read(log) == "--verify --strict --verbose=2 core\n")
end

local function test_a_codesign_ended_by_a_signal_is_128_past_it(dir: string)
  assert(stand_in.place(stand_in_under(dir), dir .. "/codesign", "signal TERM"))
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 143)
end

--- codesign is found on the PATH given, as the shell script found it:
--- none there, or one without execute permission, is 127.
local function test_a_codesign_not_on_path_is_127(dir: string)
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 127)
  unstartable_codesign(dir, 0x1ed)
  assert(sys.chmod(dir .. "/codesign", 0x1a4))
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 127)
end

--- One found on the PATH that cannot be started is 127 too.
local function test_a_codesign_that_cannot_start_is_127(dir: string)
  unstartable_codesign(dir, 0x1ed)
  assert(VerifyCodesign.verify("Darwin", "core", dir) == 127)
end

--- The first codesign on the PATH is the one run.
local function test_the_first_codesign_on_path_runs(dir: string)
  assert(Fs.mkdirs(dir .. "/a") and Fs.mkdirs(dir .. "/b"))
  local probe = stand_in_under(dir)
  local log = fake_codesign(probe, dir .. "/a", 0)
  fake_codesign(probe, dir .. "/b", 5)
  assert(VerifyCodesign.verify("Darwin", "core", dir .. "/a:" .. dir .. "/b") == 0)
  assert(Fs.exists(log))
end

local function test_main_answers_help_and_refuses_an_option()
  -- Help is answered wherever it is asked, and nothing is verified: a
  -- second word is no usage error and "-x" is not the binary's path.
  assert(VerifyCodesign.main({ [1] = "a", [2] = "--help" }) == 0)
  assert(VerifyCodesign.main({ [1] = "-h" }) == 0)
  assert(VerifyCodesign.main({ [1] = "-x" }) == 2)
  assert(VerifyCodesign.main({}) == 2)
end
