--- End to end: an unsandboxed run given COSMIC_TEST_KEY=declared keys
--- each verdict by its test's declared inputs, as a sandboxed run does
--- (build/declared_key.tl), though nothing holds a worker to them -- as
--- macOS, which has no sandbox, trusts what CI's Linux legs enforce. Its
--- verdict stands on a run again and in another checkout, through the
--- shared cache, until what the test declares changes; its worker is
--- given the environment its key holds and no more; and neither a
--- sandboxed verdict nor an unenforced one stands for the other. Each
--- run is unsandboxed by COSMIC_TEST_SANDBOX=0, so every host runs
--- these, whether or not it can sandbox a worker.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- What a run of `cosmic test` needs of the host, and the program it
--- runs; and whether this run is held to sandboxing, for the one case
--- that starts a sandboxed run.
Test.needs{
  env = { "COSMIC_CI_REQUIRE_SANDBOX" },
  tool = true,
}

--- The summary of an unenforced run.
local UNENFORCED <const> = "; unsandboxed, keyed by declared inputs (COSMIC_TEST_KEY=declared))"

--- A checkout of the suite at `root`: a test that reads a declared
--- directory, and one that reads a declared variable and finds one it
--- does not declare unset, though the run has it.
local function checkout(root: string)
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/suite/data/f", "one\n"))
  assert(Fs.write(root .. "/suite/data_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data/" } }

local function test_data()
  assert(Fs.read("suite/data/f") ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/env_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { env = { "FLAVOUR", "OUTER_TMPDIR" } }

local function test_env()
  assert(Env.get("FLAVOUR") == "sweet", tostring(Env.get("FLAVOUR")))
  assert(Env.get("UNDECLARED") == nil, "a variable it does not declare reached it")
  -- Unenforced (OUTER_TMPDIR set), TMPDIR is its own scratch directory:
  -- not the run's, nor the /tmp a sandbox would give it, and it may
  -- write there.
  local outer = Env.get("OUTER_TMPDIR")
  if outer ~= nil then
    local temporary = Env.get("TMPDIR")
    assert(temporary ~= nil and temporary ~= outer and temporary ~= "/tmp",
      "TMPDIR is " .. tostring(temporary) .. ", the run's " .. outer)
    assert(Fs.write(temporary .. "/written", "x"))
  end
end
]]))
end

--- The environment an unenforced run of the suite is started with, its
--- shared cache at `cache`: unsandboxed, keyed by declarations, with
--- a variable no test declares, and the run's own TMPDIR, which a
--- worker's is not.
local function environment(cache: string): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_TEST_KEY = "declared"
  env.FLAVOUR = "sweet"
  env.UNDECLARED = "leaked"
  env.OUTER_TMPDIR = env.TMPDIR or "/tmp"
  return env
end

--- Runs `cosmic test` on `root`, answering its exit status and what it
--- printed, which must say it started.
local function run(root: string, output: string, env: {string:string}): integer, string
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.code or -1, text
end

--- A run that must pass and say `wanted`.
local function says(root: string, output: string, env: {string:string}, wanted: string): string
  local code, text = run(root, output, env)
  assert(code == 0, text)
  assert(text:find(wanted, 1, true), wanted .. "\n" .. text)
  return text
end

--- Its verdicts stand on a run again -- the scratch directory each
--- worker is given, new every run, is no part of their keys -- and in
--- another checkout of the same content, on the verdicts the first
--- reached; the summary says how the run was keyed; and each worker
--- was given only the variables its key holds.
local function test_an_unenforced_verdict_stands_again_and_in_another_checkout(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  says(tmp .. "/first", tmp .. "/first.out", env, "2 ran, 0 stood")
  says(tmp .. "/first", tmp .. "/again.out", env, "0 ran, 2 stood")
  checkout(tmp .. "/second")
  local second = says(tmp .. "/second", tmp .. "/second.out", env,
    "0 ran, 2 stood, 2 of them on another checkout's verdict")
  assert(second:find(UNENFORCED, 1, true), second)
end

--- A file beneath a declared directory that changes runs the test that
--- declares it, and it alone.
local function test_an_edit_to_what_a_test_declares_runs_it(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/root")
  says(tmp .. "/root", tmp .. "/first.out", env, "2 ran, 0 stood")
  assert(Fs.write(tmp .. "/root/suite/data/f", "two\n"))
  says(tmp .. "/root", tmp .. "/edited.out", env, "1 ran, 1 stood")
end

--- A way of keying it does not know is refused, naming the one it does.
local function test_a_key_mode_it_does_not_know_is_refused(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  env.COSMIC_TEST_KEY = "observed-ish"
  checkout(tmp .. "/root")
  local code, text = run(tmp .. "/root", tmp .. "/refused.out", env)
  assert(code == 2, text)
  assert(text:find("COSMIC_TEST_KEY is \"observed-ish\": set it to declared", 1, true), text)
end

--- Neither a sandboxed verdict nor an unenforced one stands for the
--- other, whichever came first: each keys under a runtime of its own.
--- The runtime's " declared" tag (build/test.tl) is not what this case
--- turns on: the two runs differ in COSMIC_TEST_SANDBOX, which every
--- key holds pinned, and a sandboxed runtime carries " sandboxed". The
--- tag names the mode in the key itself, so the two stay apart though
--- neither of those tells them apart any longer -- a run in auto mode
--- on a host that can sandbox a worker one day and not the next, were
--- the " sandboxed" mark to go -- and no test can reach a runtime but
--- through the keys these runs print.
--- Where this host cannot sandbox a worker of the run it starts --
--- macOS, which has no sandbox, decided before anything starts; one
--- nested in this test's own sandbox, which the kernel refuses root,
--- or a host refusing user namespaces, told by the run's summary --
--- there is nothing to check, unless this run is held to sandboxing:
--- then it fails.
local function test_a_sandboxed_and_an_unenforced_verdict_stand_apart(tmp: string)
  local function environments(cache: string): {string:string}, {string:string}
    local unenforced = environment(cache)
    local sandboxed: {string:string} = {}
    for name, value in pairs(unenforced) do sandboxed[name] = value end
    sandboxed.COSMIC_TEST_SANDBOX = nil
    sandboxed.COSMIC_TEST_KEY = nil
    sandboxed.UNDECLARED = nil
    sandboxed.OUTER_TMPDIR = nil
    return sandboxed, unenforced
  end
  -- macOS has no sandbox at all: nothing to check there.
  local names = assert(sys.uname())
  if names.sysname == "Darwin" and not confine.held_to_sandbox() then return end
  local sandboxed, unenforced = environments(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  local code, first = run(tmp .. "/first", tmp .. "/first.out", sandboxed)
  assert(code == 0, first)
  if not first:find("; sandboxed)", 1, true) then
    assert(not confine.held_to_sandbox(),
      "the run is held to sandboxing, but the run it started was not:\n" .. first)
    return
  end
  assert(first:find("2 ran, 0 stood", 1, true), first)
  says(tmp .. "/first", tmp .. "/first-unenforced.out", unenforced, "2 ran, 0 stood")
  sandboxed, unenforced = environments(tmp .. "/other-cache/verdicts.db")
  checkout(tmp .. "/second")
  says(tmp .. "/second", tmp .. "/second-unenforced.out", unenforced, "2 ran, 0 stood")
  local second = says(tmp .. "/second", tmp .. "/second.out", sandboxed, "2 ran, 0 stood")
  assert(second:find("; sandboxed)", 1, true), second)
end
