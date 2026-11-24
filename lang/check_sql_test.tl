--- SQL sent to a handle of a `local schema` is read against that schema: SQLite prepares it at check time, so a
--- table or column the schema lacks, and a values list of the wrong length, are found where written.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

--- A small cosmic.sqlite: the functions and methods the reads look at.
local SQLITE <const> = [[
local record Row
  integer: function(Row, integer): integer
  number: function(Row, integer): number
  text: function(Row, integer): string
  bytes: function(Row, integer): string
  blob: function(Row, integer): string
end
local record Handle
  run: function(Handle, string, ?{integer | string}): boolean
  rows: function(Handle, string, ?{integer | string}): {Row}
  one: function(Handle, string, ?{integer | string}): Row
  map: function(Handle, string, {integer | string}, function(Row): integer): {integer}
  prepare: function(Handle, string): boolean
  exec: function(Handle, string): boolean
  exec_result: function(Handle, string): boolean
  migrate: function(Handle, {string}): boolean
end
local record Schema
  ddl: string
end
local record OpenOptions
  writable?: boolean
  schema?: Schema
end
local record MemoryOptions
  schema?: Schema
end
local record Sqlite
  type Handle = Handle
  type Row = Row
  schema: function(string): Schema
  open: function(string, ?OpenOptions): Handle
  memory: function(?MemoryOptions): Handle
end
return Sqlite
]]

local MODULES <const> = { ["cosmic.sqlite"] = SQLITE }

local HEAD <const> = 'local Sqlite = require("cosmic.sqlite")\n' ..
  'local schema Notes "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"\n' ..
  'local db = Sqlite.memory({ schema = Notes })\n'

local function accepted(source: string)
  local run = Programs.run(source, MODULES)
  local first = run.errors[1]
  assert(#run.before == 0 and first == nil, table.concat(run.before, " ") ..
      (if first ~= nil then first.code .. ": " .. first.msg else "" end) .. " in\n" .. source)
end

local function says(source: string, code: string, text: string)
  local run = Programs.run(source, MODULES)
  local first = run.errors[1]
  assert(first ~= nil and first.code == code and first.msg:find(text, 1, true) ~= nil,
    (if first ~= nil then first.code .. ": " .. first.msg else "no error" end) .. " in\n" .. source)
end

local function test_sql_the_schema_holds_is_accepted()
  accepted(HEAD .. 'print(db:run("INSERT INTO notes (body) VALUES (?1)", { "a" }))\n' ..
      'print(db:rows("SELECT id, body FROM notes WHERE id = ?1 AND body = ?2", { 1, "a" }))\n' ..
      'print(db:one("SELECT count(*) FROM notes"))\n')
end

local function test_a_column_the_schema_lacks_is_refused()
  says(HEAD .. 'print(db:rows("SELECT nme FROM notes"))\n', "sql_refused", "no such column: nme")
  says(HEAD .. 'print(db:run("DELETE FROM note"))\n', "sql_refused", "no such table: note")
  says(HEAD .. 'print(db:prepare("SELEC 1"))\n', "sql_refused", "syntax error")
end

local function test_concatenated_and_constant_sql_is_read()
  says(HEAD .. 'local Q <const> = "SELECT nme "\nprint(db:rows(Q .. "FROM notes"))\n', "sql_refused", "no such column: nme")
end

local function test_a_values_list_of_another_length_is_refused()
  says(HEAD .. 'print(db:run("INSERT INTO notes (body) VALUES (?1)", { "a", "b" }))\n', "sql_parameters",
    "the SQL binds 1 value, and 2 are given")
  says(HEAD .. 'print(db:run("INSERT INTO notes (id, body) VALUES (?1, ?2)"))\n', "sql_parameters",
    "the SQL binds 2 values, and 0 are given")
  -- a call last in the list may give any number of values
  accepted(HEAD .. 'local function two(): (integer, string) return 1, "a" end\n' ..
      'print(db:run("INSERT INTO notes (id, body) VALUES (?1, ?2)", { two() }))\n')
end

local function test_a_handle_with_no_schema_and_sql_built_at_run_time_are_not_read()
  accepted('local Sqlite = require("cosmic.sqlite")\nlocal db = Sqlite.memory()\nprint(db:rows("SELECT nme FROM x"))\n')
  accepted(HEAD .. 'local function name(): string return "nme" end\nprint(db:rows("SELECT " .. name() .. " FROM notes"))\n')
  -- a handle of no schema's type, opened with one or not, may hold any database
  accepted(HEAD .. 'local function f(other: Sqlite.Handle) print(other:rows("SELECT nme FROM x")) end\nf(db)\n')
  accepted('local Sqlite = require("cosmic.sqlite")\nlocal Notes <const> = Sqlite.schema("CREATE TABLE notes (id INTEGER)")\n' ..
      'local db = Sqlite.memory({ schema = Notes })\nprint(db:rows("SELECT nme FROM x"))\n')
end

--- A handle of a schema keeps its type where it goes: a parameter, a field, a return.
local function test_a_handle_of_a_schema_is_read_where_its_type_goes()
  says(HEAD .. 'local function f(h: Notes) print(h:rows("SELECT nme FROM notes")) end\nf(db)\n', "sql_refused",
    "`h` is a handle of the schema `Notes`")
  says(HEAD .. 'local record App\n  db: Notes\nend\nlocal app: App = { db = db }\nprint(app.db:rows("SELECT nme FROM notes"))\n',
    "sql_refused", "`app.db` is a handle of the schema `Notes`")
  -- a handle of a schema is a handle; a handle is no handle of a schema
  accepted(HEAD .. 'local function f(h: Sqlite.Handle) print(h) end\nf(db)\n')
  says(HEAD .. 'local h: Notes = Sqlite.memory()\nprint(h)\n', "not_assignable", "`Notes` is wanted")
  says(HEAD .. 'local h: Notes = Sqlite.memory({ schema = Sqlite.schema("CREATE TABLE notes (id)") })\nprint(h)\n',
    "not_assignable", "`Notes` is wanted")
end

--- A schema's handles come from open and memory alone: no literal makes one, `is` does not test for one, and no function
--- is written into one. Its value is [`Sqlite.schema`] of the DDL, with the field `ddl`.
local function test_a_schema_is_no_class_a_program_makes_or_tests()
  says(HEAD .. 'local fake: Notes = {}\nprint(fake)\n', "class_scope", "whose handles have the metatable of")
  says(HEAD .. 'local function f(v: Notes | string): string\n  if v is Notes then return "h" end\n  return v\nend\n' ..
      'print(f(db))\n', "class_scope", "tests the metatable of a `local schema`")
  local made = Programs.run(HEAD .. 'function Notes.count(): integer return 1 end\nprint(Notes)\n', MODULES)
  local first = made.errors[1]
  local said = table.concat(made.before, " ") .. (if first ~= nil then first.code .. ": " .. first.msg else "" end)
  assert(said:find("schema_member", 1, true) ~= nil, said)
  accepted(HEAD .. 'local ddl: string = Notes.ddl\nprint(ddl)\n')
  says(HEAD .. 'print(Notes.exec(db, "DELETE FROM notes"))\n', "field_unknown", "exec")
  -- the argument is checked once
  local run = Programs.run(HEAD .. 'local other = Sqlite.memory({ schema = Sqlite.nope })\nprint(other)\n', MODULES)
  local count = 0
  for _, e in ipairs(run.errors) do
    if e.msg:find("nope", 1, true) ~= nil then count = count + 1 end
  end
  assert(count == 1, tostring(count))
end

--- A schema is a type and a value that crosses modules as any declaration does.
local function test_a_schema_of_another_module_is_read()
  local modules: {string: string} = {
    ["cosmic.sqlite"] = SQLITE,
    ["store"] = 'local Sqlite = require("cosmic.sqlite")\n' ..
      'local schema Notes "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"\n' ..
      'local record Store\n  type Notes = Notes\n  schema: Sqlite.Schema\n  open: function(): Notes\nend\n' ..
      'Store.schema = Notes\nfunction Store.open(): Notes return Sqlite.memory({ schema = Notes }) end\nreturn Store\n',
  }
  local run = Programs.run('local Store = require("store")\nlocal db = Store.open()\n' ..
      'local function f(h: Store.Notes) print(h:run("DELETE FROM note")) end\nf(db)\n', modules)
  local first = run.errors[1]
  assert(first ~= nil and first.code == "sql_refused" and first.msg:find("no such table: note", 1, true) ~= nil,
    if first ~= nil then first.code .. ": " .. first.msg else "no error" end)
end

local function test_assert_around_open_keeps_the_schema()
  says('local Sqlite = require("cosmic.sqlite")\n' ..
      'local schema Notes "CREATE TABLE notes (id INTEGER PRIMARY KEY)"\n' ..
      'local db = assert(Sqlite.open("x.db", { writable = true, schema = Notes }))\nprint(db:rows("SELECT nme FROM notes"))\n',
    "sql_refused", "no such column: nme")
end

local function test_ddl_sqlite_refuses_is_refused()
  says('local Sqlite = require("cosmic.sqlite")\nlocal schema Bad "CREATE TABLE t (x"\nprint(Sqlite, Bad)\n',
    "sql_schema", "SQLite refuses the DDL of the schema `Bad`: incomplete input")
  says('local Sqlite = require("cosmic.sqlite")\nlocal Bad <const> = Sqlite.schema("CREATE TABLE t (x")\nprint(Bad)\n',
    "sql_schema", "SQLite refuses the schema's DDL")
  says('local Sqlite = require("cosmic.sqlite")\nlocal Bad <const> = Sqlite.schema("ATTACH \'x.db\' AS x")\nprint(Bad)\n',
    "sql_schema", "too many attached databases")
end

local function test_a_table_of_an_attached_database_is_not_read()
  accepted(HEAD .. 'print(db:rows("SELECT y FROM other.t"))\n')
end

--- SQL that makes a table or attaches a database ends the reads of the handle: a table made at run time is not refused.
local function test_sql_that_changes_the_schema_ends_the_reads()
  accepted(HEAD .. 'print(db:exec("CREATE TEMP TABLE scratch (a)"))\nprint(db:rows("SELECT a FROM scratch"))\n')
  accepted(HEAD .. 'print(db:run("ATTACH \'o.db\' AS o"))\nprint(db:run("CREATE TABLE o.t (x)"))\n')

  accepted(HEAD .. 'local function sql(): string return "CREATE TABLE extra (z)" end\nprint(db:exec(sql()))\n' ..
      'print(db:rows("SELECT z FROM extra"))\n')

  -- through a field or another local, and by `exec_result` or `migrate`, the schema's reads end for the module
  accepted(HEAD .. 'local record App\n  db: Notes\nend\nlocal app: App = { db = db }\n' ..
      'print(app.db:exec("CREATE TABLE extra (a)"))\nprint(db:rows("SELECT a FROM extra"))\n')
  accepted(HEAD .. 'print(db:exec_result("CREATE TABLE extra (a)"))\nprint(db:rows("SELECT a FROM extra"))\n')
  accepted(HEAD .. 'print(db:migrate({ "CREATE TABLE extra (a)" }))\nprint(db:rows("SELECT a FROM extra"))\n')
  -- reads before the change stand
  says(HEAD .. 'print(db:rows("SELECT nme FROM notes"))\nprint(db:exec("CREATE TABLE extra (a)"))\n', "sql_refused",
    "no such column: nme")

  -- a column named like a keyword is no change
  says(HEAD .. 'print(db:rows("SELECT created FROM notes"))\n', "sql_refused", "no such column: created")
end

--- DDL that holds a NUL, runs forever or creates no table is refused, and the check goes on.
local function test_ddl_that_cannot_run_is_refused_without_stopping_the_check()
  says('local Sqlite = require("cosmic.sqlite")\nlocal Bad <const> = Sqlite.schema("CREATE TABLE t (x)\\0")\nprint(Bad)\n',
    "sql_schema", "cannot hold a NUL")
  says('local Sqlite = require("cosmic.sqlite")\nlocal Bad <const> = Sqlite.schema("CREATE TABLE t AS WITH RECURSIVE ' ..
      'c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c")\nprint(Bad)\n', "sql_schema", "ran past")
  says('local Sqlite = require("cosmic.sqlite")\nlocal Bad <const> = Sqlite.schema("CREATE VIEW v AS SELECT 1")\nprint(Bad)\n',
    "sql_schema", "creates no table")
end

local function test_sql_of_several_statements_is_refused_with_exec_as_the_fix()
  local run = Programs.run(HEAD .. 'print(db:run("DELETE FROM notes; DELETE FROM notes"))\n', MODULES)
  local first = run.errors[1]
  assert(first ~= nil and first.code == "sql_refused" and first.fix:find("db:exec", 1, true) ~= nil)
end

local ROWS <const> = 'local Sqlite = require("cosmic.sqlite")\n' ..
  'local schema S "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT NOT NULL, data BLOB, w REAL) ' ..
  'STRICT; CREATE TABLE loose (n INTEGER, t TEXT, r REAL, b BLOB)"\n' ..
  'local db = Sqlite.memory({ schema = S })\n'

--- A read of a row from SQL on a handle of a schema is held to the column's declared type.
local function test_a_read_of_the_wrong_type_is_refused()
  says(ROWS .. 'local row = db:one("SELECT id, body FROM docs")\nprint(row:text(1))\n', "sql_column",
    "column 1 is docs.id, declared INTEGER in a STRICT table, so `text` raises")
  says(ROWS .. 'local rows = db:rows("SELECT id, body FROM docs")\nlocal first = assert(rows[1])\nprint(first:integer(2))\n', "sql_column",
    "column 2 is docs.body, declared TEXT in a STRICT table, so `integer` raises")
  says(ROWS .. 'local rows = db:rows("SELECT w FROM docs")\nfor _, row in ipairs(rows) do print(row:integer(1)) end\n',
    "sql_column", "declared REAL")
  says(ROWS .. 'local row = db:one("SELECT id FROM docs")\nprint(row:integer(2))\n', "sql_column",
    "the SQL gives 1 column, so this row has no column 2")
end

local function test_reads_of_the_declared_type_and_of_any_column_are_accepted()
  accepted(ROWS .. 'local row = db:one("SELECT id, body, data, w, count(*) FROM docs")\n' ..
      'print(row:integer(1), row:number(1), row:text(2), row:bytes(2), row:blob(3), row:number(4), row:text(5), ' ..
      'row:integer(5))\n')
  -- a table that is not STRICT keeps a text it cannot convert, and a blob, in any column
  accepted(ROWS .. 'local row = db:one("SELECT n, t, r, b FROM loose")\n' ..
      'print(row:text(1), row:blob(1), row:text(3), row:bytes(2), row:integer(4), row:text(4), row:number(1))\n')
  -- the later arms of a compound select may give any cell
  accepted(ROWS .. 'local row = db:one("SELECT id FROM docs UNION ALL SELECT \'a\'")\nprint(row:text(1))\n')
end

local function test_a_loose_table_refuses_what_affinity_never_gives()
  says(ROWS .. 'local row = db:one("SELECT t FROM loose")\nprint(row:integer(1))\n', "sql_column",
    "column 1 is loose.t, declared TEXT, so `integer` raises")
  says(ROWS .. 'local row = db:one("SELECT r FROM loose")\nprint(row:integer(1))\n', "sql_column", "declared REAL")
  says(ROWS .. 'local row = db:one("SELECT data FROM docs")\nprint(row:text(1))\n', "sql_column",
    "declared BLOB in a STRICT table")
end

local function test_the_row_of_map_is_read()
  says(ROWS .. 'print(db:map("SELECT body FROM docs WHERE id = ?1", { 1 }, function(row: Sqlite.Row): integer\n' ..
      '  return row:integer(1)\nend))\n', "sql_column", "declared TEXT")
end
