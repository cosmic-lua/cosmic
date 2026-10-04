--- `cosmic sandbox` run as this program, holding real host programs to
--- what the command line grants: a granted file is read and an ungranted
--- one is not, and the exit status, the start that fails and the program
--- that is not there are what `cosmic help sandbox` says. These start
--- this program and, under it, host programs, so they declare `tool` and
--- `system`; the command line's own reading is in `sandbox_test.tl`. A
--- host that gives no sandbox (anything but Linux, a kernel without
--- Landlock or seccomp, a container that refuses one) skips them where it
--- could have given one (build.sandbox_skip).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local sandbox_skip = require("build.sandbox_skip")
local searchable = require("build.searchable")
local this_program = require("build.this_program")

--- The program itself, and the host programs it starts under a policy.
Test.needs{ tool = true, system = true }

local record Ran
  code: integer
  out: string
  err: string
end

--- Runs `cosmic <words>` in `dir`, and skips the test, where the host
--- refused the sandbox a start asked for.
local function cosmic(dir: string, words: {string}, fds?: {integer:integer}): Ran
  -- A root caller's program runs as a user of its own, who must be able to
  -- search the directory it starts in.
  searchable.open(dir)
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(60), fds = fds,
  })
  local result = assert(Child.run(started.argv, started.options))
  local ran: Ran = { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
  if ran.code == 125 and (ran.err:find("Landlock", 1, true) or ran.err:find("seccomp", 1, true) or
      ran.err:find("not implemented", 1, true) or ran.err:find("only Linux gives", 1, true)) then
    sandbox_skip.refused(ran.err)
  end
  return ran
end

--- Whether this platform cannot sandbox at all, which skips a test that
--- needs a start to run: off Linux every policy's start is refused.
local function no_sandbox_here(): boolean
  if confine.sandbox_platform() then return false end
  sandbox_skip.refused("a policy holds a program only on Linux")
  return true
end

local function test_a_granted_file_is_read_and_an_ungranted_one_is_not(tmp: string)
  if no_sandbox_here() then return end
  searchable.open(tmp)
  assert(Fs.mkdirs(tmp .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n") and Fs.write(tmp .. "/other/b", "beta\n"))
  local ran = cosmic(tmp, { "sandbox", "--system", "--read", tmp .. "/ro", "--", "cat", tmp .. "/ro/a" })
  assert(ran.code == 0 and ran.out == "alpha\n" and ran.err == "", ran.code .. ran.out .. ran.err)
  local denied = cosmic(tmp, { "sandbox", "--system", "--read=" .. tmp .. "/ro", "cat", tmp .. "/other/b" })
  assert(denied.code ~= 0 and denied.code < 125, tostring(denied.code))
  assert(denied.out == "" and denied.err:find("Permission denied", 1, true), denied.err)
  -- Nothing but what is granted: not the working directory either.
  local here = cosmic(tmp, { "sandbox", "--system", "cat", tmp .. "/ro/a" })
  assert(here.code ~= 0 and here.out == "", here.out)
end

local function test_the_programs_status_is_the_exit_status(tmp: string)
  if no_sandbox_here() then return end
  assert(cosmic(tmp, { "sandbox", "--system", "--", "true" }).code == 0)
  assert(cosmic(tmp, { "sandbox", "--system", "--", "false" }).code == 1)
  local seven = cosmic(tmp, { "sandbox", "--system", "--", "sh", "-c", "exit 7" })
  assert(seven.code == 7 and seven.out == "" and seven.err == "", seven.code .. seven.err)
  local killed = cosmic(tmp, { "sandbox", "--system", "--", "sh", "-c", "kill -9 $$" })
  assert(killed.code == 137, tostring(killed.code) .. killed.err)
end

local function test_everything_after_the_program_is_its_own(tmp: string)
  if no_sandbox_here() then return end
  local ran = cosmic(tmp, { "sandbox", "--system", "sh", "-c", "printf '%s ' \"$@\"", "sh",
    "--read", "--help", "-h", "--" })
  assert(ran.code == 0 and ran.out == "--read --help -h -- ", ran.code .. ran.out .. ran.err)
end

local function test_a_program_that_runs_past_the_timeout_exits_124(tmp: string)
  if no_sandbox_here() then return end
  local ran = cosmic(tmp, { "sandbox", "--system", "--timeout", "1", "--", "sleep", "30" })
  assert(ran.code == 124 and ran.err:find("timed out after 1 second", 1, true), ran.code .. ran.err)
end

local function test_a_program_that_is_not_there_exits_127(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--system", "--", "zzqqx-no-such-program" })
  assert(ran.code == 127 and ran.out == "", ran.code .. ran.err)
  assert(ran.err:find("^cosmic: sandbox: ") and ran.err:find("zzqqx-no-such-program", 1, true), ran.err)
  local path = cosmic(tmp, { "sandbox", "--system", "--", tmp .. "/absent" })
  assert(path.code == 127, path.code .. path.err)
end

local function test_a_start_that_fails_exits_125_with_the_reason(tmp: string)
  if no_sandbox_here() then return end
  local ran = cosmic(tmp, { "sandbox", "--system", "--connect", "example.com:443", "--", "true" })
  assert(ran.code == 125 and ran.out == "", ran.code .. ran.err)
  assert(ran.err:find("^cosmic: sandbox: ") and ran.err:find("relay", 1, true), ran.err)
  -- A grant that names nothing is a start that cannot be met.
  local missing = cosmic(tmp, { "sandbox", "--system", "--read", tmp .. "/absent", "--", "true" })
  assert(missing.code == 125 and missing.err:find("absent", 1, true), missing.code .. missing.err)
end

local function test_a_command_line_it_refuses_exits_2(tmp: string)
  for _, words in ipairs({ { "sandbox" }, { "sandbox", "--system" }, { "sandbox", "--nope", "true" },
      { "sandbox", "--path", "xr:.", "true" } }) do
    local ran = cosmic(tmp, words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.code .. ran.err)
    assert(ran.err:find("^cosmic: sandbox: "), ran.err)
    assert(not ran.err:find("FAIL", 1, true), ran.err)
  end
end

local function test_help_is_the_verbs_before_the_program_and_the_programs_after(tmp: string)
  if no_sandbox_here() then return end
  local ran = cosmic(tmp, { "sandbox", "--help" })
  assert(ran.code == 0 and ran.out:find("cosmic sandbox", 1, true) and ran.out:find("--read", 1, true),
    ran.out)
  assert(cosmic(tmp, { "sandbox", "--system", "--help" }).out:find("--isolate", 1, true))
  local index = cosmic(tmp, { "help" })
  assert(index.out:find("sandbox", 1, true), index.out)
  -- After the program, --help is the program's: sh reports it as its own.
  local program = cosmic(tmp, { "sandbox", "--system", "--", "sh", "--help" })
  assert(not program.out:find("cosmic sandbox", 1, true), program.out)
  assert(program.code ~= 0 and program.code < 125 and program.err ~= "", program.code .. program.err)
end

local function test_a_program_not_granted_exits_125_not_127(tmp: string)
  -- It is found on the PATH; the policy lacks the grants to run it.
  local ran = cosmic(tmp, { "sandbox", "--", "true" })
  assert(ran.code == 125 and ran.out == "", ran.code .. ran.err)
  assert(ran.err:find("not granted", 1, true) and ran.err:find("system", 1, true), ran.err)
  assert(not ran.err:find("no PATH search", 1, true), ran.err)
  -- A missing grant is the start's, not the program's, whatever the program.
  local grant = cosmic(tmp, { "sandbox", "--system", "--read", tmp .. "/absent", "--", "ls" })
  assert(grant.code == 125 and not grant.err:find("no PATH search", 1, true), grant.code .. grant.err)
end

local function test_a_program_that_cannot_be_run_exits_126(tmp: string)
  assert(Fs.write(tmp .. "/plain", "#!/bin/sh\n"))
  assert(sys.chmod(tmp .. "/plain", 420))
  searchable.open(tmp)
  local ran = cosmic(tmp, { "sandbox", "--system", "--run", tmp .. "/plain", "--", tmp .. "/plain" })
  assert(ran.code == 126 and ran.out == "", ran.code .. ran.err)
end

local function test_fd_hands_the_callers_descriptor_to_the_program(tmp: string)
  if no_sandbox_here() then return end
  assert(Fs.write(tmp .. "/data", "carried\n"))
  local fd = assert(sys.open(tmp .. "/data", sys.O_RDONLY))
  local ran = cosmic(tmp, { "sandbox", "--system", "--fd", "5", "--promise", "fork", "--", "sh", "-c", "cat <&5" }, { [5] = fd })
  local _ = sys.close(fd)
  assert(ran.code == 0 and ran.out == "carried\n", ran.code .. ran.out .. ran.err)
  -- Not named, it is not the program's, though the caller holds it.
  local other = assert(sys.open(tmp .. "/data", sys.O_RDONLY))
  local shut = cosmic(tmp, { "sandbox", "--system", "--promise", "fork", "--", "sh", "-c", "cat <&5" }, { [5] = other })
  local _ = sys.close(other)
  assert(shut.code ~= 0 and shut.out == "", shut.code .. shut.out)
  -- A descriptor the caller does not hold fails the start.
  local none = cosmic(tmp, { "sandbox", "--system", "--fd", "9", "--", "true" })
  assert(none.code == 125 and none.err:find("^cosmic: sandbox: "), none.code .. none.err)
end
