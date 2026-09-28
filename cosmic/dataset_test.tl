local Dataset = require("cosmic.dataset")
local Json = require("cosmic.json")
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

local function loaded(text: string, name?: string): Sqlite.Handle, Dataset.Table
  local rows = assert(Dataset.read("json", text))
  local db = memory()
  local made = assert(Dataset.load(db, name or "t", rows))
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
  local without = memory()
  local rows_of = assert(Dataset.read("json", '[{"a": 1}]'))
  local made = assert(Dataset.load(without, "t", rows_of, { json_column = false }))
  assert(table.concat(made.columns, ",") == "a")
  assert(not Sqlite.rows(without, "SELECT _json FROM t"))
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
  local rows = assert(Dataset.read("json", '{"a": {"rows": [{"id": 1}, {"id": 2}]}}',
    { at = assert(Json.parse_path("$.a.rows")) }))
  assert(#rows == 2 and rows[2].id == 2)
  local none, why = Dataset.read("json", '{"a": 1}', { at = assert(Json.parse_path("$.b")) })
  assert(none == nil and why:find('no key "b"', 1, true), why)
  local bad, bad_why = Dataset.read("json", "{", {})
  assert(bad == nil and bad_why:find("invalid JSON", 1, true), bad_why)
end

local function test_ndjson_is_a_row_per_line()
  local rows = assert(Dataset.read("ndjson", '{"a": 1}\n\n{"a": 2, "b": "x"}\r\n7\n'))
  assert(#rows == 3 and rows[2].b == "x" and rows[3].value == 7)
  local db = memory()
  local made = assert(Dataset.load(db, "t", rows))
  assert(table.concat(made.columns, ",") == "a,b,value,_json")
  assert(grid(db, "SELECT sum(a) FROM t")[1] == "i3")
  assert(#assert(Dataset.read("ndjson", "")) == 0)
  local bad, why = Dataset.read("ndjson", '{"a": 1}\n{\n')
  assert(bad == nil and why:find("line 2", 1, true), why)
  local at, at_why = Dataset.read("ndjson", "{}", { at = { "a" } })
  assert(at == nil and at_why:find("no path", 1, true), at_why)
end

local function test_formats_are_found_by_name_and_extension()
  assert(table.concat(Dataset.names(), ",") == "json,ndjson")
  assert(Dataset.format_of("a/b.json") == "json" and Dataset.format_of("x.JSONL") == "ndjson")
  assert(Dataset.format_of("x.ndjson") == "ndjson")
  local unknown, why = Dataset.format_of("data.csv")
  assert(unknown == nil and why == "unknown extension .csv (known: .json, .jsonl, .ndjson)", why)
  local none, none_why = Dataset.format_of("README")
  assert(none == nil and none_why:find("^no extension"), none_why)
  local missing, missing_why = Dataset.read("yaml", "a: 1")
  assert(missing == nil and missing_why == "no format yaml (known: json, ndjson)", missing_why)
  assert(Dataset.about("json") ~= nil and Dataset.about("yaml") == nil)
end

local function test_load_refuses_what_sqlite_or_the_caller_cannot_take()
  local db = memory()
  local rows = assert(Dataset.read("json", '[{"a": 1}]'))
  assert(Dataset.load(db, "t", rows))
  local again, why = Dataset.load(db, "T", rows)
  assert(again == nil and why:find("already exists", 1, true), why)
  local nameless, nameless_why = Dataset.load(db, "", rows)
  assert(nameless == nil and nameless_why == "a table needs a name")
  local odd = assert(Dataset.load(db, 'we"ird name', rows))
  assert(odd.name == 'we"ird name')
  local ok = Sqlite.rows(db, 'SELECT a FROM "we""ird name"')
  assert(ok ~= nil)
  local bad, bad_why = Dataset.load(db, "u", { { a = print as any } })
  assert(bad == nil and bad_why:find("row 1, a: a function has no SQLite value", 1, true), bad_why)
  -- A refused load leaves no table behind.
  assert(not Sqlite.rows(db, "SELECT * FROM u"))
end

local function test_a_nul_byte_in_a_key_or_name_is_not_sql()
  local db = memory()
  local made = assert(Dataset.load(db, "t", { { ["a\0b"] = 1, ["a_b"] = 2 } }))
  assert(table.concat(made.columns, ",") == "a_b,a_b_2,_json", table.concat(made.columns, ","))
  assert(made.renamed["a_b"] == "a\0b" and made.renamed["a_b_2"] == "a_b")
  assert(grid(db, "SELECT a_b, a_b_2 FROM t")[1] == "i1|i2")
  local bad, why = Dataset.load(db, "u\0v", {})
  assert(bad == nil and why == "a table name cannot hold a NUL byte", why)
end
