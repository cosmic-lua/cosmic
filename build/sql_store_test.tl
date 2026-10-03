--- `cosmic sql` over the running program's own database: the source it
--- picks by default, and what that database answers and refuses
--- (build/sql_test.tl holds the rest).

local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local sql = require("build.sql")

--- The program's own database is read through a handle
--- ([`Store.databases()`]), which reads every module's rows too.
Test.needs{ store = true }

--- A temporary root whose o/cosmic.db holds one small table.
local function project(): string
  local root = assert(Fs.mkdtemp("cosmic-sql-test-"))
  assert(Fs.mkdirs(root .. "/o"))
  local db = assert(Sqlite.open(root .. "/o/cosmic.db", { writable = true }))
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

--- The database [`sql.source`] picks for a command line, or nil and why.
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
    out = function(line: string): boolean, string
      written.out[#written.out + 1] = line
      return true, ""
    end,
    err = function(line: string) written.err[#written.err + 1] = line end,
    verdict = function(passed: boolean, detail: string)
      assert(written.verdict == "", "a second verdict: " .. written.verdict)
      written.verdict = "sql: " .. (passed and "PASS" or "FAIL") .. " (" .. detail .. ")"
    end,
  })
  return code, written
end

--- The binary's own database reads the clock through its VFS, which
--- passes the question to the default one: `julianday('now')` answers
--- rather than ending the process.
local function test_the_binarys_own_database_tells_the_time()
  local root = project()
  local code, said = run(root, { "--store", "SELECT julianday('now') > 2460000 AS now" })
  assert(Fs.remove_tree(root))
  assert(code == 0 and said.out[2] == "1", table.concat(said.out, "|"))
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
  local lines = assert(sql.query(opened.db, "SELECT count(*) > 0 AS any FROM sqlite_schema"))
  assert(#lines == 2 and lines[1] == "any" and lines[2] == "1", table.concat(lines, "|"))
  -- A PRAGMA it refuses is answered with what a query can tell instead.
  local code, said = run(root, { "--store", "PRAGMA table_info(modules)" })
  assert(code == 1 and #said.out == 0)
  assert(said.err[1]:find("not authorized; the binary's own database answers a query",
    1, true) ~= nil, said.err[1])
  code, said = run(root, { "--store", "SELECT * FROM modules LIMIT 0" })
  assert(code == 0 and #said.out == 1 and said.out[1]:find("\t", 1, true) ~= nil,
    table.concat(said.out, "|"))
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
