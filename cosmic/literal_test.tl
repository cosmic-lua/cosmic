#!/usr/bin/env cosmic
-- Tests for cosmic.literal: Teal source read as data.
--
-- The module's contract is "the value the file would have returned",
-- which is a claim about EQUALITY with Lua, not merely about parsing.
-- The string tests below are written as that comparison: the expected
-- value is the same literal written in Teal, so the test states the
-- contract instead of restating the implementation.

local literal = require("cosmic.literal")

--- Read a source and return the table, failing the test with the
--- reader's own message when it refuses.
local function read(src: string): {string: any}
  local v, err = literal.parse(src, {file = "t", noun = "pin"})
  assert(v, "expected a literal, got: " .. tostring(err))
  return v as {string: any} -- cast: record union after the assert
end

--- Read a source expecting refusal, and return the message.
local function refused(src: string): string
  local v, err = literal.parse(src, {file = "t", noun = "pin"})
  assert(not v, "expected a refusal, got a value")
  return err
end

-- Short strings carry escapes, and the reader must decode them.
-- Returning the raw bytes between the quotes reads `"a\nb"` as four
-- characters instead of three -- silently wrong data from a module
-- whose whole promise is fidelity.
local function test_escapes_decode()
  assert(read([[return { s = "a\nb" }]]).s == "a\nb", "\\n")
  assert(read([[return { s = "a\tb" }]]).s == "a\tb", "\\t")
  assert(read([[return { s = "q\"q" }]]).s == "q\"q", "escaped quote")
  assert(read([[return { s = "b\\s" }]]).s == "b\\s", "escaped backslash")
  assert(read([[return { s = "\65\66" }]]).s == "AB", "decimal escape")
  assert(read([[return { s = "\x41" }]]).s == "A", "hex escape")
  assert(read([[return { s = "\u{263A}" }]]).s == "\u{263A}", "unicode escape")
  assert(read("return { s = 'sq\\ngl' }").s == "sq\ngl", "single quotes too")
end
test_escapes_decode()

-- Every escape above sits at the END of its string, which is the one
-- position where a wrong resume index is invisible: overshooting past
-- `#body` just ends the loop, and the assertion still passes. An
-- off-by-two in `\u{}` (treating an absolute position capture as
-- relative) eats the two characters behind every unicode escape and
-- shows up nowhere. Each form is followed by text here, which pins the
-- resume arithmetic of each branch rather than only its value.
local function test_escapes_resume_at_the_right_index()
  assert(read([[return { s = "\u{41}BC" }]]).s == "ABC", "\\u{} then text")
  assert(read([[return { s = "\u{41}BCDE" }]]).s == "ABCDE", "\\u{} then more")
  assert(read([[return { s = "x\u{263A}y" }]]).s == "x\u{263A}y", "\\u{} surrounded")
  assert(read([[return { s = "\x41BC" }]]).s == "ABC", "\\x then text")
  assert(read([[return { s = "\65BC" }]]).s == "ABC", "decimal then text")
  assert(read([[return { s = "a\nbc" }]]).s == "a\nbc", "simple then text")
  assert(read("return { s = \"\\z   BC\" }").s == "BC", "\\z then text")
  -- A bracketed key runs the same decoder, so it needs the same pin.
  assert(read([[return { ["\u{41}k"] = "v" }]]).Ak == "v", "\\u{} in a key")
end
test_escapes_resume_at_the_right_index()

-- The lexer is this module's own rather than tl's, so a config reader
-- does not depend on the Teal compiler (see the module header). These
-- are the shapes a hand-written lexer gets wrong.
local function test_lexing()
  assert(read("-- a comment\nreturn { a = 1 }").a == 1, "line comment before")
  assert(read("return { a = 1 } -- trailing").a == 1, "line comment after")
  assert(read("--[[ two\nlines ]]\nreturn { a = 1 }").a == 1, "long comment")
  assert(read("--[==[ x ]==] return { a = 1 }").a == 1, "long comment, level 2")
  assert(read("#!/usr/bin/env cosmic\nreturn { a = 1 }").a == 1, "shebang skipped")
  -- `--` inside a string is not a comment.
  assert(read("return { s = 'a -- b' }").s == "a -- b", "dashes in a string")
  assert(read("return { a = 0x10 }").a == 16, "hex integer")
  assert(read("return { a = 1e3 }").a == 1000.0, "exponent")
  assert(read("return { a = 0x1p4 }").a == 16.0, "hex float")
  assert(read("return { a = 1, }").a == 1, "trailing comma")
  assert(read("return { a = 1; b = 2 }").b == 2, "semicolon separator")
  -- A reserved word lexes as a keyword, so it can never be read as a key.
  assert(refused("return { end = 1 }"):find("<literal>", 1, true),
    "a keyword is not an identifier")
end
test_lexing()

-- Input that cannot be finished has no next token to complain about, so
-- the lexer refuses it itself -- with the line, like every other refusal.
local function test_unfinishable_input_is_refused()
  assert(refused('return { a = "oops }'):find("unterminated string", 1, true),
    "unterminated short string")
  assert(refused("return { a = [[oops }"):find("unterminated long string", 1, true),
    "unterminated long string")
  assert(refused("--[[ oops\nreturn { a = 1 }"):find("unterminated long comment", 1, true),
    "unterminated long comment")
end
test_unfinishable_input_is_refused()

-- Long brackets take no escapes and drop one leading newline, and the
-- delimiter is as many `=` as were written -- so stripping a fixed one
-- character per side reads `[==[x]==]` as `==[x]==`.
local function test_long_brackets()
  assert(read("return { s = [[hi]] }").s == "hi", "level 0")
  assert(read("return { s = [=[hi]=] }").s == "hi", "level 1")
  assert(read("return { s = [==[hi]==] }").s == "hi", "level 2")
  assert(read("return { s = [[\nline]] }").s == "line", "leading newline dropped")
  assert(read([==[return { s = [[a\nb]] }]==]).s == "a\\nb",
    "a long bracket is literal: no escape decoding")
end
test_long_brackets()

-- A bracketed key is a string token like any other, so it decodes the
-- same way.
local function test_bracketed_keys()
  local t = read([[return { ["a\tb"] = "v" }]])
  assert(t["a\tb"] == "v", "an escaped key decodes")
  assert(t["a\\tb"] == nil, "and not to its raw bytes")
end
test_bracketed_keys()

-- The lexer emits `-` as its own token, so a negative number arrives
-- as two tokens and is easy to mistake for an operator. Nothing about
-- -1 asks the file to compute anything, so it must read.
local function test_negative_numbers()
  assert(read("return { n = -1 }").n == -1, "negative integer")
  assert(read("return { n = -1.5 }").n == -1.5, "negative float")
  assert(read("return { n = 2 }").n == 2, "positive still works")
end
test_negative_numbers()

-- Depth is stack depth in a recursive-descent parser, so without a cap
-- a crafted literal THROWS `stack overflow` out of a library that
-- promises never to throw. It must refuse like any other bad pin.
local function test_deep_nesting_is_refused_not_thrown()
  local n = 100000
  local src = "return " .. string.rep("{ a = ", n) .. "1" .. string.rep(" }", n)
  local ok, v, err = pcall(literal.parse, src, {file = "t", noun = "pin"})
  assert(ok, "reading a deep literal must not throw: " .. tostring(v))
  assert(not v, "a deep literal must be refused")
  assert((err as string):find("nests deeper", 1, true), -- cast: pcall result
    "the message names the reason, got: " .. tostring(err))

  -- The limit is far past any real config, so ordinary nesting passes.
  local shallow = read("return { a = { b = { c = { d = 1 } } } }")
  local a = shallow.a as {string: any} -- cast: from any
  local b = a.b as {string: any} -- cast: from any
  local c = b.c as {string: any} -- cast: from any
  assert(c.d == 1, "4 levels still read")
end
test_deep_nesting_is_refused_not_thrown()

-- Nesting was the first way a crafted file could throw out of this
-- module; these are the other two, and they are the same bug wearing
-- different clothes. A token that LEXES is not a value that EXISTS.
--
-- Both are reachable from a pin, where a throw is a `--make fetch`
-- traceback standing where a named refusal belongs.
local function test_a_crafted_value_is_refused_not_thrown()
  -- `%x+` has no length limit, so the escape parses and the code point
  -- is past what utf8.char takes.
  local ok, v, err = pcall(literal.parse,
    'return { x = "\\u{FFFFFFFFFF}" }', {file = "t", noun = "pin"})
  assert(ok, "an out-of-range code point must not throw: " .. tostring(v))
  assert(not v and (err as string):find("malformed string", 1, true), -- cast: pcall result
    "it is refused by name, got: " .. tostring(err))

  -- `0x.` matches the lexer's numeral shape and `tonumber` reads it as
  -- nil: negated that threw, and stored bare it silently DROPPED the
  -- key -- a pin whose sha256 goes missing rather than being refused.
  for _, src in ipairs({"return { x = -0x. }", "return { x = 0x. }"}) do
    local nok, nv, nerr = pcall(literal.parse, src, {file = "t", noun = "pin"})
    assert(nok, src .. " must not throw: " .. tostring(nv))
    assert(not nv, src .. " must be refused, not silently dropped")
    assert((nerr as string):find("malformed number", 1, true), -- cast: pcall result
      "named by reason, got: " .. tostring(nerr))
  end

  -- And the values either side of the boundary still read.
  assert(read('return { x = "\\u{48}\\u{49}" }').x == "HI",
    "an ordinary code point still decodes")
  assert(read("return { x = -1, y = 2.5, z = 0x10 }").z == 16,
    "ordinary numbers still read")
end
test_a_crafted_value_is_refused_not_thrown()

-- The grammar itself: a file read this way cannot do anything.
local function test_a_literal_cannot_be_code()
  assert(refused('return { a = "x" .. "y" }'):find("concatenation", 1, true),
    "concatenation is refused")
  assert(refused("return { a = f() }"):find("literals only", 1, true),
    "a call is refused")
  assert(refused("local x = 1\nreturn { a = x }"):find("exactly", 1, true),
    "a statement before the return is refused")
  assert(refused("return 42"):find("table literal", 1, true),
    "a non-table return is refused")
end
test_a_literal_cannot_be_code()

print("all literal tests passed")
