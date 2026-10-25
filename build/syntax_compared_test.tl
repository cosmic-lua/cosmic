--- Tests of [`build.syntax_compared`]: a file the fork's readers and their ports read alike is told so, a file one of
--- them cannot read is left out, and a reader that answers otherwise is named.
local Analyzer = require("build.syntax_analyzer")
local Ast = require("lang.ast")
local Compared = require("build.syntax_compared")
local Globals = require("build.syntax_globals")
local LinkText = require("build.link_text")
local Lexical = require("build.syntax_scopes")
local Match = require("build.syntax_match")
local PluralSites = require("build.plural_sites")
local Node = require("build.syntax_node")
local Rewrite = require("build.syntax_rewrite")
local Scopes = require("lang.scopes")
local Stub = require("build.syntax_stub")
local SyntaxLinkText = require("build.syntax_link_text")
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

--- A file with a row for every dimension of the analysis: a policy, a test, a catalog message, a doc comment with a
--- link, a reference through an alias, a name bound to a module and an example.
local ANALYSIS_FILE <const> = source(
  'local Test = require("cosmic.test")',
  'local Fs = require("cosmic.fs")',
  'Test.policy{ env = { "HOME" } }',
  "",
  "--- Opens a thing: see [`open`] and [`Fs.read`].",
  "local function open(path: string): nil, string",
  '  return nil, "the path is empty"',
  "end",
  "",
  "--- Joins what it is given.",
  "local function join(a: integer, b: string | nil, list: {integer}): string | nil",
  "  return b",
  "end",
  "",
  "local function test_it()",
  '  assert(Fs.read("x") == nil)',
  "end",
  "",
  "function Example.open()",
  '  assert(Fs.read("x") == nil)',
  "end",
  "",
  "local function describe(rows: {string}): string",
  '  return #rows .. " tests"',
  "end",
  "return open")

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

local function test_every_dimension_of_the_analysis_compares_rows_of_a_file()
  local outcome = Compared.file(built, "a_test.tl", ANALYSIS_FILE)
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
  for _, dimension in ipairs(Compared.dimensions) do
    assert((outcome.counts[dimension] or 0) > 0, dimension .. " compared no row")
  end
end

--- A record with the field a class has no use for, a method and a metamethod: the fork documents the field and the
--- method (and the metamethod), the port the one method (and the metamethod).
local CLASS_FILE <const> = source(
  'local Fs = require("cosmic.fs")',
  "--- A stream: see [`Stream.read`].",
  "local record Stream",
  "  n: integer",
  "  --- Reads.",
  "  read: function(self: Stream, max: integer): string",
  "  --- Ends it.",
  "  close: function(self: Stream)",
  "  metamethod __close: function(Stream)",
  "end",
  "local mt: metatable<Stream> = {",
  "  __index = Stream,",
  "  __close = function(self: Stream)",
  "    self:close()",
  "  end,",
  "}",
  "function Stream:read(max: integer): string",
  '  return Fs.read("x")',
  "end",
  "--- Closes it.",
  "function Stream:close()",
  "end",
  "return Stream")

local function test_a_file_whose_methods_move_into_a_class_has_its_analysis_compared_without_lines()
  local outcome = Compared.file(built, "class.tl", CLASS_FILE)
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
  assert((outcome.counts["analyzer docs"] or 0) >= 5, tostring(outcome.counts["analyzer docs"]))
  assert((outcome.counts["link_text"] or 0) >= 1)
end

--- A metatable's `__close` becomes a method of the class the translation makes, which the fork's reader does not see
--- in a table: the port's row for it is left out of the comparison, and one the record declares is compared.
local function test_a_metamethod_the_translation_makes_of_a_metatable_is_left_out_of_the_comparison()
  local outcome = Compared.file(built, "made.tl", source(
    "local record Conn",
    "  n: integer",
    "  close: function(self: Conn)",
    "end",
    "local mt: metatable<Conn> = {",
    "  __index = Conn,",
    "  __close = function(self: Conn)",
    "    self:close()",
    "  end,",
    "}",
    "function Conn:close()",
    "end",
    "return Conn"))
  assert(outcome.skipped == "" and #outcome.differences == 0, outcome.skipped .. table.concat(outcome.differences, "\n"))
  assert((outcome.counts["analyzer docs"] or 0) >= 3, tostring(outcome.counts["analyzer docs"]))
end

local function test_a_file_the_fork_or_the_translation_cannot_read_is_left_out()
  local fork = Compared.file(built, "bad.tl", "if x then\n")
  assert(fork.skipped:find("the fork does not parse it", 1, true) ~= nil, fork.skipped)
  local tuple = Compared.file(built, "tuple.tl", source("local a: {{string, integer}}", "return a"))
  assert(tuple.skipped:find("its translation does not parse", 1, true) ~= nil, tuple.skipped)
end

local function test_a_reader_that_answers_otherwise_is_named()
  local made = stub.made
  stub.made = function(parsed: ast.Parsed, every?: boolean): stub.Made
    local right = made(parsed, every)
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

--- The docs of `found` with the signature of the entry `symbol` changed by `change`.
local function with_signature(found: Analyzer.Analysis, symbol: string, change: function(signature: string): string)
  for index, entry in ipairs(found.docs) do
    if entry.symbol == symbol then
      assert(change(entry.signature) ~= entry.signature, "the plant changes " .. entry.signature)
      found.docs[index] = { symbol = entry.symbol, source_symbol = entry.source_symbol, exported = entry.exported,
        kind = entry.kind, signature = change(entry.signature), text = entry.text, line = entry.line }
    end
  end
end

--- A plant in the analysis the port answers: `change` is run on what it answers, which the comparison then finds
--- differs from the fork's.
local function analysis_plant(change: function(found: Analyzer.Analysis)): function(): function()
  return function(): function()
    local held = Analyzer.analysis_of
    Analyzer.analysis_of = function(chunk: Ast.Chunk, scoped: Scopes.Scoped, text: string, name: string):
        Analyzer.Analysis?, string
      local found, why = held(chunk, scoped, text, name)
      if found ~= nil then
        change(found)
      end
      return found, why
    end
    return function() Analyzer.analysis_of = held end
  end
end

--- A plant in the sites the port finds: `change` is given the first site the port finds and answers the sites it finds
--- instead, which the comparison then finds differ from the fork's.
local function plurals_plant(change: function(first: {string}): {{string}}): function(): function()
  return function(): function()
    local held = PluralSites.of_chunk
    PluralSites.of_chunk = function(chunk: Ast.Chunk): {{string}}
      return change(assert(held(chunk)[1]))
    end
    return function() PluralSites.of_chunk = held end
  end
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
                              member: (function(module: string, name: string, line: integer))?): {Lexical.Binding}
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
      Stub.made = function(chunk: Ast.Chunk, every?: boolean): Stub.Made
        local right = held(chunk, every)
        return { text = right.text:gsub("\n[^\n]*\n$", "\n"), pruned = right.pruned }
      end
      return function() Stub.made = held end
    end },
    { reader = "analyzer tests", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.tests[#found.tests + 1] = "test_planted" end) },
    { reader = "analyzer export", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.export = "Planted" end) },
    { reader = "analyzer inputs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.inputs = nil end) },
    { reader = "analyzer catalog", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.catalog[1].message = "planted" end) },
    { reader = "analyzer docs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.docs[1].text = "planted" end) },
    { reader = "analyzer references", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.references[1].line = 99 end) },
    { reader = "analyzer bound", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis) found.bound[1].module = "planted" end) },
    { reader = "analyzer examples", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        found.examples[1].source = found.examples[1].source .. "\nplanted()"
      end) },
    { reader = "analyzer docs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        with_signature(found, "join", function(signature: string): string
          return (signature:gsub("%(a: integer, b: string%?", "(b: string?, a: integer"))
        end)
      end) },
    { reader = "analyzer docs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        with_signature(found, "join", function(signature: string): string
          return (signature:gsub("%?", ""))
        end)
      end) },
    { reader = "analyzer docs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        with_signature(found, "join", function(signature: string): string
          return (signature:gsub(":", ","))
        end)
      end) },
    { reader = "analyzer docs", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        with_signature(found, "join", function(signature: string): string
          return (signature:gsub("[{}]", ""))
        end)
      end) },
    { reader = "analyzer examples", file = "a_test.tl", text = ANALYSIS_FILE, plant = analysis_plant(
      function(found: Analyzer.Analysis)
        local lines: mut {string} = {}
        for line in found.examples[1].source:gmatch("[^\n]+") do
          table.insert(lines, 1, line)
        end
        local example = found.examples[1]
        found.examples[1] = { name = example.name, text = example.text, source = table.concat(lines, "\n"),
          line = example.line }
      end) },
    { reader = "link_text", file = "a_test.tl", text = ANALYSIS_FILE, plant = function(): function()
      local held = SyntaxLinkText.found
      SyntaxLinkText.found = function(_chunk: Ast.Chunk, _scoped: Scopes.Scoped, _text: string): {LinkText.Found}
        return {}
      end
      return function() SyntaxLinkText.found = held end
    end },
    { reader = "plurals", file = "a_test.tl", text = ANALYSIS_FILE, plant = plurals_plant(
      function(_first: {string}): {{string}} return {} end) },
    { reader = "plurals", file = "a_test.tl", text = ANALYSIS_FILE, plant = plurals_plant(
      function(first: {string}): {{string}}
        return { { assert(first[1]), "planted", assert(first[3]), assert(first[4]) } }
      end) },
    { reader = "plurals", file = "a_test.tl", text = ANALYSIS_FILE, plant = plurals_plant(
      function(first: {string}): {{string}}
        return { { "9" .. assert(first[1]), assert(first[2]), assert(first[3]), assert(first[4]) } }
      end) },
    { reader = "lines", file = "m.tl", text = TREE_FILE, plant = function(): function()
      local held = coverage.syntax_executable
      coverage.syntax_executable = function(_source: string, _name: string): {integer: boolean}?, string
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
