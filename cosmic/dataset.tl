--- Data files as SQLite tables: the loader behind `cosmic sql --from`.
---
--- A format is a reader that turns a file's text into rows, and `load`
--- builds one table from any rows, so a question about a data file -- sum
--- the balances by type -- is a SQL statement over a table rather than a
--- script:
---
---     local rows = assert(Dataset.read("json", '[{"id": 1, "type": "a"}, {"id": 2}]'))
---     local db = assert(Sqlite.memory())
---     local table = assert(Dataset.load(db, "accounts", rows))
---     -- columns id, type, _json; the second row's type is NULL
---
--- A row is an object: a table from column name to value, the shape
--- `Json.decode(text, { null_value = Json.null })` gives an object. The
--- table `load` makes has:
---
--- - one column per key any row has, with no declared type, so SQLite
---   keeps each value as it was stored. A row without a key holds NULL
---   there. The order is [`LoadOptions.columns`] when given, else the
---   order the rows carry ([`Rows.columns`], a CSV's header), and any other
---   key follows in byte order: rows with no order are in byte order
---   throughout.
--- - a `_json` column last: the whole row as compact JSON text, keys
---   sorted, so `json_extract(_json, '$.a.b')` reaches anything.
--- - scalars stored as SQLite values: a JSON integer as INTEGER, a
---   number with a fraction or exponent as REAL, a string as TEXT,
---   [`Json.null`] as NULL, and a boolean as the integer 0 or 1 (SQLite has
---   no boolean; `WHERE flag` and `WHERE flag = 1` both read a `true`).
---   A number outside 64 bits is REAL.
--- - a nested object or array stored as its JSON text, which
---   `json_extract` and `json_each` read. It is TEXT, so
---   `typeof(col) = 'text'` cannot tell it from a string: `json_valid`
---   and `json_type` can.
---
--- A key that cannot be a column name as it is gets another, and
--- [`Table.renamed`] says which: SQLite folds ASCII case in names, so a key
--- whose lower case an earlier column has (`A` after `a`) gets `_2` after
--- it (`A_2`), or `_3` and on; the empty key is `_`; a NUL byte in a key,
--- which SQL text cannot hold, is `_`; a key `_json` is renamed the same
--- way while the row's own `_json` column is there; and so are `rowid`,
--- `oid` and `_rowid_`, which would otherwise shadow SQLite's own row id
--- (`rowid_2`).
--- Names are quoted (`"` doubled), so a space, a dot or a keyword in a key
--- is no trouble in the statement either, written in double quotes.
---
--- The `csv` and `tsv` formats ([`cosmic.csv`] reads them) make a row of each
--- record after the header, its columns the header's names. A cell that is
--- plainly a number is INTEGER or REAL: an optional `-`, digits and an
--- optional fraction or exponent, with no `+`, no leading zeros (`0` and
--- `0.5` only) and no spaces, so `007`, `+1`, ` 1`, `1e5x`, `.5` and `1.`
--- stay text; a number past 64 bits is REAL, as in JSON, and one too large
--- for a real (`1e999`) stays text. An empty cell is NULL, not `''`, as a
--- file's missing value is: `WHERE x IS NULL` finds it and `x = ''` does
--- not. With `raw` every cell is text as written, the empty one `''`. A
--- row's `_json` holds the same values, an empty cell `null`, so a CSV
--- row is the JSON object of the file's JSON twin. `-0` is a plain
--- number and loads as the integer 0, and `-0.0` as the real 0.0: no sign
--- shows through SQL or `_json`. The columns follow the header's order, so
--- `SELECT *` reads the file's own columns left to right; the JSON
--- formats' rows carry no order and their columns are in byte order.
--- A file whose header has no rows still has its columns (all of them
--- empty).
---
--- The formats are a table kept here, one entry each -- a name, the
--- file extensions it goes by, and a reader from text to rows -- so a
--- format is added as one entry and `cosmic sql --from` takes it by name
--- and by extension with no other change.

local Csv = require("cosmic.csv")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")

local record Dataset
  --- One row: a column name's key to its value. A value is a string, a
  --- number, a boolean, [`Json.null`], or a table (a nested object or
  --- array, stored as JSON text).
  type Row = {string:any}

  --- The rows a reader made, and the order of their keys when the format
  --- has one (a CSV's header): `load` puts the columns in it unless
  --- `opts.columns` says otherwise.
  record Rows is {Dataset.Row}
    --- The column names, in the order the format gives them.
    columns: {string}
  end

  --- What a reader may be told.
  record ReadOptions
    --- Where in the document the rows are, as [`Json.parse_path`] gives
    --- it: the whole document when nil. Only a format that reads a
    --- document takes one (`json`); the others refuse it.
    at: {string | integer}
    --- Keep every cell as the text it is: no number is read and an empty
    --- cell is `''`, not NULL. Only a format of text cells (`csv`,
    --- `tsv`) takes it; the JSON formats, typed by their syntax, refuse it.
    raw: boolean
  end

  --- What `load` may be told.
  record LoadOptions
    --- Add the `_json` column (default true).
    json_column: boolean
    --- The keys whose columns come first, in this order, even for a key
    --- no row has; any other key follows, in byte order. Nil is the
    --- rows' own order ([`Rows.columns`]), byte order if they have none.
    --- A key listed twice counts once.
    columns: {string}
  end

  --- A table `load` made.
  record Table
    --- The table's name, as `load` was given it.
    name: string
    --- The rows loaded.
    count: integer
    --- The columns, in order: each key's column, then `_json` unless
    --- `json_column` was false.
    columns: {string}
    --- A column that is not its key as written, to that key: see the
    --- module comment. Absent for a column named as its key.
    renamed: {string:string}
  end

  --- One format: what `read` looks up by name.
  record Format
    --- What it is, for a message.
    about: string
    --- The file extensions it goes by, lower case, without the dot.
    extensions: {string}
    --- The rows text holds, and ""; nil and why when it is not the
    --- format or an option does not apply.
    read: function(text: string, opts: Dataset.ReadOptions): Dataset.Rows | nil, string
  end
end

--- A row for one JSON value: an object is the row; anything else (a
--- number, a string, a nested array) is a row of one column, `value`.
local function row_of(element: any): Dataset.Row
  local object, _ = Json.entries(element)
  if object ~= nil then
    return object
  end
  return { value = element }
end

--- The rows of a JSON value: each element of an array is a row as
--- [`row_of`] makes it; a value that is not an array is one row.
local function rows_of(value: any): Dataset.Rows
  local rows: Dataset.Rows = {}
  local items, _ = Json.items(value)
  if items == nil then
    rows[1] = row_of(value)
    return rows
  end
  for index, element in ipairs(items) do
    rows[index] = row_of(element)
  end
  return rows
end

--- The value of one CSV cell: an integer or a real when it is plainly a
--- number (see the module comment), [`Json.null`] when empty, and the text
--- otherwise.
local function cell_of(text: string): any
  if text == "" then
    return Json.null
  end
  local at = text:byte(1) == 45 and 2 or 1
  local first = text:byte(at)
  if first == 48 then
    at = at + 1
  elseif first ~= nil and first >= 49 and first <= 57 then
    at = text:find("%D", at) or #text + 1
  else
    return text
  end
  local plain = true
  if text:byte(at) == 46 then
    local digits = text:match("^%d+", at + 1)
    if digits == nil then
      return text
    end
    at = at + 1 + #digits
    plain = false
  end
  local mark = text:byte(at)
  if mark == 101 or mark == 69 then
    local digits = text:match("^[+-]?%d+", at + 1)
    if digits == nil then
      return text
    end
    at = at + 1 + #digits
    plain = false
  end
  if at <= #text then
    return text
  end
  local value = tonumber(text)
  if value == nil or value ~= value or value == math.huge or value == -math.huge then
    return text
  end
  if plain and math.type(value) == "integer" then
    return value
  end
  return value + 0.0
end

--- A reader of the delimited text `Csv` reads with `delimiter`.
local function delimited(name: string, delimiter: string): function(text: string, opts: Dataset.ReadOptions): Dataset.Rows | nil, string
  return function(text: string, opts: Dataset.ReadOptions): Dataset.Rows | nil, string
    if opts.at ~= nil then
      return nil, "the " .. name .. " format takes no path: each record is a row"
    end
    local made, trouble = Csv.table(text, { delimiter = delimiter })
    if made == nil then
      return nil, trouble
    end
    local rows: Dataset.Rows = {}
    rows.columns = made.columns
    for index, record in ipairs(made.rows) do
      local row: Dataset.Row = {}
      for key, cell in pairs(record) do
        row[key] = opts.raw and cell or cell_of(cell)
      end
      rows[index] = row
    end
    return rows, ""
  end
end

local formats: {string:Dataset.Format} = {
  json = {
    about = "one JSON document: an array of objects is a table of them, an array " ..
      "of anything else a `value` column, and any other value one row",
    extensions = { "json" },
    read = function(text: string, opts: Dataset.ReadOptions): Dataset.Rows | nil, string
      if opts.raw then
        return nil, "the json format has no raw cells: its values are typed by JSON"
      end
      local document, trouble = Json.decode(text, { null_value = Json.null })
      if trouble ~= "" then
        return nil, trouble
      end
      local value, missing = Json.get(document, opts.at or {})
      if missing ~= "" then
        return nil, missing
      end
      return rows_of(value), ""
    end,
  },
  ndjson = {
    about = "JSON Lines: one JSON value to a line, an object a row and anything else a `value`",
    extensions = { "ndjson", "jsonl" },
    read = function(text: string, opts: Dataset.ReadOptions): Dataset.Rows | nil, string
      if opts.at ~= nil then
        return nil, "the ndjson format takes no path: each line is a row"
      end
      if opts.raw then
        return nil, "the ndjson format has no raw cells: its values are typed by JSON"
      end
      local values, trouble = Json.decode_lines(text, { null_value = Json.null })
      if values == nil then
        return nil, trouble
      end
      return rows_of(values), ""
    end,
  },
  csv = {
    about = "comma-separated values: a header line names the columns, each later line is a row",
    extensions = { "csv" },
    read = delimited("csv", ","),
  },
  tsv = {
    about = "tab-separated values: a header line names the columns, each later line is a row",
    extensions = { "tsv", "tab" },
    read = delimited("tsv", "\t"),
  },
}

--- The names of the formats there are, sorted: `csv`, `json`, `ndjson`, `tsv`.
function Dataset.names(): {string}
  local names: {string} = {}
  for name in pairs(formats) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- What the format `name` is, for a message: nil when there is none.
function Dataset.about(name: string): string | nil
  local format = formats[name]
  return format and format.about
end

--- The format a file name's extension names, case aside -- `json` for
--- `a.json`, `ndjson` for `a.jsonl` and `a.ndjson`, `tsv` for `a.tab` --
--- or nil and why (the extensions there are) when it has none or an
--- unknown one.
function Dataset.format_of(path: string): string | nil, string
  local extension = path:match("%.([^./]+)$")
  local known: {string} = {}
  for _, name in ipairs(Dataset.names()) do
    for _, each in ipairs(formats[name].extensions) do
      if extension ~= nil and extension:lower() == each then
        return name, ""
      end
      known[#known + 1] = "." .. each
    end
  end
  table.sort(known)
  return nil, (extension and "unknown extension ." .. extension or "no extension") ..
    " (known: " .. table.concat(known, ", ") .. ")"
end

--- The rows `text` holds in the format `name`, and ""; nil and why when
--- there is no such format (the ones there are), the text is not that
--- format, or `opts.at` or `opts.raw` is given to a format that takes none.
function Dataset.read(name: string, text: string, opts?: Dataset.ReadOptions): Dataset.Rows | nil, string
  local format = formats[name]
  if format == nil then
    return nil, "no format " .. name .. " (known: " .. table.concat(Dataset.names(), ", ") .. ")"
  end
  return format.read(text, opts or {})
end

--- `name` as an SQL identifier, quoted.
local function quoted(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

--- One value as a bound parameter, or nil and why.
local function bound(value: any): Sqlite.Value | nil, string
  if value == Json.null or value == nil then
    return {}
  elseif value is string then
    return { text = value }
  elseif value is boolean then
    return { integer = value and 1 or 0 }
  elseif value is integer then
    return { integer = value }
  elseif value is number then
    return { number = value }
  elseif value is table then
    local text, trouble = Json.encode(value)
    if text == nil then
      return nil, trouble
    end
    return { text = text }
  end
  return nil, "a " .. type(value) .. " has no SQLite value"
end

--- The columns for `rows`' keys: those of `first`, then the rest in byte
--- order, each named as the module comment says. Also the key each
--- column holds, and the key each renamed column was.
local function columns_of(rows: {Dataset.Row}, json_column: boolean, first: {string} | nil): {string}, {string:string}, {string:string}
  local seen: {string:boolean} = {}
  local keys: {string} = {}
  for _, key in ipairs(first or {}) do
    if not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end
  local rest: {string} = {}
  for _, row in ipairs(rows) do
    for key in pairs(row) do
      if not seen[key] then
        seen[key] = true
        rest[#rest + 1] = key
      end
    end
  end
  table.sort(rest)
  for _, key in ipairs(rest) do
    keys[#keys + 1] = key
  end
  local taken: {string:boolean} = { _json = json_column or nil, rowid = true, oid = true, _rowid_ = true }
  local names: {string} = {}
  local key_of: {string:string} = {}
  local renamed: {string:string} = {}
  for _, key in ipairs(keys) do
    local name = key == "" and "_" or (key:gsub("\0", "_"))
    local candidate = name
    local number = 1
    while taken[candidate:lower()] do
      number = number + 1
      candidate = name .. "_" .. number
    end
    taken[candidate:lower()] = true
    names[#names + 1] = candidate
    key_of[candidate] = key
    if candidate ~= key then
      renamed[candidate] = key
    end
  end
  return names, key_of, renamed
end

--- SQLite's default limit on the columns of a table.
local max_columns <const> = 2000

--- Makes the table `name` on `handle` from `rows` and inserts them, in
--- one transaction, so a failure leaves no table. The columns and how a
--- value is stored are the module comment's. Answers the table it made;
--- nil and why when `name` is empty, there are more keys than SQLite holds
--- columns (2000, `_json` among them), SQLite refuses the table (it
--- exists, or `name` is reserved) or a row, a row holds a value with
--- no SQLite one, or a nested value cannot be encoded.
--- `name` is written into SQL text, so it holds no NUL byte.
function Dataset.load(handle: Sqlite.Handle, name: string, rows: Dataset.Rows,
                      opts?: Dataset.LoadOptions): Dataset.Table | nil, string
  if name == "" then
    return nil, "a table needs a name"
  end
  if name:find("\0", 1, true) then
    return nil, "a table name cannot hold a NUL byte"
  end
  local json_column = not (opts and opts.json_column == false)
  local columns_given: {string} | nil = rows.columns
  if opts and opts.columns then
    columns_given = opts.columns
  end
  local names, key_of, renamed = columns_of(rows, json_column, columns_given)
  if #names + (json_column and 1 or 0) > max_columns then
    return nil, "too many columns: " .. String.counted(#names, "distinct key") .. ", and SQLite holds at most " ..
      String.counted(max_columns, "column") .. " in a table" .. (json_column and " (one is `_json`)" or "")
  end
  local declared: {string} = {}
  local marks: {string} = {}
  for index, column in ipairs(names) do
    declared[index] = quoted(column)
    marks[index] = "?" .. index
  end
  local width = #names
  if json_column then
    declared[width + 1] = quoted("_json")
    marks[width + 1] = "?" .. (width + 1)
  end
  local insert = "INSERT INTO " .. quoted(name) .. " VALUES (" .. table.concat(marks, ", ") .. ")"
  local ok, trouble = Sqlite.transact(handle, function(): boolean, string
    local created, why = handle:exec("CREATE TABLE " .. quoted(name) ..
      " (" .. table.concat(declared, ", ") .. ")")
    if not created then
      return false, why
    end
    for number, row in ipairs(rows) do
      local values: {Sqlite.Value} = {}
      for index, column in ipairs(names) do
        local value, bad = bound(row[key_of[column]])
        if value == nil then
          return false, "row " .. number .. ", " .. column .. ": " .. bad
        end
        values[index] = value
      end
      if json_column then
        local text, bad = Json.encode(row)
        if text == nil then
          return false, "row " .. number .. ": " .. bad
        end
        values[width + 1] = { text = text }
      end
      local inserted, bad = Sqlite.run(handle, insert, values)
      if not inserted then
        return false, "row " .. number .. ": " .. bad
      end
    end
    return true, ""
  end)
  if not ok then
    return nil, trouble
  end
  local columns: {string} = {}
  for index, column in ipairs(names) do
    columns[index] = column
  end
  if json_column then
    columns[width + 1] = "_json"
  end
  return { name = name, count = #rows, columns = columns, renamed = renamed }, ""
end

return Dataset
