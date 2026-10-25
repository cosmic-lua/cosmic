--- Fuzz properties for [`build.dataset`], whose readers take a data file's
--- bytes and whose loader takes any keys: reading is total on any text,
--- and a row loaded is a row read back through `_json`, whatever its keys
--- (dots, quotes, case twins, the empty key, `_json` itself).
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local dataset = require("build.dataset")
local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")

--- Keys that need care, drawn more often than chance would.
local KEYS <const> = { "a", "A", "id", "type", "value", "_json", "_JSON", "_json_2", "", "_", "a b", "a.b",
  '"', 'a"b', "select", "\n", "\x7f", "\xc3\xa9", "\xff", "1", "a_2" }

--- Values by index: each SQLite type, a boolean, null, nested and edge.
local function value_at(index: integer): any
  local values: {any} = { 1, -7, 2.5, 1e300, "x", "", "a\0b", true, false, Json.null,
    Json.array({ 1, "two" }), { k = { "deep" } }, Json.array(), {} }
  return values[index]
end

--- Rows as packed triples: `r` starts a row; `p`, a key and a value index
--- add a pair to the row before it. Each is drawn with [`Fuzz.more`], so
--- shrinking can cut any row or pair.
local function gen_rows(src: Fuzz.Source): string
  local fields: mut {string} = {}
  local rows = 0
  while Fuzz.more(src, rows, 4) do
    rows = rows + 1
    fields[#fields + 1] = "r"
    fields[#fields + 1] = ""
    fields[#fields + 1] = ""
    local count = 0
    while Fuzz.more(src, count, 4) do
      count = count + 1
      fields[#fields + 1] = "p"
      fields[#fields + 1] = src:int(0, 11) == 0 and Fuzz.bytes(src, 4) or Fuzz.pick(src, KEYS)
      fields[#fields + 1] = tostring(src:int(1, 14))
    end
  end
  return Fuzz.pack(fields)
end

local function rows_from(input: string): {dataset.Row}
  local fields = Fuzz.unpack(input)
  local rows: mut {dataset.Row} = {}
  for at = 1, #fields - 2, 3 do
    if fields[at] == "r" then
      rows[#rows + 1] = {}
    elseif rows[#rows] ~= nil then
      rows[#rows][fields[at + 1]] = value_at(math.tointeger(tonumber(fields[at + 2])) or 1)
    end
  end
  return rows
end

-- Any rows load, into distinct columns, and each row reads back whole.
local function test_a_loaded_row_reads_back_through_json(tmp: string)
  Fuzz.run({
    name = "dataset load round trip",
    dir = tmp,
    gen = gen_rows,
    requires = { "renamed", "plain", "no rows", "refused" },
    shares = { renamed = 0.05, refused = 0.02 },
    check = function(input: string): boolean, string
      local rows = rows_from(input)
      local db = assert(Sqlite.memory())
      local ok, made, why = pcall(dataset.load, db, "t", rows)
      if not ok then return false, "raised: " .. tostring(made) end
      if made == nil then
        -- A key that is not UTF-8 (which no decoder makes) cannot be
        -- written into `_json`, and the load leaves no table.
        local text_keys = false
        for _, row in ipairs(rows) do
          for key in pairs(row) do
            if utf8.len(key) == nil then text_keys = true end
          end
        end
        if not text_keys or Sqlite.rows(db, "SELECT 1 FROM t") ~= nil then
          return false, "refused: " .. why
        end
        Fuzz.label("refused")
        return true, ""
      end
      if #rows == 0 then Fuzz.label("no rows") end
      if next(made.renamed) ~= nil then Fuzz.label("renamed") else Fuzz.label("plain") end
      if made.count ~= #rows then return false, "counted " .. made.count .. " of " .. #rows end
      local seen: mut {string:boolean} = {}
      for _, column in ipairs(made.columns) do
        if seen[column:lower()] then return false, column .. " is a column twice" end
        seen[column:lower()] = true
      end
      local keys: mut {string:boolean} = {}
      local distinct = 0
      for _, row in ipairs(rows) do
        for key in pairs(row) do
          if not keys[key] then distinct = distinct + 1 end
          keys[key] = true
        end
      end
      if #made.columns ~= distinct + 1 then
        return false, #made.columns .. " columns for " .. distinct .. " keys"
      end
      local texts, trouble = Sqlite.text_rows(db, "SELECT _json FROM t ORDER BY rowid")
      if texts == nil then return false, trouble end
      for index, row in ipairs(rows) do
        local expected = assert(Json.encode_any(row))
        if texts[index]:text(1) ~= expected then
          return false, "row " .. index .. " read back as " .. texts[index]:text(1) .. ", not " .. expected
        end
      end
      return true, ""
    end,
  })
end

local SAMPLES <const> = {
  "[]", "{}", "[{}]", '[{"a": 1}, {"b": [1, 2]}]', '[1, "x", null, [2], {"a": {"b": 1}}]',
  '{"rows": [{"a": 1}]}', '{"a": 1}\n{"a": 2}\n', '\n\n{"a": null}\r\n7\n', "null", "42", '"s"',
  '[{"": 1, "A": 2, "a": 3, "_json": 4}]', "{", "[{", '{"a": 1}\n{', "\xff\xfe", "",
}

local TOKENS <const> = { "[", "]", "{", "}", ":", ",", '"', "a", "1", "null", "true", "\n", " ", "\0", "\xff" }

local function gen_text(src: Fuzz.Source): string
  local format = if src:int(0, 1) == 0 then "json" else "ndjson" end
  local text: string
  if src:int(0, 3) == 0 then
    local parts: mut {string} = {}
    while Fuzz.more(src, #parts, 20) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    text = table.concat(parts)
  else
    text = Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), if src:int(0, 1) == 0 then 0 else 4 end)
  end
  return Fuzz.pack({ format, text })
end

-- Any text is rows or a message, never a raise, and rows always load.
local function test_a_reader_is_total_on_any_text(tmp: string)
  Fuzz.run({
    name = "dataset read total",
    dir = tmp,
    gen = gen_text,
    requires = { "read", "refused" },
    shares = { read = 0.15, refused = 0.15 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local ok, rows, why = pcall(dataset.read, fields[1], fields[2])
      if not ok then return false, "raised: " .. tostring(rows) end
      if rows == nil then
        Fuzz.label("refused")
        if why == "" then return false, "a refusal with no message" end
        return true, ""
      end
      Fuzz.label("read")
      local db = assert(Sqlite.memory())
      local loaded, trouble = dataset.load(db, "t", rows)
      if loaded == nil then return false, "rows read but not loaded: " .. trouble end
      if loaded.count ~= #rows then return false, "counted " .. loaded.count .. " of " .. #rows end
      return true, ""
    end,
  })
end

--- A cell a query reads: its kind and the field of that name.
local record Expected
  kind: Sqlite.Kind
  integer?: integer
  number?: number
  text?: string
end

--- What [`dataset.load`] stores for `value`, as the cell a query reads.
local function expected_cell(value: any): Expected
  if value == nil or value == Json.null then return { kind = "null" } end
  if value is boolean then return { kind = "integer", integer = if value then 1 else 0 end } end
  if value is integer then return { kind = "integer", integer = value } end
  if value is number then return { kind = "number", number = value } end
  if value is string then return { kind = "text", text = value } end
  return { kind = "text", text = assert(Json.encode(value)) }
end

-- Whatever the key, `SELECT "<column>"` reads back its value from each
-- row: what the quoting and the renaming exist for.
local function test_each_key_reads_back_by_its_column(tmp: string)
  Fuzz.run({
    name = "dataset column read back",
    dir = tmp,
    gen = gen_rows,
    requires = { "renamed", "quoted", "read" },
    shares = { renamed = 0.05, quoted = 0.15 },
    check = function(input: string): boolean, string
      local rows = rows_from(input)
      local db = assert(Sqlite.memory())
      local made = dataset.load(db, "t", rows)
      if made == nil then return true, "" end
      local column_of: mut {string:string} = {}
      -- The last column is the row's own `_json`, no key's.
      for index = 1, #made.columns - 1 do
        local column = made.columns[index]
        column_of[made.renamed[column] or column] = column
      end
      for key, column in pairs(column_of) do
        do
          if column ~= key then Fuzz.label("renamed") end
          if not key:match("^[%a_][%w_]*$") then Fuzz.label("quoted") end
          local got, trouble = Sqlite.rows(db, 'SELECT "' .. column:gsub('"', '""') .. '" FROM t ORDER BY rowid')
          if got == nil then return false, column .. ": " .. trouble end
          for index, row in ipairs(rows) do
            local want = expected_cell(row[key])
            local read = got[index]
            local kind = read:kind(1)
            Fuzz.label("read")
            if kind ~= want.kind or (kind == "integer" and read:integer(1) ~= want.integer) or
                (kind == "number" and read:number(1) ~= want.number) or
                (kind == "text" and read:text(1) ~= want.text) then
              return false, "key " .. Json.quote(key) .. " row " .. index .. " read as " .. kind
            end
          end
        end
      end
      return true, ""
    end,
  })
end

--- Cells for a CSV or TSV: numbers plain and not, the empty cell, quotes,
--- delimiters, line breaks, a NUL and bytes that are no UTF-8.
local CELLS <const> = { "1", "-0", "007", "2.5", "-0.0", "1e999", "1e-400", "12345678901234567890", "",
  "x", 'a"b', "a,b", "a\tb", "a\nb", "a\r\nb", " ", "\xff", "\xc3\xa9", "\0", "rowid", "_json", "A", "a" }

--- One field as CSV writes it: quoted when it holds the delimiter, a
--- quote or a line break.
local function written(field: string, delimiter: string): string
  if field:find(delimiter, 1, true) or field:find('[\r\n"]') then
    return '"' .. field:gsub('"', '""') .. '"'
  end
  return field
end

--- A csv or tsv of a few rows of those cells, its header among them too;
--- now and then mutated, so a fault is read as well as a table.
local function gen_delimited(src: Fuzz.Source): string
  local format = if src:int(0, 1) == 0 then "csv" else "tsv" end
  local delimiter = if format == "csv" then "," else "\t" end
  local width = src:int(1, 4)
  local lines: mut {string} = {}
  local rows = src:int(0, 4)
  for row = 0, rows do
    local fields: mut {string} = {}
    for column = 1, width do
      local cell = if row == 0 and src:int(0, 2) == 0 then "h" .. column else Fuzz.pick(src, CELLS) end
      fields[column] = written(cell, delimiter)
    end
    lines[#lines + 1] = table.concat(fields, delimiter)
  end
  local text = table.concat(lines, "\n") .. (if src:int(0, 1) == 0 then "\n" else "" end)
  if src:int(0, 3) == 0 then
    text = Fuzz.mutate(src, text, 3)
  end
  return Fuzz.pack({ format, text, if src:int(0, 1) == 0 then "path" else "text" end, if src:int(0, 1) == 0 then "raw" else "" end })
end

--- Each row of `t` on `db`: its cells as `quote` writes them, then its
--- `_json` object's members, each key, JSON type and value, and what a
--- JSON function takes `_json` for: text, not an object.
local function cells_of(db: Sqlite.Handle, columns: {string}): string
  local quoted: mut {string} = {}
  for index, column in ipairs(columns) do
    quoted[index] = 'quote("' .. column:gsub('"', '""') .. '")'
  end
  -- A text with no records makes a table of `_json` alone.
  if #quoted == 0 then
    quoted[1] = "''"
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT " .. table.concat(quoted, " || '|' || ") ..
      ", (SELECT group_concat(key || ':' || type || ':' || quote(atom), ',') FROM json_each(t._json))" ..
      ", json_type(json_object('row', t._json), '$.row') FROM t ORDER BY rowid"))
  local out: mut {string} = {}
  for index, row in ipairs(rows) do
    out[index] = table.concat(row:texts(), " ; ")
  end
  return table.concat(out, "\n")
end

--- A csv or tsv that `load_text` copies through SQLite's CSV table is the
--- table `read` and `load` make of it, cell for cell, with the same
--- columns, renamings and `_json` members; and what one refuses the other
--- refuses with the same words.
local function test_load_text_makes_the_table_read_and_load_make(tmp: string)
  local Fs = require("cosmic.fs")
  local path = tmp .. "/rows"
  Fuzz.run({
    name = "dataset load_text agrees with read and load",
    dir = tmp,
    gen = gen_delimited,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local format, text, how, raw = fields[1], fields[2], fields[3], fields[4] == "raw"
      local fast_db = assert(Sqlite.memory())
      local slow_db = assert(Sqlite.memory())
      local file: string? = nil
      if how == "path" then
        assert(Fs.write(path, text))
        file = path
      end
      local fast, fast_why = dataset.load_text(fast_db, "t", format, text, { raw = raw }, file)
      local slow: dataset.Table?
      local slow_why: string
      local rows, read_why = dataset.read(format, text, { raw = raw })
      if rows == nil then
        slow, slow_why = nil, read_why
      else
        slow, slow_why = dataset.load(slow_db, "t", rows)
      end
      local function closed(ok: boolean, why: string): boolean, string
        assert(fast_db:close())
        assert(slow_db:close())
        return ok, why
      end
      if fast == nil or slow == nil then
        Fuzz.label("refused")
        if (fast == nil) ~= (slow == nil) or fast_why ~= slow_why then
          return closed(false, string.format("%q: load_text answered %s, read and load %s", text,
            if fast then "a table" else fast_why end, if slow then "a table" else slow_why end))
        end
        return closed(true, "")
      end
      Fuzz.label("read")
      if table.concat(fast.columns, "\0") ~= table.concat(slow.columns, "\0") or fast.count ~= slow.count then
        return closed(false, string.format("%q: columns %s (%d rows), read and load %s (%d)", text,
          table.concat(fast.columns, ","), fast.count, table.concat(slow.columns, ","), slow.count))
      end
      for _, column in ipairs(slow.columns) do
        if fast.renamed[column] ~= slow.renamed[column] then
          return closed(false, string.format("%q: %s is the key %q, not %q", text, column,
            tostring(slow.renamed[column]), tostring(fast.renamed[column])))
        end
      end
      local data_columns = table.move(fast.columns, 1, #fast.columns - 1, 1, {})
      local got, want = cells_of(fast_db, data_columns), cells_of(slow_db, data_columns)
      if got ~= want then
        return closed(false, string.format("%q: load_text's rows\n%s\nread and load's\n%s", text, got, want))
      end
      if fast.copied then
        Fuzz.label("copied in C")
        if format == "tsv" then Fuzz.label("tsv copied in C") end
      end
      return closed(true, "")
    end,
    requires = { "read", "refused", "copied in C", "tsv copied in C" },
  })
end
