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
  local v, err = literal.of_source(src, "t", "pin")
  assert(v, "expected a literal, got: " .. tostring(err))
  return v as {string: any} -- cast: record union after the assert
end

--- Read a source expecting refusal, and return the message.
local function refused(src: string): string
  local v, err = literal.of_source(src, "t", "pin")
  assert(not v, "expected a refusal, got a value")
  return err
end

-- Short strings carry escapes, and the reader must decode them. The
-- old `sub(2, -2)` returned the raw bytes between the quotes, so
-- `"a\nb"` read as four characters instead of three -- silently wrong
-- data from a module whose whole promise is fidelity.
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

-- Long brackets take no escapes and drop one leading newline, and the
-- delimiter is as many `=` as were written. Stripping one character
-- per side turned `[==[x]==]` into `==[x]==`.
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

-- The lexer emits `-` as its own token, so a negative number looked
-- like an operator and was refused. Nothing about -1 asks the file to
-- compute anything.
local function test_negative_numbers()
  assert(read("return { n = -1 }").n == -1, "negative integer")
  assert(read("return { n = -1.5 }").n == -1.5, "negative float")
  assert(read("return { n = 2 }").n == 2, "positive still works")
end
test_negative_numbers()

-- Depth is stack depth in a recursive-descent parser, so a crafted
-- literal used to THROW `stack overflow` out of a library that
-- promises never to throw. It must refuse like any other bad pin.
local function test_deep_nesting_is_refused_not_thrown()
  local n = 100000
  local src = "return " .. string.rep("{ a = ", n) .. "1" .. string.rep(" }", n)
  local ok, v, err = pcall(literal.of_source, src, "t", "pin")
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
