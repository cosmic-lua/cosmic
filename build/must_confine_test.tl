--- End to end: what [`confine.must_confine`] does with a start it cannot hold to what was declared, the same on every
--- host, so these run wherever the program does. Each case runs in a process of its own, a child of
--- build/must_confine_children_test.tl: a spawn `must_confine` refuses fails every running stand-in, the one that runs a
--- test included. The cases that need a sandbox to confine a process are in `must_confine_sandboxed_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local fixture = require("build.must_confine_fixture")
local this_program = require("build.this_program")
local _ = require("build.must_confine_children_test")

--- What these tests start is this very program, which runs the tool's own modules besides the closure's, in a root of its
--- own (`nests`).
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
}
-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

--- A spawn `must_confine` refuses does not start, and fails the test that made it, naming the program, the part of the
--- sandbox, why, and the errno's name. It fails a test that passed over the spawn's failure, and one that raised besides,
--- whose own failure follows. So too a process given more paths than a sandbox unveils; one started with a sandbox of its
--- own that does not unveil and take the network.
local function test_a_refused_spawn_fails_the_test_whatever_it_made_of_it(tmp: string)
  local said = fixture.run(tmp, "refusals", { fixture.probe(tmp), tmp })
  assert(said.code == 0, said.text)
  local too_many = "^must_confine: .*could not start confined: unveil could not be applied: %d+ paths, more than the " ..
    tostring(confine.unveil_max) .. " a sandbox unveils %(EINVAL%)$"
  local passed = fixture.field(said, "passed_over")
  assert(passed:find(too_many) ~= nil, said.text)
  local raised = fixture.field(said, "raised_too")
  local joint = assert(raised:find("; and then: ", 1, true), said.text)
  assert(raised:find("its own failure$") ~= nil, said.text)
  assert(raised:sub(1, joint - 1):find(too_many) ~= nil, said.text)
  local own_sandbox = "^must_confine: .*could not start confined: unveil and offline could not be applied: a sandbox " ..
    "of its own that does not unveil and take the network, which must_confine does not add to %(EINVAL%)$"
  assert(fixture.field(said, "offline_alone"):find(own_sandbox) ~= nil, said.text)
end

--- A worker a Landlock ruleset holds -- one whose module does not declare `nests` -- cannot give a process a root of its
--- own, whose mounts the kernel refuses under the ruleset: a start in one, through `confine` or a sandbox of its own that
--- unveils, is refused outright, naming `nests`, and fails the test however it took the refusal, rather than fall back to
--- running the process unconfined. Every process of the worker's learns of the hold from its environment
--- ([`confine.held_variable`]), which a child is given here to stand for it, the same on every host; sandboxed, the
--- worker is held by a ruleset in fact (`must_confine_held_test.tl`).
local function test_a_worker_held_by_landlock_is_refused_a_root_of_its_own(tmp: string)
  local probe = fixture.probe(tmp)
  local module = "suite.outer_test"
  local said = fixture.run(tmp, "held", { probe, tmp }, { [confine.held_variable] = module })
  assert(said.code == 0, said.text)
  local refused = probe .. " cannot start in a root of its own: " .. module .. "'s worker is held by a Landlock " ..
    "ruleset, under which the kernel refuses every mount; declare the promise \"nest\" in its Test.policy"
  assert(fixture.field(said, "confined") == refused, said.text)
  assert(fixture.field(said, "own_sandbox") == refused, said.text)
end

--- A `cosmic test` started in a worker held by a ruleset, asked to sandbox its workers, refuses to.
local function test_a_run_started_in_a_held_worker_refuses_to_sandbox_its_workers(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/plain_test.tl", "local function test_plain()\n  assert(true)\nend\n"))
  local env = this_program.environment()
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_TEST_SANDBOX"] = nil
  env["COSMIC_SANDBOX"] = nil
  env[confine.held_variable] = "suite.outer_test"
  local started = this_program.program({ "test" }, { cwd = root, env = env, stdout = "capture", stderr = "stdout",
    timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  local text = result.stdout or ""
  assert(not result.ok and text:find("test: this run was started in suite.outer_test's worker, " ..
      "which a Landlock ruleset holds", 1, true) ~= nil and
      text:find("declare the promise \"nest\" in its Test.policy", 1, true) ~= nil, text)
end

--- COSMIC_SANDBOX=must makes every `confine` a `must_confine`: a process that fell back to running unconfined, and
--- passed, is refused with it. Any other value fails the test that confines.
local function test_the_sandbox_mode_holds_confine_to_must_confine(tmp: string)
  local probe = fixture.probe(tmp)
  local plain = fixture.run(tmp, "mode", { probe, tmp })
  assert(plain.code == 0 and fixture.field(plain, "fell_back") == "ok", plain.text)
  local must = fixture.run(tmp, "mode", { probe, tmp }, { COSMIC_SANDBOX = "must" })
  assert(must.code == 0, must.text)
  assert(fixture.field(must, "fell_back"):find("^confine %(COSMIC_SANDBOX=must%): .*could not start confined: " ..
      "unveil could not be applied: ") ~= nil, must.text)
  local misspelt = fixture.run(tmp, "mode", { probe, tmp }, { COSMIC_SANDBOX = "Must" })
  assert(misspelt.text:find('COSMIC_SANDBOX is "Must"', 1, true) ~= nil, misspelt.text)
end

--- COSMIC_SANDBOX=must is in every verdict's key, sandboxed or not: a test that stood, in a run without it, runs again
--- in one with it, so a pass reached by falling back to an unconfined process does not stand for a run that forbids that.
--- The suite is a project's of one plain test, run by `cosmic test` three times.
local function test_the_sandbox_mode_is_part_of_the_key_of_a_verdict(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/plain_test.tl", "local function test_plain()\n  assert(true)\nend\n"))
  local function run(must: boolean): string
    local env = this_program.environment()
    env["COSMIC_VERDICT_CACHE"] = "0"
    env["COSMIC_TEST_ALL"] = nil
    env["COSMIC_TEST_SANDBOX"] = nil
    env["COSMIC_SANDBOX"] = nil
    if must then env["COSMIC_SANDBOX"] = "must" end
    local started = this_program.program({ "test" }, { cwd = root, env = env, stdout = "capture", stderr = "stdout",
      timeout_ns = Clock.seconds(60) })
    local result = assert(Child.run(started.argv, started.options))
    return result.stdout or ""
  end
  local first = run(false)
  assert(first:find("1 ran", 1, true) ~= nil, first)
  local again = run(false)
  assert(again:find("0 ran, 1 stood", 1, true) ~= nil, again)
  local must = run(true)
  -- A run held to sandboxing fails where none of its workers can be, as this one's sandbox may leave them.
  if must:find("no worker can be sandboxed here", 1, true) ~= nil then
    Test.skip(confine.unsandboxed_reason(must))
  end
  assert(must:find("1 ran", 1, true) ~= nil and must:find("0 ran", 1, true) == nil, must)
end

--- Where the platform has no sandbox to confine with, a process under `must_confine` is refused, not run unconfined, and
--- a `confine` that cannot confine falls back to an unconfined process and runs. This branches on the platform because
--- where it can confine, the process runs held to what was declared, which `must_confine_sandboxed_test.tl` checks.
local function test_without_a_sandbox_a_must_confined_process_is_refused_and_a_confined_one_falls_back(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local said = fixture.run(tmp, "unsandboxed", { fixture.probe(tmp), tmp })
  assert(said.code == 0, said.text)
  assert(fixture.field(said, "refused"):find("^must_confine: %S+ could not start confined: .+ could not be applied: " ..
      ".+ %(E[A-Z0-9]+%)$") ~= nil, said.text)
  assert(fixture.field(said, "fell_back") == "ok", said.text)
end
