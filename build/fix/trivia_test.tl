--- [`build.fix.trivia`] over tiny sources: the items in order, the line breaks before each, trailing and own-line
--- comments, the `#!` line, and a round trip over the lexer's fuzz sources that writes the stream back from its
--- items and gaps.
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Sources = require("build.lexer_sources")
local Trivia = require("build.fix.trivia")

local function stream_of(source: string): Trivia.Stream, Lexer.Tokens
  local lexed = Lexer.lex(source, "f.tl")
  return Trivia.of(source, lexed.tokens), lexed.tokens
end

--- Item `i` of `list`, which is there.
local function at(list: {Trivia.Item}, i: integer): Trivia.Item
  local item = assert(list[i], "there is no item " .. tostring(i))
  return item
end

--- The stream of `source` as one line: each item as `<breaks before> <what> <text>`, `what` being `tok`, `eof`, or
--- `trail` or `own` for a comment, separated by `; `.
local function items(source: string): string
  local stream = stream_of(source)
  local out: mut {string} = {}
  for _, item in ipairs(stream.items) do
    local what = if item.kind == "token" then "tok"
      elseif item.kind == "eof" then "eof"
      elseif item.trailing then "trail"
      else "own" end
    out[#out + 1] = tostring(item.newlines) .. " " .. what .. (if item.text == "" then "" else " " .. item.text end)
  end
  return table.concat(out, "; ")
end

local function test_a_comment_on_the_line_of_the_code_before_it_trails_and_the_next_stands_alone()
  assert(items("x -- a\n-- b\ny\n") == "0 tok x; 0 trail -- a; 1 own -- b; 1 tok y; 1 eof",
    items("x -- a\n-- b\ny\n"))
end

local function test_a_comment_before_a_closer_is_an_item_before_the_closer()
  assert(items("do\n  -- c\nend") == "0 tok do; 1 own -- c; 1 tok end; 0 eof", items("do\n  -- c\nend"))
end

local function test_a_comment_on_the_line_of_the_code_after_it_is_not_trailing()
  assert(items("x\n--[[c]] y") == "0 tok x; 1 own --[[c]]; 0 tok y; 0 eof", items("x\n--[[c]] y"))
end

local function test_the_comments_after_the_last_token_come_before_the_end_of_file()
  assert(items("x\n-- a\n\n-- b") == "0 tok x; 1 own -- a; 2 own -- b; 0 eof", items("x\n-- a\n\n-- b"))
  assert(items("x -- t") == "0 tok x; 0 trail -- t; 0 eof", items("x -- t"))
  assert(items("x -- t\n") == "0 tok x; 0 trail -- t; 1 eof", items("x -- t\n"))
end

local function test_a_file_of_only_comments_has_no_trailing_one()
  assert(items("-- only") == "0 own -- only; 0 eof", items("-- only"))
  assert(items("-- a\n-- b\n") == "0 own -- a; 1 own -- b; 1 eof", items("-- a\n-- b\n"))
end

local function test_an_empty_file_is_the_end_of_file_alone()
  local stream = stream_of("")
  local eof = at(stream.items, 1)
  assert(#stream.items == 1 and eof.kind == "eof" and eof.text == "" and eof.token == 1)
  assert(eof.newlines == 0 and not eof.blank and stream.shebang == nil)
  assert(items("\n\n") == "2 eof", items("\n\n"))
  assert(at(stream_of("\n\n").items, 1).blank, "an empty line precedes the end of the file")
  assert(at(stream_of("\nx").items, 1).blank, "the first line is empty")
  assert(not at(stream_of("x").items, 1).blank)
end

local function test_a_run_of_blank_lines_is_one_gap()
  local stream = stream_of("a\nb\n\nc\n\n\n\nd")
  local breaks: mut {string} = {}
  local blank: mut {string} = {}
  for _, item in ipairs(stream.items) do
    breaks[#breaks + 1] = tostring(item.newlines)
    blank[#blank + 1] = if item.blank then "B" else "-" end
  end
  assert(table.concat(breaks, ",") == "0,1,2,4,0", table.concat(breaks, ","))
  assert(table.concat(blank, "") == "--BB-", "two breaks or more make a blank line: " .. table.concat(blank, ""))
end

local function test_every_line_ending_is_one_break()
  for _, e in ipairs({ "\n", "\r", "\r\n", "\n\r" }) do
    local source = "a" .. e .. "b" .. e .. e .. "c" .. e
    local want = "0 tok a; 1 tok b; 2 tok c; 1 eof"
    assert(items(source) == want, string.format("%q: %s", source, items(source)))
  end
  assert(items("a\r\n\r\nb") == "0 tok a; 2 tok b; 0 eof", "two CRLF are two breaks")
  assert(items("a\n\rb") == "0 tok a; 1 tok b; 0 eof", "\\n\\r is one break")
  assert(items("a\r\r\nb") == "0 tok a; 2 tok b; 0 eof", "\\r then \\r\\n are two")
  assert(items("a\n\n\rb") == "0 tok a; 2 tok b; 0 eof", "\\n then \\n\\r are two")
end

local function test_a_break_inside_a_comment_or_a_token_moves_the_line_it_ends_on()
  assert(items("x --[[a\r\nb]] y") == "0 tok x; 0 trail --[[a\r\nb]]; 0 tok y; 0 eof", "a long comment")
  local got = stream_of("x = [[a\nb]]\nz").items
  assert(at(got, 3).y == 1 and at(got, 3).yend == 2 and at(got, 4).y == 3 and at(got, 4).newlines == 1)
  local pair = stream_of("x --[[a\n\rb]] -- c\ny").items
  assert(at(pair, 2).yend == 2 and at(pair, 3).trailing and at(pair, 4).newlines == 1, "\\n\\r in a long comment")
  local cr = stream_of("x = [[a\r\nb\rc]] z").items
  assert(at(cr, 3).yend == 3 and at(cr, 4).newlines == 0 and at(cr, 4).y == 3, "CRLF and CR in a long string")
end

local function test_the_shebang_line_is_kept_apart_and_counts_as_line_one()
  local stream = stream_of("#!/bin/x -v\nlocal")
  assert(stream.shebang == "#!/bin/x -v")
  assert(items("#!/bin/x -v\nlocal") == "1 tok local; 0 eof", items("#!/bin/x -v\nlocal"))
  assert(not at(stream.items, 1).blank)
  assert(items("#!x\n\nlocal") == "2 tok local; 0 eof")
  assert(at(stream_of("#!x\n\nlocal").items, 1).blank)
  assert(stream_of("#!x\r\nlocal").shebang == "#!x")
  assert(stream_of("#!x").shebang == "#!x" and items("#!x") == "0 eof")
  assert(items("#!x\n-- c\n") == "1 own -- c; 1 eof", "a comment after the shebang is not trailing it")
  assert(stream_of(" #!x").shebang == nil, "only a first line at byte 0 is a shebang")
  assert(stream_of("x\n#!y").shebang == nil)
end

local function test_a_comment_reports_the_column_it_began_at()
  local got = stream_of("x = 1 -- c\n  -- d\n\t--[[e]] y").items
  assert(at(got, 4).x == 7 and at(got, 4).text == "-- c")
  assert(at(got, 5).x == 3 and at(got, 5).text == "-- d")
  assert(at(got, 6).x == 2 and at(got, 6).text == "--[[e]]")
  assert(at(got, 1).x == 1 and at(got, 2).x == 3 and at(got, 3).x == 5)
end

local function test_a_token_that_runs_to_the_end_with_its_break_leaves_no_break_after_it()
  -- An unterminated long string holds the break at the end of the file, so the end of the file follows it on the line
  -- after and no break lies between.
  assert(items("[[\n") == "0 tok [[\n; 0 eof", items("[[\n"))
  assert(items("x\n--[==[ a\r\n") == "0 tok x; 1 tok --[==[ a\r\n; 0 eof", items("x\n--[==[ a\r\n"))
  assert(items("[[a\n\n") == "0 tok [[a\n\n; 0 eof", items("[[a\n\n"))
end

local function test_a_break_the_token_before_took_does_not_count_twice()
  -- `'a\` and the break after it are one token, so the empty line after that is the one line between it and `y`.
  local stream = stream_of("'a\\\n\ny")
  assert(items("'a\\\n\ny") == "0 tok 'a\\\n; 1 tok y; 0 eof", items("'a\\\n\ny"))
  assert(at(stream.items, 2).blank, "line 2 is empty")
  assert(not at(stream_of("'a\\\ny").items, 2).blank, "no line lies between")
  assert(at(stream_of("'a\\\r\n\r\nb'").items, 2).blank)
end

local function test_a_comment_after_a_comment_on_its_line_follows_it()
  assert(items("x --[[a\nb]] -- c") == "0 tok x; 0 trail --[[a\nb]]; 0 trail -- c; 0 eof", items("x --[[a\nb]] -- c"))
  assert(items("x\n--[[a]] -- b") == "0 tok x; 1 own --[[a]]; 0 own -- b; 0 eof", items("x\n--[[a]] -- b"))
  assert(items("--[[a]] -- b\nx") == "0 own --[[a]]; 0 own -- b; 1 tok x; 0 eof", items("--[[a]] -- b\nx"))
end

local function test_a_token_an_error_makes_is_an_item_too()
  assert(items("x @ 'a\ny") == "0 tok x; 0 tok @; 0 tok 'a; 1 tok y; 0 eof", items("x @ 'a\ny"))
  assert(items("x -- a\n[[b") == "0 tok x; 0 trail -- a; 1 tok [[b; 0 eof", items("x -- a\n[[b"))
end

local function normal_breaks(text: string): string
  local out: mut {string} = {}
  local from = 1
  while true do
    local found = text:find("[\r\n]", from)
    if found == nil then
      out[#out + 1] = text:sub(from)
      return table.concat(out)
    end
    out[#out + 1] = text:sub(from, found - 1) .. "\n"
    local c, d = text:byte(found), text:byte(found + 1)
    from = if (d == 10 or d == 13) and d ~= c then found + 2 else found + 1 end
  end
end

--- The source written back from its stream: the `#!` line, then each item after its line breaks, or after one
--- space where it follows another on a line.
local function written(stream: Trivia.Stream): string
  local out: mut {string} = { stream.shebang or "" }
  for i, item in ipairs(stream.items) do
    local gap = if item.newlines > 0 then ("\n"):rep(item.newlines)
      elseif i > 1 and item.kind ~= "eof" then " "
      else "" end
    out[#out + 1] = gap .. item.text
  end
  return table.concat(out)
end

--- Why the gaps of `stream` are not the source's own, or "": read from the bytes between the items and from the
--- lexer's table of where each line begins, not from the stream.
local function gaps_differ(source: string, stream: Trivia.Stream, tokens: Lexer.Tokens): string
  local function line_of(offset: integer): integer
    local low, high = 1, #tokens.line
    while low < high do
      local middle = (low + high + 1) // 2
      if (tokens.line[middle] or math.maxinteger) <= offset then low = middle else high = middle - 1 end
    end
    return low
  end
  local shebang = stream.shebang
  local previous_end = if shebang == nil then 0 else #shebang end
  local previous_text = ""
  for i, item in ipairs(stream.items) do
    local last = item.offset + #item.text - 1
    local between = source:sub(previous_end + 1, item.offset - 1)
    if between:find("[^ \t\r\n\v\f]") then
      return string.format("item %d: %q lies between the items", i, between)
    end
    local breaks = 0
    for _ in normal_breaks(between):gmatch("\n") do breaks = breaks + 1 end
    local starts_line = if i == 1 then shebang == nil else previous_text:find("[\r\n]$") ~= nil end

    if item.newlines ~= breaks or item.blank ~= (breaks >= (if starts_line then 1 else 2 end)) then
      return string.format("item %d: %d breaks between, stream says %d (blank %s)", i, breaks, item.newlines,
        tostring(item.blank))
    end
    local y, yend = line_of(item.offset), line_of(math.max(last, item.offset))
    if item.x ~= item.offset - (tokens.line[y] or 0) + 1 then
      return string.format("item %d: column %d, the lexer's table says %d", i, item.x,
        item.offset - (tokens.line[y] or 0) + 1)
    end
    if item.y ~= y or item.yend ~= yend + (if item.text:find("[\r\n]$") then 1 else 0 end) then
      return string.format("item %d: lines %d-%d, the lexer's table says %d-%d", i, item.y, item.yend, y, yend)
    end
    previous_end, previous_text = last, item.text
  end
  return ""
end

--- Why the stream of `source` does not give it back, or "". Written back, it is the source but for its line
--- endings and the whitespace within lines; and lexed again, it has the same tokens, comments, lines and gaps.
local function round_trip_of(source: string, stream: Trivia.Stream, tokens: Lexer.Tokens): string
  local back = written(stream)
  local function bare(text: string): string
    return (normal_breaks(text):gsub("[ \t\v\f]", ""))
  end
  if bare(back) ~= bare(source) then
    return string.format("written back %q", back)
  end
  local again, tokens_again = stream_of(back)
  if #again.items ~= #stream.items then
    return string.format("%d items, then %d after %q", #stream.items, #again.items, back)
  end
  for i, item in ipairs(stream.items) do
    local other = again.items[i]
    if other == nil or other.kind ~= item.kind or other.text ~= item.text or other.y ~= item.y or
        other.yend ~= item.yend or other.newlines ~= item.newlines or other.blank ~= item.blank or
        other.trailing ~= item.trailing or
        Lexer.kind(tokens_again, other.token) ~= Lexer.kind(tokens, item.token) then
      return string.format("item %d differs after %q", i, back)
    end
  end
  if again.shebang ~= stream.shebang then
    return "the shebang differs"
  end
  return gaps_differ(source, stream, tokens)
end

local function round_trip(source: string): string
  local stream, tokens = stream_of(source)
  return round_trip_of(source, stream, tokens)
end

local function test_the_stream_gives_back_the_source_on_chosen_sources()
  local sources = {
    "", "\n", "-- c", "#!x", "#!x\n\n\n-- a\nx --[[b\nc]] y -- d\n\n",
    "local a = 1 -- t\n\n-- own\nfunction f()\n  -- body\nend -- tail\n-- eof",
    "a\r\nb\n\rc\rd\r\r\ne\n\n\rf", "x = [[a\r\nb]] .. 'c\\\r\nd' -- z\r\n",
    "x\t=\v1\f--[==[\n\n]==]\ny", "'abc\n@@ \195\169 \0 1e+ 0x", "--[[ open\nnever closed",
  }
  for _, source in ipairs(sources) do
    local why = round_trip(source)
    assert(why == "", string.format("%q: %s", source, why))
  end
end

local function test_the_stream_gives_back_any_source_the_lexer_fuzz_draws(tmp: string)
  Fuzz.run({
    name = "trivia gives back the source",
    dir = tmp,
    gen = Sources.source,
    check = function(input: string): boolean, string
      local stream, tokens = stream_of(input)
      local why = round_trip_of(input, stream, tokens)
      if why ~= "" then
        return false, why
      end
      if stream.shebang ~= nil then
        Fuzz.label("shebang")
      end
      for _, item in ipairs(stream.items) do
        if item.kind == "comment" then
          Fuzz.label(if item.trailing then "trailing" else "own-line" end)
        end
        if item.blank then
          Fuzz.label("blank")
        end
      end
      return true, ""
    end,
    requires = { "trailing", "own-line", "blank", "shebang" },
    shares = { trailing = 0.1, ["own-line"] = 0.05, blank = 0.1, shebang = 0.01 },
  })
end
