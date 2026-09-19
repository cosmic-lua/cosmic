local Sqlite = require("cosmic.sqlite")
local work = require("build.work")

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.rows(db, "SELECT count(*) FROM " .. table_name))
  return math.tointeger(tonumber(rows[1][1])) as integer
end

local function test_recording_error_rolls_back_every_table(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  assert(handle.db:exec([[CREATE TEMP TRIGGER reject_coverage
    BEFORE INSERT ON coverage BEGIN SELECT RAISE(ABORT, 'injected'); END]]))
  assert(work.begin(handle))
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 1, '', 1, '', 'k', 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 1, 1, 1)"))
  assert(handle.db:exec("INSERT INTO test_runs VALUES (1)"))
  local inserted, trouble = handle.db:exec("INSERT INTO coverage VALUES (1, 'p', 1, 1)")
  assert(not inserted and trouble:find("injected", 1, true) ~= nil)
  assert(work.abort(handle))
  local reopened = assert(Sqlite.open(tmp .. "/o/build.db", false))
  for _, table_name in ipairs({
    "runs", "verdicts", "test_runs", "coverage", "coverage_by_test",
  }) do
    assert(count(reopened, table_name) == 0, table_name .. " must roll back")
  end
  assert(reopened:close())
end

local function test_assertion_failure_records_atomically(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  assert(work.begin(handle))
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 0, 'asserted', 1, '', 'k', 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 0, 1, 1)"))
  assert(handle.db:exec("INSERT INTO test_runs VALUES (1)"))
  assert(handle.db:exec("INSERT INTO coverage VALUES (1, 'p', 1, 1)"))
  assert(work.close(handle))

  local reopened = assert(Sqlite.open(tmp .. "/o/build.db", false))
  assert(count(reopened, "runs") == 1)
  assert(count(reopened, "verdicts") == 1)
  assert(count(reopened, "test_runs") == 1)
  assert(count(reopened, "coverage") == 1)
  assert(reopened:close())
end
