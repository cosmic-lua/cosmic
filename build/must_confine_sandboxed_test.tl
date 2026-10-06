--- End to end: what [`confine.must_confine`], and COSMIC_SANDBOX=must,
--- which makes every `confine` one, do where the kernel confines a process:
--- it runs held to what was declared, or the test fails naming what could
--- not be applied. Each suite runs in a `cosmic test` of its own, whose
--- workers nest in this test's own sandbox, so these declare `nests` and are
--- not applicable where the host gives no nest (`requires`). The refusals
--- the same on every host are in `must_confine_test.tl`.

local Fs = require("cosmic.fs")
local confine = require("build.confine")
local fixture = require("build.must_confine_fixture")
local Test = require("cosmic.test")

--- What these tests start is this very program, which runs the
--- tool's own modules besides the closure's, in a root of its own
--- (`nests`); and the variables `unsandboxed` reads, which hold a run
--- to sandboxing.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "nest" },
}
-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

local suite_tree, environment, failure_of = fixture.suite_tree, fixture.environment, fixture.failure_of

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed and whether it passed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}): string, boolean
  local ran = fixture.run(root, output, env, words)
  return ran.text, ran.ok
end

--- Whether the run that printed `text` sandboxed none of its workers;
--- if so, the running test is skipped ([`Test.skip`]) for the reason
--- that run gave, since a case of a confined process then has only the
--- refusal to check. The workers, and what they confine, nest in this
--- test's own sandbox, which a host may refuse: the kernel lets root
--- nest one only two deep (core/syscalls.c's `map_ids`). CI's
--- unprivileged runners nest them.
local function unsandboxed(text: string): boolean
  if text:find("; sandboxed", 1, true) then return false end
  Test.skip(confine.unsandboxed_reason(text))
  return true
end

--- Where the kernel confines a process, one under `must_confine` runs
--- held to what was declared -- not seeing what it was not given, and
--- with no network but a loopback -- and its test passes; where it does
--- not, the test fails naming what could not be applied, and under
--- COSMIC_SANDBOX=must, which says this host confines, this test fails
--- with it. It never runs unconfined.
local function test_a_must_confined_process_is_confined_or_refused(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  suite_tree(tmp, root)
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(hidden .. "/f", "secret"))
  assert(Fs.write(root .. "/suite/data.txt", "in"))
  local real = assert(Fs.absolute(root .. "/suite/data.txt"))
  assert(Fs.write(root .. "/suite/real_test.tl", string.format([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "bin/probe", letters = "r" } }, promises = { "nest" } }

local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine

local function test_confined(tmp: string)
  local probe = assert(Fs.absolute("bin/probe"))
  confine.must_confine({ reads = { %q, probe } })
  local r, _ = Child.run({ probe,
    "exists %s/f 3; copy %s out; " ..
    "present /proc/self/net/dev && grep-count /proc/self/net/dev : || exit 0" },
    { cwd = tmp, stdout = "capture" })
  confine.confine(nil)
  if r == nil then return end -- refused: the run says why
  assert(r.code == 0, "the confined process exited " .. tostring(r.code))
  local out = assert(Fs.read(tmp .. "/out"))
  assert(out == "in" and (r.stdout == "" or r.stdout == "1\n"), out .. tostring(r.stdout))
end
]], real, hidden, real)))
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  if ok then
    assert(text:find("1 ran", 1, true), text)
    return
  end
  local why = text:match("FAIL  suite%.real_test test_confined: ([^\n]*)")
  assert(why ~= nil and why:find("^must_confine: %S*bin/probe could not start confined: .+ could " ..
      "not be applied: .+ %(E[A-Z0-9]+%)$"), text)
  if unsandboxed(text) then return end
  Test.skip("a sandboxed worker could not confine what it started: " .. why)
end

--- COSMIC_SANDBOX=must makes every `confine` a `must_confine`, and every
--- key holds it, sandboxed or not. A test that fell back to an
--- unconfined process and passed stands without it, and runs again and
--- fails with it. Any other value fails the test that confines.
local function test_the_sandbox_mode_holds_confine_to_must_confine(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/fallback_test.tl", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "bin/probe", letters = "r" } }, promises = { "nest" } }

local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine

local function test_falls_back(tmp: string)
  local probe = assert(Fs.absolute("bin/probe"))
  local many: {string} = { probe }
  for i = 1, 300 do many[#many + 1] = tmp .. "/many" .. tostring(i) end
  confine.confine({ reads = many })
  local r = assert(Child.run({ probe, "exit 0" }))
  confine.confine(nil)
  assert(r.ok, "the process it fell back to did not run")
end
]]))
  local text, ok = run(root, tmp .. "/first", environment(nil))
  assert(ok and text:find("1 ran", 1, true), text)
  -- It stands on its declared key, which holds the mode below.
  text, ok = run(root, tmp .. "/stood", environment(nil))
  assert(ok and text:find("0 ran, 1 stood", 1, true), text)
  text, ok = run(root, tmp .. "/must", environment("must"))
  -- A run held to sandboxing fails where none of its workers can be, as
  -- this one's sandbox may leave them (a root worker that cannot map a user).
  if text:find("no worker can be sandboxed here", 1, true) then
    Test.skip(confine.unsandboxed_reason(text))
    return
  end
  assert(not ok, text)
  assert(text:find("FAIL  suite%.fallback_test test_falls_back: confine %(COSMIC_SANDBOX=must%): " ..
      "%S*bin/probe could not start confined: unveil could not be applied: "), text)
  text, ok = run(root, tmp .. "/misspelt", environment("Must"))
  assert(not ok and text:find('COSMIC_SANDBOX is "Must"', 1, true), text)
end

--- A worker a Landlock ruleset holds is refused a root of its own, as the
--- same suite in `must_confine_test.tl` shows with an unsandboxed run given
--- the hold in its environment; here the worker is held by a ruleset in fact.
local function test_a_sandboxed_worker_is_held_by_a_ruleset_and_refused_a_root_of_its_own(tmp: string)
  local root = tmp .. "/root"
  fixture.held_suite(tmp, root)
  local env = environment(nil)
  -- Sandboxed, its own worker is held so.
  env[confine.held_variable] = nil
  local text, ok = run(root, tmp .. "/sandboxed", env, { "--all" })
  if unsandboxed(text) then return end
  assert(not ok and text:find("(2 of 3 failed", 1, true), text)
  local refused = fixture.refusal("suite.held_test")
  assert(failure_of(text, "held_test", "test_confined") == refused, text)
  assert(failure_of(text, "held_test", "test_own_sandbox") == refused, text)
end
