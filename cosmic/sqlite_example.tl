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
  local note = assert(rows[1])
  assert(note:kind(1) == "text" and note:text(1) == "hi")
  assert(frozen:close())
  local opened, why = pcall(Sqlite.open, path, { writable = true, immutable = true })
  assert(not opened and tostring(why):find("both writable and immutable", 1, true) ~= nil,
    tostring(why))
  assert(Fs.remove_tree(dir))
end

--- Read a value without losing its SQLite storage class.
function Example.typed_row()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT 42, 'answer', NULL"))
  local row = assert(rows[1])
  assert(row:kind(1) == "integer" and row:integer(1) == 42)
  assert(row:kind(2) == "text" and row:text(2) == "answer")
  assert(row:kind(3) == "null")
  assert(db:close())
end

--- A row is read a column at a time, by the type the caller expects. A
--- column of another type raises, so a query that does not answer what
--- the reader assumed fails where it is read; ask `is_null` or `kind`
--- first where a column may hold something else.
function Example.read_a_row()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT 7, 'seven', NULL, x'ff00'"))
  local row = assert(rows[1])
  print(row:count(), row:integer(1), row:text(2), row:is_null(3), #row:blob(4))
  assert(row:count() == 4 and row:integer(1) == 7 and row:text(2) == "seven")
  assert(row:is_null(3) and row:kind(4) == "blob")
  local ok, why = pcall(function(): string return row:text(1) end)
  print(why) -- the failure names the column and what it holds
  assert(not ok and tostring(why):find("column 1 is an integer, not text", 1, true) ~= nil)
  assert(db:close())
end

--- A record per row: `map` runs a projection over each row and gives the
--- list of what it answered, or nil and why the query failed.
function Example.map()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (name TEXT, n INTEGER); INSERT INTO t VALUES ('a', 1), ('b', 2)"))
  local record Named
    name: string
    n: integer
  end
  local found = assert(Sqlite.map(db, "SELECT name, n FROM t WHERE n > ?1 ORDER BY n",
    { { integer = 0 } }, function(r: Sqlite.Row): Named
      return { name = r:text(1), n = r:integer(2) }
    end))
  local first, second = assert(found[1]), assert(found[2])
  print(#found, second.name) -- 2  b
  assert(#found == 2 and first.n == 1 and second.name == "b")
  local none, why = Sqlite.map(db, "SELECT * FROM missing", nil, function(r: Sqlite.Row): integer
    return r:integer(1)
  end)
  assert(none == nil and why:find("missing", 1, true) ~= nil, why)
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
    for row in q:each() do print(row:integer(1)) end
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
  assert(not raised and tostring(err) == "boom", tostring(err))
  local count = assert(Sqlite.rows(db, "SELECT count(*) FROM t"))
  assert(assert(count[1]):integer(1) == 0)
  assert(Sqlite.transact(db, function(): boolean, string
    return Sqlite.run(db, "INSERT INTO t VALUES (3)")
  end))
  count = assert(Sqlite.rows(db, "SELECT count(*) FROM t"))
  assert(assert(count[1]):integer(1) == 1)
  assert(db:close())
end

--- The SQLite the core carries, for a report or a feature check.
function Example.version()
  print(Sqlite.version)
  assert(Sqlite.version:match("^3%.%d+%.%d+$") ~= nil, Sqlite.version)
end

--- Codes describe an operation; its reason is for a person. A SQL error
--- such as malformed JSON says nothing about the health of the database.
function Example.captured_results()
  local opened = Sqlite.open_result(":memory:", { writable = true })
  local db = assert(opened.handle, opened.reason)
  local created = Sqlite.run_result(db, "CREATE TABLE notes (body TEXT)")
  assert(created.code == Sqlite.OK, created.reason)
  local inserted = Sqlite.run_result(db, "INSERT INTO notes VALUES (?1)", { { text = "hello" } })
  assert(inserted.code == Sqlite.OK, inserted.reason)
  local cells = Sqlite.rows_result(db, "SELECT count(*) FROM notes")
  assert(cells.code == Sqlite.OK and assert(assert(cells.rows)[1]):integer(1) == 1, cells.reason)
  local texts = Sqlite.text_rows_result(db, "SELECT body FROM notes")
  assert(texts.code == Sqlite.OK and assert(assert(texts.rows)[1]):text(1) == "hello", texts.reason)
  local invalid = Sqlite.rows_result(db, "SELECT json('invalid')")
  assert(invalid.rows == nil and invalid.code ~= Sqlite.OK)
  assert(invalid.code ~= Sqlite.CORRUPT and invalid.code ~= Sqlite.NOTADB)
  assert(invalid.code ~= Sqlite.BUSY and invalid.code ~= Sqlite.LOCKED)
  assert(db:close())
end

--- Vector search in SQL: store each chunk's embedding as a blob of
--- floats, normalized once, then rank by distance under any filter. A
--- real program stores what an embedding API answers; these three
--- dimensions stand in for its hundreds.
function Example.vector_search()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, body TEXT, tenant TEXT, embedding BLOB);
    INSERT INTO chunks VALUES
      (1, 'cats purr in the sun', 'a', l2_normalize('[0.9, 0.1, 0.0]')),
      (2, 'dogs fetch the ball', 'a', l2_normalize('[0.7, 0.6, 0.1]')),
      (3, 'mars is a cold planet', 'a', l2_normalize('[0.0, 0.2, 0.9]')),
      (4, 'kittens nap all day', 'b', l2_normalize('[0.8, 0.2, 0.1]'));
  ]]))
  local query = "[0.85, 0.15, 0.05]"
  local found = assert(Sqlite.map(db, [[
    SELECT body, cosine_distance(embedding, ?1) FROM chunks
    WHERE tenant = 'a' ORDER BY 2 LIMIT 2
  ]], { { text = query } }, function(r: Sqlite.Row): string
    return string.format("%s (%.3f)", r:text(1), r:number(2))
  end))
  print(table.concat(found, "; ")) -- cats purr in the sun (0.004); dogs fetch the ball (0.139)
  local first = assert(found[1])
  assert(first:find("cats", 1, true) == 1, first)
  assert(db:close())
end

return Example
