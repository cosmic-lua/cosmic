--- Worked examples for [`cosmic.sqlite`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local Example = {}

--- A file database is read-only until `writable` creates it; `immutable`
--- reads one that nothing changes while it is open, leaving no `-wal`,
--- `-shm` or journal beside it. Asking for both raises.
function Example.open()
  local dir = assert(Fs.mkdtemp("cosmic-sqlite-example-"))
  local path = dir .. "/notes.db"
  assert(Sqlite.open(path) == nil, "a read-only open does not create the file")
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE notes (body TEXT)"))
  assert(Sqlite.run(db, "INSERT INTO notes VALUES (?1)", { { text = "hi" } }))
  assert(db:close())
  local frozen = assert(Sqlite.open(path, { immutable = true }))
  local rows = assert(Sqlite.rows(frozen, "SELECT body FROM notes"))
  assert(rows[1][1].kind == "text" and rows[1][1].text == "hi")
  assert(frozen:close())
  local both = pcall(Sqlite.open, path, { writable = true, immutable = true })
  assert(not both, "writable and immutable together raise")
  assert(Fs.remove_tree(dir))
end

--- Read a value without losing its SQLite storage class.
function Example.typed_row()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT 42, 'answer', NULL"))
  assert(rows[1][1].kind == "integer" and rows[1][1].integer == 42)
  assert(rows[1][2].kind == "text" and rows[1][2].text == "answer")
  assert(rows[1][3].kind == "null")
  assert(db:close())
end

--- The new id after an INSERT, and whether a DELETE found its row.
function Example.rowid_and_changes()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)"))
  assert(Sqlite.run(db, "INSERT INTO items (value) VALUES (?1)", { { text = "a" } }))
  local id = db:last_insert_rowid()
  assert(id == 1)
  assert(Sqlite.run(db, "DELETE FROM items WHERE id = ?1", { { integer = id } }))
  assert(db:changes() == 1)
  -- Deleting an id that is no longer there changes nothing: this is
  -- how a caller tells "removed" from "was never there" without a
  -- SELECT of its own first.
  assert(Sqlite.run(db, "DELETE FROM items WHERE id = ?1", { { integer = id } }))
  assert(db:changes() == 0)
  assert(db:close())
end

--- A result too large to hold whole, read a row at a time: `query`
--- gives the rows `rows` would, one by one, and a `<close>` variable
--- finalizes the statement however the loop ends, so the handle closes.
function Example.query()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE events (id INTEGER PRIMARY KEY, level TEXT)"))
  for _, level in ipairs({ "info", "warn", "info", "warn" }) do
    assert(Sqlite.run(db, "INSERT INTO events (level) VALUES (?1)", { { text = level } }))
  end
  do
    local q <close> = assert(Sqlite.query(db,
      "SELECT id FROM events WHERE level = ?1 ORDER BY id", { { text = "warn" } }))
    for row in q:each() do print(row[1].integer) end
    assert(q:failure() == "", q:failure())
  end
  assert(db:close())
end

--- Two inserts that stand or fall together. When the work answers `false`
--- nothing is kept, and `transact` answers why; when it raises, the
--- rollback happens first and the same error is raised again.
function Example.transact()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  local ok, why = Sqlite.transact(db, function(): boolean, string
    assert(Sqlite.run(db, "INSERT INTO t VALUES (1)"))
    return false, "changed my mind"
  end)
  assert(not ok and why == "changed my mind", why)
  local raised, err = pcall(Sqlite.transact, db, function(): boolean, string
    assert(Sqlite.run(db, "INSERT INTO t VALUES (2)"))
    error("boom", 0)
  end)
  assert(not raised and (err as any) == "boom", tostring(err))
  local count = assert(Sqlite.rows(db, "SELECT count(*) FROM t"))
  assert(count[1][1].integer == 0)
  assert(Sqlite.transact(db, function(): boolean, string
    return Sqlite.run(db, "INSERT INTO t VALUES (3)")
  end))
  count = assert(Sqlite.rows(db, "SELECT count(*) FROM t"))
  assert(count[1][1].integer == 1)
  assert(db:close())
end

--- The SQLite the core carries, for a report or a feature check.
function Example.version()
  print(Sqlite.version)
  assert(Sqlite.version:match("^3%.%d+%.%d+$") ~= nil, Sqlite.version)
end

return Example
