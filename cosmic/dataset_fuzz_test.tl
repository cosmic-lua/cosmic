--- Fuzz properties for `cosmic.dataset`, whose readers take a data file's
--- bytes and whose loader takes any keys: reading is total on any text,
--- and a row loaded is a row read back through `_json`, whatever its keys
--- (dots, quotes, case twins, the empty key, `_json` itself).
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Dataset = require("cosmic.dataset")
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

--- Rows as packed fields: for each row, its pair count, then each pair's
--- key and value index.
local function gen_rows(src: Fuzz.Source): string
  local fields: {string} = {}
  local rows = 0
  while Fuzz.more(src, rows, 4) do
    rows = rows + 1
    local pairs_count = src:int(0, 4)
    fields[#fields + 1] = tostring(pairs_count)
    for _ = 1, pairs_count do
      fields[#fields + 1] = src:int(0, 11) == 0 and Fuzz.bytes(src, 4) or Fuzz.pick(src, KEYS)
      fields[#fields + 1] = tostring(src:int(1, 14))
    end
  end
  return Fuzz.pack(fields)
end

local function rows_from(input: string): {Dataset.Row}
  local fields = Fuzz.unpack(input)
  local rows: {Dataset.Row} = {}
  local at = 1
  while at <= #fields do
    local row: Dataset.Row = {}
    local count = math.tointeger(tonumber(fields[at])) or 0
    at = at + 1
    for _ = 1, count do
      row[fields[at]] = value_at(math.tointeger(tonumber(fields[at + 1])) or 1)
      at = at + 2
    end
    rows[#rows + 1] = row
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
      local ok, made, why = pcall(Dataset.load, db, "t", rows)
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
      local seen: {string:boolean} = {}
      for _, column in ipairs(made.columns) do
        if seen[column:lower()] then return false, column .. " is a column twice" end
        seen[column:lower()] = true
      end
      local keys: {string:boolean} = {}
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
        local expected = assert(Json.encode(row))
        if texts[index][1] ~= expected then
          return false, "row " .. index .. " read back as " .. texts[index][1] .. ", not " .. expected
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
  local format = src:int(0, 1) == 0 and "json" or "ndjson"
  local text: string
  if src:int(0, 3) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 20) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    text = table.concat(parts)
  else
    text = Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), src:int(0, 1) == 0 and 0 or 4)
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
      local ok, rows, why = pcall(Dataset.read, fields[1], fields[2])
      if not ok then return false, "raised: " .. tostring(rows) end
      if rows == nil then
        Fuzz.label("refused")
        if why == "" then return false, "a refusal with no message" end
        return true, ""
      end
      Fuzz.label("read")
      local db = assert(Sqlite.memory())
      local loaded, trouble = Dataset.load(db, "t", rows)
      if loaded == nil then return false, "rows read but not loaded: " .. trouble end
      if loaded.count ~= #rows then return false, "counted " .. loaded.count .. " of " .. #rows end
      return true, ""
    end,
  })
end
