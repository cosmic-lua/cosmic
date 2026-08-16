--- Functional check for the json-cli task (_eval/tasks/json-cli.md):
--- exercises the built `o/bin/jstat` against a pinned copy of the
--- brief's fixture, asserting the Acceptance facts' exact
--- outputs/exit codes -- including the two S-traps (a zero-count
--- record must still appear; summary must print a single clean line).
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/jstat"

local ITEMS_JSON < const > = [[
[
  {"name": "alpha", "kind": "fruit", "count": 3},
  {"name": "beta", "kind": "veg", "count": 5},
  {"name": "gamma", "kind": "fruit", "count": 2},
  {"name": "delta", "kind": "veg", "count": 0}
]
]]

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  local wok, werr = support.write_fixture(workspace, "testdata/items.json", ITEMS_JSON)
  if not wok then
    support.fail(acc, "could not write fixture testdata/items.json: " .. tostring(werr))
    return support.result(acc)
  end
  local bok, berr = support.write_fixture(workspace, "bad.json", "{nope")
  if not bok then
    support.fail(acc, "could not write fixture bad.json: " .. tostring(berr))
    return support.result(acc)
  end

  local res, err = support.run(workspace, BIN, {"list", "testdata/items.json"})
  if support.expect_exit(acc, "list items.json", res, err, true) then
    support.expect_stdout(acc, "list items.json", res, "alpha\nbeta\ngamma\ndelta\n")
  end

  res, err = support.run(workspace, BIN, {"filter", "testdata/items.json", "fruit"})
  if support.expect_exit(acc, "filter fruit", res, err, true) then
    support.expect_stdout(acc, "filter fruit", res, "alpha\ngamma\n")
  end

  -- S-trap: delta has count 0 and must still appear in the veg filter.
  res, err = support.run(workspace, BIN, {"filter", "testdata/items.json", "veg"})
  if support.expect_exit(acc, "filter veg", res, err, true) then
    support.expect_stdout(acc, "filter veg", res, "beta\ndelta\n")
  end

  -- S-trap: the total must include delta's 0, and the line must be
  -- exactly one line -- a multi-return printed raw would trail a nil.
  res, err = support.run(workspace, BIN, {"summary", "testdata/items.json"})
  if support.expect_exit(acc, "summary items.json", res, err, true) then
    support.expect_stdout(acc, "summary items.json", res, "items=4 total=10 kinds=2\n")
  end

  res, err = support.run(workspace, BIN, {"summary", "testdata/missing.json"})
  if support.expect_exit(acc, "summary missing.json", res, err, false) then
    support.expect_empty_stdout(acc, "summary missing.json", res)
    support.expect_stderr_contains(acc, "summary missing.json", res, "testdata/missing.json")
  end

  res, err = support.run(workspace, BIN, {"list", "bad.json"})
  if support.expect_exit(acc, "list bad.json", res, err, false) then
    support.expect_empty_stdout(acc, "list bad.json", res)
    support.expect_nonempty_stderr(acc, "list bad.json", res)
  end

  support.expect_test_file_present(acc, workspace)

  return support.result(acc)
end

local record json_cli_check
  check: function(workspace: string): integer, {string}
end

local M: json_cli_check = {
  check = check,
}

return M
