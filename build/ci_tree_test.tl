--- What CI's driver (ci/cosmic_ci) holds the tree to, checked by the
--- tree's own suite rather than by the driver's, whose tests of it
--- `ci.yml` skips wherever its marker's key, which hashes none of these
--- sources, found an earlier pass: here each verdict is keyed by the
--- sources it reads, so a change to one runs it again on every leg.
local Ceilings = require("build.ceilings")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Test = require("cosmic.test")
local String = require("cosmic.string")

--- The tree's sources, the variables the driver keeps from a gating
--- suite (ci/cosmic_ci/run_names.json), and the darwin list.
Test.policy{
  grants = {
    { path = "build/", letters = "r" },
    { path = "cosmic/", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "test/", letters = "r" },
    { path = "eval/", letters = "r" },
    { path = "cmd/", letters = "r" },
    { path = "doc/", letters = "r" },
    { path = "ci/cosmic_ci/run_names.json", letters = "r" },
    { path = "ci/darwin-tests.txt", letters = "r" },
    { path = "ci/strict-files.txt", letters = "r" },
    { path = "ci/bootstrap-files.txt", letters = "r" },
    { path = "ci/run_local.tl", letters = "r" },
    { path = "ci/run_local_proof.tl", letters = "r" },
    { path = "ci/cosmic_ci/runtime_setup.tl", letters = "r" },
    { path = "ci/testdata/portable/", letters = "r" },
  },
}

--- The names a gating suite's workers are not given, as
--- ci/cosmic_ci/run_names.json lists them: JSON, since no module of ci/
--- is the tree's to require.
local record RunNames
  exact: {string}
  prefixes: {string}
  kept: {string}
end

local RUN_NAMES <const> = Shape.record_of("RunNames")

local function run_names(): RunNames
  local names, why = RUN_NAMES:decode_into((assert(Fs.read("ci/cosmic_ci/run_names.json"))))
  assert(names ~= nil, why)
  return names
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
  -- As the platform and checked jobs' env (the shares', the format job's) set it, and the workflow's;
  -- RUNNER_TEMP, GITHUB_OUTPUT and GITHUB_ENV as a step's `run` names
  -- them.
  ["build/workflows_test.tl"] = { COSMIC_CI_DECLARED_KEYS = true, COSMIC_CI_SAVES = true,
    COSMIC_CI_SCOPE = true, COSMIC_CI_CHECKED_SUITE = true, COSMIC_CI_FORMAT = true, COSMIC_CI_EVENT = true,
    COSMIC_CI_BASE_SHA = true, COSMIC_CI_FORMAT_CHANGED = true, COSMIC_CI_SHARD = true,
    COSMIC_CI_CHECKED_SHARD = true, COSMIC_CI_CHECK_MEMO = true, COSMIC_CI_PORTABLE_SUITE = true,
    GITHUB_OUTPUT = true, GITHUB_ENV = true,
    RUNNER_TEMP = true },
  -- The check that the ceilings only fall reads the run's own variables, in the tool's `fix --check` and not in a suite's
  -- worker; its test gives them to the check as a table.
  ["build/ceilings_base.tl"] = { COSMIC_CEILINGS_BASE = true, COSMIC_CI_BASE_SHA = true, COSMIC_CI_EVENT = true, GITHUB_EVENT_NAME = true,
    GITHUB_REF = true, GITHUB_ACTIONS = true },
  ["build/ceilings_base_test.tl"] = { COSMIC_CEILINGS_BASE = true, COSMIC_CI_BASE_SHA = true, COSMIC_CI_EVENT = true, GITHUB_EVENT_NAME = true,
    GITHUB_REF = true, GITHUB_ACTIONS = true },
  -- Names GITHUB_OUTPUT as the file it gives the script it runs, as a step's environment does.
  ["build/branch_scope_test.tl"] = { GITHUB_OUTPUT = true },
}

--- The names of variables a suite forgets that `text`, a source,
--- names, less `allowed`.
local function forgotten(names: RunNames, text: string, allowed: {string:boolean}): {string}
  local found: mut {string} = {}
  local seen: mut {string:boolean} = {}
  for name in text:gmatch("[%u%d_]+") do
    -- CI is a word of prose too often to tell a read of it.
    if name ~= "CI" and seen[name] ~= true and allowed[name] ~= true and names_the_run(names, name) then
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
--- unset in CI. A new one is kept out of ci/cosmic_ci/run_names.json or
--- set by the test. This module, which names them only as what it
--- checks for, is left out.
local function test_no_tree_source_reads_what_a_suite_forgets()
  local names = run_names()
  local found: mut {string} = {}
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
  local modules: mut {string} = {}
  for line in (assert(Fs.read("ci/darwin-tests.txt"))):gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then modules[#modules + 1] = path end
  end
  assert(#modules > 0, "the darwin list names no module")
  local seen: mut {string:boolean} = {}
  for _, module in ipairs(modules) do
    assert(seen[module] ~= true, module .. ": listed twice")
    seen[module] = true
    assert(module:match("^[%w_/]+_test%.tl$"), module .. ": not a test module's path")
    local st = Fs.stat(module)
    assert(st ~= nil and st.kind == "file", module .. ": no such test module")
  end
end

--- ci/strict-files.txt lists the files the running product compiles at run time with no ceiling to stand on. `fix --check .`
--- passes a file with a pin; the product's run of it stops at the first finding, so a file there has no pin in any stage
--- of build/ceilings.txt.
local function strict_files(): {string}
  local files: mut {string} = {}
  for line in (assert(Fs.read("ci/strict-files.txt"))):gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then files[#files + 1] = path end
  end
  return files
end

local function test_a_file_run_without_ceilings_has_none_pinned()
  local files = strict_files()
  assert(#files > 0, "the list of files run without ceilings names none")
  local pinned = assert(Ceilings.read("."))
  local seen: mut {string:boolean} = {}
  for _, file in ipairs(files) do
    assert(seen[file] ~= true, file .. ": listed twice")
    seen[file] = true
    local st = Fs.stat(file)
    assert(st ~= nil and st.kind == "file", file .. ": no such file")
    for stage, keys in pairs(pinned.stages) do
      for key, count in pairs(keys) do
        assert(key ~= file and key:sub(1, #file + 1) ~= file .. " ",
          file .. " is compiled by the running product without ceilings, so it has none: [" .. stage .. "] pins " ..
            tostring(count) .. " (" .. key .. "); fix the finding rather than raise the pin")
      end
    end
  end
end

--- The files test/portable/probe.tl reaches in the tree ci/cosmic_ci/runtime_setup.tl packs for it: `require` by a literal
--- name through the tree's modules, the module [`build.artifact`] replaced by the row of ci/testdata/portable that stands for it.
local function test_the_files_the_portable_probe_reaches_are_listed()
  local listed: mut {string:boolean} = {}
  for _, file in ipairs(strict_files()) do listed[file] = true end
  local seen: mut {string:boolean} = {}
  local function visit(file: string)
    if seen[file] == true then return end
    seen[file] = true
    local shown = if file == "build/artifact.tl" then "ci/testdata/portable/artifact_row.tl" else file end
    assert(listed[shown], shown .. " is reached by test/portable/probe.tl and is not in ci/strict-files.txt")
    for name in (assert(Fs.read(shown))):gmatch('require%(%s*"([%w_%.]+)"%s*%)') do
      if name:sub(1, 7) ~= "cosmic." then
        local base = name:gsub("%.", "/")
        for _, candidate in ipairs({ base .. ".tl", base .. "/init.tl" }) do
          local st = Fs.stat(candidate)
          if st ~= nil then
            visit(candidate)
            break
          end
        end
      end
    end
  end
  visit("test/portable/probe.tl")
  assert(seen["build/artifact.tl"] == true, "the probe no longer reaches build.artifact: update this test and the list")
end

--- Every `.tl` file under `directory` (a directory of the checkout) is listed in ci/strict-files.txt, `why` saying what
--- runs it: the guard walks the directory, so a file added there cannot be left off the list.
local function assert_directory_listed(directory: string, why: string)
  local listed: mut {string:boolean} = {}
  for _, file in ipairs(strict_files()) do listed[file] = true end
  local names = assert(Fs.walk(directory))
  local count = 0
  for _, name in ipairs(names) do
    if name:match("%.tl$") then
      count = count + 1
      assert(listed[directory .. "/" .. name], directory .. "/" .. name .. " is not in ci/strict-files.txt (" .. why .. ")")
    end
  end
  assert(count > 0, directory .. " holds no Teal file: update this test and the list")
end

--- A script of test/terminal is run by the product from ci/fixtures/self_driven_test.tl.
local function test_every_script_of_the_terminal_directory_is_listed()
  assert_directory_listed("test/terminal", "run by path from ci/fixtures/self_driven_test.tl")
end

--- The portable fixtures' sources, the `cmd/*/main.tl` programs among them, are the product's to compile.
local function test_every_portable_fixture_source_is_listed()
  assert_directory_listed("ci/testdata/portable", "a portable fixture's source")
end

--- The helper the fixtures run by path from the checkout has no pin, and is listed to keep it so.
local function test_the_portable_tool_is_listed()
  local listed: mut {string:boolean} = {}
  for _, file in ipairs(strict_files()) do listed[file] = true end
  assert(listed["test/portable/tool.tl"], "test/portable/tool.tl is not in ci/strict-files.txt")
end

--- The strings of `path` that `pattern` captures, from `opening` to the `}` that closes the list: the lists are
--- ci/cosmic_ci's, which no module of build/ may require, so they are read as text.
local function strings_of(path: string, opening: string, pattern: string): {string}
  local text = (assert(Fs.read(path)))
  local from = assert(text:find(opening, 1, true), path .. " no longer has " .. opening)
  local to = assert(text:find("}", from, true))
  local out: mut {string} = {}
  for found in text:sub(from, to):gmatch(pattern) do out[#out + 1] = found end
  return out
end

--- Every file ci/bootstrap-files.txt lists is listed in ci/strict-files.txt too: the pinned release runs it with no
--- ceiling. (`check-islands` holds the same list to the checkout and to build/zig.tl's runs; this is the half the
--- tree's own suite, which CI and a local `bin/cosmic test` both run, can hold.)
local function test_every_file_the_bootstrap_may_run_is_listed_as_strict()
  local listed: mut {string:boolean} = {}
  for _, file in ipairs(strict_files()) do listed[file] = true end
  local count = 0
  -- The reader of the list, copied from ci/cosmic_ci/bootstrap_list.tl (`paths`), which build/ cannot require, and the
  -- same as bin/cosmic-bootstrap's sed: one path a line, what a `#` starts dropped, white space trimmed.
  for line in (assert(Fs.read("ci/bootstrap-files.txt"))):gmatch("[^\n]+") do
    local file = String.trim((line:gsub("#.*$", "")))
    if file ~= "" then
      count = count + 1
      assert(listed[file], file .. " is in ci/bootstrap-files.txt and not in ci/strict-files.txt")
    end
  end
  assert(count > 0, "ci/bootstrap-files.txt lists no file")
end

--- The file that stands for a module of the tree in the probe's packed tree (`RuntimeSetup.artifact_row`) is listed.
local function test_the_file_standing_for_a_packed_module_is_listed()
  local listed: mut {string:boolean} = {}
  for _, file in ipairs(strict_files()) do listed[file] = true end
  local stand_ins = strings_of("ci/cosmic_ci/runtime_setup.tl", "RuntimeSetup.artifact_row = {", '= "([^"]+)"')
  assert(#stand_ins > 0, "RuntimeSetup.artifact_row names no file")
  for _, file in ipairs(stand_ins) do
    assert(listed[file], file .. " stands for a module in RuntimeSetup.artifact_row and is not in ci/strict-files.txt")
  end
end
