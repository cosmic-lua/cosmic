--- Tests of [`build.syntax_analyzer`] and [`build.syntax_link_text`]: what each reads of a source, and what the new grammar
--- changes of the analysis the fork made once, which is what these tests say.
local Analyzer = require("build.syntax_analyzer")
local Test = require("cosmic.test")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

Test.policy{}

--- Joins lines the way a real source file would read.
local function lines(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The analysis of `source`, a file named `name`.
local function analyzed(source: string, name?: string): Analyzer.Analysis
  local found, why = Analyzer.analyze(source, name or "fixture.tl")
  return (assert(found, why))
end

--- One source both analyzers read, and the dimension its test is about, which must hold rows.
local record Fixture
  name: string
  dimension: string
  source: string
end

local FIXTURES: {Fixture} = {
  { name = "tests are the top-level local functions named test_", dimension = "analyzer tests", source = lines(
    "local function test_one() end",
    "local function helper() end",
    "local function test_two()",
    "  local function test_nested() end",
    "end") },
  { name = "a return of a name, a table and a call", dimension = "analyzer export", source = lines(
    "local M = {}",
    "return M") },
  { name = "a catalog holds literal failures and not those of an inner function", dimension = "analyzer catalog",
    source = lines(
      "local function refuse(why: string): nil, string return nil, why end",
      "--- Opens.",
      "local function open(path: string): boolean, string",
      "  if path == \"\" then",
      "    return nil, \"the path is empty\"",
      "  end",
      "  local function inner(): nil, string",
      "    return nil, \"an inner failure\"",
      "  end",
      "  if path == \"x\" then return false, \"that name is taken: \" .. path end",
      "  if path == \"y\" then return nil, \"no\" end",
      "  return refuse(\"it was refused here\")",
      "end",
      "return open") },
  { name = "a record, its fields and an enum", dimension = "analyzer docs", source = lines(
    "--- A module.",
    "",
    "--- A shape.",
    "local record Shape",
    "  --- The width.",
    "  width: integer",
    "  height: integer -- trailing note",
    "  --- How it is drawn.",
    "  enum Style",
    "    --- Plain.",
    "    \"plain\"",
    "    \"fancy\"",
    "  end",
    "  record Corner",
    "    x: integer",
    "  end",
    "  area: function(self: Shape,",
    "    scale: integer): integer",
    "end",
    "",
    "--- Draws.",
    "function Shape.draw(self: Shape, style: Shape.Style): boolean",
    "  return true",
    "end",
    "",
    "local type Alias = {string: integer}",
    "--- A value.",
    "local LIMIT <const> = 3",
    "return Shape") },
  { name = "a module returns a variable typed as a record", dimension = "analyzer docs", source = lines(
    "local record Thing",
    "  n: integer",
    "end",
    "local record Hidden",
    "  m: integer",
    "end",
    "--- Makes one.",
    "local function make(h: Hidden): Thing return {} end",
    "local api: Thing = { n = 1 }",
    "function api.make(h: Hidden): Thing return make(h) end",
    "return api") },
  { name = "a function the record's field is implemented by", dimension = "analyzer docs", source = lines(
    "local record Api",
    "  --- The declared field.",
    "  make: function(): integer",
    "end",
    "--- The implementation.",
    "function Api.make(): integer",
    "  return 1",
    "end",
    "return Api") },
  { name = "a record only the returned variable's type names", dimension = "analyzer docs", source = lines(
    "local record Thing",
    "  --- The count.",
    "  n: integer",
    "end",
    "local api: Thing = { n = 1 }",
    "return api") },
  { name = "a long string message starts with its line break", dimension = "analyzer catalog", source = lines(
    "local function open(path: string): nil, string",
    "  return nil, [[",
    "the path is empty]]",
    "end",
    "return open") },
  { name = "a table return gives its members their names", dimension = "analyzer docs", source = lines(
    "--- Adds.",
    "local function add(a: integer, b: integer): integer return a + b end",
    "local function sub(a: integer, b: integer): integer return a - b end",
    "return { plus = add, [\"minus\"] = sub }") },
  { name = "references follow the alias in scope and stop at its reassignment", dimension = "analyzer references",
    source = lines(
      "local Fs = require(\"cosmic.fs\")",
      "local function a()",
      "  local Fs = require(\"cosmic.json\")",
      "  return Fs.encode",
      "end",
      "local first = Fs.read",
      "Fs.write = nil",
      "for i = 1, 2 do local Fs = i end",
      "return require(\"cosmic.string\").trim") },
  { name = "a name bound once to a module is bound", dimension = "analyzer bound", source = lines(
    "local Fs = require(\"cosmic.fs\")",
    "local type Json = require(\"cosmic.json\")",
    "local Twice = require(\"cosmic.a\")",
    "Twice = require(\"cosmic.b\")",
    "local Two = require(\"cosmic.c\")",
    "local Two = require(\"cosmic.d\")",
    "local Typed: any = require(\"cosmic.e\")",
    "return Fs") },
  { name = "an example carries what it uses and no more", dimension = "analyzer examples", source = lines(
    "local Fs = require(\"cosmic.fs\")",
    "local Json = require(\"cosmic.json\")",
    "local Test = require(\"cosmic.test\")",
    "",
    "Test.policy{}",
    "",
    "local function inner(): integer",
    "  return 1",
    "end",
    "",
    "--- Helps the example.",
    "local function helper(): integer",
    "  return inner() + 1",
    "end",
    "",
    "local record Pair",
    "  a: integer",
    "end",
    "",
    "--- Reads.",
    "function Example.read()",
    "  local p: Pair = { a = helper() }",
    "  assert(Fs.read(\"x\") == nil and p.a == 2)",
    "end",
    "",
    "-- a note on what follows",
    "function Example.shadowed(helper: integer)",
    "  local Fs = 1",
    "  assert(helper == Fs)",
    "end") },
  { name = "a policy is read as data", dimension = "analyzer inputs", source = lines(
    "local Test = require(\"cosmic.test\")",
    "",
    "Test.policy{",
    "  grants = { { path = \"testdata\", letters = \"r\" }, { path = \"/cache/zig\", letters = \"rwxc\" } },",
    "  loopback = { \"127.0.0.1\" }, env = { \"HOME\" }, profiles = { \"system\" }, requires = { \"proc\" },",
    "  [\"promises\"] = { \"nest\" },",
    "}",
    "local function test_it() end") },
  { name = "links in comments resolve against what the file declares and requires", dimension = "link_text",
    source = lines(
      "local Fs = require(\"cosmic.fs\")",
      "--- A shape: see [`Shape.width`], [`Fs.read`], [`helper`] and [the guide](doc/a.md).",
      "local record Shape",
      "  width: integer",
      "end",
      "",
      "-- [`helper`] is not in scope above its declaration, [`Shape.draw`] is declared below.",
      "local function helper()",
      "  local Fs = 1",
      "  -- [`Fs.read`] is shadowed here.",
      "end",
      "function Shape.draw() end",
      "return Shape") },
}

local function test_a_fixture_is_analyzed_with_the_rows_it_exists_for()
  for _, case in ipairs(FIXTURES) do
    local found, why = Analyzer.analyze(case.source, "fixture.tl")
    assert(found ~= nil, case.name .. ": " .. tostring(why))
  end
end

--- A line ends at `\r`, `\r\n` and `\n\r` as at `\n`: a text of three lines with no `\n` in it is analyzed, and what
--- it exports is documented from the comment on the line above it.
local function test_a_line_ends_at_each_of_the_lexers_line_breaks()
  for _, ending in ipairs({ "\r", "\r\n", "\n\r", "\n" }) do
    local source = table.concat({ "local x = 1", "--- Counts.", "local record counter", "end", "return counter", "" }, ending)
    local found, why = Analyzer.analyze(source, "counter.tl")
    assert(found ~= nil, ("%q: %s"):format(ending, tostring(why)))
    assert(#found.docs > 0, ("%q: no docs"):format(ending))
  end
end

local function test_a_policy_the_build_cannot_read_is_refused()
  local cases: {{string}} = {
    { "a policy twice", lines('local Test = require("cosmic.test")', "Test.policy{}", "Test.policy{}") },
    { "an unknown field", lines('local Test = require("cosmic.test")', "Test.policy{ nothing = true }") },
    { "a policy in a function", lines('local Test = require("cosmic.test")', "local function f() Test.policy{} end") },
    { "a policy that is a value", lines('local Test = require("cosmic.test")', "local p = {}", "Test.policy(p)") },
    { "a path that climbs", lines('local Test = require("cosmic.test")',
      'Test.policy{ grants = { { path = "../x", letters = "r" } } }') },
    { "an escape in a path", lines('local Test = require("cosmic.test")',
      'Test.policy{ grants = { { path = "a\\tb", letters = "r" } } }') },
    { "a loopback that is not", lines('local Test = require("cosmic.test")', 'Test.policy{ loopback = { "10.0.0.1" } }') },
  }
  for _, case in ipairs(cases) do
    local _, why = Analyzer.analyze(nth(case, 2), "fixture_test.tl")
    assert(why:find("fixture_test.tl:", 1, true) == 1 and why:find(": test.policy: ", 1, true) ~= nil, nth(case, 1) .. ": " .. why)
  end
end

--- A deliberate difference: a source cannot jump, so a policy is never refused for a jump past its call.
local function test_a_goto_is_a_parse_error_and_no_refusal_of_the_policy()
  local source = lines('local Test = require("cosmic.test")', "Test.policy{}", "goto done", "::done::")
  local found, why = Analyzer.analyze(source, "fixture_test.tl")
  assert(found == nil and why:find("goto", 1, true) ~= nil, tostring(why))
end

--- A deliberate difference: a method is a member of its class, with `self`, and its doc comment is the one above it.
local function test_a_classs_methods_are_documented_as_the_methods_the_fork_documented()
  local found = analyzed(lines(
    "--- A stream.",
    "local class Stream",
    "  __close: function(self: Stream)",
    "  --- The count.",
    "  n: integer",
    "",
    "  --- Reads.",
    "  function read(self, max: integer?): string?, string",
    "    return nil, \"nothing to read\"",
    "  end",
    "end",
    "",
    "return Stream"))
  local by: mut {string: Analyzer.DocEntry} = {}
  for _, entry in ipairs(found.docs) do
    by[entry.source_symbol] = entry
  end
  local stream = assert(by["Stream"], "a class is documented")
  assert(stream.kind == "record" and stream.exported, "a class is documented as a record")
  local count = assert(by["Stream.n"], "a field is documented")
  assert(count.kind == "field" and count.text == "The count.")
  local close = assert(by["Stream.__close"], "a metamethod is documented")
  assert(close.kind == "metamethod" and close.signature == "__close: function(self: Stream)")
  local read = by["Stream:read"]
  assert(read ~= nil and read.kind == "method" and read.symbol == "read" and read.exported and read.text == "Reads.")
  assert(read.signature == "function read(self, max: integer?): string?, string", read.signature)
  -- The metamethods follow the fields, and the methods come last, as the docs list them.
  local order: mut {string} = {}
  for _, entry in ipairs(found.docs) do
    order[#order + 1] = entry.source_symbol
  end
  assert(table.concat(order, " ") == " Stream Stream.n Stream.__close Stream:read", table.concat(order, " "))
  assert(#found.catalog == 1 and found.catalog[1].symbol == "Stream:read" and found.catalog[1].message == "nothing to read")
end

--- A message is read as the source means it: an escape is decoded, and a long string's first line break is not its text.
local function test_a_catalog_message_is_read_as_the_source_means_it()
  local found = analyzed(lines(
    "local function f(): nil, string",
    "  return nil, \"say \\\"stop\\\" here\"",
    "end",
    "local function g(): nil, string",
    "  return nil, [[a long message]]",
    "end",
    "local function h(): nil, string",
    "  return nil, [[",
    "the first line break is the string's own]]",
    "end"))
  assert(#found.catalog == 3, tostring(#found.catalog))
  assert(nth(found.catalog, 1).message == 'say "stop" here', nth(found.catalog, 1).message)
  assert(nth(found.catalog, 2).message == "a long message", nth(found.catalog, 2).message)
  -- The line break that opens a long string is the string's own, not part of its value.
  assert(nth(found.catalog, 3).message == "the first line break is the string's own", nth(found.catalog, 3).message)
end

--- The translation writes a metatable's `__close` as a method of the class, which is a metamethod row as the field is.
local function test_a_method_named_for_a_metamethod_is_a_metamethod_row()
  local found = analyzed(lines(
    "local class Conn",
    "  mut fd: integer",
    "",
    "  function close(self)",
    "  end",
    "",
    "  function __close(self)",
    "    self.fd = 0",
    "  end",
    "end",
    "return Conn"))
  local kinds: mut {string} = {}
  for _, entry in ipairs(found.docs) do
    kinds[#kinds + 1] = entry.kind .. ":" .. entry.symbol
  end
  assert(table.concat(kinds, " ") == "record:Conn field:fd metamethod:__close method:close", table.concat(kinds, " "))
end

local function test_the_values_of_an_enum_are_listed_in_order_and_each_carries_its_doc()
  local found = analyzed(lines(
    "local enum Mode",
    "  --- Second in the source.",
    "  \"b\"",
    "  --- First in the alphabet.",
    "  \"a\"",
    "end"))
  local values: mut {string} = {}
  for _, entry in ipairs(found.docs) do
    values[#values + 1] = entry.symbol .. "=" .. entry.text
  end
  assert(table.concat(values, "|") == "Mode=|Mode.b=Second in the source.|Mode.a=First in the alphabet.",
    table.concat(values, "|"))
end

--- The doc comment is the run above the declaration that is not the end of a line of code.
local function test_a_comment_after_code_is_no_doc_comment_of_what_follows()
  local found = analyzed(lines(
    "local x = 1 --- not a doc",
    "local function f() end",
    "local y = 2",
    "--- A doc.",
    "-- A note beside it.",
    "local function g() end"))
  assert(nth(found.docs, 1).symbol == "f" and nth(found.docs, 1).text == "", nth(found.docs, 1).text)
  assert(nth(found.docs, 2).symbol == "g" and nth(found.docs, 2).text == "A doc.", nth(found.docs, 2).text)
end

--- The head of a function is read to the token before its body, a comment in it left out.
local function test_a_signature_is_the_head_on_one_line()
  local found = analyzed(lines(
    "local record R",
    "end",
    "function R.f(",
    "  a: integer, -- the first",
    "  b: integer",
    "): integer -- a result",
    "  -- the body",
    "  return a + b",
    "end",
    "local function g() end"))
  assert(nth(found.docs, 2).signature == "function R.f(a: integer, b: integer): integer", nth(found.docs, 2).signature)
  assert(nth(found.docs, 3).signature == "local function g()", nth(found.docs, 3).signature)
end

--- The comment that opens a file is the module's, unless it ends right above a function, which it documents.
local function test_the_opening_comment_documents_the_module_or_the_function_below_it()
  local function symbols(source: string): string
    local found = analyzed(source)
    local out: mut {string} = {}
    for _, entry in ipairs(found.docs) do
      out[#out + 1] = entry.kind .. ":" .. entry.symbol .. "=" .. entry.text
    end
    return table.concat(out, "|")
  end
  assert(symbols(lines("--- Opens.", "local function open() end")) == "function:open=Opens.")
  assert(symbols(lines("--- A module.", "", "local function open() end")) == "module:=A module.|function:open=")
  -- Above a value the comment is the module's alone, never that value's.
  assert(symbols(lines("--- A module.", "local LIMIT <const> = 3", "return LIMIT")) == "module:=A module.")
  assert(symbols(lines("local a = 1", "--- A value.", "local LIMIT <const> = 3", "return LIMIT")) == "value:LIMIT=A value.")
end

--- A `TODO:` note is the maintainers', never documentation: a module whose opening run of `--` lines is one has no doc.
local function test_a_todo_comment_is_no_module_documentation()
  local function module_text(source: string): string?
    for _, entry in ipairs(analyzed(source).docs) do
      if entry.kind == "module" then
        return entry.text
      end
    end
    return nil
  end
  assert(module_text(lines("-- TODO: make this greet in Klingon too", "", "local x = 1", "return x")) == nil)
  assert(module_text(lines("-- TODO: make this greet", "-- in Klingon too", "", "local x = 1", "return x")) == nil)
  assert(module_text(lines("-- Greets.", "--", "-- TODO: Klingon,", "-- too.", "local x = 1", "return x")) == "Greets.\n")
  assert(module_text(lines("-- Doc.", "--", "-- TODO: later", "--", "-- More doc.", "local x = 1", "return x")) == "Doc.\n\nMore doc.")
  assert(module_text(lines("--- Doc.", "--- TODO: later", "local x = 1", "return x")) == "Doc.")
end

--- The line that declares a table of C bindings is for the build: no doc text shows it, with LF or CR LF line ends, and
--- a line that only holds it among other words stays.
local function test_the_binding_line_is_no_documentation()
  local function module_text(source: string): string?
    for _, entry in ipairs(analyzed(source).docs) do
      if entry.kind == "module" then return entry.text end
    end
    return nil
  end
  assert(module_text(lines("--- A table.", "--- @kind binding", "local x = 1", "return x")) == "A table.")
  assert(module_text("--- A table.\r\n--- @kind binding\r\nlocal x = 1\r\nreturn x\r\n") == "A table.")
  assert((module_text(lines("--- @kind binding", "local x = 1", "return x")) or "") == "")
  assert(module_text(lines("--- A table, @kind binding in prose.", "local x = 1", "return x")) ==
      "A table, @kind binding in prose.")
end
