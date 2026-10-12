--- What [`Csv.load`] copies: CSV, from text or a file, into a table through
--- SQLite's CSV table.

local Csv = require("cosmic.csv")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

--- `sql`'s rows on `handle` as text: each row's cells joined by `|`, the
--- rows by `;`.
local function quoted(handle: Sqlite.Handle, sql: string): string
  local rows = assert(Sqlite.text_rows(handle, sql))
  local out: {string} = {}
  for index, row in ipairs(rows) do
    out[index] = table.concat(row:texts(), "|")
  end
  return table.concat(out, ";")
end

local function test_load_types_cells_as_cosmic_sql_does()
  local db = assert(Sqlite.memory())
  local copied = assert(Csv.load(db, "t",
    { text = "id,n,x\n1,007,\n-0,1e999,2.5\n12345678901234567890,-3,\"a, \"\"b\"\"\"\n" }))
  assert(copied == 3, tostring(copied))
  local got = quoted(db, "SELECT quote(id), quote(n), quote(x) FROM t ORDER BY rowid")
  assert(got == "1|'007'|NULL;0|'1e999'|2.5;1.2345678901234567e+19|-3|'a, \"b\"'", got)
  assert(quoted(db, "SELECT count(*) FROM t WHERE id > 0") == "2")
  assert(db:close())
end

local function test_load_keeps_text_as_written_when_raw()
  local db = assert(Sqlite.memory())
  assert(Csv.load(db, "t", { text = "a,b\n1,\n", raw = true }) == 1)
  local got = quoted(db, "SELECT quote(a), quote(b) FROM t")
  assert(got == "'1'|''", got)
  assert(db:close())
end

local function test_load_names_columns_as_csv_table_does()
  local db = assert(Sqlite.memory())
  assert(Csv.load(db, "t", { text = "\xEF\xBB\xBFa,A,,rowid\n1,2,3,4\n" }) == 1)
  local got = quoted(db, "SELECT group_concat(name, ',') FROM pragma_table_info('t')")
  assert(got == "a,A_2,_,rowid_2", got)
  assert(db:close())
end

local function test_load_reads_a_file(tmp: string)
  local path = tmp .. "/rows.csv"
  assert(Fs.write(path, "id,city\n1,\"Lagos, Nigeria\"\n2,Paris\n"))
  local db = assert(Sqlite.memory())
  assert(Csv.load(db, "rows", { path = path }) == 2)
  assert(quoted(db, "SELECT city FROM rows WHERE id = 1") == "Lagos, Nigeria")
  assert(db:close())
end

--- A failure answers why and leaves neither the table nor SQLite's CSV
--- table behind.
local function test_load_failures_leave_nothing(tmp: string)
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE taken (a)"))
  local cases: {{string, Csv.Source, string}} = {
    { "taken", { text = "a\n1\n" }, "already exists" },
    { "fresh", { text = "" }, "holds no header" },
    { "fresh", { text = "a\0b\n" }, "holds a NUL byte at byte 2" },
    { "fresh", { path = tmp .. "/absent.csv" }, "cannot open" },
  }
  for _, case in ipairs(cases) do
    local copied, why = Csv.load(db, case[1], case[2])
    assert(copied == nil and why:find(case[3], 1, true) ~= nil, why)
  end
  assert(quoted(db, "SELECT count(*) FROM sqlite_schema WHERE name = 'fresh'") == "0")
  assert(quoted(db, "SELECT count(*) FROM sqlite_temp_schema") == "0")
  local ok, why = pcall(Csv.load, db, "t", {})
  assert(not ok and tostring(why):find("one of them", 1, true) ~= nil, tostring(why))
  assert(db:close())
end

--- SQLite's CSV table may not be made in a database file's schema, where
--- the file would choose what it reads.
local function test_a_csv_table_is_only_made_in_temp()
  local db = assert(Sqlite.memory())
  local ok, why = db:exec("CREATE VIRTUAL TABLE main.x USING csv(data='a,b')")
  assert(not ok and why:find("must be in the temp schema", 1, true) ~= nil, why)
  assert(db:exec("CREATE VIRTUAL TABLE temp.x USING csv(data='a,b')"))
  assert(db:close())
end

--- SQLite's CSV table fails a query on what the reader refuses, rather
--- than reading the rest of the text into other fields.
local function test_a_csv_table_refuses_a_malformed_record()
  local db = assert(Sqlite.memory())
  assert(db:exec([[CREATE VIRTUAL TABLE temp.x USING csv(data='a,b
"q"z,1
')]]))
  local rows, why = Sqlite.text_rows(db, "SELECT * FROM temp.x")
  assert(rows == nil and why:find("line 2: unescaped \" character", 1, true) ~= nil, why)
  assert(db:close())
end

--- A temp table of the same name does not catch the rows.
local function test_load_writes_the_main_schema()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TEMP TABLE t (x, y)"))
  assert(Csv.load(db, "t", { text = "a,b\n1,2\n" }) == 1)
  assert(quoted(db, "SELECT count(*) FROM temp.t") == "0")
  assert(quoted(db, "SELECT a, b FROM main.t") == "1|2")
  assert(db:close())
end

--- A fault inside a record is reported as itself, not as what the reader
--- would make of the rest of the record.
local function test_a_quote_fault_mid_record_is_named()
  local db = assert(Sqlite.memory())
  local copied, why = Csv.load(db, "t", { text = 'a,b,c\n1,"x"y,2\n' })
  assert(copied == nil and why:find("unescaped \" character", 1, true) ~= nil, why)
  assert(db:close())
end

--- A number too small for a real is 0.0, and -0.0 is 0.0, as `cosmic sql
--- --from` reads them; one too large stays text.
local function test_load_types_underflow_and_negative_zero_as_sql_from_does()
  local db = assert(Sqlite.memory())
  assert(Csv.load(db, "t", { text = "a,b,c\n1e-400,-0.0,1e400\n" }) == 1)
  local got = quoted(db, "SELECT typeof(a), a, hex(ieee754_to_blob(b)), typeof(c) FROM t")
  assert(got == "real|0.0|0000000000000000|text", got)
  assert(db:close())
end
