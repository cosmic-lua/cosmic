local dataset = require("build.dataset")
local Sqlite = require("cosmic.sqlite")

--- A fresh in-memory database.
local function memory(): Sqlite.Handle
  return (assert(Sqlite.memory()))
end

--- The text every cell of `sql` reads as, `NULL` for none, one row per
--- element and `|` between cells.
local function grid(db: Sqlite.Handle, sql: string): {string}
  local out: {string} = {}
  local q <close> = assert(Sqlite.query(db, sql))
  for row in q:each() do
    local cells: {string} = {}
    for index, cell in ipairs(row) do
      if cell.kind == "null" then
        cells[index] = "NULL"
      elseif cell.kind == "integer" then
        cells[index] = "i" .. cell.integer
      elseif cell.kind == "number" then
        cells[index] = "r" .. cell.number
      else
        cells[index] = cell.text
      end
    end
    out[#out + 1] = table.concat(cells, "|")
  end
  return out
end

local function loaded(text: string, name?: string): Sqlite.Handle, dataset.Table
  local rows = assert(dataset.read("json", text))
  local db = memory()
  local made = assert(dataset.load(db, name or "t", rows))
  return db, made
end

local function test_columns_are_the_union_of_keys_in_sorted_order()
  local db, made = loaded('[{"b": 1, "a": 2}, {"c": 3, "a": 4}]')
  assert(table.concat(made.columns, ",") == "a,b,c,_json", table.concat(made.columns, ","))
  assert(made.count == 2 and made.name == "t")
  local rows = grid(db, "SELECT a, b, c FROM t")
  assert(rows[1] == "i2|i1|NULL" and rows[2] == "i4|NULL|i3", table.concat(rows, ";"))
end

local function test_scalars_keep_their_sqlite_types()
  local db = loaded('[{"i": 7, "r": 1.5, "whole": 2.0, "s": "x", "n": null, "t": true, "f": false, "big": 12345678901234567890}]')
  local types = grid(db, "SELECT typeof(i), typeof(r), typeof(whole), typeof(s), typeof(n), typeof(t), " ..
      "typeof(f), typeof(big) FROM t")
  assert(types[1] == "integer|real|real|text|null|integer|integer|real", types[1])
  local booleans = grid(db, "SELECT t, f FROM t")
  assert(booleans[1] == "i1|i0", booleans[1])
  assert(#grid(db, "SELECT 1 FROM t WHERE t AND NOT f") == 1)
end

local function test_nested_values_are_json_text_that_json_extract_reaches()
  local db = loaded('[{"o": {"k": [1, {"z": "deep"}]}, "a": [1, 2, 3], "e": {}, "l": []}]')
  local rows = grid(db, "SELECT o, a, e, l, json_extract(o, '$.k[1].z'), typeof(o), " ..
      "(SELECT sum(value) FROM json_each(a)) FROM t")
  assert(rows[1] == '{"k":[1,{"z":"deep"}]}|[1,2,3]|{}|[]|deep|text|i6', rows[1])
end

local function test_json_column_holds_the_whole_row()
  local db = loaded('[{"b": [1], "a": null, "c": "\\u00e9\\n"}]')
  local rows = grid(db, "SELECT _json FROM t")
  assert(rows[1] == '{"a":null,"b":[1],"c":"é\\n"}', rows[1])
end

local function test_keys_are_quoted_and_collisions_renamed()
  local db, made = loaded('[{"a b": 1, "x\\"y": 2, "select": 3, "A": 4, "a": 5, "": 6, "_json": 7, "_JSON": 8, "a_2": 9}]')
  local by_name = table.concat(made.columns, ",")
  assert(by_name == '_,A,_JSON_2,_json_3,a_2,a b,a_2_2,select,x"y,_json', by_name)
  -- Each key's value is in the column named for it, or the renamed one.
  local function value(column: string): string
    local rows = assert(Sqlite.text_rows(db, 'SELECT "' .. column:gsub('"', '""') .. '" FROM t'))
    return rows[1][1]
  end
  assert(value("a b") == "1" and value('x"y') == "2" and value("select") == "3")
  assert(value("A") == "4" and value("_") == "6")
  assert(made.renamed["a_2"] == "a" and made.renamed["_"] == "" and made.renamed["a_2_2"] == "a_2")
  assert(made.renamed["_JSON_2"] == "_JSON" and made.renamed["_json_3"] == "_json")
  assert(made.renamed["A"] == nil and made.renamed["select"] == nil)
  -- Every column is distinct even when case is folded, and `_json` is the row's own.
  local seen: {string:boolean} = {}
  for _, column in ipairs(made.columns) do
    assert(not seen[column:lower()], column .. " twice")
    seen[column:lower()] = true
  end
  assert(made.columns[#made.columns] == "_json")
  assert(grid(db, "SELECT json_extract(_json, '$.a'), json_extract(_json, '$.\"\"') FROM t")[1] == "i5|i6")
end

local function test_an_array_of_scalars_is_a_value_column()
  local db, made = loaded('[1, "two", null, [3], {"value": 9}, 2.5]')
  assert(table.concat(made.columns, ",") == "value,_json" and made.count == 6)
  local rows = grid(db, "SELECT value, _json FROM t")
  assert(rows[1] == "i1|{\"value\":1}", rows[1])
  assert(rows[2] == "two|{\"value\":\"two\"}" and rows[3] == "NULL|{\"value\":null}", rows[3])
  assert(rows[4] == "[3]|{\"value\":[3]}", rows[4])
  assert(rows[5] == "i9|{\"value\":9}" and rows[6] == "r2.5|{\"value\":2.5}", rows[6])
end

local function test_a_value_that_is_not_an_array_is_one_row()
  local db, made = loaded('{"users": [1, 2], "name": "n"}')
  assert(made.count == 1)
  assert(grid(db, "SELECT name, users FROM t")[1] == "n|[1,2]")
  local scalar, one = loaded("42")
  assert(one.count == 1 and grid(scalar, "SELECT value, _json FROM t")[1] == 'i42|{"value":42}')
  local nothing, zero = loaded("[]")
  assert(zero.count == 0 and table.concat(zero.columns, ",") == "_json")
  assert(#grid(nothing, "SELECT * FROM t") == 0)
end

local function test_at_reads_the_rows_from_a_path()
  local rows = assert(dataset.read("json", '{"a": {"rows": [{"id": 1}, {"id": 2}]}}',
    { at = { "a", "rows" } }))
  assert(#rows == 2 and rows[2].id == 2)
  local none, why = dataset.read("json", '{"a": 1}', { at = { "b" } })
  assert(none == nil and why == 'json: no value at pointer "/b"', why)
  local last = assert(dataset.read("json", '{"a": [{"id": 1}, {"id": 2}]}', { at = { "a", -1 } }))
  assert(#last == 1 and last[1].id == 2)
  local bad, bad_why = dataset.read("json", "{", {})
  assert(bad == nil and bad_why:find("invalid JSON", 1, true), bad_why)
end

local function test_ndjson_is_a_row_per_line()
  local rows = assert(dataset.read("ndjson", '{"a": 1}\n\n{"a": 2, "b": "x"}\r\n7\n'))
  assert(#rows == 3 and rows[2].b == "x" and rows[3].value == 7)
  local db = memory()
  local made = assert(dataset.load(db, "t", rows))
  assert(table.concat(made.columns, ",") == "a,b,value,_json")
  assert(grid(db, "SELECT sum(a) FROM t")[1] == "i3")
  assert(#assert(dataset.read("ndjson", "")) == 0)
  local bad, why = dataset.read("ndjson", '{"a": 1}\n{\n')
  assert(bad == nil and why:find("line 2", 1, true), why)
  local at, at_why = dataset.read("ndjson", "{}", { at = { "a" } })
  assert(at == nil and at_why:find("no path", 1, true), at_why)
end

local function test_formats_are_found_by_name_and_extension()
  assert(table.concat(dataset.names(), ",") == "csv,json,ndjson,tsv")
  assert(dataset.format_of("a/b.json") == "json" and dataset.format_of("x.JSONL") == "ndjson")
  assert(dataset.format_of("x.ndjson") == "ndjson")
  local unknown, why = dataset.format_of("data.xml")
  assert(unknown == nil and why == "dataset: unknown extension .xml (known: .csv, .json, .jsonl, .ndjson, .tab, .tsv)", why)
  local none, none_why = dataset.format_of("README")
  assert(none == nil and none_why:find("^dataset: no extension"), none_why)
  local missing, missing_why = dataset.read("yaml", "a: 1")
  assert(missing == nil and missing_why == "dataset: no format yaml (known: csv, json, ndjson, tsv)", missing_why)
  assert(dataset.about("json") ~= nil and dataset.about("yaml") == nil)
end

local function test_load_refuses_what_sqlite_or_the_caller_cannot_take()
  local db = memory()
  local rows = assert(dataset.read("json", '[{"a": 1}]'))
  assert(dataset.load(db, "t", rows))
  local again, why = dataset.load(db, "T", rows)
  assert(again == nil and why:find("already exists", 1, true), why)
  local nameless, nameless_why = dataset.load(db, "", rows)
  assert(nameless == nil and nameless_why == "dataset: a table needs a name")
  local odd = assert(dataset.load(db, 'we"ird name', rows))
  assert(odd.name == 'we"ird name')
  local ok = Sqlite.rows(db, 'SELECT a FROM "we""ird name"')
  assert(ok ~= nil)
  local bad, bad_why = dataset.load(db, "u", { { a = print as any } })
  assert(bad == nil and bad_why:find("row 1, a: a function has no SQLite value", 1, true), bad_why)
  -- A refused load leaves no table behind.
  assert(not Sqlite.rows(db, "SELECT * FROM u"))
end

local function test_a_nul_byte_in_a_key_or_name_is_not_sql()
  local db = memory()
  local made = assert(dataset.load(db, "t", { { ["a\0b"] = 1, ["a_b"] = 2 } }))
  assert(table.concat(made.columns, ",") == "a_b,a_b_2,_json", table.concat(made.columns, ","))
  assert(made.renamed["a_b"] == "a\0b" and made.renamed["a_b_2"] == "a_b")
  assert(grid(db, "SELECT a_b, a_b_2 FROM t")[1] == "i1|i2")
  local bad, why = dataset.load(db, "u\0v", {})
  assert(bad == nil and why == "dataset: a table name cannot hold a NUL byte", why)
end

local function test_a_key_named_rowid_does_not_shadow_the_row_id()
  local db, made = loaded('[{"rowid": "mine", "oid": 1, "_rowid_": 2, "ROWID": 3}]')
  assert(table.concat(made.columns, ",") == "ROWID_2,_rowid__2,oid_2,rowid_3,_json",
    table.concat(made.columns, ","))
  assert(grid(db, "SELECT rowid FROM t")[1] == "i1")
  assert(made.renamed["rowid_3"] == "rowid" and made.renamed["ROWID_2"] == "ROWID")
  assert(grid(db, "SELECT json_extract(_json, '$.rowid') FROM t")[1] == "mine")
end

local function test_too_many_columns_says_the_limit_and_the_count()
  local row: dataset.Row = {}
  for index = 1, 1999 do row["k" .. index] = index end
  local db = memory()
  assert(dataset.load(db, "t", { row }), "1999 keys and `_json` are 2000 columns")
  row.extra = 1
  local made, why = dataset.load(db, "u", { row })
  assert(made == nil and why == "dataset: too many columns: 2000 distinct keys, and SQLite holds at most " ..
      "2000 columns in a table (one is `_json`)", why)
  assert(not Sqlite.rows(db, "SELECT * FROM u"), "a refused load leaves no table")
end

--- The cells of one CSV row, typed: `typeof|value` per column, in order.
local function csv_cells(text: string, raw?: boolean): string
  local rows = assert(dataset.read("csv", text, { raw = raw }))
  local db = memory()
  local made = assert(dataset.load(db, "t", rows))
  local picks: {string} = {}
  for index = 1, #made.columns - 1 do
    picks[index] = 'typeof("' .. made.columns[index] .. '") || \':\' || coalesce("' .. made.columns[index] .. '", \'NULL\')'
  end
  return grid(db, "SELECT " .. table.concat(picks, " || '|' || ") .. " FROM t")[1]
end

local function test_a_csv_cell_that_is_plainly_a_number_is_one()
  -- Columns are in byte order: a b c d e f g h.
  assert(csv_cells("a,b,c,d,e,f,g,h\n1,-2,0,3.5,-0.25,1e3,2E-2,12345678901234567890\n") ==
      "integer:1|integer:-2|integer:0|real:3.5|real:-0.25|real:1000.0|real:0.02|real:1.2345678901234567e+19",
    csv_cells("a,b,c,d,e,f,g,h\n1,-2,0,3.5,-0.25,1e3,2E-2,12345678901234567890\n"))
end

local function test_every_other_csv_cell_stays_text()
  for _, cell in ipairs({ "007", "02134", "+1", " 1", "1 ", "1e5x", "1.", ".5", "-", "1e", "1e+", "0x10", "1,5",
      "00", "-01", "0.", "1_000", "NaN", "inf", "1e999", "-1e999", "١٢" }) do
    local got = csv_cells('a\n"' .. cell .. '"\n')
    assert(got == "text:" .. cell, cell .. " read as " .. got)
  end
end

local function test_an_empty_csv_cell_is_null_and_raw_keeps_it_text()
  assert(csv_cells("a,b,c\n,x,\n") == "null:NULL|text:x|null:NULL")
  assert(csv_cells("a,b\n1,\"\"\n") == "integer:1|null:NULL", "a quoted empty cell is empty too")
  local raw = csv_cells("a,b,c\n,007,1\n", true)
  assert(raw == "text:|text:007|text:1", raw)
end

local function test_a_csv_row_is_json_of_the_same_values()
  local rows = assert(dataset.read("csv", 'id,name,note,n\n1,"a ""b""",,2.5\n'))
  local db = memory()
  assert(dataset.load(db, "t", rows))
  local json = grid(db, "SELECT _json FROM t")[1]
  assert(json == '{"id":1,"n":2.5,"name":"a \\"b\\"","note":null}', json)
  local raw = assert(dataset.read("csv", "id\n1\n", { raw = true }))
  local db2 = memory()
  assert(dataset.load(db2, "t", raw))
  assert(grid(db2, "SELECT _json FROM t")[1] == '{"id":"1"}')
end

local function test_tsv_reads_tabs_and_csv_and_tsv_refuse_a_path()
  local rows = assert(dataset.read("tsv", "a\tb\n1,5\t2\n"))
  assert(rows[1].a == "1,5" and rows[1].b == 2)
  assert(dataset.format_of("x.tab") == "tsv" and dataset.format_of("X.TSV") == "tsv")
  assert(dataset.format_of("x.csv") == "csv")
  for _, name in ipairs({ "csv", "tsv" }) do
    local none, why = dataset.read(name, "a\n1\n", { at = { "a" } })
    assert(none == nil and why == "dataset: the " .. name .. " format takes no path: each record is a row", why)
  end
  local bad, why = dataset.read("csv", "a,b\n1\n")
  assert(bad == nil and why:find("line 2, column 1", 1, true), why)
end

local function test_duplicate_and_empty_csv_headers_are_renamed_like_json_keys()
  local rows = assert(dataset.read("csv", "a,A,,a,_json\n1,2,3,4,5\n"))
  local db = memory()
  local made = assert(dataset.load(db, "t", rows))
  assert(table.concat(made.columns, ",") == "a,A_2,_,a_3,_json_2,_json", table.concat(made.columns, ","))
  assert(grid(db, "SELECT a, A_2, a_3, _, _json_2 FROM t")[1] == "i1|i2|i4|i3|i5")
end

local function test_json_formats_refuse_raw()
  for _, name in ipairs({ "json", "ndjson" }) do
    local none, why = dataset.read(name, "[]", { raw = true })
    assert(none == nil and why:find("no raw cells", 1, true), why)
  end
end

local function test_load_follows_the_rows_own_column_order()
  local rows = assert(dataset.read("csv", "z,a,m\n1,2,3\n"))
  local made = assert(dataset.load(memory(), "t", rows))
  assert(table.concat(made.columns, ",") == "z,a,m,_json", table.concat(made.columns, ","))
end

local function test_a_csv_table_follows_the_header_and_json_stays_sorted()
  local rows = assert(dataset.read("csv", "z,a,m\n1,2,3\n"))
  local db = memory()
  local made = assert(dataset.load(db, "t", rows))
  assert(table.concat(made.columns, ",") == "z,a,m,_json", table.concat(made.columns, ","))
  local star = Sqlite.text_rows(db, "SELECT * FROM t")
  assert(star ~= nil and star[1][1] == "1" and star[1][2] == "2" and star[1][3] == "3")
  -- Rows with no order of their own are in byte order.
  local db2 = memory()
  assert(table.concat(assert(dataset.load(db2, "t", { { z = 1, a = 2 } })).columns, ",") == "a,z,_json")
  local json = assert(dataset.read("json", '[{"z": 1, "a": 2}]'))
  assert(json.columns == nil)
  -- A key the reader lists that no row has is still a column, one listed
  -- twice counts once, and the others follow in byte order.
  local listed = assert(dataset.read("json", '[{"b": 1, "a": 2}]'))
  listed.columns = { "q", "b", "q" }
  local extra = assert(dataset.load(memory(), "t", listed))
  assert(table.concat(extra.columns, ",") == "q,b,a,_json", table.concat(extra.columns, ","))
  -- A header alone is a table of empty columns.
  local none = assert(dataset.read("csv", "x,y\n"))
  local empty = assert(dataset.load(memory(), "t", none))
  assert(table.concat(empty.columns, ",") == "x,y,_json" and empty.count == 0)
end

local function test_a_one_column_csv_keeps_an_interior_blank_line_as_null()
  local rows = assert(dataset.read("csv", "a\n1\n\n3\n\n"))
  assert(#rows == 3)
  local db2 = memory()
  assert(dataset.load(db2, "t", rows))
  assert(#grid(db2, "SELECT 1 FROM t WHERE a IS NULL") == 1)
end

local function test_minus_zero_loads_as_the_integer_zero()
  local got = csv_cells("a,b\n-0,-0.0\n")
  assert(got == "integer:0|real:0.0", got)
end

--- A CSV file as a table, then a question about it as SQL: the columns
--- follow the header, a number is a number, and an empty cell is NULL.
local function test_a_csv_file_answers_a_sum_by_group()
  local rows = assert(dataset.read("csv", "type,balance\nsavings,10\nchecking,5\nsavings,2.5\nchecking,\n"))
  local db = memory()
  local made = assert(dataset.load(db, "accounts", rows))
  assert(table.concat(made.columns, ",") == "type,balance,_json")
  local totals = assert(Sqlite.text_rows(db,
    "SELECT type, sum(balance) FROM accounts GROUP BY type ORDER BY type"))
  assert(totals[1][1] == "checking" and totals[1][2] == "5")
  assert(totals[2][1] == "savings" and totals[2][2] == "12.5")
end

--- JSON rows carry no column order, so a key one row lacks is NULL there
--- and the columns come in byte order; the format follows the extension.
local function test_json_rows_have_null_for_a_missing_key_and_byte_order_columns()
  local db, made = loaded('[{"id": 1, "type": "a"}, {"id": 2}]', "accounts")
  assert(table.concat(made.columns, ",") == "id,type,_json")
  local nulls = assert(Sqlite.rows(db, "SELECT id FROM accounts WHERE type IS NULL"))
  assert(#nulls == 1 and nulls[1][1].integer == 2)
  assert(dataset.format_of("accounts.jsonl") == "ndjson")
end
