--- End to end: a test that says this host cannot check it
--- ([`Test.skip`]) is counted skipped in the summary of the `cosmic test`
--- that ran it, not passed, and keeps no verdict. Each run here is unsandboxed (COSMIC_TEST_SANDBOX=0), so
--- it means the same on every host.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" } }

--- A project of one test module: one test that skips, one that passes.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/skip_test.tl", [[
local Test = require("cosmic.test")

local function test_skips()
  Test.skip("this host cannot")
  Test.skip("this host cannot")
  return
end

local function test_passes()
  assert(true)
end
]]))
  return root
end

--- What `cosmic test` in `root` printed and its status, run
--- unsandboxed with `extra` set in its environment, and held to
--- sandboxing by nothing else.
local function run(root: string, extra: {string:string}): string, integer
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX = nil
  env.COSMIC_CI_REQUIRE_SANDBOX = nil
  for name, value in pairs(extra) do env[name] = value end
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  return (result.stdout or "") .. (result.stderr or ""), result.code
end

local function test_a_skipped_test_is_counted_and_runs_every_time(tmp: string)
  local root = project(tmp)
  local out, code = run(root, {})
  assert(code == 0, out)
  assert(out:find("(2 tests, 1 module; 2 ran, 0 stood, 1 skipped (this host could not " ..
      "check it), ", 1, true), out)
  -- Each reason once.
  assert(out:find("test: SKIP  skip_test test_skips: this host cannot\n", 1, true), out)
  -- No verdict is kept of it: the pass stands on its declared key, the
  -- skip runs again.
  out, code = run(root, {})
  assert(code == 0, out)
  assert(out:find("; 1 ran, 1 stood, 1 skipped ", 1, true), out)
end

--- A run held to sandboxing counts a skipped test skipped as any other
--- does: it passes, the reason listed.
local function test_a_run_held_to_sandboxing_skips_a_skipped_test(tmp: string)
  for i, held in ipairs({ { COSMIC_SANDBOX = "must" }, { COSMIC_CI_REQUIRE_SANDBOX = "1" } }) do
    local out, code = run(project(tmp .. "/" .. tostring(i)), held)
    assert(code == 0, out)
    assert(out:find("test: SKIP  skip_test test_skips: this host cannot", 1, true), out)
    assert(out:find("1 skipped", 1, true), out)
  end
end

local function test_unavailable_noexec_skips_without_loading_and_keeps_no_verdict(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/noexec_test.tl", [[
local Test = require("cosmic.test")
Test.needs { noexec = true }
error("an unavailable capability must not load its test module")
local function test_requires_noexec() error("must not execute") end
]]))
  for _ = 1, 2 do
    local out, code = run(root, { COSMIC_TEST_NOEXEC = "/forged" })
    assert(code == 0, out)
    assert(out:find("SKIP  noexec_test test_requires_noexec: noexec scratch requires", 1, true), out)
    assert(out:find("2 skipped", 1, true), out)
    assert(not out:find("must not load", 1, true), out)
  end
  local out, code = run(root, { COSMIC_SANDBOX = "must" })
  assert(code == 0, out)
  assert(out:find("SKIP  noexec_test test_requires_noexec: noexec scratch requires", 1, true), out)
end
