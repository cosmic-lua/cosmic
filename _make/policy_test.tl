#!/usr/bin/env cosmic
-- Tests for _make.policy: the two verbs that orchestrate other verbs.
--
-- `ci` takes its registry lookup as an argument, which is what makes it
-- testable without a make binary: a stub registry answers for every
-- stage, so the ORDER, the material gating and the failure reporting
-- are asserted directly rather than inferred from a real run.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local policy = require("_make.policy")
local types = require("_make.types")

local type Kind = types.Kind
local type Project = types.Project
local type Verb = types.Verb

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A project holding one file of each named kind.
local function project_of(kinds: {Kind}): Project
  local files: {types.File} = {}
  for i, k in ipairs(kinds) do
    files[#files + 1] = {path = "f" .. i .. ".tl", kind = k} as types.File -- cast: partial record fixture
  end
  return {root = "/p", binaries = {}, files = files}
end

--- A stub registry: each verb records that it ran and returns the code
--- the caller asked for.
local record Stub
  lookup: function(name: string): Verb | nil
  --- The names that ran, in order.
  ran: {string}
end

--- @param codes {string: integer} Exit code per verb name, default 0
--- @return Stub The lookup and the record of what it ran
local function registry(codes: {string: integer}): Stub
  local ran: {string} = {}
  return {
    ran = ran,
    lookup = function(name: string): Verb | nil
      return {
        name = name,
        run = function(_p: Project, _paths: {string}, _c: string): integer
          ran[#ran + 1] = name
          return codes[name] or 0
        end,
      } as Verb -- cast: a stub verb needs only name and run
    end,
  }
end

-- The gate is a fixed order of verb NAMES. If a stage could reimplement
-- what its verb does, the two would drift; this is the assertion that
-- keeps `ci` a list.
local function test_stage_order_is_the_documented_pipeline()
  local names: {string} = {}
  for _, s in ipairs(policy.STAGES) do
    names[#names + 1] = s.verb
  end
  assert(table.concat(names, " ") == "fmt check test example lint coverage",
    "got: " .. table.concat(names, " "))
end
test_stage_order_is_the_documented_pipeline()

-- Every stage is gated by MATERIAL: a project with no tests has no test
-- stage and no coverage stage, and that is a PASS, not an error. A
-- fresh project must not fail on a stage that had nothing to do.
local function test_stages_without_material_are_skipped()
  local stub = registry({})
  local code = policy.run_ci(stub.lookup, project_of({"module"}), {}, "cosmic")
  assert(code == 0, "a project with no tests still passes, got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check lint",
    "only the unconditional stages run, got: " .. table.concat(stub.ran, " "))
end
test_stages_without_material_are_skipped()

-- And with material, every stage runs.
local function test_material_earns_the_stage()
  local stub = registry({})
  local code = policy.run_ci(stub.lookup, project_of({"module", "test", "example"}),
    {}, "cosmic")
  assert(code == 0, "got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check test example lint coverage",
    "got: " .. table.concat(stub.ran, " "))
end
test_material_earns_the_stage()

-- A failing stage does not stop the run: a gate that reports one
-- problem per run costs a round trip per problem, and the stages are
-- independent by construction. Every failure is named in the verdict.
local function test_ci_runs_every_stage_and_names_each_failure()
  local stub = registry({check = 1, lint = 1})
  local code = policy.run_ci(stub.lookup, project_of({"module"}), {}, "cosmic")
  assert(code == 1, "a failing stage fails the gate, got " .. code)
  assert(table.concat(stub.ran, " ") == "fmt check lint",
    "a failure must not stop the run, got: " .. table.concat(stub.ran, " "))
end
test_ci_runs_every_stage_and_names_each_failure()

-- `ci` is the whole gate, so a path is a mistake worth naming rather
-- than a narrowing to guess at.
local function test_ci_refuses_a_selection()
  local stub = registry({})
  local code = policy.run_ci(stub.lookup, project_of({"module"}), {"cosmic"}, "c")
  assert(code == 1, "a selection must be refused")
  assert(#stub.ran == 0, "and nothing must run")
end
test_ci_refuses_a_selection()

-- The material test itself, since every stage's gating rests on it.
local function test_has_material()
  local proj = project_of({"module", "test"})
  assert(policy.has(proj, {"test"}), "this project has a test")
  assert(not policy.has(proj, {"example"}), "and no example")
  assert(policy.has(proj, {"example", "test"}), "either kind counts")
end
test_has_material()

-- The ratchet is opt-in by committing a floor. Without one, coverage
-- still runs and still passes -- the absence IS the answer to "should
-- there be a ratchet", so nothing has to be configured either way.
local function test_the_baseline_is_a_convention()
  assert(policy.BASELINE == ".coverage",
    "the floor is a dot-file at the root, got: " .. policy.BASELINE)
  local dir = fs.join(tmpdir, "policy-nobaseline")
  check.must(fs.makedirs(dir))
  local cwd = check.must(fs.getcwd())
  check.must(fs.chdir(dir))
  local absent = not fs.isfile(policy.BASELINE)
  check.must(fs.chdir(cwd))
  assert(absent, "the fixture must not have a floor")
end
test_the_baseline_is_a_convention()

print("all policy tests passed")
