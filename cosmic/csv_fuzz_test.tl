--- Fuzz properties for `cosmic.csv`, which reads untrusted bytes: what
--- `encode` writes `parse` reads back, in any of the delimiters; `parse`
--- and `rows` are total on any bytes, and what they read is a fixed point
--- of writing and reading again; and a defect put into well-formed text is
--- refused naming the line and column it was put at.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Csv = require("cosmic.csv")
local Fuzz = require("build.fuzz")

local DELIMITERS <const> = { ",", "\t", ";", "|" }

--- Fields that need care, drawn more often than chance would.
local FIELDS <const> = { "", "a", "1", " ", "a b", ",", "\t", ";", '"', '""', 'a"b', "\n", "\r\n", "\r", "a\nb",
  ',"', "\xEF\xBB\xBF", "\xEF\xBB\xBFx", "\0", "\xff", "\xc3\xa9", "007", "-1.5e3", "|" }

--- One field of a drawn record.
local function field(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then return Fuzz.bytes(src, 6) end
  return Fuzz.pick(src, FIELDS)
end

--- A delimiter and records as packed strings: the delimiter first, then
--- `r` to start a record and `f<text>` to add a field to it. Drawn with
--- `Fuzz.more`, so shrinking can cut any record or field.
local function gen_records(src: Fuzz.Source): string
  local parts: {string} = { Fuzz.pick(src, DELIMITERS) }
  local records = 0
  while Fuzz.more(src, records, 6) do
    records = records + 1
    parts[#parts + 1] = "r"
    local count = 0
    while Fuzz.more(src, count, 5) do
      count = count + 1
      parts[#parts + 1] = "f" .. field(src)
    end
  end
  return Fuzz.pack(parts)
end

--- The delimiter and the records `gen_records` packed; a record with no
--- field is dropped, as text cannot hold it.
local function records_from(input: string): string, {{string}}
  local parts = Fuzz.unpack(input)
  local records: {{string}} = {}
  local current: {string} = {}
  local started = false
  for index = 2, #parts do
    if parts[index] == "r" then
      started = false
    elseif parts[index]:sub(1, 1) == "f" then
      if not started then
        current = {}
        records[#records + 1] = current
        started = true
      end
      current[#current + 1] = parts[index]:sub(2)
    end
  end
  return parts[1] or ",", records
end

local function same(a: {{string}}, b: {{string}}): boolean
  if #a ~= #b then return false end
  for number, record in ipairs(a) do
    if #record ~= #b[number] then return false end
    for index, value in ipairs(record) do
      if value ~= b[number][index] then return false end
    end
  end
  return true
end

-- Whatever the fields hold, parse(encode(records)) is the records.
local function test_what_encode_writes_parse_reads_back(tmp: string)
  Fuzz.run({
    name = "csv round trip",
    dir = tmp,
    gen = gen_records,
    requires = { "quoted", "plain", "multiline", "empty field", "no records" },
    shares = { quoted = 0.3, multiline = 0.1 },
    check = function(input: string): boolean, string
      local delimiter, records = records_from(input)
      local text, why = Csv.encode(records, { delimiter = delimiter })
      if text == nil then return false, "encode refused: " .. why end
      local back, trouble = Csv.parse(text, { delimiter = delimiter })
      if back == nil then return false, "parse refused its own text: " .. trouble end
      if not same(back, records) then return false, "read back differently from " .. text end
      if #records == 0 then Fuzz.label("no records") end
      if text:find('"', 1, true) then Fuzz.label("quoted") else Fuzz.label("plain") end
      if text:find("\n.", 1, false) and text:find('"[^"]*\n', 1, false) then Fuzz.label("multiline") end
      for _, record in ipairs(records) do
        for _, value in ipairs(record) do
          if value == "" then Fuzz.label("empty field") end
        end
      end
      return true, ""
    end,
  })
end

local SAMPLES <const> = {
  "", "a", "a,b\n1,2\n", "a,b\r\n1,2\r\n", '"a,b","c""d","e\nf"\n', '\xEF\xBB\xBFid,name\n1,"x"\n',
  "a,b,\n,,\n", 'a"b\n', '"a"b\n', '"never closed', "a\rb\n", "\n\n\n", '""\n', "a\tb\n1\t2\n",
}

local TOKENS <const> = { ",", '"', "\n", "\r\n", "\r", "\t", ";", "a", "1", " ", '""', "\0", "\xff", "\xEF\xBB\xBF" }

local function gen_text(src: Fuzz.Source): string
  local text: string
  if src:int(0, 3) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 24) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    text = table.concat(parts)
  else
    text = Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), src:int(0, 1) == 0 and 0 or 4)
  end
  return Fuzz.pack({ Fuzz.pick(src, DELIMITERS), text })
end

-- Any bytes are records or a message that names a place, never a raise;
-- what is read writes and reads back the same; `rows` agrees with `parse`.
local function test_parse_and_rows_are_total_on_any_bytes(tmp: string)
  Fuzz.run({
    name = "csv total",
    dir = tmp,
    gen = gen_text,
    requires = { "read", "refused", "ragged" },
    shares = { read = 0.2, refused = 0.1 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local options: Csv.Options = { delimiter = fields[1] }
      local ok, records, why = pcall(Csv.parse, fields[2], options)
      if not ok then return false, "parse raised: " .. tostring(records) end
      local rows_ok, rows, rows_why = pcall(Csv.rows, fields[2], options)
      if not rows_ok then return false, "rows raised: " .. tostring(rows) end
      if records == nil then
        Fuzz.label("refused")
        if not why:find("line %d+, column %d+") then return false, "no place in: " .. why end
        if rows ~= nil then return false, "rows read what parse refused" end
        return true, ""
      end
      Fuzz.label("read")
      local text = assert(Csv.encode(records, options))
      local again = Csv.parse(text, options)
      if again == nil or not same(again, records) then return false, "not a fixed point: " .. text end
      if rows == nil then
        Fuzz.label("ragged")
        if not rows_why:find("^line %d+, column 1: the record has ") then return false, "rows said: " .. rows_why end
      elseif (records[1] == nil or #records[1] > 1) and #rows ~= math.max(#records - 1, 0) then
        return false, #rows .. " rows for " .. #records .. " records"
      end
      return true, ""
    end,
  })
end

--- A well-formed table of `rows` lines of two fields drawn from a small
--- alphabet, a defect kind, and where to put it, packed.
local function gen_defect(src: Fuzz.Source): string
  local lines = src:int(1, 8)
  return Fuzz.pack({
    tostring(lines),
    tostring(src:int(1, lines)),
    tostring(src:int(1, 3)),
    (Fuzz.bytes(src, 3):gsub('[",\r\n]', "x")),
  })
end

-- A quote put in an unquoted field, a quote left open and a record of
-- another length are each refused at the line (and column) they were put.
local function test_a_defect_is_refused_at_the_place_it_was_put(tmp: string)
  Fuzz.run({
    name = "csv malformed",
    dir = tmp,
    gen = gen_defect,
    requires = { "stray", "unclosed", "ragged" },
    shares = { stray = 0.15, unclosed = 0.15, ragged = 0.15 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local lines = math.tointeger(tonumber(fields[1])) or 1
      local where = math.tointeger(tonumber(fields[2])) or 1
      local kind = math.tointeger(tonumber(fields[3])) or 1
      local filler = fields[4] or ""
      local out: {string} = {}
      for line = 1, lines do
        local text = "k" .. line .. "," .. filler .. "v"
        if line == where then
          if kind == 1 then text = "k" .. line .. "," .. filler .. 'v"w'
          elseif kind == 2 then text = "k" .. line .. ',"' .. filler .. "v"
          else text = "k" .. line .. "," .. filler .. "v,extra" end
        end
        out[line] = text
      end
      local text = table.concat(out, "\n") .. "\n"
      if kind == 3 then
        Fuzz.label("ragged")
        local rows, why = Csv.rows("h1,h2\n" .. text)
        local expected = "line " .. (where + 1) .. ", column 1: the record has 3 fields, the header 2"
        if rows ~= nil or why ~= expected then return false, "rows said " .. tostring(why) .. ", not " .. expected end
        local records = Csv.parse("h1,h2\n" .. text)
        if records == nil or #records ~= lines + 1 then return false, "parse refused a ragged table" end
        return true, ""
      end
      local column = #("k" .. where .. "," .. filler .. "v") - (kind == 1 and 0 or #filler + 1)
      local expected: string
      if kind == 1 then
        Fuzz.label("stray")
        expected = "a quote inside an unquoted field at line " .. where .. ", column " .. (column + 1)
      else
        Fuzz.label("unclosed")
        expected = "unclosed quote opened at line " .. where .. ", column " .. (#("k" .. where) + 2)
      end
      local records, why = Csv.parse(text)
      if records ~= nil or why ~= expected then return false, "parse said " .. tostring(why) .. ", not " .. expected end
      return true, ""
    end,
  })
end
