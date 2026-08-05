#!/usr/bin/env cosmic
-- Tests for _make.stage: the half of a verb that is the same for every
-- verb -- what it acts on, how a selection narrows it, and the verdict
-- line every run ends in.
--
-- The graph_stage path itself is exercised end to end by build_test,
-- selection_test and fixtures_test, which run real projects. What is
-- asserted here is the part those cannot see without a make binary:
-- the tables and the two pure functions.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local spawn = require("cosmic.child")
local stage = require("_make.stage")
local types = require("_make.types")

local type File = types.File

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A File of the given kind and path, as the walk would produce it.
local function file(path: string, kind: types.Kind): File
  return {path = path, kind = kind} as File -- cast: partial record fixture
end

--- The paths of a candidate list, for comparison.
local function paths(files: {File}): string
  local out: {string} = {}
  for _, f in ipairs(files) do
    out[#out + 1] = f.path
  end
  table.sort(out)
  return table.concat(out, " ")
end

-- Every graph verb's selection names files of its OWN kind. A verb
-- whose table said otherwise would silently act on the wrong set --
-- `fmt` gating payload, `test` running examples -- so the mapping is
-- asserted rather than assumed.
local function test_each_selection_names_its_own_kind()
  local proj: types.Project = {
    root = "/p",
    binaries = {},
    files = {
      file("pkg/a.tl", "module"),
      file("pkg/a_test.tl", "test"),
      file("pkg/a_example.tl", "example"),
      file("embed/data.txt", "asset"),
    },
  }
  assert(paths(stage.candidates(proj, stage.SELECTS.test)) == "pkg/a_test.tl",
    "test selects tests")
  assert(paths(stage.candidates(proj, stage.SELECTS.example)) ==
    "pkg/a_example.tl", "example selects examples")
  local built = paths(stage.candidates(proj, stage.SELECTS.build))
  assert(built:find("pkg/a.tl", 1, true), "build compiles modules")
  assert(not built:find("embed/data.txt", 1, true),
    "build does not compile payload, got: " .. built)
end
test_each_selection_names_its_own_kind()

-- The suffix filter is nil, not "": `sub(-#"")` is `sub(0)`, which is
-- the whole string, so an empty-string filter matches NOTHING while
-- reading as "unfiltered". A `.lua` test must survive the filter.
local function test_a_lua_test_survives_selection()
  local proj: types.Project = {
    root = "/p",
    binaries = {},
    files = {file("pkg/a_test.lua", "test")},
  }
  assert(paths(stage.candidates(proj, stage.SELECTS.test)) == "pkg/a_test.lua",
    "a .lua test is a test")
end
test_a_lua_test_survives_selection()

-- Every verb ends in a machine-readable verdict, because CI reads the
-- last line and a caller that only reads the exit code still gets one
-- that agrees with it.
local function test_verdict_line_and_exit_code()
  assert(stage.verdict("test", true, "3 files") == 0, "PASS exits 0")
  assert(stage.verdict("test", false, "") == 1, "FAIL exits 1")
end
test_verdict_line_and_exit_code()

-- Where a project's binaries land is derived from the model, which is
-- what lets `test` answer "which binary is under test" without being
-- told.
local function test_bin_dir_is_derived()
  local proj: types.Project = {root = "/p", binaries = {}, files = {}}
  assert(stage.bin_dir(proj) == fs.join("/p", project.BUILD_DIR, "bin"),
    "got: " .. stage.bin_dir(proj))
end
test_bin_dir_is_derived()

-- "Which binary is under test" is derived, not configured: the model
-- says a binary lands at o/bin/<name>, so that is what TEST_BIN names
-- and what goes first on the child PATH.
local function test_binaries_go_on_the_path()
  local env = require("cosmic.env")
  local saved_path, saved_bin = env.get("PATH"), env.get("TEST_BIN")
  local proj: types.Project = {root = "/p", binaries = {}, files = {}}
  env.set("PATH", "/usr/bin", true)
  stage.binaries_on_path(proj)
  local bin = env.get(stage.BIN_ENV)
  assert(bin == fs.join(project.BUILD_DIR, "bin"),
    "TEST_BIN names the build's bin directory, got: " .. tostring(bin))
  -- `get_or` rather than `get`: this is a read the test cannot survive
  -- being nil, so it says so instead of indexing whatever came back.
  -- The honest return type is what surfaced it; before, this line
  -- type-checked and would have crashed on a PATH-less environment.
  local first = env.get_or("PATH", ""):match("^[^:]+")
  assert(first == stage.bin_dir(proj),
    "the project's binaries come first, got: " .. tostring(first))

  -- Idempotent: `test` and `example` in one `ci` run would otherwise
  -- stack the same entry once per stage.
  local once = env.get("PATH")
  stage.binaries_on_path(proj)
  assert(env.get("PATH") == once, "a second call must not stack the entry")

  env.set("PATH", saved_path, true)
  if saved_bin ~= "" then env.set(stage.BIN_ENV, saved_bin, true) end
end
test_binaries_go_on_the_path()

-- A PATH-less environment must not crash. `get` returns nil, not "",
-- for an unset variable, so the guard has to admit nil -- the concat in
-- the "already present?" branch threw on the very setup a stripped-env
-- CI runner or a minimal container hands the build.
local function test_binaries_on_path_without_a_path()
  local env = require("cosmic.env")
  local saved = env.get("PATH")
  env.unset("PATH")
  local proj: types.Project = {root = "/p", binaries = {}, files = {}}
  stage.binaries_on_path(proj)
  assert(env.get("PATH") == stage.bin_dir(proj),
    "an unset PATH becomes the build's bin dir, got: " ..
    tostring(env.get("PATH")))
  if saved ~= nil then env.set("PATH", saved, true) end
end
test_binaries_on_path_without_a_path()

-- A stage's summary must not survive INTO a run that never reached it.
--
-- `graph_stage` reads the detail for its verdict from
-- `o/<target>-summary.txt`, written by one of the LAST recipes in a
-- stage's own graph. A run whose make dies earlier (a compile error
-- here) never reaches that recipe, and reading whatever the PREVIOUS
-- run left there attributes THIS run's failure to THAT run's counts --
-- named here as "1 of 2", a real prior failure -- rather than saying
-- nothing ran at all. `--make` engine, so this end-to-end (the same
-- pattern build_test.tl and generate_test.tl use); skips rather than
-- fails without one.
local function test_a_dead_stage_does_not_report_a_stale_summary()
  local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN") or "", "cosmic"))
  local make_bin = fs.abspath(os.getenv("COSMIC_MAKE") or "o/make")
  check.needs("the make engine at " .. make_bin, fs.isfile(make_bin))
  local root = fs.join(tmpdir, "stage-stale-summary")
  fs.rmrf(root)
  assert(fs.makedirs(root))
  assert(fs.write(fs.join(root, "mod.tl"), "return {}\n"))
  assert(fs.write(fs.join(root, "a_test.tl"),
      "local m = require('mod')\nassert(m ~= nil)\n"))
  assert(fs.write(fs.join(root, "b_test.tl"),
      "assert(false, 'a real, prior failure')\n"))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))

  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""), "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir, "NO_COLOR=1", "COSMIC_NO_WELCOME=1",
  }
  local h1 = check.must(spawn.spawn({cosmic, "--make", "test"},
      {cwd = root, env = env}))
  local r1 = check.must(h1:wait())
  assert(r1.code ~= 0, "the first run has one genuine failure")
  assert((r1.stdout or ""):find("1 of 2", 1, true),
    "and reports it: " .. tostring(r1.stdout))

  -- Now break `mod`, which a_test imports and b_test does not: a
  -- compile error that blocks a_test's own prerequisite chain, so the
  -- `test` target can never reach ALL its test_got files and dies
  -- before test-summary.txt's recipe runs at all -- the earlier
  -- failure's numbers (from b_test, untouched here) are the only ones
  -- on disk.
  assert(fs.write(fs.join(root, "mod.tl"), "local x: string = 5\nreturn {}\n"))
  local h2 = check.must(spawn.spawn({cosmic, "--make", "test"},
      {cwd = root, env = env}))
  local r2 = check.must(h2:wait())
  assert(r2.code ~= 0, "a broken compile still fails")
  assert(not (r2.stdout or ""):find("1 of 2", 1, true),
    "must not report the PREVIOUS run's stale failure count, got: " ..
    tostring(r2.stdout))
end
test_a_dead_stage_does_not_report_a_stale_summary()

print("all stage tests passed")
