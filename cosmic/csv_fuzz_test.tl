--- Fuzz properties for [`cosmic.csv`], which reads untrusted bytes: what
--- the writer below writes `parse` reads back, in any of the delimiters;
--- `parse` and `table` are total on any bytes, and what they read is a fixed point
--- of writing and reading again; and a defect put into well-formed text is
--- refused naming the line and column it was put at; and `table` answers
--- the line each row was written to begin on.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Csv = require("cosmic.csv")
local Fuzz = require("build.fuzz")

local DELIMITERS <const> = { ",", "\t", ";", "|" }

local BOM <const> = "\xEF\xBB\xBF"

--- One field as it is written: quoted when it holds the delimiter, a
--- quote or a line break, begins with what a reader would drop as a byte
--- order mark, or is the empty only field of its record.
local function field_text(field: string, delimiter: string, only: boolean): string
  if field:find(delimiter, 1, true) or field:find('[\r\n"]') or field:sub(1, 3) == BOM or
      (only and field == "") then
    return '"' .. field:gsub('"', '""') .. '"'
  end
  return field
end

--- `records` as text, one per line ended by LF, that `parse` reads back
--- as they were; nil and why when a record has no fields, which text
--- cannot hold.
local function encode(records: {{string}}, delimiter: string): string | nil, string
  local lines: {string} = {}
  for number, record in ipairs(records) do
    if #record == 0 then
      return nil, "record " .. number .. " has no fields"
    end
    local parts: {string} = {}
    for index, field in ipairs(record) do
      parts[index] = field_text(field, delimiter, #record == 1)
    end
    lines[number] = table.concat(parts, delimiter) .. "\n"
  end
  return table.concat(lines), ""
end

--- The rows [`Csv.table`] reads, or nil and why.
local function rows_of(text: string, opts?: Csv.Options): {{string:string}} | nil, string
  local made, why = Csv.table(text, opts)
  if made == nil then
    return nil, why
  end
  return made.rows, ""
end

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
--- [`Fuzz.more`], so shrinking can cut any record or field.
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

--- The delimiter and the records [`gen_records`] packed; a record with no
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
local function test_what_is_written_parse_reads_back(tmp: string)
  Fuzz.run({
    name = "csv round trip",
    dir = tmp,
    gen = gen_records,
    requires = { "quoted", "plain", "multiline", "empty field", "no records" },
    shares = { quoted = 0.3, multiline = 0.1 },
    check = function(input: string): boolean, string
      local delimiter, records = records_from(input)
      local text, why = encode(records, delimiter)
      if text == nil then return false, "encode refused: " .. why end
      local back, trouble = Csv.parse(text, { delimiter = delimiter })
      if back == nil then return false, "parse refused its own text: " .. trouble end
      if not same(back, records) then return false, "read back differently from " .. text end
      if #records == 0 then Fuzz.label("no records") end
      if text:find('"', 1, true) then Fuzz.label("quoted") else Fuzz.label("plain") end
      if text:find("\n.", 1, false) and text:find('"[^"]*\n', 1, false) then
        Fuzz.label("multiline")
      end
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
-- what is read writes and reads back the same; `table` agrees with `parse`.
local function test_parse_and_table_are_total_on_any_bytes(tmp: string)
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
      local rows_ok, rows, rows_why = pcall(rows_of, fields[2], options)
      if not rows_ok then return false, "table raised: " .. tostring(rows) end
      if records == nil then
        Fuzz.label("refused")
        if not why:find("line %d+, column %d+") then return false, "no place in: " .. why end
        if rows ~= nil then return false, "table read what parse refused" end
        return true, ""
      end
      Fuzz.label("read")
      local text = assert(encode(records, fields[1]))
      local again = Csv.parse(text, options)
      if again == nil or not same(again, records) then
        return false, "not a fixed point: " .. text
      end
      if rows == nil then
        Fuzz.label("ragged")
        if not rows_why:find("^csv: line %d+, column 1: the record has ") then
          return false, "table said: " .. rows_why
        end
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
          if kind == 1 then
            text = "k" .. line .. "," .. filler .. 'v"w'
          elseif kind == 2 then
            text = "k" .. line .. ',"' .. filler .. "v"
          else
            text = "k" .. line .. "," .. filler .. "v,extra"
          end
        end
        out[line] = text
      end
      local text = table.concat(out, "\n") .. "\n"
      if kind == 3 then
        Fuzz.label("ragged")
        local rows, why = rows_of("h1,h2\n" .. text)
        local expected = "csv: line " .. (where + 1) .. ", column 1: the record has 3 fields, the header 2"
        if rows ~= nil or why ~= expected then
          return false, "rows said " .. tostring(why) .. ", not " .. expected
        end
        local records = Csv.parse("h1,h2\n" .. text)
        if records == nil or #records ~= lines + 1 then
          return false, "parse refused a ragged table"
        end
        return true, ""
      end
      local column = #("k" .. where .. "," .. filler .. "v") - (kind == 1 and 0 or #filler + 1)
      local expected: string
      if kind == 1 then
        Fuzz.label("stray")
        expected = "csv: a quote inside an unquoted field at line " .. where .. ", column " .. (column + 1)
      else
        Fuzz.label("unclosed")
        expected = "csv: unclosed quote opened at line " .. where .. ", column " .. (#("k" .. where) + 2)
      end
      local records, why = Csv.parse(text)
      if records ~= nil or why ~= expected then
        return false, "parse said " .. tostring(why) .. ", not " .. expected
      end
      return true, ""
    end,
  })
end

--- One-column records, as packed strings: each field empty or drawn.
local function gen_column(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 8) do
    parts[#parts + 1] = src:int(0, 2) == 0 and "" or field(src)
  end
  return Fuzz.pack(parts)
end

-- A one-column file the writer wrote gives back exactly the records after
-- the header, in order, an empty one included, `""` keeping a last one.
local function test_a_one_column_file_reads_back_its_rows(tmp: string)
  Fuzz.run({
    name = "csv one column",
    dir = tmp,
    gen = gen_column,
    requires = { "empty row", "last empty", "rows", "no rows" },
    shares = { ["empty row"] = 0.2, ["last empty"] = 0.05 },
    check = function(input: string): boolean, string
      local values = Fuzz.unpack(input)
      local records: {{string}} = { { "h" } }
      for _, value in ipairs(values) do records[#records + 1] = { value } end
      local text = assert(encode(records, ","))
      local rows, why = rows_of(text)
      if rows == nil then return false, "rows refused its own text: " .. why end
      if #rows ~= #values then return false, #rows .. " rows for " .. #values .. " in " .. text end
      for index, value in ipairs(values) do
        if rows[index].h ~= value then return false, "row " .. index .. " differs in " .. text end
        if value == "" then Fuzz.label("empty row") end
      end
      if #values == 0 then Fuzz.label("no rows") else Fuzz.label("rows") end
      if values[#values] == "" then Fuzz.label("last empty") end
      return true, ""
    end,
  })
end

--- Raw one-column lines, each blank or `x`, packed after the header.
local function gen_lines(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 12) do
    parts[#parts + 1] = src:int(0, 1) == 0 and "" or "x"
  end
  return Fuzz.pack(parts)
end

-- Interior and trailing blank lines: the rows are the lines up to the last
-- nonblank one, blanks among them empty; a two-column header skips them.
local function test_blank_lines_count_by_the_headers_width(tmp: string)
  Fuzz.run({
    name = "csv blank lines",
    dir = tmp,
    gen = gen_lines,
    requires = { "interior", "trailing", "wide" },
    shares = { interior = 0.2, trailing = 0.2 },
    check = function(input: string): boolean, string
      local lines = Fuzz.unpack(input)
      local last = 0
      local blanks = 0
      for index, line in ipairs(lines) do
        if line ~= "" then last = index else blanks = blanks + 1 end
      end
      local text = "h\n" .. table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
      local rows = rows_of(text)
      if rows == nil or #rows ~= last then
        return false, "one column: " .. (rows ~= nil and tostring(#rows) or "refused") .. " rows, not " .. last
      end
      if last > 0 and blanks - (#lines - last) > 0 then Fuzz.label("interior") end
      if #lines > last then Fuzz.label("trailing") end
      local wide: {string} = {}
      for index, line in ipairs(lines) do wide[index] = line == "" and "" or "x,y" end
      local two = rows_of("h,g\n" .. table.concat(wide, "\n") .. (#lines > 0 and "\n" or ""))
      if two == nil or #two ~= #lines - blanks then
        return false, "two columns did not skip the blanks"
      end
      Fuzz.label("wide")
      return true, ""
    end,
  })
end

--- A table as packed strings: the delimiter, `b` or `-` for a byte order
--- mark or none, then per record `r` and what ends it (`n` LF, `c` CRLF,
--- `b` LF and a blank line), and `f<text>` per field. The first record
--- with a field is the header; the check fits each after it to its width.
local function gen_located(src: Fuzz.Source): string
  local parts: {string} = { Fuzz.pick(src, DELIMITERS), src:int(0, 3) == 0 and "b" or "-" }
  local records = 0
  while Fuzz.more(src, records, 6) do
    records = records + 1
    parts[#parts + 1] = "r" .. Fuzz.pick(src, { "n", "c", "b" })
    local count = 0
    while Fuzz.more(src, count, 4) do
      count = count + 1
      parts[#parts + 1] = "f" .. field(src)
    end
  end
  return Fuzz.pack(parts)
end

-- Each row's line is the one its record was written to begin on, counting
-- the line breaks quoted in the fields before it, CRLF and blank lines
-- alike; so the lines rise, and each holds the start of its first field.
local function test_each_row_is_at_the_line_its_record_was_written_on(tmp: string)
  Fuzz.run({
    name = "csv lines",
    dir = tmp,
    gen = gen_located,
    requires = { "rows", "quoted break", "blank", "crlf" },
    shares = { rows = 0.2, ["quoted break"] = 0.03 },
    check = function(input: string): boolean, string
      local parts = Fuzz.unpack(input)
      local delimiter = parts[1] or ","
      local out: {string} = { parts[2] == "b" and BOM or "" }
      local width = 0
      local written: {string} = {}
      local expected: {integer} = {}
      local line = 1
      local index = 3
      while index <= #parts do
        local ending = parts[index]:sub(2)
        local fields: {string} = {}
        index = index + 1
        while index <= #parts and parts[index]:sub(1, 1) == "f" do
          fields[#fields + 1] = parts[index]:sub(2)
          index = index + 1
        end
        if #fields > 0 then
          if width == 0 then width = #fields end
          local texts: {string} = {}
          for at = 1, width do texts[at] = field_text(fields[at] or "", delimiter, width == 1) end
          local record = table.concat(texts, delimiter)
          if #out > 1 then
            expected[#expected + 1] = line
            written[#written + 1] = texts[1]
          end
          -- A blank line in a one-column file is a row, not a gap.
          local blank = ending == "b" and width > 1
          out[#out + 1] = record .. (ending == "c" and "\r\n" or "\n") .. (blank and "\n" or "")
          local _, breaks = record:gsub("\n", "")
          if breaks > 0 and #out > 2 then Fuzz.label("quoted break") end
          if blank then Fuzz.label("blank") end
          if ending == "c" then Fuzz.label("crlf") end
          line = line + 1 + breaks + (blank and 1 or 0)
        end
      end
      local text = table.concat(out)
      local made, why = Csv.table(text, { delimiter = delimiter })
      if made == nil then return false, "table refused its own text: " .. why end
      if #made.lines ~= #made.rows or #made.rows ~= #expected then
        return false, #made.lines .. " lines, " .. #made.rows .. " rows, " .. #expected .. " written"
      end
      local starts: {integer} = { #out[1] + 1 }
      for at in text:gmatch("\n()") do starts[#starts + 1] = at end
      for number, began in ipairs(made.lines) do
        if began ~= expected[number] then
          return false, "row " .. number .. " at line " .. began .. ", written at " .. expected[number]
        end
        if number > 1 and began <= made.lines[number - 1] then return false, "lines do not rise" end
        local first = written[number]
        if text:sub(starts[began], starts[began] + #first - 1) ~= first then
          return false, "line " .. began .. " does not begin with row " .. number .. "'s first field"
        end
      end
      if #expected > 0 then Fuzz.label("rows") end
      return true, ""
    end,
  })
end
