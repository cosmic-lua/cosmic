local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sql = require("build.sql")

--- A temporary root whose o/cosmic.db holds one small table.
local function project(): string
  local root = assert(Fs.mkdtemp("cosmic-sql-test-"))
  assert(Fs.mkdirs(root .. "/o"))
  local db = assert(Sqlite.open(root .. "/o/cosmic.db", true))
  assert(Sqlite.exec(db, "CREATE TABLE t (a, b); INSERT INTO t VALUES " ..
    "(1, 'one'), (NULL, x'00ff'), (1.5, 'tab' || char(9) || 'and\\'), (2.0, '')"))
  assert(db:close())
  return root
end

local function parse(words: {string}): Flags.Parsed
  local argv: {integer:string} = { [1] = "sql" }
  for index, word in ipairs(words) do
    argv[index + 1] = word
  end
  return (assert(Flags.parse(argv, 2, { ["--db"] = true, ["--build"] = false,
    ["--store"] = false })))
end

local function run(root: string, words: {string}): integer
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sql" }
  for index, word in ipairs(words) do
    argv[index + 1] = word
  end
  return sql.run(argv, root)
end

local function query(path: string, statement: string): {string} | nil, string
  local opened = assert(sql.open({ name = path, path = path }))
  local lines, trouble = sql.query(opened.db, statement)
  assert(opened.db:close())
  return lines, trouble
end

local function test_rows_come_back_one_line_each_with_cells_escaped()
  local root = project()
  local path = root .. "/o/cosmic.db"
  local lines = assert(query(path, "SELECT a, b FROM t ORDER BY rowid"))
  assert(#lines == 4, #lines)
  assert(lines[1] == "1\tone", lines[1])
  assert(lines[2] == "\\N\tX'00FF'", lines[2])
  assert(lines[3] == "1.5\ttab\\tand\\\\", lines[3])
  assert(lines[4] == "2.0\t", lines[4])
  local none = assert(query(path, "SELECT a FROM t WHERE 0"))
  assert(#none == 0)
  assert(run(root, { "SELECT count(*) FROM t" }) == 0)
  assert(run(root, { "SELECT a FROM t WHERE 0" }) == 0)
  assert(Fs.remove_tree(root))
end

local function test_sqlite_refuses_every_write()
  local root = project()
  local path = root .. "/o/cosmic.db"
  local before = assert(Fs.read(path))
  for _, statement in ipairs({
    "INSERT INTO t VALUES (3, 'three')",
    "UPDATE t SET a = 0",
    "DELETE FROM t",
    "DROP TABLE t",
    "CREATE TABLE u (a)",
    "CREATE TEMP TABLE u (a)",
    "PRAGMA user_version = 7",
    "VACUUM",
    "VACUUM INTO '" .. root .. "/copy.db'",
    "ATTACH '" .. root .. "/new.db' AS n",
    "ANALYZE",
    "SELECT 1; DELETE FROM t",
  }) do
    local lines, trouble = query(path, statement)
    assert(lines == nil, statement .. " ran")
    assert(trouble ~= "", statement)
    assert(run(root, { statement }) == 1, statement)
  end
  -- These run, but alone they change nothing: the statement is the only
  -- one its connection ever prepares.
  for _, statement in ipairs({
    "PRAGMA query_only = 0",
    "PRAGMA writable_schema = 1",
    "ATTACH ':memory:' AS m",
  }) do
    assert(run(root, { statement }) == 0, statement)
  end
  assert(Fs.read(path) == before, "the database changed")
  -- VACUUM INTO's refused write leaves the empty file SQLite created
  -- before query_only stopped it; see the TODO in build.sql.
  assert(Fs.read(root .. "/copy.db") == "", "VACUUM INTO wrote a copy")
  assert(Fs.exists(root .. "/new.db") == false, "ATTACH made a file")
  assert(Fs.remove_tree(root))
end

local function test_a_missing_database_and_bad_sql_fail()
  local root = project()
  local missing = root .. "/o/nothing.db"
  local opened, trouble = sql.open({ name = missing, path = missing })
  assert(opened == nil and trouble == "no such database", trouble)
  assert(run(root, { "--db", missing, "SELECT 1" }) == 1)
  assert(run(root, { "--build", "SELECT 1" }) == 1)
  assert(Fs.exists(missing) == false, "opening made the file")
  local lines, why = query(root .. "/o/cosmic.db", "SELEC 1")
  assert(lines == nil and why:find("syntax error", 1, true) ~= nil, why)
  assert(run(root, { "SELECT nope FROM t" }) == 1)
  assert(Fs.remove_tree(root))
end

local function test_a_command_line_it_cannot_read_is_a_usage_error()
  local root = project()
  assert(run(root, {}) == 2)
  assert(run(root, { "SELECT", "1" }) == 2)
  assert(run(root, { "--nope", "SELECT 1" }) == 2)
  assert(run(root, { "--build", "--store", "SELECT 1" }) == 2)
  assert(run(root, { "--db" }) == 2)
  assert(Fs.remove_tree(root))
end

local function test_the_default_is_the_project_database_else_the_binarys_own()
  local root = project()
  local chosen = assert(sql.source(root, parse({})))
  assert(chosen.path == root .. "/o/cosmic.db", chosen.name)
  chosen = assert(sql.source(root, parse({ "--build" })))
  assert(chosen.path == root .. "/o/build.db")
  chosen = assert(sql.source(root, parse({ "--store" })))
  assert(chosen.path == nil)
  chosen = assert(sql.source(root, parse({ "--db", root .. "/x.db" })))
  assert(chosen.path == root .. "/x.db")
  local refused, why = sql.source(root, parse({ "--db", "x.db", "--store" }))
  assert(refused == nil and why == "name one database, not --db and --store", why)

  assert(Fs.remove(root .. "/o/cosmic.db"))
  chosen = assert(sql.source(root, parse({})))
  assert(chosen.path == nil, chosen.name)
  -- The binary's own database answers, and still refuses a write.
  local opened = assert(sql.open(chosen))
  assert(not opened.owned)
  local lines = assert(sql.query(opened.db, "SELECT count(*) > 0 FROM sqlite_master"))
  assert(lines[1] == "1", lines[1])
  for _, statement in ipairs({
    "CREATE TEMP TABLE u (a)",
    "ATTACH ':memory:' AS m",
    "PRAGMA writable_schema = 1",
    "VACUUM INTO '" .. root .. "/copy.db'",
  }) do
    local written = sql.query(opened.db, statement)
    assert(written == nil, statement .. " ran")
  end
  assert(Fs.exists(root .. "/copy.db") == false, "VACUUM INTO made a file")
  assert(Fs.remove_tree(root))
end
