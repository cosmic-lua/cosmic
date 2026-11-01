--- Tests of [`build.test_returns`]: a test that returns early from its own body is found, one that skips with
--- [`Test.skip`], returns from a branch that also asserts, or returns from anything but a test is not.
local SyntaxNode = require("build.syntax_node")
local Test = require("cosmic.test")
local TestReturns = require("build.test_returns")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- What the reader finds in `text`, as `line:test:shape` in order.
local function read(text: string): {string}
  local out: mut {string} = {}
  for _, site in ipairs(TestReturns.of_chunk((assert(SyntaxNode.parse(text, "t_test.tl"))))) do
    out[#out + 1] = table.concat(site, ":")
  end
  return out
end

local record Case
  name: string
  text: string
  found: {string}
end

local CASES: {Case} = {
  { name = "a guard that returns", text = source(
    "local function test_a()",
    "  local x = nil",
    "  if x == nil then return end",
    "  assert(x)",
    "end"), found = { "3:test_a:if ... then return end" } },
  { name = "a guard with a comment after its return", text = source(
    "local function test_a()",
    "  if nothing() then return end -- not here",
    "  assert(true)",
    "end"), found = { "2:test_a:if ... then return end" } },
  { name = "a bare return", text = source(
    "local function test_a()",
    "  assert(true)",
    "  return",
    "end"), found = { "3:test_a:return" } },
  { name = "a return of a value", text = source(
    "local function test_a()",
    "  if nothing() then return 1 end",
    "  return 2",
    "end"), found = {} },
  { name = "each test of a file on its own line", text = source(
    "local function test_a()",
    "  if nothing() then return end",
    "end",
    "",
    "local function test_b(tmp: string)",
    "  if tmp == nil then return end",
    "end"), found = { "2:test_a:if ... then return end", "6:test_b:if ... then return end" } },
  { name = "a return after Test.skip, the idiom", text = source(
    "local function test_a()",
    "  if nothing() then",
    "    Test.skip(\"no\")",
    "    return",
    "  end",
    "  Test.skip(\"also no\")",
    "  return",
    "end"), found = {} },
  { name = "a return after something else than Test.skip", text = source(
    "local function test_a()",
    "  other.skip(\"no\")",
    "  return",
    "end"), found = { "3:test_a:return" } },
  { name = "a skip", text = source(
    "local function test_a()",
    "  if nothing() then Test.skip(\"no\") end",
    "  assert(true)",
    "end"), found = {} },
  { name = "a branch that asserts before it returns", text = source(
    "local function test_a()",
    "  if nothing() then",
    "    assert(true)",
    "    return",
    "  end",
    "  assert(false)",
    "end"), found = {} },
  { name = "a branch with an else", text = source(
    "local function test_a()",
    "  if nothing() then return else assert(true) end",
    "end"), found = {} },
  { name = "a branch with an elseif", text = source(
    "local function test_a()",
    "  if nothing() then return elseif other() then assert(true) end",
    "end"), found = {} },
  { name = "a return in a loop, a callback and a helper", text = source(
    "local function test_a()",
    "  for _, x in ipairs(list) do",
    "    if x == nil then return end",
    "  end",
    "  run(function() if nothing() then return end end)",
    "  local function inner() if nothing() then return end end",
    "  inner()",
    "end"), found = {} },
  { name = "a function that is no test", text = source(
    "local function helper()",
    "  if nothing() then return end",
    "end",
    "local function tests_nothing()",
    "  return",
    "end",
    "local tests = {}",
    "function tests.test_field()",
    "  if nothing() then return end",
    "end"), found = {} },
  { name = "a return named in a string or a comment", text = source(
    "local function test_a()",
    "  -- if x then return end",
    "  local s = \"if x then return end\"",
    "  assert(s)",
    "end"), found = {} },
}

local function test_early_returns_are_found_only_as_statements_of_a_test_body()
  for _, case in ipairs(CASES) do
    local found = read(case.text)
    assert(table.concat(found, " ") == table.concat(case.found, " "),
      case.name .. ": found " .. table.concat(found, " "))
  end
end
