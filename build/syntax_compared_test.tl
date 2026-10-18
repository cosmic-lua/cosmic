--- Tests of [`build.syntax_compared`]: a file the fork's readers and their ports read alike is told so, a file one of
--- them cannot read is left out, and a reader that answers otherwise is named.
local Ast = require("lang.ast")
local Compared = require("build.syntax_compared")
local Globals = require("build.syntax_globals")
local Lexical = require("build.syntax_scopes")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local Rewrite = require("build.syntax_rewrite")
local Scopes = require("lang.scopes")
local Stub = require("build.syntax_stub")
local coverage = require("build.coverage")
local Test = require("cosmic.test")
local ast = require("build.ast")
local stub = require("build.stub")
local teal = require("build.teal")

Test.policy{}

local built = assert(teal.load(true))

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local TREE_FILE <const> = source(
  "--- A module.",
  'local Fs = require("cosmic.fs")',
  'local type Types = require("build.types")',
  "local record M",
  "  n: integer",
  "end",
  "local function twice(n: integer): integer",
  "  local read = Fs.read",
  "  for i = 1, n do",
  "    local each = Fs.write",
  "  end",
  "  return n * 2",
  "end",
  "function M.f(x: integer): integer",
  "  return twice(x)",
  "end",
  "return M")

local function test_a_file_the_fork_and_the_ports_read_alike_has_no_difference()
  local outcome = Compared.file(built, "m.tl", TREE_FILE)
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
end

local function test_a_file_whose_methods_move_into_a_class_is_compared_apart_from_its_lines()
  local outcome = Compared.file(built, "c.tl", source(
    'local Fs = require("cosmic.fs")',
    "local record R",
    "  n: integer",
    "  bump: function(R)",
    "end",
    "local mt: metatable<R> = { __index = R }",
    "function R:bump()",
    "  local read = Fs.read",
    "  self.n = self.n + 1",
    "end",
    "return R"))
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
end

local function test_a_file_the_fork_or_the_translation_cannot_read_is_left_out()
  local fork = Compared.file(built, "bad.tl", "if x then\n")
  assert(fork.skipped:find("the fork does not parse it", 1, true) ~= nil, fork.skipped)
  local tuple = Compared.file(built, "tuple.tl", source("local a: {{string, integer}}", "return a"))
  assert(tuple.skipped:find("its translation does not parse", 1, true) ~= nil, tuple.skipped)
end

local function test_a_reader_that_answers_otherwise_is_named()
  local made = stub.made
  stub.made = function(parsed: ast.Parsed): stub.Made
    local right = made(parsed)
    return { text = right.text, pruned = not right.pruned }
  end
  local ok, raised = pcall(function(): string
    local outcome = Compared.file(built, "m.tl", TREE_FILE)
    assert(#outcome.differences == 1 and outcome.differences[1]:find("stub: pruned", 1, true) == 1,
      table.concat(outcome.differences, "\n"))
    return ""
  end)
  stub.made = made
  assert(ok, raised)
end

local DECLARATIONS <const> = source(
  "global record Box",
  "  n: integer",
  "end",
  "  global enum Level",
  '    "warn"',
  "  end",
  "global type Name = string",
  "global print: any",
  "local record Helper",
  "end")

local function test_the_global_declarations_of_a_declaration_file_are_compared_by_line_and_column()
  local outcome = Compared.file(built, "std.d.tl", DECLARATIONS)
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
  assert(#Globals.found((assert(Node.parse(DECLARATIONS, "std.d.tl")))) == 4)
end

--- One plant: a reader of the ports answers otherwise, and the comparison names it.
local record Plant
  reader: string
  --- The file the plant is run on.
  file: string
  text: string
  plant: function(): function()
end

local function test_every_dimension_of_the_comparison_reports_a_difference_in_its_reader()
  local plants: {Plant} = {
    { reader = "requires", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = Node.requires
      Node.requires = function(_chunk: Ast.Chunk): {string} return {} end
      return function() Node.requires = held end
    end },
    { reader = "match", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = Rewrite.find_all
      Rewrite.find_all = function(_pattern: Match.Pattern, _chunk: Ast.Chunk): {Match.Hit}
        return {}
      end
      return function() Rewrite.find_all = held end
    end },
    { reader = "globals", file = "std.d.tl", text = DECLARATIONS, plant = function(): function()
      local held = Globals.found
      Globals.found = function(chunk: Ast.Chunk): {Globals.Place}
        local places = held(chunk)
        for _, place in ipairs(places) do
          place.column = place.column + 1
        end
        return places
      end
      return function() Globals.found = held end
    end },
    { reader = "references", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = Lexical.walk
      Lexical.walk = function(chunk: Ast.Chunk, scoped: Scopes.Scoped,
                              member: function(module: string, name: string, line: integer) | nil): {Lexical.Binding}
        if member ~= nil then
          member("cosmic.fs", "planted", 1)
        end
        return held(chunk, scoped, member)
      end
      return function() Lexical.walk = held end
    end },
    { reader = "scopes", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = Lexical.in_scope
      Lexical.in_scope = function(_bindings: {Lexical.Binding}, _y: integer, _x: integer, _heading: boolean):
          {string: string}
        return { planted = "" }
      end
      return function() Lexical.in_scope = held end
    end },
    { reader = "stub", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = Stub.made
      Stub.made = function(chunk: Ast.Chunk): Stub.Made
        local right = held(chunk)
        return { text = right.text:gsub("\n[^\n]*\n$", "\n"), pruned = right.pruned }
      end
      return function() Stub.made = held end
    end },
    { reader = "lines", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = coverage.syntax_executable
      coverage.syntax_executable = function(_source: string, _name: string): {integer: boolean} | nil, string
        return { [1] = true }, ""
      end
      return function() coverage.syntax_executable = held end
    end },
  }
  for _, case in ipairs(plants) do
    local clean = Compared.file(built, case.file, case.text)
    assert(#clean.differences == 0, case.reader .. " differs before it is planted: " .. table.concat(clean.differences, "\n"))
    local undo = case.plant()
    local ok, raised = pcall(function(): string
      local outcome = Compared.file(built, case.file, case.text)
      local named = false
      for _, line in ipairs(outcome.differences) do
        named = named or line:sub(1, #case.reader + 1) == case.reader .. ":"
      end
      assert(named, case.reader .. " reported nothing: " .. table.concat(outcome.differences, "\n"))
      return ""
    end)
    undo()
    assert(ok, raised)
  end
end
