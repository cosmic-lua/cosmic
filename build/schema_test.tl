--- The shipped module key remains unique and non-null, and a lookup
--- by name does not need unrelated modules' large payloads.

local Array = require("cosmic.array")
local Sqlite = require("cosmic.sqlite")
local schema = require("build.schema")
local symbols = require("cosmic.internal.symbols")

local function database(): Sqlite.Handle
  local db = assert(schema.hold(assert(Sqlite.memory())))
  return db
end

local function test_a_module_needs_one_unique_name()
  local db = database()
  local tail = ", 'a.tl', 'module', X'01', X'02', X'03', '', X'04')"
  local null_path, _ = db:exec("INSERT INTO modules VALUES (NULL" .. tail)
  assert(not null_path, "a null module path was accepted")
  assert(db:exec("INSERT INTO modules VALUES ('a'" .. tail))
  local duplicate, _ = db:exec("INSERT INTO modules VALUES ('a'" .. tail)
  assert(not duplicate, "a duplicate module path was accepted")
  local rows = assert(db:text_rows(
    "SELECT path, file, kind, hex(source_hash), hex(key), hex(bytecode), tests, " ..
      "hex(source) FROM modules WHERE path = 'a'"))
  assert(#rows == 1 and table.concat(rows[1]:texts(), "|") == "a|a.tl|module|01|02|03||04")
  assert(db:close())
end

--- The name index covers path-only searches even when the module's
--- bytecode and source occupy many overflow pages. The runtime's
--- payload query first finds the same key, then reads that row alone.
local function test_module_names_are_indexed_apart_from_their_payloads()
  local db = database()
  local payload = string.rep("bytecode\0", 4096)
  for _, name in ipairs({ "z", "a", "middle" }) do
    assert(db:run("INSERT INTO modules VALUES (?1, ?2, 'module', X'01', X'02', " ..
        "?3, '', zeroblob(65536))",
      { { text = name }, { text = name .. ".tl" }, { blob = payload } }))
  end
  local plan = assert(db:text_rows(
    "EXPLAIN QUERY PLAN SELECT path FROM modules WHERE path = 'middle'"))
  assert(#plan == 1)
  local plan_row = Array.at(plan, 1)
  assert(plan_row:text(4):find("COVERING INDEX", 1, true) ~= nil,
    "finding a module name reaches the table's payload: " .. table.concat(plan_row:texts(), " "))
  local lookup = "SELECT bytecode, kind FROM main.modules WHERE path = ?1"
  local search = assert(db:text_rows("EXPLAIN QUERY PLAN " .. lookup,
    { { text = "middle" } }))
  assert(#search == 1)
  local search_row = Array.at(search, 1)
  assert(search_row:text(4):find("SEARCH", 1, true) ~= nil and
      search_row:text(4):find("USING INDEX", 1, true) ~= nil, table.concat(search_row:texts(), " "))
  local found = assert(db:rows(lookup, { { text = "middle" } }))
  assert(#found == 1)
  local found_row = Array.at(found, 1)
  assert(found_row:blob(1) == payload and found_row:text(2) == "module")
  local rows = assert(db:text_rows(
    "SELECT file, kind, length(bytecode), length(source) FROM modules WHERE path = 'middle'"))
  assert(#rows == 1 and table.concat(rows[1]:texts(), "|") == "middle.tl|module|36864|65536")
  local missing = assert(db:text_rows("SELECT bytecode FROM modules WHERE path = 'none'"))
  assert(#missing == 0)
  assert(db:close())
end

local function digest_of(db: Sqlite.Handle, sql: string): string
  return Array.at(assert(db:text_rows(sql)), 1):text(1)
end

--- The data tables' digest holds the web assets, and leaves them out for a
--- database from before the table, which it then reads without error.
local function test_tables_digest_holds_the_web_assets_and_reads_an_older_database()
  local db = database()
  local empty = digest_of(db, schema.tables_digest(""))
  assert(db:exec("INSERT INTO web_assets VALUES ('a.js', X'01', 's', 't', '1')"))
  local one = digest_of(db, schema.tables_digest(""))
  assert(one ~= empty, "a web asset moved no digest")
  assert(db:exec("UPDATE web_assets SET version = '2'"))
  assert(digest_of(db, schema.tables_digest("")) ~= one, "a version moved no digest")
  assert(db:exec("DROP TABLE web_assets"))
  local absent, _ = db:text_rows(schema.tables_digest(""))
  assert(absent == nil, "the table was read though absent")
  local older = digest_of(db, schema.tables_digest("", false))
  assert(older ~= empty and #older == 64)
end

--- The indexes spell the expressions the queries of [`cosmic.internal.symbols`] spell, so SQLite uses them.
local function test_the_docs_indexes_are_the_queries_expressions()
  local ddl = schema.build.ddl
  assert(ddl:find("CREATE INDEX docs_by_last_name ON docs (" .. symbols.last_name("symbol") .. ")", 1, true) ~= nil,
    "docs_by_last_name is not on symbols.last_name")
  assert(ddl:find("CREATE INDEX " .. symbols.local_index .. " ON docs ", 1, true) ~= nil,
    "no index is named symbols.local_index")
end

--- `create` gives the statements of the schema, each under the qualifier, and a database of them holds the schema.
local function test_create_is_the_schema_under_a_qualifier()
  local plain = schema.create("")
  assert(table.concat(plain, ";\n") == schema.build.ddl)
  for k, statement in ipairs(schema.create("out.")) do
    local head = statement:match("^CREATE TABLE ") or statement:match("^CREATE INDEX ") or
      statement:match("^CREATE VIRTUAL TABLE ")
    assert(head ~= nil and statement:sub(#head + 1, #head + 4) == "out.", statement)
    assert(head .. statement:sub(#head + 5) == Array.at(plain, k), statement)
  end
  local db = assert(Sqlite.memory({ schema = schema.build }))
  assert(db:run("INSERT INTO meta VALUES ('k', X'01')"))
  assert(db:close())
end

--- A new file takes the settings before its first table; a file that holds the tables keeps its own.
local function test_hold_sets_a_new_file_up_and_checks_an_old_one(tmp: string)
  local path = tmp .. "/build.db"
  local opened = assert(Sqlite.open(path, { writable = true }))
  assert(opened:exec("PRAGMA page_size = 8192"))
  -- A file with no table yet takes the settings, which put the page size back.
  local db = assert(schema.hold(opened))
  assert(assert(db:one("PRAGMA page_size")):integer(1) == 4096)
  assert(assert(db:one("PRAGMA auto_vacuum")):integer(1) == 0)
  assert(db:run("INSERT INTO meta VALUES ('k', X'01')"))
  assert(db:close())
  local reading = assert(Sqlite.open(path, { reads_only = true }))
  local held = assert(schema.hold(reading))
  assert(assert(held:one("SELECT count(*) FROM meta")):integer(1) == 1)
  assert(held:close())
end
