--- What a stub ([`build.syntax_stub`]) keeps and leaves out of a source in the new grammar.
local Node = require("build.syntax_node")
local Stub = require("build.syntax_stub")
local Test = require("cosmic.test")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local function stub_of(text: string): string
  local chunk, why = Node.parse(text, "m.tl")
  return Stub.made((assert(chunk, why))).text
end

--- The lines of `text`, each without its trailing spaces.
local function lines(text: string): {string}
  local out: {string} = {}
  for line in text:gmatch("([^\n]*)\n") do
    out[#out + 1] = (line:gsub("%s+$", ""))
  end
  return out
end

local function test_a_stub_leaves_out_bodies_and_comments_and_keeps_positions()
  local stubbed = lines(stub_of(source(
    "--- The module.",
    'local Json = require("cosmic.json")',
    "local record M",
    "  -- A count.",
    "  n: integer",
    "end",
    "local LIMIT <const> = 3",
    "function M.f(a: integer): integer",
    "  local b = a + LIMIT -- why",
    "  return Json.encode(b) and b or 0",
    "end",
    "M.g = function(s: string): string return s .. 'x' end",
    "function M.empty() end",
    "return (M)")))
  local want = {
    "",
    'local Json = require("cosmic.json")',
    "local record M",
    "",
    "  n: integer",
    "end",
    "local LIMIT <const> = 3",
    "function M.f(a: integer): integer",
    "",
    "",
    "end",
    "M.g = function(s: string): string",
    "function M.empty() end",
    "return (M)",
  }
  assert(#stubbed == #want, table.concat(stubbed, "\n"))
  for i, line in ipairs(want) do
    if i == 12 then
      -- The one-line function keeps its `end` at the column it had.
      assert(stubbed[i]:match("^M%.g = function%(s: string%): string +end$") ~= nil, "line 12: " .. stubbed[i])
    else
      assert(stubbed[i] == line, "line " .. i .. ": " .. stubbed[i])
    end
  end
  local text = stub_of(source("local record M", "end", "M.g = function(s: string): string return s end", "return (M)"))
  assert(text:find("M.g = function(s: string): string" .. (" "):rep(10) .. "end", 1, true) ~= nil, text)
end

local function test_a_module_returning_its_record_keeps_only_what_its_type_names()
  local stubbed = lines(stub_of(source(
    'local Json = require("cosmic.json")',
    'local Shape = require("cosmic.shape")',
    'local type Ledger = require("ledger")',
    "local record Helper",
    "  n: integer",
    "end",
    "local record M",
    "  spec: Shape.Spec",
    "end",
    "local LIMIT <const> = 3",
    "local function helper(l: Ledger): integer return LIMIT end",
    "function M.f(h: Helper): integer",
    "  return Json.encode(h) and helper() or 0",
    "end",
    "M.g = 1",
    "return M")))
  local want = {
    "",
    'local Shape = require("cosmic.shape")',
    "",
    "local record Helper",
    "  n: integer",
    "end",
    "local record M",
    "  spec: Shape.Spec",
    "end",
    "",
    "",
    "function M.f(h: Helper): integer",
    "",
    "end",
    "",
    "return M",
  }
  assert(#stubbed == #want, table.concat(stubbed, "\n"))
  for i, line in ipairs(want) do
    assert(stubbed[i] == line, "line " .. i .. ": " .. stubbed[i])
  end
end

local function test_a_record_name_declared_again_as_a_value_keeps_every_statement()
  local stubbed = stub_of(source(
    "local record M",
    "end",
    "local M = {}",
    "M.x = 1",
    "return M"))
  assert(stubbed:find("M.x = 1", 1, true) ~= nil, stubbed)
end

local function test_a_never_function_s_stub_body_raises()
  local stubbed = stub_of(source(
    "local record M",
    "end",
    "local function stop(): never error('stop') end",
    "function M.die(why: string): never",
    "  error(why)",
    "end",
    "function M.quit(): never error('x') end",
    "function M.halt(): never stop() end",
    "return M"))
  assert(stubbed:find("function M.die(why: string): never\n  error()\nend", 1, true) ~= nil, stubbed)
  assert(stubbed:find("function M.quit(): never error()    end", 1, true) ~= nil, stubbed)
  -- A body with no room for `error()` on its line is kept.
  assert(stubbed:find("function M.halt(): never stop() end", 1, true) ~= nil, stubbed)
end

local function test_a_function_inside_a_top_level_value_loses_its_body()
  local stubbed = stub_of(source(
    "local handlers: {string: function(integer): integer} = {",
    "  double = function(n: integer): integer",
    "    return n * 2",
    "  end,",
    "}",
    "return handlers"))
  assert(stubbed:find("n * 2", 1, true) == nil and
      stubbed:find("double = function(n: integer): integer\n\n  end,", 1, true) ~= nil, stubbed)
end

local function test_a_method_of_a_class_loses_its_body()
  local stubbed = stub_of(source(
    "local class Box",
    "  n: integer",
    "  function bump(self, by: integer): integer",
    "    return self.n + by",
    "  end",
    "end",
    "return Box"))
  assert(stubbed:find("self.n + by", 1, true) == nil and stubbed:find("function bump(self, by: integer): integer", 1, true) ~= nil,
    stubbed)
end

local function test_a_literal_typed_by_its_context_keeps_its_body()
  local text = source(
    "local record M",
    "  f: function(integer): integer",
    "  stop: function(string): never",
    "  g: function(integer): integer",
    "end",
    "M.f = function(n: integer) return n end",
    "M.stop = function(why: string) error(why) end",
    "M.g = function(n: integer): integer return n end",
    "return (M)")
  local stubbed = stub_of(text)
  assert(stubbed:find("M.f = function(n: integer) return n end", 1, true) ~= nil and
      stubbed:find("M.stop = function(why: string) error(why) end", 1, true) ~= nil and
      stubbed:find("M%.g = function%(n: integer%): integer +end") ~= nil, stubbed)
end

local function test_a_stub_is_declaration_only_where_the_module_returns_its_type()
  local function prunes(text: string): boolean
    local chunk, why = Node.parse(text, "m.tl")
    return Stub.made((assert(chunk, why))).pruned
  end
  assert(prunes(source("local record M", "end", "return M")))
  assert(prunes(source("local type M = string", "return M")))
  assert(prunes(source("local function main(): integer return 0 end", "return main")))
  assert(prunes(source("local record R", "end", "local m: R = {}", "return m")))
  assert(not prunes(source("local m = {}", "return m")), "a local of an inferred type")
  assert(not prunes(source("local record R", "end", "local m, n: R, R = {}, {}", "return m")),
    "a local declared beside another")
  assert(not prunes(source("local record M", "end", "return (M)")), "a parenthesized name")
  assert(not prunes(source("local record M", "end", "local M = {}", "return M")), "a name declared last as a value")
  assert(not prunes(source("return {}")), "a table")
end

local function test_a_module_returning_a_typed_local_keeps_the_declaration_and_what_it_names()
  local stubbed = stub_of(source(
    'local Json = require("cosmic.json")',
    "local record M",
    "  f: function(integer): integer",
    "end",
    "local function f(n: integer): integer return Json.encode(n) and n or 0 end",
    "local m: M = { f = f }",
    "return m"))
  assert(stubbed:find("cosmic.json", 1, true) == nil and stubbed:find("local m: M = { f = f }", 1, true) ~= nil,
    stubbed)
end

local function test_a_long_string_keeps_its_lines()
  local stubbed = lines(stub_of(source("local TEXT = [[one", "two]]", "local n = 1", "return TEXT")))
  assert(#stubbed == 4 and stubbed[2] == "two]]" and stubbed[3] == "local n = 1", table.concat(stubbed, "|"))
end

--- The fork does not mark a `local function` `never`, so leaves its stub body empty; the port writes `error()` as it does
--- for the function of a record, since a `never` function must not reach its end.
local function test_a_local_never_function_with_a_body_on_its_own_lines_gets_the_raising_body()
  local stubbed = stub_of(source(
    "local function fail(why: string): never",
    "  error(why, 0)",
    "end",
    "local record M",
    "end",
    "return (M)"))
  assert(stubbed:find("local function fail(why: string): never\n  error()\nend", 1, true) ~= nil, stubbed)
end

local function test_a_stub_of_every_statement_drops_bodies_alone()
  local text = source('local Json = require("cosmic.json")', "local record M", "end",
    "local unused = Json.encode({})", "function M.f(): integer return 1 end", "return M")
  local chunk, why = Node.parse(text, "m.tl")
  local parsed = assert(chunk, why)
  local pruned = Stub.made(parsed)
  assert(pruned.pruned and pruned.text:find("unused", 1, true) == nil, pruned.text)
  local every = Stub.made(parsed, true)
  assert(not every.pruned, "every statement is kept")
  assert(every.text:find("local unused = Json.encode({})", 1, true) ~= nil, every.text)
  assert(every.text:find("return 1", 1, true) == nil, "a body is left out: " .. every.text)
end
