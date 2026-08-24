#!/usr/bin/env cosmic
-- Tests for the reader `cosmic.literal.parse` dispatches to.
--
-- Two implementations read this grammar -- one in C, one the lexer in
-- `cosmic/literal.tl` -- and the promise is that a caller cannot tell
-- which answered. So the tests are written as that comparison: one
-- source through `engine = "c"` and `engine = "teal"`, values compared
-- for equality and refusals BYTE for byte.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")

--- Read under one engine, failing with the reader's own message.
local function read(src: string, engine: string): {string: any}
  local v, err = literal.parse(src, {file = "t", noun = "pin", engine = engine})
  assert(v, engine .. ": expected a literal, got: " .. tostring(err))
  return v
end

--- Read under one engine expecting refusal; return the message.
local function refused(src: string, engine: string): string
  local v, err = literal.parse(src, {file = "t", noun = "pin", engine = engine})
  assert(not v, engine .. ": expected a refusal, got a value")
  return err
end

-- The value halves must agree over the corners the two implementations
-- code separately: comments of both kinds, a shebang, nested tables, a
-- bracketed key, every number form, booleans, and strings in all three
-- quotings.
local NESTED = [==[
#!/usr/bin/env cosmic
-- a line comment, and below a long one, both of which readers skip
--[[ long
comment ]]
return {
  ["a key"] = "x\ny",
  escapes = "\65\x41\u{263A}\t\\\"",
  long = [[a long bracket
carrying no escapes]],
  n = 1, neg = -2, hex = 0x10, hexf = 0x1p4, f = 1.5, exp = 1e3,
  t = true, no = false,
  inner = {deep = {leaf = 'single quoted'}},
}
]==]

local function test_engines_agree_on_a_nested_payload()
  local as_c = check.must(literal.format(read(NESTED, "c")))
  local as_teal = check.must(literal.format(read(NESTED, "teal")))
  assert(as_c == as_teal, "engines disagree:\n" .. as_c .. "\n" .. as_teal)
end
test_engines_agree_on_a_nested_payload()

-- Every refusal is written once, in the Teal reader, and the C path
-- discards its own message to re-read and report that one — so each of
-- these must come back identical under both engines, label included.
local REFUSALS: {string} = {
  "return {a = foo}",
  "return {a = 1, a = 2}",
  "return {a = 1} x",
  "{a = 1}",
  "return 1",
  "return {a = 1",
  "return {a = 0x}",
  "return {a = [==[unterminated}",
  "return {a = 1} --[[unterminated",
}

local function test_refusals_are_byte_identical()
  for _, src in ipairs(REFUSALS) do
    local c = refused(src, "c")
    local teal = refused(src, "teal")
    assert(c == teal, "refusals differ for `" .. src .. "`:\n  c:    " ..
      c .. "\n  teal: " .. teal)
    assert(c:sub(1, 2) == "t:", "refusal lost its file label: " .. c)
  end
end
test_refusals_are_byte_identical()

-- A resolver is the one option the C reader cannot honour -- it refuses
-- a repeat outright, with no hook -- so `parse` keeps the source on the
-- Teal reader whenever one is supplied, as `_tool/coverage/baseline.tl`
-- depends on.
local function test_on_duplicate_still_resolves_under_auto()
  local v, err = literal.parse("return {a = 1, a = 2}", {
      on_duplicate = function(_key: string, _first: any, second: any): any
        return second
      end,
    })
  assert(v, "expected a literal, got: " .. tostring(err))
  assert(v.a == 2, "resolver did not run: " .. tostring(v.a))
end
test_on_duplicate_still_resolves_under_auto()

-- An engine nobody implements is a caller's typo, and one that read the
-- file anyway would hide which reader ran. The message names the three.
local function test_unknown_engine_is_refused()
  local v, err = literal.parse("return {a = 1}", {engine = "rust"})
  assert(not v, "expected a refusal, got a value")
  assert(err:find("auto", 1, true) and err:find("teal", 1, true) and
    err:find('"c"', 1, true), "message does not name the engines: " .. err)
  assert(err:find("rust", 1, true), "message does not name the ask: " .. err)
end
test_unknown_engine_is_refused()

-- `parse_file` takes the same options, so an engine chosen there must
-- reach the reader rather than being dropped on the way.
local function test_parse_file_carries_the_engine()
  local path = fs.join(os.getenv("TEST_TMPDIR") or ".", "engine_pin.tl")
  local ok, werr = fs.write(path, "return {a = foo}")
  assert(ok, tostring(werr))
  local v, err = literal.parse_file(path, {file = "t", noun = "pin", engine = "c"})
  assert(not v, "expected a refusal, got a value")
  assert(err == refused("return {a = foo}", "teal"),
    "parse_file's refusal is not the reader's: " .. err)
end
test_parse_file_carries_the_engine()
