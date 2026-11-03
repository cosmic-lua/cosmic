--- [`build.tree_checks`]'s `ci_testdata` with the new checker ([`build.pipeline`]): a file under `ci/testdata` that does
--- not check is named with its line in the checker's words. It needs the declarations of the standard library that the
--- program itself carries, which a policy of the profile "cosmic" gives a worker.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local tree_checks = require("build.tree_checks")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The complaints of `ci_testdata` over a tree of `files` (by their path below `ci/testdata`).
local function told(dir: string, files: {string: string}): string
  local base = dir .. "/tree/ci/testdata"
  for name, text in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(base .. "/" .. name)))
    assert(Fs.write(base .. "/" .. name, text))
  end
  return table.concat(tree_checks.ci_testdata(dir .. "/tree"), "\n")
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
  assert(#tree_checks.ci_testdata(dir .. "/nowhere") == 0)
end

--- Every finding of the new checker in a file under ci/testdata is told: no marker holds one, so a new finding fails.
local function test_a_finding_is_told_though_its_line_carries_a_marker(dir: string)
  local root = dir .. "/tree"
  assert(Fs.mkdirs(root .. "/ci/testdata"))
  assert(Fs.write(root .. "/ci/testdata/bad.tl", "local x: integer = \"s\"\nreturn x\n"))
  local bare = table.concat(tree_checks.ci_testdata(root), "\n")
  assert(bare:find("ci/testdata/bad.tl:1:", 1, true) ~= nil and
      bare:find("1 error of not_assignable in its bodies on line 1; follow the fix above", 1, true) ~= nil, bare)
  -- a marker on the line holds nothing
  assert(Fs.write(root .. "/ci/testdata/bad.tl", "local x: integer = \"s\" -- checked: not_assignable\nreturn x\n"))
  local marked = table.concat(tree_checks.ci_testdata(root), "\n")
  assert(marked == bare, marked)
end
