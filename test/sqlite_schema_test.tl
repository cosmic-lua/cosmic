--- A schema given to open or memory: a new file gets its tables, and
--- a file that does not hold them fails at open, naming what differs.
local Failure = require("cosmic.failure")
local Sqlite = require("cosmic.sqlite")

local Notes <const> = Sqlite.schema([[
  CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL, made integer);
  CREATE INDEX notes_body ON notes (body);
  CREATE TABLE tags (note INTEGER NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (note, tag));
]])

local function has(failure: Failure, text: string): boolean
  return failure.message:find(text, 1, true) ~= nil
end

local function test_a_memory_database_starts_with_the_tables()
  local db = assert(Sqlite.memory({ schema = Notes }))
  assert(db:run("INSERT INTO notes (body) VALUES (?1)", { "hi" }))
  assert(db:run("INSERT INTO tags VALUES (1, 'a')"))
  local index = assert(db:one("SELECT count(*) FROM sqlite_schema WHERE name = 'notes_body'"))
  assert(index:integer(1) == 1)
  assert(db:close())
end

local function test_a_new_file_gets_the_tables_and_keeps_its_rows(tmp: string)
  local path = tmp .. "/notes.db"
  local db = assert(Sqlite.open(path, { writable = true, schema = Notes }))
  assert(db:run("INSERT INTO notes (body) VALUES (?1)", { "kept" }))
  assert(db:close())
  -- The second open finds the tables, checks them, and changes nothing.
  local again = assert(Sqlite.open(path, { writable = true, schema = Notes }))
  local row = assert(again:one("SELECT body FROM notes"))
  assert(row:text(1) == "kept")
  assert(again:close())
  local reading = assert(Sqlite.open(path, { schema = Notes }))
  assert(reading:close())
end

local function test_a_read_only_open_of_a_new_file_fails(tmp: string)
  local path = tmp .. "/empty.db"
  local made = assert(Sqlite.open(path, { writable = true }))
  assert(made:close())
  local db, why = Sqlite.open(path, { schema = Notes })
  assert(db == nil)
  assert(has(why, "does not hold the schema"))
  assert(has(why, "no table notes (id INTEGER PRIMARY KEY 1, body TEXT NOT NULL, made INTEGER)"))
  assert(has(why, "no table tags"))
end

local function test_a_file_with_other_columns_fails_naming_them(tmp: string)
  local path = tmp .. "/old.db"
  local old = assert(Sqlite.open(path, { writable = true }))
  assert(old:exec([[
    CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
    CREATE TABLE tags (note INTEGER NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (note, tag));
    CREATE TABLE other (x);
  ]]))
  assert(old:close())
  local db, why = Sqlite.open(path, { writable = true, schema = Notes })
  assert(db == nil and why.code == nil)
  assert(has(why, "table notes is (id INTEGER PRIMARY KEY 1, body TEXT) where the schema declares " ..
      "(id INTEGER PRIMARY KEY 1, body TEXT NOT NULL, made INTEGER)"))
  -- tags matches, and a table the schema does not name is not checked.
  assert(not has(why, "tags") and not has(why, "table other"))
  -- Nothing was written: the old table is as it was.
  local plain = assert(Sqlite.open(path))
  local columns = assert(plain:one("SELECT count(*) FROM pragma_table_info('notes')"))
  assert(columns:integer(1) == 2)
  assert(plain:close())
end

local function test_a_file_with_only_a_view_is_not_new(tmp: string)
  local path = tmp .. "/view.db"
  local old = assert(Sqlite.open(path, { writable = true }))
  assert(old:exec("CREATE VIEW v AS SELECT 1"))
  assert(old:close())
  local db, why = Sqlite.open(path, { writable = true, schema = Notes })
  assert(db == nil and has(why, "no table notes"))
end

--- DDL that SQLite refuses raises where the schema is made, not at an
--- open, so a typo fails as the module loads.
local function test_ddl_that_fails_raises_at_the_schema()
  local ok, err = pcall(Sqlite.schema, "CREATE TABLE t (x INTEGER")
  assert(not ok and tostring(err):find("the DDL fails", 1, true) ~= nil)
  local ok2, err2 = pcall(Sqlite.schema, "CREATE VIEW v AS SELECT 1")
  assert(not ok2 and tostring(err2):find("creates no table", 1, true) ~= nil)
end

--- A view of a table's name is no table.
local function test_a_view_named_as_a_table_fails(tmp: string)
  local path = tmp .. "/named.db"
  local old = assert(Sqlite.open(path, { writable = true }))
  assert(old:exec("CREATE VIEW t AS SELECT 1 AS x"))
  assert(old:close())
  local db, why = Sqlite.open(path, { schema = Sqlite.schema("CREATE TABLE t (x)") })
  assert(db == nil and has(why, "no table t (x)"))
end

--- Names and types read the same in capitals or not, and a type with
--- other spaces is the same type.
local function test_case_and_spaces_do_not_differ(tmp: string)
  local path = tmp .. "/spaced.db"
  local old = assert(Sqlite.open(path, { writable = true }))
  assert(old:exec("CREATE TABLE T (Body varchar( 10 ), n DOUBLE   PRECISION, d decimal(4 , 2))"))
  assert(old:close())
  local schema = Sqlite.schema("CREATE TABLE t (body VARCHAR(10), N double precision, d DECIMAL(4,2))")
  local db = assert(Sqlite.open(path, { schema = schema }))
  assert(db:close())
end

local function test_ddl_with_a_nul_raises()
  local ok, err = pcall(Sqlite.schema, "CREATE TABLE t (x)\0")
  assert(not ok and tostring(err):find("NUL", 1, true) ~= nil)
end

local function test_an_attach_in_the_ddl_raises()
  local ok, err = pcall(Sqlite.schema, "ATTACH ':memory:' AS other; CREATE TABLE other.t (x)")
  assert(not ok and tostring(err):find("too many attached", 1, true) ~= nil)
end
