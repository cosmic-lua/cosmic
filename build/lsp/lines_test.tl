--- `cosmic lsp`'s lines and positions ([`build.lsp.lines`]): a character
--- counted in UTF-16 units or in bytes, as the client and server agree.

local lines = require("build.lsp.lines")

local function test_a_position_counts_utf16_units_or_bytes()
  -- "😀" is four bytes and two UTF-16 units; byte 6 is the `x` after it.
  local held = lines.lines_of('a\r"😀x"\n')
  local wide = lines.position(held, 3 + 5, "utf-16")
  assert(wide.line == 1 and wide.character == 3, tostring(wide.line) .. ":" .. tostring(wide.character))
  local narrow = lines.position(held, 3 + 5, "utf-8")
  assert(narrow.character == 5, tostring(narrow.character))
  assert(lines.byte_of('"😀x"', 3, "utf-16") == 6)
end

local function test_the_checker_counts_lines_as_its_lexer_does()
  -- "\r\n" and "\n\r" are one break each, a lone "\r" and a lone "\n" are one.
  local starts = lines.checker_starts("a\r\nb\rc\nd\n\re")
  assert(#starts == 5 and starts[2] == 4 and starts[3] == 6 and starts[4] == 8 and starts[5] == 11,
    table.concat(starts, ","))
end

local function test_a_place_is_found_in_the_earlier_text_after_two_separate_edits()
  local old = "a\nb\nc\nd\ne\n"
  local new = "a\nb2\nc\nd\ne!\n"
  local aligned = lines.align(old, new)
  -- Lines the texts share keep their places.
  assert(lines.earlier(aligned, 5) == 3, tostring(lines.earlier(aligned, 5)))
  assert(lines.earlier(aligned, 10) == 9, tostring(lines.earlier(aligned, 10)))
  -- After the edit in a line: the same place where what is before the cursor is the same, else the start of the change.
  assert(lines.earlier(aligned, 3) == 3, tostring(lines.earlier(aligned, 3)))
  assert(lines.earlier(aligned, 12) == 9, tostring(lines.earlier(aligned, 12)))
  assert(aligned.same_as[1] == 1 and aligned.same_as[2] == 0 and aligned.same_as[3] == 3 and aligned.same_as[5] == 0)
  -- A line added between two lines is at the start of the line after it.
  local added = lines.align("a\nb\n", "a\nx\nb\n")
  assert(lines.earlier(added, 3) == 2, tostring(lines.earlier(added, 3)))
end

local function test_a_change_of_line_endings_edits_no_line()
  local aligned = lines.align("a\nbc\nd\n", "a\r\nbc\r\nd\r\n")
  assert(aligned.same_as[1] == 1 and aligned.same_as[2] == 2 and aligned.same_as[3] == 3)
  -- After the `c` of the second line, at its end, and after the `d` of the third.
  assert(lines.earlier(aligned, 5) == 4, tostring(lines.earlier(aligned, 5)))
  assert(lines.earlier(aligned, 7) == 5, tostring(lines.earlier(aligned, 7)))
  assert(lines.earlier(aligned, 8) == 6, tostring(lines.earlier(aligned, 8)))
end

local function test_lines_that_moved_are_found_by_their_text()
  local aligned = lines.align("a\nb\nc\nd\n", "b\nc\nx\nd\n")
  assert(aligned.same_as[3] == 0)
  assert(aligned.same_as[1] == 2 and aligned.same_as[2] == 3 and aligned.same_as[4] == 4)
end

--- `count` lines "line n", with the numbers in `changed` spelled otherwise.
local function numbered(count: integer, changed: {integer: string}): string
  local out: mut {string} = {}
  for n = 1, count do out[#out + 1] = changed[n] or ("line " .. tostring(n)) end
  return table.concat(out, "\n") .. "\n"
end

local function test_a_place_is_found_by_lines_that_stand_once_where_the_texts_are_too_large_to_pair()
  -- Two edits 890 lines apart leave 890 x 890 lines between them: more cells than are paired.
  local old = numbered(1000, {})
  local new = numbered(1000, { [10] = "edited ten", [900] = "line 900 and" })
  local aligned = lines.align(old, new)
  assert(aligned.complete)
  assert(aligned.same_as[500] == 500 and aligned.same_as[11] == 11 and aligned.same_as[901] == 901)
  assert(aligned.same_as[10] == 0 and aligned.same_as[900] == 0)
  -- The cursor after the edit in line 900 is in line 900 of the earlier text, not in a line near it.
  local count = #numbered(899, {}) + #"line 900 and"
  local expected = #numbered(899, {}) + #"line 900"
  assert(lines.earlier(aligned, count) == expected, tostring(lines.earlier(aligned, count)))
end

local function test_a_place_in_lines_that_cannot_be_told_apart_is_unknown()
  local old_lines: mut {string} = {}
  local new_lines: mut {string} = {}
  for n = 1, 1500 do
    old_lines[#old_lines + 1] = "x"
    new_lines[#new_lines + 1] = if n == 100 then "y" else "x" end
  end
  local old = table.concat(old_lines, "\n") .. "\nend\n"
  local new = table.concat(new_lines, "\n") .. "\nz\n"
  local aligned = lines.align(old, new)
  assert(not aligned.complete)
  assert(lines.earlier(aligned, 1500) == nil)
end

local function test_the_places_of_a_line_replaced_by_more_lines_rise_with_the_text()
  local aligned = lines.align("a\nb\nz\n", "a\nb1\nb2\nb3\nz\n")
  local first, last = assert(lines.earlier(aligned, 4)), assert(lines.earlier(aligned, 11))
  assert(first <= last and last <= 5, tostring(first) .. " " .. tostring(last))
end
