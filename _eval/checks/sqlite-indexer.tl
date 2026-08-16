--- Functional check for the sqlite-indexer task
--- (_eval/tasks/sqlite-indexer.md): exercises the built `o/bin/findex`
--- against a pinned copy of the brief's fixture tree, asserting exact
--- lookup/dupes output -- including the S-trap (a doubled relative
--- path, exactly what a wrong join of the walk visitor's full-path
--- argument with its basename produces, must be refused).
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/findex"

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()

  local files: {{string, string}} = {
    {"testdata/tree/a.txt", "alpha\n"},
    {"testdata/tree/sub/b.txt", "beta\n"},
    {"testdata/tree/sub/deep/c.txt", "alpha\n"},
  }
  for _, f in ipairs(files) do
    local ok, err = support.write_fixture(workspace, f[1], f[2])
    if not ok then
      support.fail(acc, "could not write fixture " .. f[1] .. ": " .. tostring(err))
      return support.result(acc)
    end
  end

  local res, err = support.run(workspace, BIN, {"index", "testdata/tree", "o/index.db"})
  support.expect_exit(acc, "index testdata/tree", res, err, true)

  res, err = support.run(workspace, BIN, {"lookup", "o/index.db", "a.txt"})
  if support.expect_exit(acc, "lookup a.txt", res, err, true) then
    support.expect_stdout(acc, "lookup a.txt", res,
      "6 b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060\n")
  end

  res, err = support.run(workspace, BIN, {"lookup", "o/index.db", "sub/b.txt"})
  if support.expect_exit(acc, "lookup sub/b.txt", res, err, true) then
    support.expect_stdout(acc, "lookup sub/b.txt", res,
      "5 f2c82decdd7181cf98945929a62598db7e6b477e11f6e0eb0ae97020eff151ad\n")
  end

  res, err = support.run(workspace, BIN, {"lookup", "o/index.db", "sub/deep/c.txt"})
  support.expect_exit(acc, "lookup sub/deep/c.txt", res, err, true)

  -- S-trap: the doubled path a wrong walk-visitor join produces.
  res, err = support.run(workspace, BIN, {"lookup", "o/index.db", "sub/b.txt/b.txt"})
  support.expect_exit(acc, "lookup sub/b.txt/b.txt (doubled)", res, err, false)

  res, err = support.run(workspace, BIN, {"dupes", "o/index.db"})
  if support.expect_exit(acc, "dupes", res, err, true) then
    support.expect_stdout(acc, "dupes", res, "a.txt sub/deep/c.txt\n")
  end

  res, err = support.run(workspace, BIN, {"lookup", "o/index.db", "nope.txt"})
  if support.expect_exit(acc, "lookup nope.txt", res, err, false) then
    support.expect_empty_stdout(acc, "lookup nope.txt", res)
    support.expect_nonempty_stderr(acc, "lookup nope.txt", res)
  end

  support.expect_test_file_present(acc, workspace)

  return support.result(acc)
end

local record sqlite_indexer_check
  check: function(workspace: string): integer, {string}
end

local M: sqlite_indexer_check = {
  check = check,
}

return M
