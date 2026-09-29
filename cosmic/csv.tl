--- CSV and TSV text as records and rows: an RFC 4180 reader and writer.
---
---     local records = assert(Csv.parse('id,name\n1,"Smith, Ann"\n2,"say ""hi"""\n'))
---     -- { {"id", "name"}, {"1", "Smith, Ann"}, {"2", 'say "hi"'} }
---     local rows = assert(Csv.rows('id,name\n1,Ann\n'))
---     -- { { id = "1", name = "Ann" } }
---     local text = assert(Csv.encode(records, { delimiter = "\t" }))
---
--- What is read:
---
--- - A field is quoted with `"` (a `""` inside is one quote) or not. A
---   quoted field holds the delimiter, quotes and line breaks as they are.
--- - A record ends at LF or CRLF; the last needs no line break. A lone
---   CR is data. Every value is a string: nothing here reads a number.
--- - The delimiter is one byte, `,` unless `opts.delimiter` says another
---   (`"\t"` for TSV, `";"`). TSV is read as CSV with a tab, so a field
---   that begins with `"` is quoted there too, and a stray `"` in one is
---   as much a fault as in CSV.
--- - A UTF-8 byte order mark at the start of the text is dropped.
--- - A line with nothing on it, outside quotes, is no record to `parse`:
---   it is skipped, so `a,b\n\n1,2\n` holds two. `rows` and `table`
---   read it by the header's width: with two or more columns it is
---   skipped, but a one-column file writes an empty cell as an empty
---   line (as pandas and spreadsheets do), so there an interior blank
---   line is a row of one empty field, and only the blank lines at the
---   end of the file are dropped (`a\n1\n\n3\n\n` has rows 1, "", 3), so
---   a final empty cell must be written `""` to be kept.
---   Blank lines before the header are skipped either way. A record of
---   one empty field is written `""`, which `encode` does, and `parse`
---   reads back.
--- - A trailing delimiter is an empty last field: `a,b,\n` holds three.
---
--- What is refused, each naming its `line N, column M` (a line counts
--- from 1, and a column is a byte in it, from 1): a quote in the middle
--- of an unquoted field, anything but a delimiter or a line end after a
--- closing quote, and a quote never closed (where it was opened). `rows`
--- also refuses, strictly, a record whose field count is not the
--- header's: a short or long row is a file whose columns are not what
--- they seem, and padding it would answer a query wrongly without a
--- word. It names the line the record began on.
---
--- `table` and `rows` turn each header field into a column name, so a
--- row can be a table keyed by the names:
---
--- - The empty name, and a NUL byte inside a name, become `_`.
--- - SQLite folds ASCII case in column names, so a name whose lower case
---   an earlier one already has gets `_2` after it, then `_3` and on:
---   `a`, `A` become `a`, `A_2`.
--- - Renaming applies to the result too: the empty name twice becomes
---   `_`, `__2`.
---
--- `cosmic.dataset` names its columns by the same rule.

--- What `read` found: the records, and the line each began on.
local record Scan
  records: {{string}}
  lines: {integer}
end

local record Csv
  --- What a reader or the writer may be told.
  record Options
    --- The one byte between fields (default `,`). It may not be `"`, CR
    --- or LF.
    delimiter: string
  end

  --- What `table` read: the column names in the header's order, and a
  --- row per record after it.
  record Table
    --- The names the header's fields became, in the header's order.
    columns: {string}
    --- One table per record after the header, from column name to field.
    rows: {{string:string}}
  end
end

local BOM <const> = "\xEF\xBB\xBF"

--- The delimiter an option names, or nil and why.
local function delimiter_of(opts: Csv.Options | nil): string | nil, string
  local delimiter = opts ~= nil and opts.delimiter or ","
  if #delimiter ~= 1 then
    return nil, "the delimiter is one byte, not " .. #delimiter
  end
  if delimiter == '"' or delimiter == "\r" or delimiter == "\n" then
    return nil, "the delimiter cannot be a quote or a line break"
  end
  return delimiter, ""
end

--- Where: "line N, column M".
local function at(line: integer, column: integer): string
  return "line " .. line .. ", column " .. column
end

--- The records of `text` and the line each began on, or nil and why.
local function read(text: string, delimiter: string): Scan | nil, string
  local records: {{string}} = {}
  local lines: {integer} = {}
  local size = #text
  local pos = text:sub(1, 3) == BOM and 4 or 1
  local line = 1
  local line_start = pos
  local delimiter_byte = delimiter:byte()
  local class = "[" .. (delimiter:find("^%w") and delimiter or "%" .. delimiter) .. '\n"]'
  while pos <= size do
    local first = text:byte(pos)
    if first == 10 or (first == 13 and text:byte(pos + 1) == 10) then
      -- A blank line: a record of no fields, which `parse` leaves out and
      -- `rows` reads by the header's width.
      records[#records + 1] = {}
      lines[#records] = line
      pos = pos + (first == 10 and 1 or 2)
      line = line + 1
      line_start = pos
    else
      local fields: {string} = {}
      lines[#records + 1] = line
      local ended = false
      local broke = false
      while not ended do
        if text:byte(pos) == 34 then
          local opened = pos
          local parts: {string} = {}
          local from = pos + 1
          local close: integer
          while true do
            local quote = text:find('"', from, true)
            if quote == nil then
              return nil, "unclosed quote opened at " .. at(line, opened - line_start + 1)
            end
            parts[#parts + 1] = text:sub(from, quote - 1)
            if text:byte(quote + 1) == 34 then
              parts[#parts + 1] = '"'
              from = quote + 2
            else
              close = quote
              break
            end
          end
          fields[#fields + 1] = table.concat(parts)
          local skipped = text:sub(opened, close)
          local _, breaks = skipped:gsub("\n", "")
          if breaks > 0 then
            line = line + breaks
            line_start = opened + skipped:match(".*\n()") - 1
          end
          pos = close + 1
          local after = text:byte(pos)
          if after == nil then
            ended = true
          elseif after == delimiter_byte then
            pos = pos + 1
          elseif after == 10 then
            pos = pos + 1
            ended, broke = true, true
          elseif after == 13 and text:byte(pos + 1) == 10 then
            pos = pos + 2
            ended, broke = true, true
          else
            return nil, "after a closing quote, expected the delimiter or the end of the line at " ..
              at(line, pos - line_start + 1)
          end
        else
          local stop = text:find(class, pos)
          if stop == nil then
            fields[#fields + 1] = text:sub(pos)
            pos = size + 1
            ended = true
          else
            local found = text:byte(stop)
            if found == 34 then
              return nil, "a quote inside an unquoted field at " .. at(line, stop - line_start + 1)
            end
            local value = text:sub(pos, stop - 1)
            if found == 10 then
              if value:byte(-1) == 13 then
                value = value:sub(1, -2)
              end
              ended, broke = true, true
            end
            fields[#fields + 1] = value
            pos = stop + 1
          end
        end
      end
      records[#records + 1] = fields
      if broke then
        line = line + 1
        line_start = pos
      end
    end
  end
  return { records = records, lines = lines }, ""
end

--- The records of `text`: each a list of its fields, all strings. Nil
--- and why (with its `line N, column M`) for a quote in an unquoted
--- field, text after a closing quote, or a quote never closed; nil and
--- why when `opts.delimiter` is not one byte or is a quote or a line
--- break. Records may differ in length here: only `rows` holds them to
--- a header. Text with no records is `{}`.
function Csv.parse(text: string, opts?: Csv.Options): {{string}} | nil, string
  local delimiter, bad = delimiter_of(opts)
  if delimiter == nil then
    return nil, bad
  end
  local scan, trouble = read(text, delimiter)
  if scan == nil then
    return nil, trouble
  end
  local records: {{string}} = {}
  for _, record in ipairs(scan.records) do
    if #record > 0 then
      records[#records + 1] = record
    end
  end
  return records, ""
end

--- A column name for each of `header`'s fields, as the module comment
--- says.
local function names_of(header: {string}): {string}
  local taken: {string:boolean} = {}
  local names: {string} = {}
  for index, field in ipairs(header) do
    local name = field == "" and "_" or (field:gsub("\0", "_"))
    local candidate = name
    local number = 1
    while taken[candidate:lower()] do
      number = number + 1
      candidate = name .. "_" .. number
    end
    taken[candidate:lower()] = true
    names[index] = candidate
  end
  return names
end

--- The header's names (see the module comment) and the rows of `text`:
--- its first record names the columns, and each record after it is a
--- table from column name to field. Nil and why for what `parse` refuses,
--- and for a record whose field count is not the header's, naming the
--- line it began on and both counts. Blank lines are read as the module
--- comment says. Text with no records has no columns, and a header alone
--- has columns and no rows.
function Csv.table(text: string, opts?: Csv.Options): Csv.Table | nil, string
  local delimiter, bad = delimiter_of(opts)
  if delimiter == nil then
    return nil, bad
  end
  local scan, trouble = read(text, delimiter)
  if scan == nil then
    return nil, trouble
  end
  local records, lines = scan.records, scan.lines
  local first = 1
  while records[first] ~= nil and #records[first] == 0 do
    first = first + 1
  end
  local rows: {{string:string}} = {}
  if records[first] == nil then
    return { columns = {}, rows = rows }, ""
  end
  local names = names_of(records[first])
  local last = #records
  if #names == 1 then
    -- Blank lines after the last record are the file's end.
    while last > first and #records[last] == 0 do
      last = last - 1
    end
  end
  for number = first + 1, last do
    local record = records[number]
    if #record == 0 then
      if #names == 1 then
        record = { "" }
      end
    elseif #record ~= #names then
      return nil, at(lines[number], 1) .. ": the record has " .. #record ..
        (#record == 1 and " field" or " fields") .. ", the header " .. #names
    end
    if #record > 0 then
      local row: {string:string} = {}
      for index, name in ipairs(names) do
        row[name] = record[index]
      end
      rows[#rows + 1] = row
    end
  end
  return { columns = names, rows = rows }, ""
end

--- The rows `table` reads, without the header's names.
function Csv.rows(text: string, opts?: Csv.Options): {{string:string}} | nil, string
  local made, trouble = Csv.table(text, opts)
  if made == nil then
    return nil, trouble
  end
  return made.rows, ""
end

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
--- as they were. Nil and why when a record has no fields, which text
--- cannot hold, or `opts.delimiter` is not one `parse` takes.
function Csv.encode(records: {{string}}, opts?: Csv.Options): string | nil, string
  local delimiter, bad = delimiter_of(opts)
  if delimiter == nil then
    return nil, bad
  end
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

return Csv
