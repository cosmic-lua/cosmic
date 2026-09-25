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
    "(1, 'one'), (NULL, x'00ff'), (1.5, 'tab' || char(9) || 'and\\'), (2.0, ''), " ..
    "(3, char(27) || '[31m' || char(127) || '\\N')"))
  assert(db:close())
  return root
end

local function argv_of(words: {string}): {integer:string}
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sql" }
  for index, word in ipairs(words) do
    argv[index + 1] = word
  end
  return argv
end

--- The database `sql.source` picks for a command line, or nil and why.
local function source(root: string, words: {string}): sql.Source | nil, string
  local parsed = assert(Flags.parse(argv_of(words), 2, { ["--db"] = true, ["--build"] = false,
    ["--store"] = false }))
  return sql.source(root, parsed)
end

--- What one run wrote, stream by stream.
local record Written
  out: {string}
  err: {string}
  --- The verdict line, as stdout would end in it.
  verdict: string
end

local function run(root: string, words: {string}): integer, Written
  local written: Written = { out = {}, err = {}, verdict = "" }
  local code = sql.run(argv_of(words), root, {
    out = function(line: string) written.out[#written.out + 1] = line end,
    err = function(line: string) written.err[#written.err + 1] = line end,
    verdict = function(passed: boolean, detail: string)
      assert(written.verdict == "", "a second verdict: " .. written.verdict)
      written.verdict = "sql: " .. (passed and "PASS" or "FAIL") .. " (" .. detail .. ")"
    end,
  })
  return code, written
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
  assert(#lines == 5, #lines)
  assert(lines[1] == "1\tone", lines[1])
  assert(lines[2] == "\\N\tX'00FF'", lines[2])
  assert(lines[3] == "1.5\ttab\\tand\\\\", lines[3])
  assert(lines[4] == "2.0\t", lines[4])
  -- No stored control byte reaches the terminal, and the text "\N" is
  -- told apart from NULL.
  assert(lines[5] == "3\t\\x1B[31m\\x7F\\\\N", lines[5])
  local none = assert(query(path, "SELECT a FROM t WHERE 0"))
  assert(#none == 0)
  -- Rows go to stdout, then the verdict; complaints go to stderr.
  local code, written = run(root, { "SELECT a FROM t WHERE a > 1 AND a < 3 ORDER BY a" })
  assert(code == 0)
  assert(#written.out == 2 and written.out[1] == "1.5" and written.out[2] == "2.0",
    table.concat(written.out, "|"))
  assert(#written.err == 0, table.concat(written.err, "|"))
  assert(written.verdict:find("^sql: PASS %(2 rows from o/cosmic.db, ") ~= nil, written.verdict)
  code, written = run(root, { "SELECT a FROM t WHERE 0" })
  assert(code == 0 and #written.out == 0)
  assert(written.verdict:find("^sql: PASS %(0 rows") ~= nil, written.verdict)
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
  assert(opened == nil and trouble == "no such database: " .. missing, trouble)
  assert(run(root, { "--db", missing, "SELECT 1" }) == 1)
  -- A missing o/build.db is named in full, with where o/ was looked for.
  local code, written = run(root, { "--build", "SELECT 1" })
  assert(code == 1 and #written.out == 0)
  assert(written.err[1] == "cosmic: sql: o/build.db: no such database: " .. root ..
    "/o/build.db; o/ is looked for only in the working directory, never above it",
    written.err[1])
  assert(written.verdict:find("^sql: FAIL %(o/build.db, ") ~= nil, written.verdict)
  assert(Fs.exists(missing) == false, "opening made the file")
  local lines, why = query(root .. "/o/cosmic.db", "SELEC 1")
  assert(lines == nil and why:find("syntax error", 1, true) ~= nil, why)
  assert(run(root, { "SELECT nope FROM t" }) == 1)
  -- Anything but a regular file is refused before SQLite opens it: a
  -- FIFO would block the open forever. A link to a database is followed.
  local dir, why_dir = sql.open({ name = "o", path = root .. "/o" })
  assert(dir == nil and why_dir == "not a regular file (its kind is dir), so not a database", why_dir)
  assert(run(root, { "--db", root .. "/o", "SELECT 1" }) == 1)
  assert(Fs.symlink(root .. "/o/cosmic.db", root .. "/link.db"))
  assert(run(root, { "--db", root .. "/link.db", "SELECT count(*) FROM t" }) == 0)
  assert(Fs.remove_tree(root))
end

local function test_a_command_line_it_cannot_read_is_a_usage_error()
  local root = project()
  assert(run(root, {}) == 2)
  assert(run(root, { "SELECT", "1" }) == 2)
  assert(run(root, { "--nope", "SELECT 1" }) == 2)
  assert(run(root, { "--build", "--store", "SELECT 1" }) == 2)
  assert(run(root, { "--db" }) == 2)
  assert(run(root, { "--db", "", "SELECT 1" }) == 2)
  assert(run(root, { "--db=", "SELECT 1" }) == 2)
  -- A repeated option is refused, not read as its last.
  assert(run(root, { "--db", "a.db", "--db", "b.db", "SELECT 1" }) == 2)
  assert(run(root, { "--db=a.db", "--db", "b.db", "SELECT 1" }) == 2)
  local code, written = run(root, { "--build", "--build", "SELECT 1" })
  assert(code == 2 and #written.out == 0)
  assert(written.err[1]:find("name one database, not --build and --build", 1, true) ~= nil,
    written.err[1])
  -- A refused command line still ends in the verb's own verdict.
  assert(written.verdict:find("^sql: FAIL %(usage") ~= nil, written.verdict)
  -- After "--" a word is the statement, even one that looks like an option.
  assert(run(root, { "--", "--build" }) == 1)
  assert(Fs.remove_tree(root))
end

local function test_the_default_is_the_project_database_else_the_binarys_own()
  local root = project()
  local chosen = assert(source(root, {}))
  assert(chosen.path == root .. "/o/cosmic.db", chosen.name)
  chosen = assert(source(root, { "--build" }))
  assert(chosen.path == root .. "/o/build.db")
  chosen = assert(source(root, { "--store" }))
  assert(chosen.path == nil)
  chosen = assert(source(root, { "--db", root .. "/x.db" }))
  assert(chosen.path == root .. "/x.db")
  local refused, why = source(root, { "--db", "x.db", "--store" })
  assert(refused == nil and why == "name one database, not --db and --store", why)
  refused, why = source(root, { "--db=a.db", "--db", "b.db" })
  assert(refused == nil and why == "name one database, not --db and --db", why)

  assert(Fs.remove(root .. "/o/cosmic.db"))
  chosen = assert(source(root, {}))
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
