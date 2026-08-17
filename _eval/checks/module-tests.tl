--- Functional check for the module-tests task
--- (_eval/tasks/module-tests.md): the slug module's shape (slug.tl,
--- slug_test.tl with >=5 test_* functions, cmd/slug/main.tl requiring
--- the module rather than reimplementing it) plus the built
--- `o/bin/slug`'s exact outputs on the brief's own example inputs.
local fs = require("cosmic.fs")
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/slug"

--- Count `test_*` function definitions in slug_test.tl's source.
--- @param src string slug_test.tl's contents
--- @return integer The number of distinct test_* functions found
local function count_test_functions(src: string): integer
  local n = 0
  for _ in src:gmatch("function%s+test_[%w_]+") do
    n = n + 1
  end
  return n
end

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  if not fs.is_file(fs.join(workspace, "slug.tl")) then
    support.fail(acc, "workspace is missing slug.tl")
  end
  local test_src = fs.read(fs.join(workspace, "slug_test.tl"))
  if not test_src then
    support.fail(acc, "workspace is missing slug_test.tl")
  elseif count_test_functions(test_src) < 5 then
    support.fail(acc, "slug_test.tl defines fewer than 5 test_* functions")
  end

  local main_src = fs.read(fs.join(workspace, "cmd/slug/main.tl"))
  if not main_src then
    support.fail(acc, "workspace is missing cmd/slug/main.tl")
  elseif not main_src:find('require("slug")', 1, true) then
    support.fail(acc, 'cmd/slug/main.tl does not require("slug")')
  end

  local res, err = support.run(workspace, BIN, {"Hello, World!"})
  if support.expect_exit(acc, "slug 'Hello, World!'", res, err, true) then
    support.expect_stdout(acc, "slug 'Hello, World!'", res, "hello-world\n")
  end

  res, err = support.run(workspace, BIN, {"  --Multi--  Space__Test  "})
  if support.expect_exit(acc, "slug multi-space", res, err, true) then
    support.expect_stdout(acc, "slug multi-space", res, "multi-space-test\n")
  end

  -- All-punctuation input has no letters/digits, so the slug (and the
  -- printed line) is empty.
  res, err = support.run(workspace, BIN, {"!!!"})
  if support.expect_exit(acc, "slug '!!!'", res, err, true) then
    support.expect_stdout(acc, "slug '!!!'", res, "\n")
  end

  support.expect_test_file_present(acc, workspace)

  return support.result(acc)
end

local record module_tests_check
  check: function(workspace: string): integer, {string}
end

local M: module_tests_check = {
  check = check,
}

return M
