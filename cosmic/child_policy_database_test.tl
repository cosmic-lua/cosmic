--- A program sealed by [`Store.seal`] boots: started on the core directly
--- (`core --database <path>`), which needs no sandbox. The sealed set holds a
--- fixture module of the test's, as the program's main. The same program
--- started by [`Child.start`] under a policy whose `database` it is, which
--- needs a sandbox, is in cosmic/child_policy_database_sandboxed_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local fixture = require("build.child_policy_database_fixture")
local this_program = require("build.this_program")

--- [`Store.seal`] reads the rows of every module it carries through
--- [`Store.databases()`], which a worker without the store is not given
--- (the grant of o/cosmic.db). The core is started past its launcher
--- (the grant of o/bin).
-- The `core_path() == nil` returns wait on a `relaunch` name: see the TODO in
-- cosmic/child_policy_database_sandboxed_test.tl.
Test.policy{
  profiles = { "cosmic" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "o/cosmic.db", letters = "r" },
  },
}

--- The core, started on the sealed file by hand, runs the main it names
--- and holds the sealed modules alone: a module the set leaves out is not
--- found, though this tree has it.
local function test_a_sealed_database_started_on_the_core_runs_its_main(tmp: string)
  local core = fixture.core_path()
  if core == nil then return end
  local path = tmp .. "/sealed.db"
  local names = fixture.seal(tmp, path)
  for _, name in ipairs(names) do
    assert(name ~= "cosmic.archive", "the fixture's set must leave cosmic.archive out")
  end
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  local r = assert(Child.run({ core, "--database", path, "/nowhere" }, { env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fixture.fields(assert(r.stdout))
  assert(out.main == "fixture.main", tostring(out.main))
  assert(out.context == "database-v1", tostring(out.context))
  assert(out.databases == "1", tostring(out.databases))
  assert(out.outside == "false", "a module outside the sealed set loaded")
end

--- A database sealed by another core is refused by this one, naming the
--- digest: what `seal` records is the core's own.
local function test_a_database_sealed_for_another_core_does_not_start(tmp: string)
  local core = fixture.core_path()
  if core == nil then return end
  local path = tmp .. "/sealed.db"
  fixture.seal(tmp, path)
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'core_sha256'",
    { { text = string.rep("0", 64) } }))
  assert(db:close())
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  local r = assert(Child.run({ core, "--database", path }, { env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(not r.ok and tostring(r.stderr):find("core_sha256", 1, true), tostring(r.stderr))
end
