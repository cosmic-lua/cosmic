local Csv = require("cosmic.csv")

--- Records as text, to compare: fields joined by `|`, records by `;`.
local function show(records: {{string}}): string
  local out: {string} = {}
  for index, record in ipairs(records) do
    out[index] = table.concat(record, "|")
  end
  return table.concat(out, ";")
end

--- The rows [`Csv.table`] reads, or nil and why.
local function rows_of(text: string, opts?: Csv.Options): {{string:string}} | nil, string
  local made, why = Csv.table(text, opts)
  if made == nil then
    return nil, why
  end
  return made.rows, ""
end

local function parsed(text: string, opts?: Csv.Options): string
  local records, why = Csv.parse(text, opts)
  assert(records ~= nil, why)
  return show(records)
end

local function refused(text: string, opts?: Csv.Options): string
  local records, why = Csv.parse(text, opts)
  assert(records == nil, "parsed as " .. show(records or {}))
  return why
end

local function test_plain_records_with_lf_crlf_and_no_final_newline()
  assert(parsed("a,b\n1,2\n") == "a|b;1|2")
  assert(parsed("a,b\r\n1,2\r\n") == "a|b;1|2")
  assert(parsed("a,b\n1,2") == "a|b;1|2")
  assert(parsed("a,b\r\n1,2") == "a|b;1|2")
  assert(parsed("a\r\n\r\nb") == "a;b", "a blank line is no record")
  assert(#assert(Csv.parse("")) == 0 and #assert(Csv.parse("\n\r\n\n")) == 0)
end

local function test_quotes_escape_and_hold_commas_and_line_breaks()
  local records = assert(Csv.parse('"a,b","say ""hi""","line\none\r\ntwo",plain\n"",x\n'))
  assert(records[1][1] == "a,b" and records[1][2] == 'say "hi"' and records[1][3] == "line\none\r\ntwo")
  assert(records[1][4] == "plain" and records[2][1] == "" and records[2][2] == "x")
  assert(parsed('"""",""""""\n') == '"|""')
  assert(parsed('"a"\r\n"b"') == "a;b")
end

local function test_empty_fields_and_a_trailing_delimiter()
  assert(parsed("a,,c\n") == "a||c")
  assert(parsed("a,b,\n") == "a|b|")
  assert(parsed("a,b,") == "a|b|")
  assert(parsed(",\n") == "|")
  assert(#assert(Csv.parse("a,b,\n"))[1] == 3)
  assert(parsed('a,""\n') == "a|")
end

local function test_a_byte_order_mark_is_dropped_only_at_the_start()
  assert(parsed("\xEF\xBB\xBFid,b\n1,2\n") == "id|b;1|2")
  assert(parsed('\xEF\xBB\xBF"id",b\n') == "id|b")
  assert(parsed("a\n\xEF\xBB\xBFb\n") == "a;\xEF\xBB\xBFb")
end

local function test_delimiters_tab_and_semicolon()
  assert(parsed("a\tb,c\n1\t2\n", { delimiter = "\t" }) == "a|b,c;1|2")
  assert(parsed('a;"b;c";d\n', { delimiter = ";" }) == "a|b;c|d")
  assert(parsed("a,b\n", { delimiter = ";" }) == "a,b")
  assert(parsed("a|b\n", { delimiter = "|" }) == "a|b" and #assert(Csv.parse("a|b\n", { delimiter = "|" }))[1] == 2)
  assert(parsed("a.b\n", { delimiter = "." }) == "a|b")
  assert(parsed("a1b\n", { delimiter = "1" }) == "a|b")
  -- Not a tail call, which would leave no frame here to name.
  local readers: {function(text: string, opts: Csv.Options): any} = {
    function(text: string, opts: Csv.Options): any
      local records = Csv.parse(text, opts)
      return records
    end,
    function(text: string, opts: Csv.Options): any
      local made = Csv.table(text, opts)
      return made
    end,
  }
  for _, bad in ipairs({ "", ",,", '"', "\n", "\r" }) do
    for _, read in ipairs(readers) do
      local ok, message = pcall(read, "a", { delimiter = bad })
      assert(not ok and tostring(message):find("csv: the delimiter", 1, true), tostring(message))
      assert(tostring(message):find("csv_test", 1, true), "named where it was called: " .. tostring(message))
    end
  end
  local wrong = { delimiter = 1 } as any as Csv.Options
  local ok, message = pcall(readers[1], "a", wrong)
  assert(not ok and tostring(message):find("not a number", 1, true), tostring(message))
end

local function test_a_lone_carriage_return_is_data()
  assert(parsed("a\rb,c\n") == "a\rb|c")
end

local function test_an_unclosed_quote_names_where_it_opened()
  assert(refused('a,"b') == "csv: unclosed quote opened at line 1, column 3")
  assert(refused('a,b\n1,2\n"never closed,x\n3\n') == "csv: unclosed quote opened at line 3, column 1")
  assert(refused('"a\nb\nc",d\ne,"f\n') == "csv: unclosed quote opened at line 4, column 3")
  assert(refused('"a""') == "csv: unclosed quote opened at line 1, column 1")
end

local function test_a_stray_quote_is_refused_with_its_place()
  assert(refused('a,b"c\n') == "csv: a quote inside an unquoted field at line 1, column 4")
  assert(refused('a\nb\nxy"z') == "csv: a quote inside an unquoted field at line 3, column 3")
  assert(refused('"x\ny"\nab"') == "csv: a quote inside an unquoted field at line 3, column 3")
  assert(refused('"a"b\n'):find("after a closing quote, expected the delimiter or the end of the line at line 1, column 4", 1, true))
  assert(refused('"a"\rb\n'):find("line 1, column 4", 1, true))
  assert(refused('1,2\n"a" ,b\n'):find("line 2, column 4", 1, true))
end

local function test_rows_key_each_record_by_the_header()
  local rows = assert(rows_of("id,name\r\n1,Ann\r\n2,\"B, b\"\r\n"))
  assert(#rows == 2 and rows[1].id == "1" and rows[1].name == "Ann" and rows[2].name == "B, b")
  assert(#assert(rows_of("id,name\n")) == 0 and #assert(rows_of("")) == 0)
  local tabs = assert(rows_of("a\tb\n1\t2\n", { delimiter = "\t" }))
  assert(tabs[1].b == "2")
end

local function test_a_ragged_record_is_refused_strictly_naming_its_line()
  local none, why = rows_of("a,b\n1,2\n3\n")
  assert(none == nil and why == "csv: line 3, column 1: the record has 1 field, the header 2", why)
  none, why = rows_of("a,b\n1,2,3\n")
  assert(none == nil and why == "csv: line 2, column 1: the record has 3 fields, the header 2", why)
  -- The line is where the record began, after a quoted line break.
  none, why = rows_of('a,b\n"x\ny",1\n\n7\n')
  assert(none == nil and why == "csv: line 5, column 1: the record has 1 field, the header 2", why)
  -- A trailing delimiter is a field, so it must be in the header too.
  none, why = rows_of("a,b\n1,2,\n")
  assert(none == nil, "a trailing delimiter makes a third field")
  assert(rows_of("a,b,\n1,2,\n") ~= nil)
  -- Parse alone keeps them.
  assert(parsed("a,b\n1\n") == "a|b;1")
  local bad_quote, quote_why = rows_of('a\n"x\n')
  assert(bad_quote == nil and quote_why:find("unclosed quote", 1, true), quote_why)
end

local function lines_of(text: string, opts?: Csv.Options): string
  local made = assert(Csv.table(text, opts))
  assert(#made.lines == #made.rows, #made.lines .. " lines for " .. #made.rows .. " rows")
  local out: {string} = {}
  for index, line in ipairs(made.lines) do
    out[index] = tostring(line)
  end
  return table.concat(out, ",")
end

local function test_each_row_carries_the_line_its_record_began_on()
  assert(lines_of("a,b\n1,2\n3,4\n") == "2,3")
  assert(lines_of("a,b\r\n1,2\r\n3,4") == "2,3")
  -- A quoted line break, LF or CRLF, pushes every later record down.
  assert(lines_of('a,b\n1,"x\ny"\n3,4\n') == "2,4")
  assert(lines_of('a,b\r\n1,"x\r\ny\r\nz"\r\n3,4\r\n') == "2,5")
  -- So does one in the header, and blank lines, skipped, still count.
  assert(lines_of('"a\nA",b\n1,2\n') == "3")
  assert(lines_of("\n\na,b\n\n1,2\n\r\n3,4\n") == "5,7")
  -- A one-column file's interior blank line is a row on its own line.
  assert(lines_of("h\n1\n\n3\n\n") == "2,3,4")
  -- A byte order mark is no line, and a lone CR does not end one.
  assert(lines_of("\xEF\xBB\xBFa,b\n1,2\n") == "2")
  assert(lines_of("a,b\n1\r2,3\n4,5\n") == "2,3")
  assert(lines_of("a\tb\n1\t\"\n\"\n3\t4\n", { delimiter = "\t" }) == "2,4")
  assert(lines_of("") == "" and lines_of("a,b\n") == "")
end

local function test_headers_are_renamed_deterministically()
  local rows = assert(rows_of("a,a,A,,,a_2,a\n1,2,3,4,5,6,7\n"))
  local row = rows[1]
  -- a, a_2 (from the second a), A_3 (a and a_2 are taken), _, __2, then a_2 is
  -- taken so the sixth `a_2` is `a_2_2`, and the last `a` is a_4.
  assert(row.a == "1" and row.a_2 == "2" and row.A_3 == "3" and row._ == "4" and row.__2 == "5", "renamed")
  assert(row.a_2_2 == "6" and row.a_4 == "7")
  local nul = assert(rows_of("x\0y,b\n1,2\n"))
  assert(nul[1]["x\0y"] == nil and nul[1].x_y == "1", "a NUL in a name is _")
end

local function test_a_large_file_reads_in_full()
  local lines: {string} = { "id,name,note" }
  for index = 1, 60000 do
    lines[#lines + 1] = index .. ',name ' .. index .. ',"note, ""' .. index .. '"" \nmore"'
  end
  local text = table.concat(lines, "\r\n") .. "\r\n"
  local rows = assert(rows_of(text))
  assert(#rows == 60000 and rows[60000].id == "60000" and rows[1].note == 'note, "1" \nmore')
  -- A fault at the end is placed by the line count, quoted breaks included.
  local none, why = rows_of(text .. "9,x")
  assert(none == nil and why == "csv: line 120002, column 1: the record has 2 fields, the header 3", why)
  local big = '"' .. string.rep("line\n", 200000) .. '"x'
  local _, big_why = Csv.parse(big)
  assert(big_why == "csv: after a closing quote, expected the delimiter or the end of the line at line 200001, column 2",
    big_why)
end

local function test_a_one_column_file_reads_an_interior_blank_line_as_an_empty_field()
  local rows = assert(rows_of("a\n1\n\n3\n"))
  assert(#rows == 3 and rows[1].a == "1" and rows[2].a == "" and rows[3].a == "3", #rows .. " rows")
  -- Blank lines at the end are the file's end, however many, LF or CRLF.
  assert(#assert(rows_of("a\n1\n\n3\n\n\n")) == 3)
  assert(#assert(rows_of("a\r\n1\r\n\r\n3\r\n\r\n")) == 3)
  assert(#assert(rows_of("a\n1\n\n\n3")) == 4)
  assert(#assert(rows_of("a\n\n\n")) == 0 and #assert(rows_of("a\n")) == 0)
  -- Blank lines before the header are skipped.
  local lead = assert(rows_of("\n\na\n1\n"))
  assert(#lead == 1 and lead[1].a == "1")
  -- parse alone never yields a record of no fields.
  assert(parsed("a\n1\n\n3\n") == "a;1;3")
end

local function test_a_file_of_two_columns_skips_blank_lines()
  local rows = assert(rows_of("a,b\n1,2\n\n3,4\n\n\n"))
  assert(#rows == 2 and rows[2].a == "3")
  assert(#assert(rows_of("\na,b\r\n\r\n1,2\r\n")) == 1)
  local none, why = rows_of("a,b\n1,2\n\n3\n")
  assert(none == nil and why == "csv: line 4, column 1: the record has 1 field, the header 2", why)
end

local function test_table_keeps_the_headers_order()
  local made = assert(Csv.table("z,a,m\n1,2,3\n"))
  assert(table.concat(made.columns, ",") == "z,a,m" and #made.rows == 1)
  local header_only = assert(Csv.table("z,a\n"))
  assert(table.concat(header_only.columns, ",") == "z,a" and #header_only.rows == 0)
  assert(#assert(Csv.table("")).columns == 0)
end

local function test_a_lone_carriage_return_at_the_end_is_data()
  assert(parsed("1,2\r") == "1|2\r")
  local rows = assert(rows_of("a,b\n1,2\r"))
  assert(rows[1].b == "2\r")
  assert(parsed("1,2\r\n") == "1|2")
end

local function test_a_blank_line_inside_quotes_is_data_in_a_one_column_file()
  local rows = assert(rows_of('a\n"x\n\ny"\n1\n'))
  assert(#rows == 2 and rows[1].a == "x\n\ny" and rows[2].a == "1")
  -- A final empty cell written "" is kept; a bare blank line there is not.
  assert(#assert(rows_of('a\n1\n""\n')) == 2)
  assert(#assert(rows_of("a\n1\n\n")) == 1)
end

local function test_a_lone_delimiter_is_a_record_of_two_empty_fields()
  local rows = assert(rows_of("a,b\n,\n1,2\n"))
  assert(#rows == 2 and rows[1].a == "" and rows[1].b == "" and rows[2].a == "1")
  assert(parsed(",\n") == "|")
end

local function test_column_names_follow_the_header_and_avoid_what_is_reserved()
  local function names(header: {string}, reserved?: {string}): string
    return table.concat(Csv.column_names(header, reserved), ",")
  end
  assert(names({ "a", "A", "", "", "a_2", "a" }) == "a,A_2,_,__2,a_2_2,a_3")
  assert(names({}) == "")
  assert(names({ "id", "rowid", "OID" }, { "rowid", "oid" }) == "id,rowid_2,OID_2")
  assert(names({ "x\0y", "x_y" }) == "x_y,x_y_2")
  assert(names({ "_json" }, { "_json" }) == "_json_2")
  assert(names({ "rowid" }) == "rowid", "nothing is reserved by default")
end
