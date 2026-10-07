--- `cosmic sandbox` run as this program, holding real host programs to
--- what the command line grants: a granted file is read and an ungranted
--- one is not, and the exit status, the start that fails and the program
--- that is not there are what `cosmic help sandbox` says. These start
--- this program and, under it, host programs, so they declare `tool` and
--- `system`; the command line's own reading is in `sandbox_test.tl` and
--- the refusals that come before a sandbox in `sandbox_refusal_tool_test.tl`.
--- Each starts a sandbox, so off Linux, which gives none, they are not
--- applicable (`requires`), and a host that refuses one skips them
--- (Test.skip).

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local fixture = require("build.sandbox_tool_fixture")

--- The program itself, and the host programs it starts under a policy.
Test.policy{
  profiles = { "system", "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  requires = { "sandbox" },
}

--- Runs `cosmic <words>` in `dir`, and skips the test, where the host
--- refused the sandbox a start asked for.
local function cosmic(dir: string, words: {string}, fds?: {integer:integer}): fixture.Ran
  -- A root caller's program runs as a user of its own, who must be able to
  -- search the directory it starts in.
  searchable.open(dir)
  local ran = fixture.cosmic(dir, words, fds)
  if ran.code == 125 and (ran.err:find("Landlock", 1, true) or ran.err:find("seccomp", 1, true) or
      ran.err:find("not implemented", 1, true)) then
    Test.skip(ran.err)
  end
  return ran
end

local function test_a_granted_file_is_read_and_an_ungranted_one_is_not(tmp: string)
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
  assert(cosmic(tmp, { "sandbox", "--system", "--", "true" }).code == 0)
  assert(cosmic(tmp, { "sandbox", "--system", "--", "false" }).code == 1)
  local seven = cosmic(tmp, { "sandbox", "--system", "--", "sh", "-c", "exit 7" })
  assert(seven.code == 7 and seven.out == "" and seven.err == "", seven.code .. seven.err)
  local killed = cosmic(tmp, { "sandbox", "--system", "--", "sh", "-c", "kill -9 $$" })
  assert(killed.code == 137, tostring(killed.code) .. killed.err)
end

local function test_everything_after_the_program_is_its_own(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--system", "sh", "-c", "printf '%s ' \"$@\"", "sh",
    "--read", "--help", "-h", "--" })
  assert(ran.code == 0 and ran.out == "--read --help -h -- ", ran.code .. ran.out .. ran.err)
end

local function test_a_program_that_runs_past_the_timeout_exits_124(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--system", "--timeout", "1", "--", "sleep", "30" })
  assert(ran.code == 124 and ran.err:find("timed out after 1 second", 1, true), ran.code .. ran.err)
end

local function test_a_start_that_fails_exits_125_with_the_reason(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--system", "--processes", "4", "--", "true" })
  assert(ran.code == 125 and ran.out == "", ran.code .. ran.err)
  assert(ran.err:find("^cosmic: sandbox: ") and ran.err:find("limits.processes", 1, true), ran.err)
  -- A grant that names nothing is a start that cannot be met.
  local missing = cosmic(tmp, { "sandbox", "--system", "--read", tmp .. "/absent", "--", "true" })
  assert(missing.code == 125 and missing.err:find("absent", 1, true), missing.code .. missing.err)
end

local function test_help_is_the_verbs_before_the_program_and_the_programs_after(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--help" })
  assert(ran.code == 0 and ran.out:find("cosmic sandbox", 1, true) and ran.out:find("--read", 1, true),
    ran.out)
  assert(cosmic(tmp, { "sandbox", "--system", "--help" }).out:find("--isolate", 1, true))
  local index = cosmic(tmp, { "help" })
  assert(index.out:find("sandbox", 1, true), index.out)
  -- After the program, --help is the program's: sh is handed it as an
  -- argument and prints it back.
  local program = cosmic(tmp, { "sandbox", "--system", "--", "sh", "-c", 'echo "$1"', "x", "--help" })
  assert(program.code == 0 and program.out == "--help\n", program.code .. program.out .. program.err)
end

local function test_fd_hands_the_callers_descriptor_to_the_program(tmp: string)
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

local function test_cwd_starts_the_program_there_and_relative_paths_are_its(tmp: string)
  searchable.open(tmp)
  assert(Fs.mkdirs(tmp .. "/work") and Fs.write(tmp .. "/work/a", "alpha\n"))
  searchable.open(tmp .. "/work/.")
  local ran = cosmic(tmp, { "sandbox", "--system", "--cwd", "work", "--read", ".", "--", "cat", "a" })
  assert(ran.code == 0 and ran.out == "alpha\n" and ran.err == "", ran.code .. ran.out .. ran.err)
  -- The grant is the directory --cwd names, not the caller's.
  local caller = cosmic(tmp, { "sandbox", "--system", "--cwd", "work", "--read", ".", "--", "ls", ".." })
  assert(caller.code ~= 0 and caller.out == "", caller.code .. caller.out)
end

local function test_cosmic_alone_runs_this_program_under_the_sandbox(tmp: string)
  searchable.open(tmp)
  assert(Fs.mkdirs(tmp .. "/work") and Fs.write(tmp .. "/work/run.tl", 'print("ran")\n'))
  searchable.share(tmp .. "/work")
  searchable.share(tmp .. "/work/run.tl")
  local ran = cosmic(tmp .. "/work", { "sandbox", "--cosmic", "--write", ".", "--",
    (assert(Proc.executable())), "run.tl" })
  assert(ran.code == 0 and ran.out == "ran\n", ran.code .. ": " .. ran.out .. ran.err)
end

--- `connect` right after the verb is the relay's client, which outside a
--- sandbox with `--connect` has no relay to ask and says what it is for.
local function test_the_relays_client_outside_a_sandbox_refuses_saying_what_it_is_for(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "connect", "github.com", "22" })
  assert(ran.code == 2 and ran.out == "", ran.code .. ran.out .. ran.err)
  assert(ran.err:find("^cosmic: sandbox connect: ALL_PROXY is not set"), ran.err)
  assert(ran.err:find("ssh's ProxyCommand inside `cosmic sandbox --connect HOST:PORT`", 1, true), ran.err)
end

--- A program named `connect` is run, not the client, wherever the word is not
--- the one right after the verb: after an option, or after `--`.
local function test_a_program_named_connect_is_run_after_an_option_or_a_dash_dash(tmp: string)
  for _, words in ipairs({ { "sandbox", "--system", "--", "connect", "a", "22" },
      { "sandbox", "--system", "connect", "a", "22" }, { "sandbox", "--", "connect" } }) do
    local ran = cosmic(tmp, words)
    -- No such program on the PATH: the status of a program that is not there.
    assert(ran.code == 127 and ran.err:find("connect", 1, true) and not ran.err:find("ALL_PROXY", 1, true),
      ran.code .. ran.out .. ran.err)
  end
end
