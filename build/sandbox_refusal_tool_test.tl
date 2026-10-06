--- `cosmic sandbox` refusals that come before a sandbox starts, run as
--- this program: a program that is not there (127) or cannot be run (126),
--- one the policy does not grant (125), and a command line it refuses (2).
--- None needs a sandbox, so these run wherever the program does; the runs
--- that start one are in `sandbox_tool_test.tl`. They start this program
--- and host programs, so they declare `tool` and `system`.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local fixture = require("build.sandbox_tool_fixture")

--- The program itself, and the host programs it names.
Test.policy{ profiles = { "system", "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Runs `cosmic <words>` in `dir`.
local function cosmic(dir: string, words: {string}): fixture.Ran
  -- A root caller's program runs as a user of its own, who must be able to
  -- search the directory it starts in.
  searchable.open(dir)
  return fixture.cosmic(dir, words)
end

local function test_a_program_that_is_not_there_exits_127(tmp: string)
  local ran = cosmic(tmp, { "sandbox", "--system", "--", "zzqqx-no-such-program" })
  assert(ran.code == 127 and ran.out == "", ran.code .. ran.err)
  assert(ran.err:find("^cosmic: sandbox: ") and ran.err:find("zzqqx-no-such-program", 1, true), ran.err)
  local path = cosmic(tmp, { "sandbox", "--system", "--", tmp .. "/absent" })
  assert(path.code == 127, path.code .. path.err)
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
