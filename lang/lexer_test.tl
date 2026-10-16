--- The lexer of the new checker's grammar ([`lang.lexer`]): the token of
--- each lexical form, its place, and each form the grammar refuses with its
--- code and the fix it gives. Every source here is also held to
--- [`lang.lexer_cover`], which asks that its tokens and comments tile it.
local Lexer = require("lang.lexer")
local Clock = require("cosmic.clock")
local Cover = require("lang.lexer_cover")

--- The letter e with an acute accent, in UTF-8, so that this file holds
--- only ASCII.
local E_ACUTE <const> = "\195\169"

local function lex(source: string): Lexer.Lexed
  local lexed = Lexer.lex(source, "t.tl")
  local ok, why = Cover.check(source, lexed)
  assert(ok, why)
  return lexed
end

--- The tokens as `kind:text`, without the final `$EOF$`.
local function shape(source: string): string
  local parts: {string} = {}
  local tokens = lex(source).tokens
  for i = 1, #tokens - 1 do
    parts[#parts + 1] = tokens[i].kind .. ":" .. tokens[i].text
  end
  return table.concat(parts, " ")
end

--- The one error of `source`, which has exactly one.
local function only_error(source: string): Lexer.Error
  local errors = lex(source).errors
  assert(#errors == 1, "expected one error, found " .. #errors .. " in " .. source)
  return errors[1]
end

--- The token at `index`, which exists.
local function token(source: string, index: integer): Lexer.Token
  local found = lex(source).tokens[index]
  assert(found ~= nil, "no token " .. index .. " in " .. source)
  return found
end

local function test_names_and_reserved_words_are_told_apart()
  assert(shape("local x_1 = nil") == "keyword:local identifier:x_1 op:= keyword:nil")
  assert(shape("_ __a9 A") == "identifier:_ identifier:__a9 identifier:A")
end

local function test_every_reserved_word_is_a_keyword()
  for word in pairs(Lexer.reserved) do
    assert(token("x." .. word, 3).kind == "keyword", word .. " after a dot")
    if word ~= "goto" then
      assert(shape(word) == "keyword:" .. word, word)
    end
  end
  assert(Lexer.reserved["global"] and Lexer.reserved["goto"], "Lua 5.5 reserves goto and global")
  assert(not Lexer.reserved["record"] and not Lexer.reserved["type"])
end

local function test_the_words_the_grammar_adds_are_reserved()
  assert(table.concat(Lexer.added, " ") == "match continue mut is asserts userdata as")
  for _, word in ipairs(Lexer.added) do
    assert(Lexer.reserved[word], word)
    assert(shape(word) == "keyword:" .. word)
  end
end

local function test_declaration_words_stay_names()
  assert(table.concat(Lexer.declaration_words, " ") == "record interface class enum type")
  assert(shape("record interface class enum type never self") ==
      "identifier:record identifier:interface identifier:class identifier:enum identifier:type " ..
      "identifier:never identifier:self")
end

local function test_a_reserved_word_stands_where_a_field_name_does()
  local sources = {
    "s:match(p)", "t.continue", "t.userdata", "{ match = 1, as = 2 }", "userdata: boolean",
    "mut mut: T", "end: string", "x.goto", "{ goto = 1 }", "goto: boolean", "goto ?: T",
  }
  for _, source in ipairs(sources) do
    local lexed = lex(source)
    assert(#lexed.errors == 0, source)
    local found = false
    for _, t in ipairs(lexed.tokens) do
      if t.kind == "keyword" then
        found = true
        assert(Lexer.field_word(t), source)
      end
    end
    assert(found, "no keyword in " .. source)
  end
  assert(Lexer.field_word(token("x", 1)))
  assert(not Lexer.field_word(token("1", 1)))
  assert(not Lexer.field_word(token("(", 1)))
end

local function test_every_operator_and_punctuator_is_kept()
  assert(shape("+ - * / // % ^ # & ~ | << >> == ~= <= >= < > = ..") ==
      "op:+ op:- op:* op:/ op:// op:% op:^ op:# op:& op:~ op:| op:<< op:>> op:== op:~= op:<= op:>= op:< op:> op:= op:..")
  assert(shape(". : , ? ( ) { } [ ] ...") == ".:. ::: ,:, ?:? (:( ):) {:{ }:} [:[ ]:] ...:...")
  assert(shape("a~b a~=b a-b a--b\n") == "identifier:a op:~ identifier:b identifier:a op:~= identifier:b " ..
      "identifier:a op:- identifier:b identifier:a")
end

local function test_two_closing_type_brackets_are_one_token()
  assert(shape("Cache<K, List<V>>") ==
      "identifier:Cache op:< identifier:K ,:, identifier:List op:< identifier:V op:>>")
  assert(shape("a >> b > > c") == "identifier:a op:>> identifier:b op:> op:> identifier:c")
end

local record Written
  text: string
  kind: Lexer.Kind
  value: number
end

local function test_integers_and_floats_have_their_values()
  local expected: {Written} = {
    { text = "0", kind = "integer", value = 0 }, { text = "12", kind = "integer", value = 12 },
    { text = "0xFF", kind = "integer", value = 255 }, { text = "0Xa", kind = "integer", value = 10 },
    { text = "1e3", kind = "number", value = 1000.0 }, { text = "2.5", kind = "number", value = 2.5 },
    { text = ".5", kind = "number", value = 0.5 }, { text = "5.", kind = "number", value = 5.0 },
    { text = "3e-2", kind = "number", value = 0.03 }, { text = "1E+2", kind = "number", value = 100.0 },
    { text = "0xffffffffffffffff", kind = "integer", value = -1 },
    { text = "9223372036854775807", kind = "integer", value = 9223372036854775807 },
  }
  for _, row in ipairs(expected) do
    local found = token(row.text, 1)
    assert(found.kind == row.kind, row.text .. " is " .. found.kind)
    assert(found.number == row.value, row.text)
    assert(found.text == row.text)
  end
end

local function test_a_decimal_integer_too_big_for_64_bits_is_a_float_as_in_lua()
  local found = token("9223372036854775808", 1)
  assert(found.kind == "number" and found.number == 9223372036854775808.0)
end

local function test_a_number_stops_before_what_cannot_continue_it()
  assert(shape("t[1]") == "identifier:t [:[ integer:1 ]:]")
  assert(shape("f(1,2)") == "identifier:f (:( integer:1 ,:, integer:2 ):)")
  assert(shape("1 .. 2") == "integer:1 op:.. integer:2")
  assert(shape("for i=1,#t do") == "keyword:for identifier:i op:= integer:1 ,:, op:# identifier:t keyword:do")
end

local function test_strings_hold_their_text_and_their_value()
  local single = token("'a\"b'", 1)
  assert(single.kind == "string" and single.text == "'a\"b'" and single.value == "a\"b")
  local double = token("\"it's\"", 1)
  assert(double.text == "\"it's\"" and double.value == "it's")
  local empty = token("''", 1)
  assert(empty.kind == "string" and empty.value == "" and empty.length == 2)
  assert(single.long == nil and token("x", 1).value == nil)
end

local function test_every_escape_of_lua_is_decoded()
  local cases: {{string}} = {
    { [[\a\b\f\n\r\t\v]], "\a\b\f\n\r\t\v" },
    { [[\\\"\']], "\\\"'" },
    { [[\x41\x7a\xFF]], "Az\255" },
    { [[\65\066\0\255]], "AB\0\255" },
    { [[\u{41}\u{20AC}\u{7FFFFFFF}]], "A\226\130\172\253\191\191\191\191\191" },
    { "a\\\nb", "a\nb" },
    { "a\\z  \n\t b", "ab" },
    { [[\z]], "" },
  }
  for _, case in ipairs(cases) do
    local found = token("\"" .. case[1] .. "\"", 1)
    assert(found.kind == "string", case[1])
    assert(found.value == case[2], case[1])
  end
end

local function test_a_string_across_lines_moves_the_lines_that_follow()
  local lexed = lex("x = \"a\\\nb\" y")
  local str, y = lexed.tokens[3], lexed.tokens[4]
  assert(str.y == 1 and str.x == 5 and str.yend == 2 and str.xend == 2)
  assert(y.y == 2 and y.x == 4 and y.offset == 12)
  local skipped = lex("\"a\\z\n\n  b\" c").tokens
  assert(skipped[1].yend == 3 and skipped[1].xend == 4 and skipped[2].y == 3 and skipped[2].x == 6)
end

local function test_long_strings_of_every_level()
  assert(token("[[a]]", 1).value == "a")
  assert(token("[==[a]]b]=]c]==]", 1).value == "a]]b]=]c")
  assert(token("[[\nabc]]", 1).value == "abc", "the first line break is not part of the string")
  assert(token("[[\n\nabc]]", 1).value == "\nabc")
  assert(token("[[\r\nabc\r\ndef]]", 1).value == "abc\ndef", "a line break is one \\n")
  assert(token("[=[]]]=]", 1).value == "]]")
  local found = token("[[a]]", 1)
  assert(found.kind == "string" and found.long == true and found.text == "[[a]]")
end

local function test_a_long_string_spans_lines_and_moves_the_lines_that_follow()
  local lexed = lex("local s = [==[\nab\ncd]==] .. x")
  local str, dots = lexed.tokens[4], lexed.tokens[5]
  assert(str.y == 1 and str.x == 11 and str.yend == 3 and str.xend == 6, str.yend .. ":" .. str.xend)
  assert(str.length == 14)
  assert(dots.y == 3 and dots.x == 8 and dots.text == "..")
end

local function test_a_bracket_that_opens_no_long_string_is_a_bracket()
  assert(shape("t[ [1] ]") == "identifier:t [:[ [:[ integer:1 ]:] ]:]")
  assert(shape("a[=1]") == "identifier:a [:[ op:= integer:1 ]:]")
  assert(shape("{[1]=2}") == "{:{ [:[ integer:1 ]:] op:= integer:2 }:}")
end

local function test_comments_are_kept_on_the_token_after_them()
  local lexed = lex("-- a\n  -- b\nx -- c\n-- d")
  local x, eof = lexed.tokens[1], lexed.tokens[2]
  local before = assert(x.comments)
  assert(#before == 2 and before[1].text == "-- a" and before[2].text == "-- b")
  assert(before[1].y == 1 and before[1].x == 1 and before[1].offset == 1 and before[1].length == 4)
  assert(before[2].y == 2 and before[2].x == 3 and before[2].offset == 8)
  local after = assert(eof.comments)
  assert(#after == 2 and after[1].text == "-- c" and after[2].text == "-- d")
  assert(eof.kind == "$EOF$")
  assert(token("x", 1).comments == nil)
end

local function test_a_comment_is_a_dash_dash_to_the_end_of_the_line()
  local lexed = lex("---[[ x\n--[ y\n--[= z\n--#pragma w\n--\nq")
  local comments = assert(lexed.tokens[1].comments)
  local texts: {string} = {}
  for _, c in ipairs(comments) do
    texts[#texts + 1] = c.text
  end
  assert(table.concat(texts, "|") == "---[[ x|--[ y|--[= z|--#pragma w|--")
  assert(#lexed.errors == 0, "none of them is a long comment")
end

local function test_a_token_knows_its_bytes_and_its_places()
  local lexed = lex("local s =\n\t\"" .. E_ACUTE .. "\" + 12\n")
  local places: {string} = {}
  for _, t in ipairs(lexed.tokens) do
    places[#places + 1] = string.format("%s@%d+%d=%d:%d-%d:%d", t.kind, t.offset, t.length, t.y, t.x, t.yend, t.xend)
  end
  assert(table.concat(places, " ") ==
      "keyword@1+5=1:1-1:5 identifier@7+1=1:7-1:7 op@9+1=1:9-1:9 string@12+4=2:2-2:5 op@17+1=2:7-2:7 " ..
      "integer@19+2=2:9-2:10 $EOF$@22+0=3:1-3:0", table.concat(places, " "))
end

local function test_the_end_of_input_is_an_empty_token()
  local empty = lex("").tokens
  assert(#empty == 1 and empty[1].kind == "$EOF$" and empty[1].offset == 1 and empty[1].length == 0)
  assert(empty[1].y == 1 and empty[1].x == 1)
  local blank = lex("  \n  \n").tokens
  assert(#blank == 1 and blank[1].y == 3 and blank[1].x == 1 and blank[1].offset == 7)
end

local function test_goto_with_a_label_is_refused_with_continue()
  local e = only_error("for i = 1, 3 do goto continue end")
  assert(e.code == "label_or_goto" and e.msg == "`goto continue` is not in the grammar")
  assert(e.fix == "write `continue`")
  assert(e.y == 1 and e.x == 17 and e.offset == 17 and e.length == 13)
  local found = token("goto continue", 1)
  assert(found.kind == "$ERR$" and found.text == "goto continue")
end

local function test_goto_to_another_label_says_how_to_restructure()
  local e = only_error("goto done")
  assert(e.code == "label_or_goto" and e.msg == "`goto done` is not in the grammar")
  assert(e.fix == "write `continue` to skip the rest of a pass of the loop around it; restructure any other " ..
      "jump with an `if` around the code to skip, or move the code into a function and `return` from it")
  local bare = only_error("goto\nx = 1")
  assert(bare.msg == "`goto` is not in the grammar" and bare.length == 4, "a name on the next line is not its label")
end

local function test_a_label_is_refused()
  local e = only_error("do\n  ::continue::\nend")
  assert(e.code == "label_or_goto" and e.msg == "the label `::continue::` is not in the grammar")
  assert(e.fix == "delete the label, and write `continue` where a `goto continue` skipped the rest of a pass " ..
      "of a loop; restructure any other jump with an `if` around the code to skip, or move the code into a " ..
      "function and `return` from it")
  assert(e.y == 2 and e.x == 3 and e.length == 12)
  assert(token("::next::", 1).kind == "$ERR$")
  assert(only_error("::").msg == "`::` is not in the grammar")
end

local function test_a_semicolon_is_refused()
  local e = only_error("local x = 1; local y")
  assert(e.code == "semicolon" and e.msg == "`;` is not in the grammar")
  assert(e.fix == "delete the `;`: a statement needs no terminator and the fields of a table are separated by `,`")
  assert(e.y == 1 and e.x == 12 and e.offset == 12 and e.length == 1)
  assert(token("local x = 1; local y", 5).kind == "$ERR$")
end

local function test_a_long_comment_is_refused_and_kept_as_a_comment()
  local lexed = lex("a --[==[ one\ntwo ]==] b")
  assert(#lexed.errors == 1)
  local e = lexed.errors[1]
  assert(e.code == "long_comment" and e.msg == "long comments are not in the grammar")
  assert(e.fix == "write line comments: begin each line of the comment with `--`")
  assert(e.y == 1 and e.x == 3 and e.offset == 3 and e.length == 19)
  local b = lexed.tokens[2]
  assert(b.text == "b" and b.y == 2 and b.x == 10, "the lines after it are counted")
  assert(assert(b.comments)[1].text == "--[==[ one\ntwo ]==]")
end

local function test_an_unfinished_long_comment_is_an_error_token_to_the_end()
  local e = only_error("a --[[ one\ntwo")
  assert(e.code == "unterminated_long_comment" and e.msg == "unfinished long comment")
  assert(e.fix == "write line comments, which begin each line with `--`; a long comment is not in the grammar " ..
      "and this one has no closing `]]`")
  local lexed = lex("a --[=[ one\ntwo")
  assert(lexed.tokens[2].kind == "$ERR$" and lexed.tokens[2].yend == 2 and lexed.tokens[3].kind == "$EOF$")
  assert(lexed.errors[1].fix:find("`]=]`", 1, true))
end

local function test_a_hashbang_line_is_refused()
  local lexed = lex("#!/usr/bin/env cosmic\nlocal x")
  assert(#lexed.errors == 1)
  local e = lexed.errors[1]
  assert(e.code == "hashbang" and e.msg == "a `#!` first line is not in the grammar")
  assert(e.fix == "delete the line; run the file with `cosmic t.tl`")
  assert(e.y == 1 and e.x == 1 and e.length == 21)
  assert(lexed.tokens[1].kind == "$ERR$" and lexed.tokens[2].text == "local" and lexed.tokens[2].y == 2)
end

local function test_a_hashbang_only_begins_the_file()
  local lexed = lex("x\n#!y")
  assert(#lexed.errors == 1 and lexed.errors[1].code == "stray_byte")
end

local function test_a_digit_separator_is_refused_and_the_number_kept()
  local e = only_error("x = 1_000")
  assert(e.code == "digit_separator" and e.msg == "`_` in a number is not in the grammar")
  assert(e.fix == "write the number without `_`: `1000`")
  assert(e.y == 1 and e.x == 5 and e.length == 5)
  local found = token("x = 1_000", 3)
  assert(found.kind == "integer" and found.number == 1000 and found.text == "1_000")
  assert(only_error("0xFF_FF").fix == "write the number without `_`: `0xFFFF`")
  assert(token("1_0.5", 1).kind == "number")
end

local function test_a_hexadecimal_float_is_refused_and_the_number_kept()
  local e = only_error("x = 0x1p4")
  assert(e.code == "hex_float" and e.msg == "a hexadecimal float is not in the grammar")
  assert(e.fix == "write the value in decimal: `16.0`")
  assert(e.y == 1 and e.x == 5 and e.length == 5)
  local found = token("x = 0x1p4", 3)
  assert(found.kind == "number" and found.number == 16.0)
  assert(only_error("0x.8").fix == "write the value in decimal: `0.5`")
  assert(only_error("0x1P-1").fix == "write the value in decimal: `0.5`")
end

local function test_a_malformed_number_is_an_error_token()
  local fix = "write decimal digits with an optional fraction and exponent (`12`, `1.5`, `2e10`) or `0x` and " ..
    "hexadecimal digits (`0xFF`), and put a space between a number and the name or operator after it"
  for _, bad in ipairs({ "3x", "0x", "1e", "1e+", "12abc", "1..2", "1.2.3", "0xg", "1__0e" }) do
    local e = only_error("a = " .. bad)
    assert(e.code == "malformed_number", bad)
    assert(e.msg == "malformed number `" .. bad .. "`", bad)
    assert(e.fix == fix, bad)
    assert(e.x == 5 and e.length == #bad, bad)
    local found = token("a = " .. bad, 3)
    assert(found.kind == "$ERR$" and found.text == bad and found.number == nil, bad)
  end
  assert(only_error(".5x").code == "malformed_number")
end

local function test_a_string_with_no_closing_quote_is_an_error_token_to_the_end_of_its_line()
  local e = only_error("x = \"abc\ny = 1")
  assert(e.code == "unterminated_string" and e.msg == "unterminated string")
  assert(e.fix == "close the string with a matching `\"` before the end of its line; to carry it onto the next " ..
      "line end this line with `\\`, or write a long string `[[ ... ]]`")
  assert(e.y == 1 and e.x == 5 and e.length == 4)
  local lexed = lex("x = 'abc\ny = 1")
  assert(lexed.tokens[3].kind == "$ERR$" and lexed.tokens[3].text == "'abc")
  assert(lexed.tokens[4].text == "y" and lexed.tokens[4].y == 2, "lexing goes on")
  assert(lexed.errors[1].fix:find("matching `'`", 1, true))
  assert(only_error("'abc").length == 4, "the end of input ends a string too")
  assert(only_error("'abc\\").code == "unterminated_string")
end

local function test_a_long_string_with_no_closing_bracket_is_an_error_token_to_the_end()
  local e = only_error("x = [==[ abc\n]] def")
  assert(e.code == "unterminated_long_string" and e.msg == "unterminated long string")
  assert(e.fix == "close the string with `]==]`")
  assert(e.y == 1 and e.x == 5)
  local lexed = lex("x = [[ abc")
  assert(lexed.tokens[3].kind == "$ERR$" and lexed.tokens[4].kind == "$EOF$")
end

local function test_a_bad_escape_says_which_escapes_there_are()
  local general = "write `\\\\q` for a backslash followed by `q`, or `q` alone. The escapes are `\\a \\b \\f \\n " ..
    "\\r \\t \\v \\\\ \\\" \\' \\z`, `\\xNN`, `\\ddd` up to 255, `\\u{NNN}` and a backslash before a line break"
  local e = only_error("x = \"a\\qb\"")
  assert(e.code == "bad_escape" and e.msg == "invalid escape `\\q`")
  assert(e.fix == general)
  assert(e.y == 1 and e.x == 7 and e.offset == 7 and e.length == 2)
  local found = token("x = \"a\\qb\"", 3)
  assert(found.kind == "$ERR$" and found.text == "\"a\\qb\"" and found.value == nil)
  local cases: {{string}} = {
    { [[\x4]], "`\\x` takes exactly two hexadecimal digits: write `\\x41` for `A`" },
    { [[\xg1]], "`\\x` takes exactly two hexadecimal digits: write `\\x41` for `A`" },
    { [[\256]], "a decimal escape is at most `\\255`: write a character past 255 as `\\u{...}`, as `\\u{100}`" },
    { [[\u41]], "`\\u` takes hexadecimal digits in braces: write `\\u{20AC}` for the euro sign" },
    { [[\u{}]], "`\\u` takes hexadecimal digits in braces: write `\\u{20AC}` for the euro sign" },
    { [[\u{80000000}]], "a code point in `\\u{...}` is at most `7FFFFFFF`: write `\\u{20AC}` for the euro sign" },
  }
  for _, case in ipairs(cases) do
    local bad = only_error("\"" .. case[1] .. "\"")
    assert(bad.code == "bad_escape", case[1])
    assert(bad.fix == case[2], case[1] .. ": " .. bad.fix)
  end
  assert(#lex("'\\u{0000000041}\\u{7FFFFFFF}'").errors == 0, "leading zeros do not count")
end

local function test_only_the_first_bad_escape_of_a_string_is_reported()
  local e = only_error("\"\\q\\w\"")
  assert(e.msg == "invalid escape `\\q`")
end

local function test_a_stray_byte_is_an_error_token_and_lexing_goes_on()
  local e = only_error("a @ b")
  assert(e.code == "stray_byte" and e.msg == "stray `@`")
  assert(e.fix == "delete it; a character outside Lua's syntax can stand only inside a string or a comment")
  assert(e.y == 1 and e.x == 3 and e.length == 1)
  assert(shape("a @ b") == "identifier:a $ERR$:@ identifier:b")
  assert(only_error("a $ b").msg == "stray `$`")
  assert(only_error("a \\ b").msg == "stray `\\`")
  assert(only_error("a `b").msg == "stray backtick")
end

local function test_bang_says_what_to_write()
  assert(only_error("a != b").fix == "write `~=` for \"not equal\"")
  assert(only_error("!a").fix == "write `not` for negation")
end

local function test_a_non_ascii_character_is_one_error_token()
  local e = only_error("x = \"ok\" -- " .. E_ACUTE .. "\ny = " .. E_ACUTE)
  assert(e.code == "stray_byte" and e.msg == "stray `" .. E_ACUTE .. "`" and e.length == 2 and e.y == 2 and e.x == 5)
  assert(e.fix == "names are ASCII letters, digits and `_`; a character like this can stand only inside a string " ..
      "or a comment")
  local bom = only_error("\239\187\191local x")
  assert(bom.fix == "delete the byte order mark at the start of the file" and bom.length == 3)
end

local function test_a_control_byte_is_shown_as_hex()
  assert(only_error("a \1 b").msg == "stray `\\x01`")
  assert(only_error("a \0 b").msg == "stray `\\x00`")
end

local function test_one_run_reports_every_problem()
  local lexed = lex("goto a; @ 1_0 'x\nlocal y = 0x1p1 --[[c]] [[z")
  local codes: {string} = {}
  for _, e in ipairs(lexed.errors) do
    codes[#codes + 1] = e.code
  end
  assert(table.concat(codes, " ") ==
      "label_or_goto semicolon stray_byte digit_separator unterminated_string hex_float long_comment " ..
      "unterminated_long_string", table.concat(codes, " "))
  assert(lexed.tokens[#lexed.tokens - 1].kind == "$ERR$" and lexed.tokens[#lexed.tokens].kind == "$EOF$")
  local ordered = true
  for i = 2, #lexed.errors do
    ordered = ordered and lexed.errors[i - 1].offset < lexed.errors[i].offset
  end
  assert(ordered, "errors come in source order")
end

local function test_an_error_names_the_file()
  local e = Lexer.lex("@", "build/x.tl").errors[1]
  assert(e.filename == "build/x.tl")
end

--- One source for each code, whose first error has that code.
local REFUSALS <const>: {Lexer.Code: string} = {
  label_or_goto = "goto continue",
  semicolon = ";",
  long_comment = "--[[ x ]]",
  unterminated_long_comment = "--[[ x",
  hashbang = "#!/bin/cosmic",
  digit_separator = "1_000",
  hex_float = "0x1p4",
  malformed_number = "3x",
  unterminated_string = "'x",
  unterminated_long_string = "[[x",
  bad_escape = "'\\q'",
  stray_byte = "@",
}

local function test_every_code_has_a_refusal_with_a_message_and_a_fix()
  assert(#Lexer.codes == 12)
  for _, code in ipairs(Lexer.codes) do
    local source = REFUSALS[code]
    assert(source ~= nil, code .. " has no refusal here")
    local errors = lex(source).errors
    assert(#errors >= 1 and errors[1].code == code, code)
    assert(errors[1].msg ~= "" and errors[1].fix ~= "", code)
    assert(errors[1].filename == "t.tl")
  end
end

local function test_a_whole_program_lexes_with_its_places()
  local source = table.concat({
    "--- doc",
    "local record Reply",
    "  body: string",
    "end",
    "",
    "local function show(r: Reply?): string",
    "  match fetch() do",
    "    | (true, body) then return body",
    "  end",
    "  return if r then r.body else \"\" end",
    "end",
    "",
  }, "\n")
  local lexed = lex(source)
  assert(#lexed.errors == 0)
  assert(shape(source):find("keyword:match identifier:fetch (:( ):) keyword:do op:| (:( keyword:true", 1, true))
  assert(shape(source):find("keyword:return keyword:if identifier:r keyword:then", 1, true))
end

--- The error of `source`, which has exactly one and it is a bad escape.
local function bad_escape_at(source: string): Lexer.Error
  local e = only_error(source)
  assert(e.code == "bad_escape", e.code)
  return e
end

local function test_a_bad_escape_is_placed_on_its_own_line_in_a_string_across_lines()
  local first = bad_escape_at("x = 'a\\q\\\nb'")
  assert(first.y == 1 and first.x == 7 and first.offset == 7, first.y .. ":" .. first.x)
  local second = bad_escape_at("x = 'a\\\nb\\q'")
  assert(second.y == 2 and second.x == 2 and second.offset == 10, second.y .. ":" .. second.x)
  local across = bad_escape_at("x = 'a\\z\n\n  \\q'")
  assert(across.y == 3 and across.x == 3, across.y .. ":" .. across.x)
end

--- The time [`Lexer.lex`] takes over `source`, in milliseconds.
local function milliseconds(source: string): integer
  local started = Clock.monotonic_ns()
  local lexed = Lexer.lex(source, "t.tl")
  local elapsed = (Clock.monotonic_ns() - started) // 1000000
  assert(#lexed.tokens > 1 or #lexed.errors > 1)
  return elapsed
end

--- The least time of three over `source`, so a slow moment on a shared
--- machine does not count against it.
local function least_milliseconds(source: string): integer
  local least = milliseconds(source)
  for _ = 1, 2 do
    least = math.min(least, milliseconds(source))
  end
  return least
end

--- A long line lexes in time that holds the line's length once: a search
--- for the next line break that ran to the end of the source at every
--- string or long token made one line of 200 KB take 30 times as long as
--- the same tokens one to a line. The bound is a ratio to that, not a
--- clock, so a slow machine slows both alike.
local function test_one_long_line_lexes_as_fast_as_the_same_tokens_on_lines_of_their_own()
  local forms: {string} = { "'ab',", "--[[c]]", "[[x]]", "'a\\q'", "x = 1" }
  for _, form in ipairs(forms) do
    local one_line = (form .. " "):rep(20000)
    local own_lines = (form .. "\n"):rep(20000)
    local long = least_milliseconds(one_line)
    local short = least_milliseconds(own_lines)
    assert(long <= 4 * short + 20, form .. ": one line took " .. long .. " ms, own lines " .. short .. " ms")
  end
end

local STYLES <const>: {string} = { "\n", "\r", "\r\n", "\n\r" }

--- The string Lua itself reads for the expression `literal`.
local function lua_string(literal: string): string
  local chunk, why = load("return " .. literal, "=t")
  assert(chunk ~= nil, tostring(why))
  local value = chunk()
  assert(value is string, "not a string")
  return value
end

--- The line Lua reports for the error `source` ends in.
local function lua_line(source: string): integer
  local chunk, why = load(source, "=t")
  assert(chunk == nil, "Lua accepted " .. source)
  local line = math.tointeger(tonumber(tostring(why):match("^t:(%d+):")))
  assert(line ~= nil, tostring(why))
  return line
end

local function test_every_kind_of_line_break_is_one_as_in_lua()
  for _, first in ipairs(STYLES) do
    for _, second in ipairs(STYLES) do
      local endings: {string} = {
        "x =" .. first .. second .. "@",
        "-- c" .. first .. second .. "@",
        "x = 'a\\" .. first .. "b'" .. second .. "@",
        "x = [[a" .. first .. "b]]" .. second .. "@",
        "x = 1 --[[a" .. first .. "b]]" .. second .. "@",
        "x = 'a\\z" .. first .. "  b'" .. second .. "@",
        "x = [==[" .. first .. "a" .. second .. "]==]" .. first .. "@",
      }
      for _, source in ipairs(endings) do
        local errors = lex(source).errors
        local last = errors[#errors]
        assert(last.code == "stray_byte", source)
        assert(last.y == lua_line(source), string.format("%q: line %d, Lua's %d", source, last.y, lua_line(source)))
      end
    end
  end
end

local function test_a_line_break_in_a_string_has_the_value_lua_gives_it()
  for _, brk in ipairs(STYLES) do
    local escaped = "'a\\" .. brk .. "b'"
    assert(token(escaped, 1).value == lua_string(escaped), string.format("%q", escaped))
    local zapped = "\"a\\z" .. brk .. brk .. "  b\""
    assert(token(zapped, 1).value == "ab" and lua_string(zapped) == "ab")
    for _, long in ipairs({
        "[[" .. brk .. "x" .. brk .. "y]]",
        "[==[" .. brk .. brk .. "x" .. brk .. "]==]",
        "[[x" .. brk .. brk .. "y" .. brk .. "]]",
        "[[" .. brk .. "]]",
    }) do
      local found = token(long, 1)
      assert(found.value == lua_string(long),
        string.format("%q is %q, Lua's %q", long, tostring(found.value), lua_string(long)))
    end
  end
  assert(token("[[\r\n\r\nx]]", 1).value == lua_string("[[\r\n\r\nx]]"))
  assert(token("[[\n\r\n\rx]]", 1).value == lua_string("[[\n\r\n\rx]]"))
  assert(token("[[\r\r\nx]]", 1).value == lua_string("[[\r\r\nx]]"))
end

local function test_a_line_break_that_is_not_escaped_ends_a_short_string_as_in_lua()
  for _, brk in ipairs(STYLES) do
    local source = "x = 'a" .. brk .. "b'"
    local chunk, why = load(source, "=t")
    assert(chunk == nil and tostring(why):find("unfinished string", 1, true))
    local errors = lex(source).errors
    assert(errors[1].code == "unterminated_string" and errors[1].length == 2, string.format("%q", source))
  end
end

local function test_a_comment_ends_before_its_line_break_whatever_the_style()
  for _, brk in ipairs(STYLES) do
    local comments = assert(token("-- a" .. brk .. "x", 1).comments)
    assert(comments[1].text == "-- a" and comments[1].length == 4, string.format("%q", brk))
  end
  assert(lex("#!/bin/cosmic\r\nx").errors[1].length == 13, "a #! line ends before its break")
end

local function test_goto_stands_as_a_field_name_across_lines_and_comments()
  local sources: {string} = {
    "x = {\ngoto\n= 1 }",
    "record R\ngoto\n: string\nend",
    "{ goto -- c\n= 1 }",
    "{ goto --[=[ c\n]=] = 1 }",
    "{ goto\r\n  --  c\r\n  ?: T }",
    "goto =",
    "goto :",
  }
  for _, source in ipairs(sources) do
    local lexed = lex(source)
    if source:find("--[=[", 1, true) then
      assert(#lexed.errors == 1 and lexed.errors[1].code == "long_comment", "only the long comment is refused")
    else
      assert(#lexed.errors == 0, source)
    end
    local kind = ""
    for _, t in ipairs(lexed.tokens) do
      if t.text == "goto" then
        kind = t.kind
      end
    end
    assert(kind == "keyword", source)
  end
end

local function test_goto_with_nothing_that_names_a_field_after_it_is_refused()
  for _, source in ipairs({ "goto", "goto -- c", "goto == x", "goto\nx = 1", "goto ? x", "t = { goto",
      "t = { goto -- note" }) do
    local e = only_error(source)
    assert(e.code == "label_or_goto" and e.length >= 4, source)
  end
end

local function test_a_hexadecimal_float_out_of_range_is_not_told_to_write_inf()
  local e = only_error("x = 0x1p99999")
  assert(e.code == "hex_float")
  assert(e.fix == "the value is out of range for a float: write a value a float holds, in decimal")
  assert(not e.fix:find("inf", 1, true) or e.fix:find("out of range", 1, true))
end

local function test_the_decimal_a_hexadecimal_float_is_told_reads_back_as_the_same_float()
  for _, text in ipairs({ "0x1p4", "0x.8", "0x1.8p1", "0xAp-3", "0x1p-1074", "0x1.fffffffffffffp1023", "0x.1", "0x3p0" }) do
    local e = only_error(text)
    local written = e.fix:match("`(.-)`$")
    assert(written ~= nil, e.fix)
    local back = tonumber(written)
    assert(back ~= nil and math.type(back) == "float" and back == token(text, 1).number, text .. " -> " .. written)
  end
end

local function test_a_byte_order_mark_inside_a_file_is_not_said_to_start_it()
  local bom = "\239\187\191"
  local inside = only_error("x = 1 " .. bom)
  assert(inside.msg == "stray byte order mark" and not inside.fix:find("at the start of the file", 1, true))
  assert(inside.fix == "delete the byte order mark; one marks the start of a file and is no part of a program")
  assert(only_error(bom .. "x = 1").fix == "delete the byte order mark at the start of the file")
end

local function test_a_bad_escape_names_the_whole_character_it_backslashes()
  local e = bad_escape_at("x = '\\" .. E_ACUTE .. "'")
  assert(e.msg == "invalid escape `\\" .. E_ACUTE .. "`" and e.length == 3, e.msg)
  assert(e.fix:find("`\\\\" .. E_ACUTE .. "`", 1, true))
  assert(e.x == 6, tostring(e.x))
  local raw = bad_escape_at("x = '\\\200'")
  assert(raw.msg == "invalid escape `\\\\xC8`", raw.msg)
  local control = bad_escape_at("x = '\\\1'")
  assert(control.msg == "invalid escape `\\\\x01`", control.msg)
  local stray = only_error("x = \200")
  assert(stray.msg == "stray `\\xC8`", stray.msg)
end

local function test_a_string_value_is_not_a_long_string_unless_it_is_one()
  assert(token("'a'", 1).long == nil and token("\"a\"", 1).long == nil and token("[[a]]", 1).long == true)
  assert(token("x", 1).long == nil)
end

local function test_a_token_that_ends_in_a_line_break_ends_on_the_line_it_began_the_break_on()
  local long = token("x = [[a\r\n", 3)
  assert(long.kind == "$ERR$" and long.y == 1 and long.x == 5 and long.yend == 1 and long.xend == 9)
  local short = token("x = 'a\\\n", 3)
  assert(short.kind == "$ERR$" and short.yend == 1 and short.xend == 8)
  local comment = token("--[[ c\n\n", 1)
  assert(comment.kind == "$ERR$" and comment.yend == 2 and comment.xend == 1)
end
