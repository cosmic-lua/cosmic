local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local work = require("build.work")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  return math.tointeger(tonumber(rows[1][1])) as integer
end

local function test_recording_error_rolls_back_every_table(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  assert(handle.db:exec([[CREATE TEMP TRIGGER reject_coverage
    BEFORE INSERT ON coverage BEGIN SELECT RAISE(ABORT, 'injected'); END]]))
  assert(work.begin(handle))
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 1, '', 1, '', 'k', 1, 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 1, 1, 1, 1)"))
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
  assert(handle.db:exec("INSERT INTO runs VALUES ('p', 't', 0, 'asserted', 1, '', 'k', 1, 1)"))
  assert(handle.db:exec("INSERT INTO verdicts VALUES ('k', 0, 1, 1, 1)"))
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

--- A warm database from the previous symbol schema is recreated before any
--- cached parse or reference row can be trusted under the new semantics.
local function test_symbol_schema_upgrade_discards_old_analysis(tmp: string)
  local old = assert(work.open(tmp))
  assert(work.commit(old))
  assert(Sqlite.run(old.db,
    "UPDATE meta SET value = '13' WHERE key = 'schema'"))
  assert(Sqlite.run(old.db,
    "INSERT INTO parsed (source_hash, has_return, export) VALUES ('old', 1, 'Old')"))
  assert(Sqlite.run(old.db,
    "INSERT INTO refs (source_hash, ordinal, module, member, line) " ..
    "VALUES ('old', 1, 'cosmic.fs', 'read', 1)"))
  assert(old.db:close())

  local upgraded = assert(work.open(tmp))
  assert(count(upgraded.db, "parsed") == 0)
  assert(count(upgraded.db, "refs") == 0)
  local columns = assert(Sqlite.text_rows(upgraded.db, "PRAGMA table_info(docs)"))
  local names: {string: boolean} = {}
  for _, row in ipairs(columns) do names[row[2]] = true end
  assert(names["source_symbol"] and names["exported"])
  assert(work.close(upgraded))
end

--- A second process building the same tree waits for the first's
--- transaction instead of failing with "database is locked": two builds
--- of one tree at once, from two terminals or two parallel tests, both
--- finish.
local function test_a_second_build_of_a_tree_waits_for_the_first(tmp: string)
  assert(Fs.write(tmp .. "/main.tl", "return function(): integer return 0 end\n"))
  local held = assert(work.open(tmp))
  local output = tmp .. "/second.out"
  local fd = assert(Fs.open_write(output))
  local second, trouble = Child.start({ assert(Proc.executable()), "main.tl" },
    { cwd = tmp, env = Env.all(), stdout = fd, stderr = fd })
  assert(Fs.close(fd))
  assert(second, trouble)
  assert(Time.sleep_ns(300000000))
  assert(work.abort(held))
  local result = assert(second:wait(60000))
  assert(result.ok, "the second build failed: " .. (Fs.read(output) or ""))
end

--- The bytes `files` holds for one staged path.
local function staged_bytes(db: Sqlite.Handle, path: string): string
  local rows = assert(Sqlite.text_rows(db,
    "SELECT CAST(data AS TEXT) FROM files WHERE path = ?1", { { text = path } }))
  return rows[1][1]
end

--- A file staged within the settle window is read again next time even
--- when a same-size rewrite in place then stamps it with the epoch, a
--- time a tool normalizing times writes: an unsettled row's time must
--- not match any stat, the epoch's included.
local function test_an_unsettled_row_is_read_again_at_the_epoch(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.write(path, "return 1\n"))
  -- An hour ahead, so it is unsettled however long staging takes.
  assert(Fs.set_mtime(path, Time.now_ns() // 1000000000 + 3600, 0))
  local handle = assert(work.open(tmp))
  assert(work.stage(handle, false))
  assert(staged_bytes(handle.db, "probe.tl") == "return 1\n")
  local unsettled = assert(Sqlite.text_rows(handle.db,
    "SELECT mtime_ns IS NULL FROM files WHERE path = 'probe.tl'"))
  assert(unsettled[1][1] == "1", "the first stage must leave the row unsettled")
  local before = assert(Fs.stat(path))

  local fd = assert(Fs.open_write(path))
  assert(Fs.put(fd, "return 2\n"))
  assert(Fs.close(fd))
  assert(Fs.set_mtime(path, 0, 0))
  local after = assert(Fs.stat(path))
  assert(after.ino == before.ino and after.size == before.size)

  local staged = assert(work.stage(handle, false))
  assert(staged.read == 1, "an unsettled row must count as moved")
  assert(staged_bytes(handle.db, "probe.tl") == "return 2\n")
  assert(work.close(handle))
end

--- A file whose time is the epoch has settled, and its row is trusted:
--- staging it again reads nothing.
local function test_a_settled_epoch_time_is_trusted(tmp: string)
  local path = tmp .. "/probe.tl"
  assert(Fs.write(path, "return 1\n"))
  assert(Fs.set_mtime(path, 0, 0))
  local handle = assert(work.open(tmp))
  local first = assert(work.stage(handle, false))
  assert(first.read == 1)
  local second = assert(work.stage(handle, false))
  assert(second.read == 0, "a settled epoch row must stand")
  assert(work.close(handle))
end
