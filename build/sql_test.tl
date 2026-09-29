local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sql = require("build.sql")
--- A temporary root whose o/cosmic.db holds one small table.
local function project(): string
  local root = assert(Fs.mkdtemp("cosmic-sql-test-"))
  assert(Fs.mkdirs(root .. "/o"))
  local db = assert(Sqlite.open(root .. "/o/cosmic.db", true))
  assert(db:exec("CREATE TABLE t (a, b); INSERT INTO t VALUES " ..
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

--- What one run wrote, stream by stream.
local record Written
  out: {string}
  err: {string}
  --- The verdict line, as stdout would end in it.
  verdict: string
end

local function run(root: string, words: {string}, input?: string): integer, Written
  local written: Written = { out = {}, err = {}, verdict = "" }
  local code = sql.run(argv_of(words), root, {
    out = function(line: string): boolean, string
      written.out[#written.out + 1] = line
      return true, ""
    end,
    err = function(line: string) written.err[#written.err + 1] = line end,
    verdict = function(passed: boolean, detail: string)
      assert(written.verdict == "", "a second verdict: " .. written.verdict)
      written.verdict = "sql: " .. (passed and "PASS" or "FAIL") .. " (" .. detail .. ")"
    end,
  }, function(): string | nil, string
    if input == nil then return nil, "no standard input given" end
    return input, ""
  end)
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
  assert(#lines == 6, #lines)
  assert(lines[1] == "a\tb", lines[1])
  assert(lines[2] == "1\tone", lines[2])
  assert(lines[3] == "\\N\tX'00FF'", lines[3])
  assert(lines[4] == "1.5\ttab\\tand\\\\", lines[4])
  assert(lines[5] == "2.0\t", lines[5])
  -- No stored control byte reaches the terminal, and the text "\N" is
  -- told apart from NULL.
  assert(lines[6] == "3\t\\x1B[31m\\x7F\\\\N", lines[6])
  -- A statement with no rows still names its columns.
  local none = assert(query(path, "SELECT a, b AS \"tab\tbed\" FROM t WHERE 0"))
  assert(#none == 1 and none[1] == "a\ttab\\tbed", none[1])
  -- Rows go to stdout, then the verdict; complaints go to stderr.
  local code, written = run(root, { "SELECT a FROM t WHERE a > 1 AND a < 3 ORDER BY a" })
  assert(code == 0)
  assert(#written.out == 3 and written.out[1] == "a" and written.out[2] == "1.5" and
    written.out[3] == "2.0", table.concat(written.out, "|"))
  assert(#written.err == 0, table.concat(written.err, "|"))
  assert(written.verdict:find("^sql: PASS %(2 rows from o/cosmic.db, ") ~= nil, written.verdict)
  code, written = run(root, { "SELECT a FROM t WHERE 0" })
  assert(code == 0 and #written.out == 1 and written.out[1] == "a")
  assert(written.verdict:find("^sql: PASS %(0 rows") ~= nil, written.verdict)
  -- A parameter is refused rather than read as NULL.
  local unbound, unbound_trouble = query(path, "SELECT a FROM t WHERE a = ?")
  assert(unbound == nil and unbound_trouble ==
    "the statement takes 1 parameter; cosmic sql binds none", unbound_trouble)
  code, written = run(root, { "SELECT ?1, ?2" })
  assert(code == 1 and #written.out == 0)
  assert(written.err[1]:find("takes 2 parameters", 1, true) ~= nil, written.err[1])
  -- A statement with no columns prints no header, and counts no row.
  code, written = run(root, { "PRAGMA query_only = 1" })
  assert(code == 0 and #written.out == 0, table.concat(written.out, "|"))
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
    "ATTACH ':memory:' AS m",
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
  }) do
    assert(run(root, { statement }) == 0, statement)
  end
  assert(Fs.read(path) == before, "the database changed")
  -- The attached-database limit stops both before SQLite makes a file.
  assert(Fs.exists(root .. "/copy.db") == false, "VACUUM INTO made a file")
  assert(Fs.exists(root .. "/new.db") == false, "ATTACH made a file")
  assert(Fs.remove_tree(root))
end

--- A read-only open used to make <db>-wal and <db>-shm beside a WAL-mode
--- database whose -wal was gone, and leave them there.
local function test_a_query_leaves_no_wal_or_shm_beside_the_database()
  local root = assert(Fs.mkdtemp("cosmic-sql-wal-test-"))
  local path = root .. "/wal.db"
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("PRAGMA journal_mode = WAL; CREATE TABLE t (a); INSERT INTO t VALUES (1)"))
  assert(db:close())
  assert(Fs.exists(path .. "-wal") == false and Fs.exists(path .. "-shm") == false,
    "the last connection's close left them")
  local opened = assert(sql.open({ name = path, path = path }))
  local lines = assert(sql.query(opened.db, "SELECT a FROM t"))
  assert(#lines == 2 and lines[2] == "1", table.concat(lines, "|"))
  assert(opened.db:close())
  assert(Fs.exists(path .. "-wal") == false, "a query made a -wal")
  assert(Fs.exists(path .. "-shm") == false, "a query made a -shm")
  assert(Fs.remove_tree(root))
end

--- An immutable open never reads a -wal, so `open` gives it only a
--- database with no frames outside the file: a build's database, mid-run,
--- holds commits only in its -wal, and a query must see them.
local function test_a_query_sees_commits_that_live_only_in_the_wal()
  local root = assert(Fs.mkdtemp("cosmic-sql-wal-frames-test-"))
  local path = root .. "/wal.db"
  local writer = assert(Sqlite.open(path, true))
  assert(writer:exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; " ..
    "CREATE TABLE t (a); INSERT INTO t VALUES (1)"))
  assert(writer:exec("PRAGMA wal_checkpoint(TRUNCATE); INSERT INTO t VALUES (2)"))
  local wal = assert(Fs.stat(path .. "-wal"))
  assert(wal.size > 0, "the commit is not in the -wal")
  local opened = assert(sql.open({ name = path, path = path }))
  local lines = assert(sql.query(opened.db, "SELECT count(*) FROM t"))
  assert(lines[2] == "2", "a query missed a commit that lives in the -wal: " .. lines[2])
  assert(opened.db:close())
  assert(writer:close())
  assert(Fs.remove_tree(root))
end

--- The -wal gains frames after `open` has looked and before its immutable
--- open is made (`between` stands for that gap): the second look sends it
--- the ordinary way, so the query still sees the commit.
local function test_a_commit_that_reaches_the_wal_during_the_open_is_seen()
  local root = assert(Fs.mkdtemp("cosmic-sql-wal-race-test-"))
  local path = root .. "/wal.db"
  local writer = assert(Sqlite.open(path, true))
  assert(writer:exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; " ..
    "CREATE TABLE t (a); INSERT INTO t VALUES (1)"))
  assert(writer:exec("PRAGMA wal_checkpoint(TRUNCATE)"))
  assert(assert(Fs.stat(path .. "-wal")).size == 0)
  local opened = assert(sql.open({ name = path, path = path }, function()
    assert(writer:exec("INSERT INTO t VALUES (2)"))
  end))
  local lines = assert(sql.query(opened.db, "SELECT count(*) FROM t"))
  assert(lines[2] == "2", "a commit that reached the -wal during the open was missed: " .. lines[2])
  assert(opened.db:close())
  assert(writer:close())
  assert(Fs.remove_tree(root))
end

--- A row that cannot be written stops the statement there.
local function test_a_failed_write_stops_the_statement()
  local root = project()
  local endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c"
  local lines: {string} = {}
  local complaints: {string} = {}
  local passed: boolean | nil
  local code = sql.run(argv_of({ endless }), root, {
    out = function(line: string): boolean, string
      lines[#lines + 1] = line
      if #lines == 3 then
        return false, "Broken pipe"
      end
      return true, ""
    end,
    err = function(line: string) complaints[#complaints + 1] = line end,
    verdict = function(ok: boolean, _: string) passed = ok end,
  })
  assert(code == 1, code)
  assert(#lines == 3, #lines)
  assert(#complaints == 1 and complaints[1]:find("Broken pipe", 1, true) ~= nil,
    table.concat(complaints, "|"))
  assert(passed == false)
  assert(Fs.remove_tree(root))
end

--- Rows are written as they are stepped: one that fails on its third row
--- has written the first two.
local function test_rows_are_written_before_the_statement_finishes()
  local root = project()
  local failing = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) " ..
    "SELECT x, CASE WHEN x = 3 THEN abs(-9223372036854775807 - 1) ELSE 0 END AS y FROM c"
  local code, written = run(root, { failing })
  assert(code == 1)
  assert(#written.out == 3 and written.out[1] == "x\ty" and written.out[2] == "1\t0" and
    written.out[3] == "2\t0", table.concat(written.out, "|"))
  assert(#written.err == 1 and written.verdict:find("^sql: FAIL") ~= nil)
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

--- A temporary directory holding the data files of the `--from` tests.
local function data(): string
  local dir = assert(Fs.mkdtemp("cosmic-sql-from-test-"))
  assert(Fs.write(dir .. "/accounts.json",
    '[{"id": 1, "type": "checking", "balance": 100.5, "tags": ["a", "b"], "active": true},' ..
    ' {"id": 2, "type": "savings", "balance": 50, "active": false},' ..
    ' {"id": 3, "type": "checking", "balance": 20, "note": null}]'))
  assert(Fs.write(dir .. "/owners.jsonl", '{"id": 1, "who": "ann"}\n\n{"id": 2, "who": "bob"}\n'))
  assert(Fs.write(dir .. "/nested.json", '{"a": {"rows": [{"n": 1}, {"n": 2}, {"n": 4}]}}'))
  assert(Fs.write(dir .. "/notes.txt", "hello"))
  assert(Fs.write(dir .. "/bad.json", "{"))
  return dir
end

local function test_from_answers_a_statement_in_the_rows_format()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/accounts.json",
    "SELECT type, sum(balance) AS total, count(*) FROM accounts GROUP BY type ORDER BY type" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(table.concat(written.out, "\n") == "type\ttotal\tcount(*)\nchecking\t120.5\t2\nsavings\t50\t1",
    table.concat(written.out, "|"))
  assert(written.verdict:find("^sql: PASS %(2 rows from " .. dir:gsub("%p", "%%%0") ..
    "/accounts.json, %d+ ms%)$") ~= nil, written.verdict)
  -- json_extract reaches a nested value; a boolean is 0 or 1.
  code, written = run(dir, { "--from", dir .. "/accounts.json",
    "SELECT json_extract(tags, '$[1]'), active FROM accounts WHERE id = 1" })
  assert(code == 0 and written.out[2] == "b\t1", table.concat(written.out, "|"))
  assert(Fs.remove_tree(dir))
end

local function test_several_files_join_and_a_name_can_be_given()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/accounts.json", "--from", dir .. "/owners.jsonl",
    "SELECT who, balance FROM accounts a JOIN owners o ON o.id = a.id ORDER BY who" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(table.concat(written.out, "|") == "who\tbalance|ann\t100.5|bob\t50", table.concat(written.out, "|"))
  -- A name before the file's own, and a name for a file whose stem is not one.
  code, written = run(dir, { "--from", "acct=" .. dir .. "/accounts.json", "--from", "p=" .. dir .. "/owners.jsonl",
    "SELECT count(*) FROM acct JOIN p USING (id)" })
  assert(code == 0 and written.out[2] == "2", table.concat(written.err, "|"))
  -- Two files with one stem are refused, naming the fix.
  code, written = run(dir, { "--from", dir .. "/accounts.json", "--from", "accounts=" .. dir .. "/owners.jsonl", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("two tables are named accounts", 1, true), written.err[1])
  assert(written.err[1]:find("--from <name>=<file>", 1, true))
  assert(written.verdict:find("^sql: FAIL %(usage") ~= nil, written.verdict)
  -- A stem that is no identifier is made one.
  assert(Fs.write(dir .. "/my-data 2024.json", '[{"x": 1}]'))
  code, written = run(dir, { "--from", dir .. "/my-data 2024.json", "SELECT x FROM my_data_2024" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(Fs.write(dir .. "/2024.json", '[{"x": 1}]'))
  code, written = run(dir, { "--from", dir .. "/2024.json", "SELECT x FROM _2024" })
  assert(code == 0, table.concat(written.err, "|"))
  code, written = run(dir, { "--from", "1x=" .. dir .. "/2024.json", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("begins with a letter", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_as_and_at_belong_to_the_from_before_them()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/nested.json", "--at", "$.a.rows",
    "--from", dir .. "/accounts.json", "SELECT (SELECT sum(n) FROM nested), (SELECT count(*) FROM accounts)" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(written.out[2] == "7\t3", table.concat(written.out, "|"))
  -- --as reads a file by another name than its extension's.
  assert(Fs.write(dir .. "/lines.dat", '{"a": 1}\n{"a": 2}\n'))
  code, written = run(dir, { "--from", dir .. "/lines.dat", "--as", "ndjson", "SELECT sum(a) FROM lines" })
  assert(code == 0 and written.out[2] == "3", table.concat(written.err, "|"))
  -- One given before any --from belongs to none.
  code, written = run(dir, { "--at", "$.a", "--from", dir .. "/nested.json", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--at belongs to the --from before it", 1, true), written.err[1])
  code, written = run(dir, { "--as", "json", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--as belongs to the --from before it", 1, true), written.err[1])
  -- A path that does not read, a path that is not there, a format that is not one.
  code, written = run(dir, { "--from", dir .. "/nested.json", "--at", "$.a[", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--at $.a[:", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/nested.json", "--at", "$.zz", "SELECT 1" })
  assert(code == 1 and written.err[1]:find('no key "zz"', 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/nested.json", "--as", "xml", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("no format xml (known: csv, json, ndjson, tsv)", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/lines.dat", "--as", "ndjson", "--at", "$.a", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("takes no path", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_standard_input_needs_as()
  local dir = data()
  local code, written = run(dir, { "--from", "-", "--as", "ndjson", "SELECT sum(a) FROM stdin" }, '{"a": 1}\n{"a": 5}\n')
  assert(code == 0, table.concat(written.err, "|"))
  assert(written.out[2] == "6" and written.verdict:find("rows? from standard input") ~= nil, written.verdict)
  code, written = run(dir, { "--from", "t=-", "--as", "json", "SELECT sum(a) FROM t" }, '[{"a": 2}]')
  assert(code == 0 and written.out[2] == "2", table.concat(written.err, "|"))
  code, written = run(dir, { "--from", "-", "SELECT 1" }, "[]")
  assert(code == 2 and written.err[1]:find("standard input has no extension", 1, true), written.err[1])
  assert(written.err[1]:find("--as", 1, true))
  code, written = run(dir, { "--from", "-", "--as", "json", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("standard input: no standard input given", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_no_statement_prints_the_schema()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/accounts.json" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(table.concat(written.out, "\n") == table.concat({
    "accounts: 3 rows",
    "  active   integer|null",
    "  balance  integer|real",
    "  id       integer",
    "  note     null",
    "  tags     null|text",
    "  type     text",
    "  _json    text",
    '  sample: {"active":true,"balance":100.5,"id":1,"tags":["a","b"],"type":"checking"}',
  }, "\n"), table.concat(written.out, "\n"))
  assert(written.verdict:find("^sql: PASS %(1 table from ") ~= nil, written.verdict)
  code, written = run(dir, { "--from", dir .. "/accounts.json", "--from", dir .. "/owners.jsonl" })
  assert(code == 0 and written.verdict:find("^sql: PASS %(2 tables from ") ~= nil, written.verdict)
  local text = table.concat(written.out, "\n")
  assert(text:find("\nowners: 2 rows\n  id     integer\n  who    text\n  _json  text\n  sample: ", 1, true), text)
  assert(Fs.remove_tree(dir))
end

local function test_a_missing_name_is_answered_with_the_names_there_are()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/accounts.json", "SELECT balanse FROM accounts" })
  assert(code == 1 and #written.out == 0)
  assert(written.err[1] == "cosmic: sql: " .. dir .. "/accounts.json: no such column: balanse; " ..
    "columns: active, balance, id, note, tags, type, _json", written.err[1])
  assert(written.verdict:find("^sql: FAIL %(") ~= nil, written.verdict)
  code, written = run(dir, { "--from", dir .. "/accounts.json", "SELECT * FROM account" })
  assert(code == 1 and written.err[1]:find("no such table: account; tables: accounts$") ~= nil, written.err[1])
  code, written = run(dir, { "--from", dir .. "/accounts.json", "--from", dir .. "/owners.jsonl",
    "SELECT nope FROM accounts, owners" })
  assert(code == 1 and written.err[1]:find("no such column: nope; columns: accounts: active, " ..
    "balance, id, note, tags, type, _json; owners: id, who, _json$") ~= nil, written.err[1])
  -- Another failure gets no hint.
  code, written = run(dir, { "--from", dir .. "/accounts.json", "SELECT FROM" })
  assert(code == 1 and not written.err[1]:find("columns:", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_from_refuses_every_write_and_leaves_the_file_alone()
  local dir = data()
  local before = assert(Fs.read(dir .. "/accounts.json"))
  for _, statement in ipairs({
    "INSERT INTO accounts (id) VALUES (9)",
    "UPDATE accounts SET balance = 0",
    "DELETE FROM accounts",
    "DROP TABLE accounts",
    "CREATE TABLE u (a)",
    "CREATE TEMP TABLE u (a)",
    "CREATE VIEW v AS SELECT 1",
    "VACUUM INTO '" .. dir .. "/copy.db'",
    "SELECT 1; DELETE FROM accounts",
  }) do
    local code, written = run(dir, { "--from", dir .. "/accounts.json", statement })
    assert(code == 1, statement .. " ran")
    assert(#written.out == 0 and written.verdict:find("^sql: FAIL") ~= nil, statement)
  end
  assert(assert(Fs.read(dir .. "/accounts.json")) == before)
  assert(Fs.exists(dir .. "/copy.db") == false, "VACUUM INTO made a file")
  local code, written = run(dir, { "--from", dir .. "/accounts.json",
    "ATTACH '" .. dir .. "/new.db' AS n" })
  assert(code == 1 and #written.out == 0)
  assert(Fs.exists(dir .. "/new.db") == false, "ATTACH made a file")
  code = run(dir, { "--from", dir .. "/accounts.json", "ATTACH ':memory:' AS m" })
  assert(code == 1, "ATTACH ':memory:' ran")
  assert(Fs.remove_tree(dir))
end

local function test_from_refuses_an_unknown_extension_invalid_json_and_a_missing_file()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/notes.txt", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("unknown extension .txt (known: .csv, .json, .jsonl, .ndjson, .tab, .tsv)", 1, true),
    written.err[1])
  assert(written.err[1]:find("give --as", 1, true))
  code, written = run(dir, { "--from", dir .. "/notes.txt", "--as", "json", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("notes.txt: invalid JSON", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/bad.json", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("bad.json: invalid JSON at line 1", 1, true), written.err[1])
  assert(#written.out == 0 and written.verdict:find("^sql: FAIL %(") ~= nil, written.verdict)
  code, written = run(dir, { "--from", dir .. "/none.json", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("none.json", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_from_is_not_a_database_option_and_takes_one_statement()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/accounts.json", "--db", dir .. "/x.db", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("not to be given with --db", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/accounts.json", "SELECT 1", "SELECT 2" })
  assert(code == 2 and written.err[1]:find("one statement", 1, true), written.err[1])
  code, written = run(dir, { "--from", "", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--from needs a file", 1, true), written.err[1])
  -- Without --from the statement is still required, and runs against a database.
  code, written = run(dir, {})
  assert(code == 2, table.concat(written.err, "|"))
  assert(Fs.remove_tree(dir))
end

local function test_from_refuses_a_second_standard_input_and_a_repeated_as_or_at()
  local dir = data()
  local code, written = run(dir, { "--from", "x=-", "--as", "ndjson", "--from", "y=-", "--as", "ndjson",
    "SELECT 1" }, '{"a": 1}\n')
  assert(code == 2 and written.err[1]:find("standard input can be read once", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/lines.dat", "--as", "json", "--as", "ndjson", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--as is given twice for", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/nested.json", "--at", "$.a", "--at", "$.a.rows", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--at is given twice for", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_a_column_with_no_types_and_a_control_byte_in_a_name()
  local dir = data()
  assert(Fs.write(dir .. "/empty.json", "[]"))
  local code, written = run(dir, { "--from", dir .. "/empty.json" })
  assert(code == 0 and written.out[2] == "  _json  -", table.concat(written.out, "|"))
  assert(Fs.write(dir .. "/ctl.json", '[{"a\\u001bb": 1}]'))
  code, written = run(dir, { "--from", dir .. "/ctl.json", "SELECT nope FROM ctl" })
  assert(code == 1 and written.err[1]:find("columns: a\\x1Bb, _json", 1, true), written.err[1])
  assert(not written.err[1]:find("\27", 1, true))
  assert(Fs.remove_tree(dir))
end

local function test_a_missing_file_names_its_path_once_and_usage_shows_as_and_at()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/none.json", "SELECT 1" })
  local _, count = written.err[1]:gsub("none.json", "")
  assert(code == 1 and count == 1, written.err[1])
  code, written = run(dir, { "--from" })
  assert(code == 2 and written.err[1]:find("--from needs a value", 1, true), written.err[1])
  assert(written.err[1]:find("[--as json|ndjson|csv|tsv] [--at '<path>'] [--raw]", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

--- A directory holding a CSV, a TSV and a JSON file to join.
local function delimited(): string
  local dir = data()
  assert(Fs.write(dir .. "/people.csv",
    '\xEF\xBB\xBFid,name,zip,score\r\n1,"Ann, Jr.",02134,9.5\r\n2,"Bob ""B""",,7\r\n3,Cy,10001,\r\n'))
  assert(Fs.write(dir .. "/scores.tsv", "id\tpoints\n1\t10\n2\t20\n"))
  return dir
end

local function test_a_csv_joins_a_json_file()
  local dir = delimited()
  local code, written = run(dir, { "--from", dir .. "/people.csv", "--from", dir .. "/accounts.json",
    "SELECT name, balance FROM people JOIN accounts USING (id) ORDER BY id" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(table.concat(written.out, "|") == "name\tbalance|Ann, Jr.\t100.5|Bob \"B\"\t50|Cy\t20", table.concat(written.out, "|"))
  code, written = run(dir, { "--from", dir .. "/people.csv", "--from", dir .. "/scores.tsv",
    "SELECT sum(score + points), count(zip) FROM people JOIN scores USING (id)" })
  assert(code == 0 and written.out[2] == "46.5\t1", table.concat(written.out, "|") .. table.concat(written.err))
  assert(Fs.remove_tree(dir))
end

local function test_raw_belongs_to_the_from_before_it_and_keeps_text()
  local dir = delimited()
  local code, written = run(dir, { "--from", dir .. "/people.csv", "--raw", "--from", dir .. "/scores.tsv",
    "SELECT typeof(p.score), p.zip = '', typeof(s.points) FROM people p JOIN scores s ON p.id = CAST(s.id AS text) WHERE p.id = '2'" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(written.out[2] == "text\t1\tinteger", table.concat(written.out, "|"))
  code, written = run(dir, { "--raw", "--from", dir .. "/people.csv", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--raw belongs to the --from before it", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/people.csv", "--raw", "--raw", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("--raw is given twice", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/accounts.json", "--raw", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("no raw cells", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_no_statement_prints_the_schema_of_a_csv()
  local dir = delimited()
  local code, written = run(dir, { "--from", dir .. "/people.csv" })
  assert(code == 0, table.concat(written.err, "|"))
  assert(table.concat(written.out, "\n") == table.concat({
    "people: 3 rows",
    "  id     integer",
    "  name   text",
    "  zip    integer|null|text",
    "  score  integer|null|real",
    "  _json  text",
    '  sample: {"id":1,"name":"Ann, Jr.","score":9.5,"zip":"02134"}',
  }, "\n"), table.concat(written.out, "\n"))
  assert(Fs.remove_tree(dir))
end

local function test_standard_input_reads_csv_with_as()
  local dir = delimited()
  local code, written = run(dir, { "--from", "-", "--as", "csv", "SELECT sum(n), count(*) FROM stdin" },
    "n,label\n1,a\n2,b\n")
  assert(code == 0 and written.out[2] == "3\t2", table.concat(written.err, "|"))
  code, written = run(dir, { "--from", "-", "--as", "tsv", "SELECT b FROM stdin" }, "a\tb\n1\tx\n")
  assert(code == 0 and written.out[2] == "x", table.concat(written.err, "|"))
  code, written = run(dir, { "--from", "-", "SELECT 1" }, "a\n1\n")
  assert(code == 2 and written.err[1]:find("csv, json, ndjson, tsv", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_csv_faults_name_the_file_and_the_place_and_at_is_refused()
  local dir = delimited()
  assert(Fs.write(dir .. "/ragged.csv", "a,b\n1,2\n3\n"))
  assert(Fs.write(dir .. "/open.csv", 'a,b\n1,"2\n'))
  local code, written = run(dir, { "--from", dir .. "/ragged.csv", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("ragged.csv: line 3, column 1: the record has 1 field, the header 2", 1, true),
    written.err[1])
  code, written = run(dir, { "--from", dir .. "/open.csv", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("unclosed quote opened at line 2, column 3", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/people.csv", "--at", "$.a", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("the csv format takes no path", 1, true), written.err[1])
  code, written = run(dir, { "--from", dir .. "/scores.tsv", "--at", "$.a", "SELECT 1" })
  assert(code == 1 and written.err[1]:find("the tsv format takes no path", 1, true), written.err[1])
  assert(Fs.remove_tree(dir))
end

local function test_a_csv_keeps_its_header_order_and_a_one_column_blank_line()
  local dir = data()
  assert(Fs.write(dir .. "/wide.csv", "z,a,m\n1,2,3\n"))
  local code, written = run(dir, { "--from", dir .. "/wide.csv", "SELECT * FROM wide" })
  assert(code == 0 and written.out[1] == "z\ta\tm\t_json", table.concat(written.err, "|") .. written.out[1])
  code, written = run(dir, { "--from", dir .. "/wide.csv" })
  assert(written.out[2] == "  z      integer" and written.out[3] == "  a      integer", table.concat(written.out, "|"))
  assert(Fs.write(dir .. "/one.csv", "a\n1\n\n3\n\n"))
  code, written = run(dir, { "--from", dir .. "/one.csv", "SELECT count(*), count(a) FROM one" })
  assert(code == 0 and written.out[2] == "3\t2", table.concat(written.err, "|") .. table.concat(written.out, "|"))
  assert(Fs.remove_tree(dir))
end
