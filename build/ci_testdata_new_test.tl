--- [`build.tree_checks`]'s `ci_testdata` with the new checker ([`build.pipeline`]): a file under `ci/testdata` that does
--- not check is named with its line in the checker's words, as the fork's reading names it
--- (the `ci_testdata` tests of build/tree_checks_test.tl). It needs the declarations of the standard library that the
--- program itself carries, which a policy of the profile "cosmic" gives a worker.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local teal = require("build.teal")
local tree_checks = require("build.tree_checks")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The complaints of `ci_testdata` over a tree of `files` (by their path below `ci/testdata`).
local function told(dir: string, files: {string: string}): string
  local base = dir .. "/tree/ci/testdata"
  for name, text in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(base .. "/" .. name)))
    assert(Fs.write(base .. "/" .. name, text))
  end
  return table.concat(tree_checks.ci_testdata(dir .. "/tree", (assert(teal.load())), "new"), "\n")
end

local function test_a_file_that_does_not_check_is_named_with_its_line_and_the_checkers_words(dir: string)
  local all = told(dir, {
    ["sub/good_test.tl"] = "local function test_x()\n  assert(true)\nend\n",
    ["sub/bad.tl"] = "local x: integer = \"s\"\nreturn x\n",
    ["sub/foreign.tl"] = "local m = require(\"cosmic_ci.nowhere\")\nreturn m\n",
  })
  assert(all:find("ci/testdata/sub/bad.tl:1:", 1, true) ~= nil, all)
  assert(all:find("ci/testdata/sub/foreign.tl", 1, true) ~= nil, all)
  assert(all:find("good_test", 1, true) == nil, all)
  -- the checker's words end a finding with its code and its fix
  assert(all:find("(", 1, true) ~= nil and all:find("): ", 1, true) ~= nil, all)
end

local function test_a_test_module_is_not_refused_for_what_nothing_calls_and_any_other_file_is(dir: string)
  local all = told(dir, {
    ["sub/zz_test.tl"] = "local function test_x()\n  local lonely = 1\n  assert(true)\nend\nlocal function helper() end\n",
    ["sub/label.tl"] = "do\n  local lonely = 1\nend\nreturn 1\n",
    ["sub/loose.tl"] = "local function helper() end\nreturn 1\n",
  })
  assert(all:find("ci/testdata/sub/label.tl:2:", 1, true) ~= nil, all)
  assert(all:find("ci/testdata/sub/loose.tl:1:", 1, true) ~= nil, all)
  assert(all:find("zz_test", 1, true) == nil, all)
end

local function test_a_tree_without_testdata_has_nothing_to_say(dir: string)
  assert(#tree_checks.ci_testdata(dir .. "/nowhere", (assert(teal.load())), "new") == 0)
end

--- What the new checker finds in a file is held to the ceilings of [testdata]: a count at its pin passes, one over is
--- told whole with the pin, and a pin above the count is told to fall.
local function test_findings_are_held_to_the_ceilings_of_the_testdata_stage(dir: string)
  local root = dir .. "/tree"
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/ci/testdata"))
  assert(Fs.write(root .. "/ci/testdata/bad.tl", "local x: integer = \"s\"\nreturn x\n"))
  local function pinned(count: integer): string
    local line = if count > 0 then "ci/testdata/bad.tl not_assignable " .. tostring(count) .. "\n" else "" end
    assert(Fs.write(root .. "/build/ceilings.txt", "[testdata]\n" .. line))
    return table.concat(tree_checks.ci_testdata(root, (assert(teal.load())), "new"), "\n")
  end
  assert(pinned(1) == "", pinned(1))
  local over = pinned(0)
  assert(over:find("ci/testdata/bad.tl:1:", 1, true) ~= nil and
      over:find("1 error of not_assignable in its bodies, pinned 0", 1, true) ~= nil, over)
  local fallen = pinned(3)
  assert(fallen:find("ci/testdata/bad.tl not_assignable: pinned 3 but 1 found; lower the pin in build/ceilings.txt's [testdata]",
    1, true) ~= nil, fallen)
end
