--- What CI's driver (ci/cosmic_ci) holds the tree to, checked by the
--- tree's own suite rather than by the driver's, whose tests of it
--- `ci.yml` skips wherever its marker's key, which hashes none of these
--- sources, found an earlier pass: here each verdict is keyed by the
--- sources it reads, so a change to one runs it again on every leg.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local String = require("cosmic.string")

--- The tree's sources, the variables the driver keeps from a gating
--- suite (ci/cosmic_ci/run_names.tl), and the darwin list.
Test.policy{
  grants = {
    { path = "build/", letters = "r" },
    { path = "cosmic/", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "test/", letters = "r" },
    { path = "eval/", letters = "r" },
    { path = "cmd/", letters = "r" },
    { path = "doc/", letters = "r" },
    { path = "ci/cosmic_ci/run_names.tl", letters = "r" },
    { path = "ci/darwin-tests.txt", letters = "r" },
  },
}

--- The names a gating suite's workers are not given, as
--- ci/cosmic_ci/run_names.tl lists them: data in text Lua reads, since
--- no module of ci/ is the tree's to require.
local record RunNames
  exact: {string}
  prefixes: {string}
  kept: {string}
end

local function run_names(): RunNames
  local chunk = assert(load(assert(Fs.read("ci/cosmic_ci/run_names.tl")), "=run_names", "t", {}))
  return chunk() as RunNames
end

--- Whether `names` says `name` names the run: as cosmic_ci.orchestration's
--- [`names_the_run`], over the same list.
local function names_the_run(names: RunNames, name: string): boolean
  for _, kept in ipairs(names.kept) do
    if name == kept then return false end
  end
  for _, exact in ipairs(names.exact) do
    if name == exact then return true end
  end
  for _, prefix in ipairs(names.prefixes) do
    if String.starts_with(name, prefix) then return true end
  end
  return false
end

--- The files that name a variable a suite forgets, each with the ones
--- it may name, and why: it sets the variable itself, in its own
--- child's environment, or names it only as ci.yml's text, which it
--- reads. Any other such name in them is found as in any other file.
local sets_what_it_reads: {string:{string:boolean}} = {
  ["build/changed_paths_test.tl"] = { GITHUB_OUTPUT = true },
  ["build/commit_verdicts_fixture.tl"] = { GITHUB_OUTPUT = true },
  ["build/commit_verdicts_jq_test.tl"] = { GITHUB_OUTPUT = true },
  ["build/commit_verdicts_test.tl"] = { GITHUB_OUTPUT = true },
  ["build/leg_host_id_test.tl"] = { GITHUB_ENV = true, GITHUB_OUTPUT = true },
  ["build/place_tree_test.tl"] = { GITHUB_SHA = true, GITHUB_WORKSPACE = true,
    GITHUB_EVENT_NAME = true, COSMIC_CI_DECLARED_KEYS = true },
  ["build/queue_seed_jq_test.tl"] = { GITHUB_OUTPUT = true, GITHUB_STEP_SUMMARY = true },
  ["build/queue_seed_test.tl"] = { GITHUB_OUTPUT = true, GITHUB_STEP_SUMMARY = true,
    RUNNER_TEMP = true },
  -- As the platform and checked jobs' env set it, and the workflow's;
  -- RUNNER_TEMP, GITHUB_OUTPUT and GITHUB_ENV as a step's `run` names
  -- them.
  ["build/workflows_test.tl"] = { COSMIC_CI_DECLARED_KEYS = true, COSMIC_CI_SAVES = true,
    COSMIC_CI_SCOPE = true, COSMIC_CI_CHECKED_SUITE = true, COSMIC_CI_FORMAT = true, COSMIC_CI_EVENT = true,
    COSMIC_CI_BASE_SHA = true, COSMIC_CI_FORMAT_CHANGED = true, COSMIC_CI_SHARD = true,
    COSMIC_CI_PORTABLE_SUITE = true,
    GITHUB_OUTPUT = true, GITHUB_ENV = true,
    RUNNER_TEMP = true },
}

--- The names of variables a suite forgets that `text`, a source,
--- names, less `allowed`.
local function forgotten(names: RunNames, text: string, allowed: {string:boolean}): {string}
  local found: {string} = {}
  local seen: {string:boolean} = {}
  for name in text:gmatch("[%u%d_]+") do
    -- CI is a word of prose too often to tell a read of it.
    if name ~= "CI" and not seen[name] and not allowed[name] and names_the_run(names, name) then
      found[#found + 1] = name
    end
    seen[name] = true
  end
  return found
end

--- A read of a variable the driver forgets is found, and a read of one
--- it keeps, or of prose's CI, is not.
local function test_a_read_of_a_forgotten_variable_is_found()
  local names = run_names()
  local found = forgotten(names, 'Env.get("GITHUB_SHA") RUNNER_TEMP COSMIC_CI_REQUIRE_SANDBOX CI HOSTNAME HOME',
    {})
  assert(table.concat(found, ",") == "GITHUB_SHA,RUNNER_TEMP,HOSTNAME", table.concat(found, ","))
  assert(#forgotten(names, "GITHUB_SHA", { GITHUB_SHA = true }) == 0)
end

--- No tree source names a variable a gating suite's workers are not
--- given (cosmic_ci.orchestration's `forget_run`) but one that sets it
--- itself (`sets_what_it_reads`): a test that read one would find it
--- unset in CI. A new one is kept out of ci/cosmic_ci/run_names.tl or
--- set by the test. This module, which names them only as what it
--- checks for, is left out.
local function test_no_tree_source_reads_what_a_suite_forgets()
  local names = run_names()
  local found: {string} = {}
  for _, dir in ipairs({ "build", "cosmic", "core", "test", "eval", "cmd", "doc" }) do
    for _, path in ipairs((assert(Fs.walk(dir)))) do
      local relative = dir .. "/" .. path
      if relative ~= "build/ci_tree_test.tl" and relative:match("%.tl$") or relative:match("%.lua$") or relative:match("%.[ch]$") then
        for _, name in ipairs(forgotten(names, (assert(Fs.read(relative))), sets_what_it_reads[relative] or {})) do
          found[#found + 1] = relative .. ": " .. name
        end
      end
    end
  end
  assert(#found == 0, "a tree source names a variable a suite forgets: " .. table.concat(found, ", "))
end

--- ci/darwin-tests.txt names test modules of the tree, each once: a
--- module renamed or removed fails here rather than dropping out of the
--- macOS leg's darwin suite, whose `cosmic test` would refuse to run a
--- selector that chooses nothing only on macOS. The list is read as
--- cosmic_ci.orchestration's `darwin_modules` reads it: one path a
--- line, with what a `#` starts and blank lines left out.
local function test_the_darwin_list_names_test_modules_of_the_tree()
  local modules: {string} = {}
  for line in (assert(Fs.read("ci/darwin-tests.txt"))):gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then modules[#modules + 1] = path end
  end
  assert(#modules > 0, "the darwin list names no module")
  local seen: {string:boolean} = {}
  for _, module in ipairs(modules) do
    assert(not seen[module], module .. ": listed twice")
    seen[module] = true
    assert(module:match("^[%w_/]+_test%.tl$"), module .. ": not a test module's path")
    local st = Fs.stat(module)
    assert(st ~= nil and st.kind == "file", module .. ": no such test module")
  end
end
