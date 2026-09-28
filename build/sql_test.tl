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
    out = function(line: string) written.out[#written.out + 1] = line end,
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
  code, written = run(dir, { "--from", dir .. "/nested.json", "--as", "csv", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("no format csv (known: json, ndjson)", 1, true), written.err[1])
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
  -- VACUUM INTO's refused write leaves the empty file SQLite created
  -- first; see the TODO in build.sql's run_from.
  assert(Fs.read(dir .. "/copy.db") == "")
  assert(Fs.remove_tree(dir))
end

local function test_from_refuses_an_unknown_extension_invalid_json_and_a_missing_file()
  local dir = data()
  local code, written = run(dir, { "--from", dir .. "/notes.txt", "SELECT 1" })
  assert(code == 2 and written.err[1]:find("unknown extension .txt (known: .json, .jsonl, .ndjson)", 1, true),
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
