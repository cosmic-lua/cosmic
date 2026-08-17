--- Functional check for the multi-module-build task
--- (_eval/tasks/multi-module-build.md): the textstat/ import chain's
--- shape (three modules, each requiring the previous, each with a
--- sibling *_test.tl) plus the built `o/bin/wordbag`'s exact output on
--- the brief's own fixture, including the count-then-alphabetical tie
--- break among count-1 words.
local fs = require("cosmic.fs")
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/wordbag"

local SAMPLE_TXT < const > = table.concat({
    "the quick brown fox jumps over the lazy dog",
    "the dog barks",
  }, "\n") .. "\n"

local WANT_REPORT < const > = table.concat({
    "the 3",
    "dog 2",
    "barks 1",
    "unique 9",
  }, "\n") .. "\n"

--- Assert one module file and its sibling *_test.tl both exist.
--- @param acc support.Acc The findings accumulator
--- @param workspace string Absolute path to the task's workspace
--- @param module_rel string Module path, e.g. "textstat/tokenize.tl"
local function expect_module_with_test(acc: support.Acc, workspace: string,
    module_rel: string)
  if not fs.is_file(fs.join(workspace, module_rel)) then
    support.fail(acc, "workspace is missing " .. module_rel)
  end
  local test_rel = (module_rel:gsub("%.tl$", "_test.tl"))
  if not fs.is_file(fs.join(workspace, test_rel)) then
    support.fail(acc, "workspace is missing " .. test_rel)
  end
end

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  expect_module_with_test(acc, workspace, "textstat/tokenize.tl")
  expect_module_with_test(acc, workspace, "textstat/count.tl")
  expect_module_with_test(acc, workspace, "textstat/report.tl")

  local count_src = fs.read(fs.join(workspace, "textstat/count.tl"))
  if count_src and not count_src:find('require("textstat.tokenize")', 1, true) then
    support.fail(acc, 'textstat/count.tl does not require("textstat.tokenize")')
  end
  local report_src = fs.read(fs.join(workspace, "textstat/report.tl"))
  if report_src and not report_src:find('require("textstat.count")', 1, true) then
    support.fail(acc, 'textstat/report.tl does not require("textstat.count")')
  end
  local main_src = fs.read(fs.join(workspace, "cmd/wordbag/main.tl"))
  if not main_src then
    support.fail(acc, "workspace is missing cmd/wordbag/main.tl")
  elseif not main_src:find('require("textstat.report")', 1, true) then
    support.fail(acc, 'cmd/wordbag/main.tl does not require("textstat.report")')
  end

  local wok, werr = support.write_fixture(workspace, "testdata/sample.txt", SAMPLE_TXT)
  if not wok then
    support.fail(acc, "could not write fixture testdata/sample.txt: " .. tostring(werr))
    return support.result(acc)
  end

  -- S-trap-adjacent: ties among count-1 words break alphabetically, so
  -- "barks" (count 1) must beat "brown" (also count 1) into the top 3.
  local res, err = support.run(workspace, BIN, {"testdata/sample.txt"})
  if support.expect_exit(acc, "wordbag sample.txt", res, err, true) then
    support.expect_stdout(acc, "wordbag sample.txt", res, WANT_REPORT)
  end

  support.expect_test_file_present(acc, workspace)

  return support.result(acc)
end

local record multi_module_build_check
  check: function(workspace: string): integer, {string}
end

local M: multi_module_build_check = {
  check = check,
}

return M
