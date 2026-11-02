--- Tests of [`build.test_clones`]: a top-level helper is cut out of a file where it begins and ends at the left margin,
--- tests and short helpers are left out, and two cuts that differ in comments and layout alone give the same tokens.
local Test = require("cosmic.test")
local TestClones = require("build.test_clones")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local function test_helpers_are_cut_with_their_lines_and_tests_are_left_out()
  local cuts = TestClones.cuts(source(
    "local x = 1",
    "",
    "local function first(a: string): string",
    "  return a",
    "end",
    "local function test_one()",
    "  assert(true)",
    "end",
    "  local function nested() end",
    "local function second(a: string): string",
    "  return a .. a",
    "end"), 1)
  assert(#cuts == 2, #cuts)
  local first, second = assert(cuts[1]), assert(cuts[2])
  assert(first.name == "first" and first.line == 3, first.name .. ":" .. tostring(first.line))
  assert(second.name == "second" and second.line == 10, second.name .. ":" .. tostring(second.line))
  assert(first.text == "(a: string): string\n  return a\nend\n", first.text)
  assert(#TestClones.cuts("local function first(a: string): string\n  return a\nend\n", 1000) == 0)
end

local function test_a_comment_and_the_layout_are_no_part_of_a_helper()
  local plain = assert(TestClones.cuts(source("local function f(a: string): string", "  return a", "end"), 1)[1])
  local noted = assert(TestClones.cuts(source("local function f(a: string): string  -- the name",
    "  -- returns it", "  return   a", "end"), 1)[1])
  assert(plain.key == noted.key, plain.key .. " / " .. noted.key)
  local one = assert(TestClones.tokens(plain.text, "a.tl"))
  local other = assert(TestClones.tokens(noted.text, "b.tl"))
  assert(table.concat(one, " ") == table.concat(other, " "), table.concat(other, " "))
  local changed = assert(TestClones.cuts(source("local function f(a: string): string", "  return b", "end"), 1)[1])
  assert(plain.key ~= changed.key)
end

local function test_a_cut_the_lexer_refuses_is_no_tokens()
  local cut = assert(TestClones.cuts("local function f(): string\n  return [[\nend\n]]\nend\n", 1)[1])
  assert(TestClones.tokens(cut.text, "a.tl") == nil)
end
