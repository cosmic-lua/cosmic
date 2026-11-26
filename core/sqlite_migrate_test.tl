--- [`Sqlite.Handle.migrate`] brings a schema up to date one step a
--- version, in one transaction, and refuses a database it did not make.

local Failure = require("cosmic.failure")
local Sqlite = require("cosmic.sqlite")

--- The one text cell `sql` returns on `db`.
local function answer(db: Sqlite.Handle, sql: string): string
  return assert(assert(db:rows(sql))[1]):as_text(1) or ""
end

local FIRST <const> = "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"
local SECOND <const> = "ALTER TABLE notes ADD COLUMN made INTEGER; CREATE INDEX notes_made ON notes (made)"
local STEPS <const>: {Sqlite.Migration} = { FIRST, SECOND }

--- The version `db:migrate(steps)` returns, which must be one.
local function migrated(db: Sqlite.Handle, steps: {Sqlite.Migration}): integer
  local version, why = db:migrate(steps)
  assert(version ~= nil, tostring(why))
  return version
end

local function test_steps_run_once_each_in_order(tmp: string)
  local path = tmp .. "/m.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(migrated(db, { FIRST }) == 1)
  assert(answer(db, "PRAGMA user_version") == "1")
  assert(db:run("INSERT INTO notes (body) VALUES ('kept')"))
  assert(db:close())
  local again = assert(Sqlite.open(path, { writable = true }))
  local ran = 0
  local steps: {Sqlite.Migration} = { FIRST, SECOND, function(h: Sqlite.Handle): (true) | (false, Failure)
    ran = ran + 1
    return h:run("UPDATE notes SET made = 7")
  end }
  assert(migrated(again, steps) == 3)
  assert(migrated(again, steps) == 3)
  assert(ran == 1, tostring(ran))
  assert(answer(again, "SELECT body || made FROM notes") == "kept7")
  assert(answer(again, "PRAGMA user_version") == "3")
  assert(again:close())
  -- A read-only handle at the version reads it and writes nothing.
  local reader = assert(Sqlite.open(path))
  assert(migrated(reader, steps) == 3)
  assert(reader:close())
end

--- A step that fails leaves the database as it was, and says which step.
local function test_a_failing_step_changes_nothing()
  local db = assert(Sqlite.memory())
  local version, why = db:migrate({ FIRST, "ALTER TABLE nowhere ADD COLUMN x" })
  assert(version == nil and tostring(why):find("step 2: ", 1, true) ~= nil, tostring(why))
  assert(tostring(why):find("no such table", 1, true) ~= nil, tostring(why))
  assert(assert(why).code == Sqlite.ERROR, tostring(why))
  assert(answer(db, "PRAGMA user_version") == "0")
  assert(answer(db, "SELECT count(*) FROM sqlite_schema") == "0")
  local said, said_why = db:migrate({ function(_: Sqlite.Handle): (true) | (false, Failure)
    return false, Failure.new("not today")
  end })
  assert(said == nil and tostring(said_why):find("step 1: not today", 1, true) ~= nil, tostring(said_why))
  local called, raised = pcall(function()
    local _, _ = db:migrate({ FIRST, function(_: Sqlite.Handle): (true) | (false, Failure)
      error("boom", 0)
    end })
  end)
  assert(not called and raised == "boom", tostring(raised))
  assert(answer(db, "SELECT count(*) FROM sqlite_schema") == "0")
  assert(db:close())
end

--- A newer program's database, and one another program made, are refused unchanged.
local function test_a_database_it_did_not_make_is_refused()
  local db = assert(Sqlite.memory())
  assert(db:exec("PRAGMA user_version = 5"))
  local version, why = db:migrate(STEPS)
  assert(version == nil and tostring(why):find("version 5, and the steps given end at version 2", 1, true) ~= nil, tostring(why))
  assert(db:close())
  local other = assert(Sqlite.memory())
  assert(other:exec("CREATE TABLE theirs (x)"))
  local refused, refused_why = other:migrate(STEPS)
  assert(refused == nil and tostring(refused_why):find("another program's database", 1, true) ~= nil,
    tostring(refused_why))
  -- Adopted at the step it is at, the rest run.
  assert(other:exec("PRAGMA user_version = 1"))
  assert(other:exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"))
  assert(migrated(other, STEPS) == 2)
  assert(other:close())
end

--- Called inside a caller's transaction, migrate is a savepoint of it, which the caller's rollback undoes.
local function test_migrate_nests_in_a_transaction()
  local db = assert(Sqlite.memory())
  local ok, _ = db:transact(function(): (true) | (false, Failure)
    assert(migrated(db, STEPS) == 2)
    return false, Failure.new("undo it")
  end)
  assert(not ok)
  assert(answer(db, "PRAGMA user_version") == "0")
  assert(migrated(db, {}) == 0)
  assert(db:close())
end

--- A database at its version is read with no lock, so a writer on another connection does not hold it up.
local function test_a_current_database_waits_behind_no_writer(tmp: string)
  local path = tmp .. "/current.db"
  local db = assert(Sqlite.open(path, { writable = true, wal = true }))
  assert(migrated(db, STEPS) == 2)
  local other = assert(Sqlite.open(path, { writable = true, wait = 0 }))
  assert(db:exec("BEGIN IMMEDIATE"))
  assert(migrated(other, STEPS) == 2)
  local behind, why = other:migrate({ FIRST, SECOND, "CREATE TABLE more (x)" })
  assert(behind == nil and assert(why).code == Sqlite.BUSY, tostring(why))
  assert(db:exec("COMMIT"))
  assert(other:close())
  assert(db:close())
  -- A read-only handle behind the version fails at the step that writes.
  local reader = assert(Sqlite.open(path))
  local stuck, stuck_why = reader:migrate({ FIRST, SECOND, "CREATE TABLE more (x)" })
  assert(stuck == nil and tostring(stuck_why):find("step 3: ", 1, true) ~= nil, tostring(stuck_why))
  assert(reader:close())
end

--- A step that commits on its own stops the steps after it and says so.
local function test_a_step_that_commits_stops_the_rest()
  local db = assert(Sqlite.memory())
  local version, why = db:migrate({ "CREATE TABLE a (x); COMMIT", "CREATE TABLE b (x)" })
  assert(version == nil and tostring(why):find("step 1 ended the transaction", 1, true) ~= nil, tostring(why))
  assert(answer(db, "SELECT count(*) FROM sqlite_schema WHERE name = 'b'") == "0")
  assert(answer(db, "PRAGMA user_version") == "0")
  assert(db:close())
end

--- SQLite's own tables are no schema of another program's; a negative version is refused.
local function test_sqlites_own_tables_and_a_negative_version()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE gone (x); CREATE INDEX gone_x ON gone (x); INSERT INTO gone VALUES (1); ANALYZE; " ..
      "DROP TABLE gone"))
  assert(answer(db, "SELECT count(*) FROM sqlite_schema WHERE name = 'sqlite_stat1'") == "1")
  assert(migrated(db, STEPS) == 2)
  assert(db:close())
  local negative = assert(Sqlite.memory())
  assert(negative:exec("PRAGMA user_version = -3"))
  local version, why = negative:migrate(STEPS)
  assert(version == nil and tostring(why):find("version -3", 1, true) ~= nil, tostring(why))
  assert(assert(why).code == nil)
  assert(negative:close())
end
