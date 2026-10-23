--- What a stub ([`build.stub`]) keeps and leaves out of a source, and
--- that a project's checker types the standard library the same from
--- stubs as from sources.

local Store = require("cosmic.store")
-- Required for its closure: the worker's database then holds the sources
-- the parity test reads with [`Store.source`].
local _ = require("cosmic.web")
local ast = require("build.ast")
local stub = require("build.stub")
local teal = require("build.teal")
local type compiler = require("build.compiler")

-- Stripped: the checks below run the compiler over the whole web
-- closure, and under a test's line hook a function with line
-- information costs most of what it runs ([`teal.load`]).
local built = assert(teal.load(true))

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local function stub_of(text: string): string
  return stub.made((assert(ast.parse(built, text, "m.tl")))).text
end

--- The lines of `text`, each without its trailing spaces.
local function lines(text: string): {string}
  local out: {string} = {}
  for line in text:gmatch("([^\n]*)\n") do
    out[#out + 1] = (line:gsub("%s+$", ""))
  end
  return out
end

--- A checker environment that answers each module `modules` names with
--- its text, and nothing else.
local function environment(modules: {string:string}): compiler.Env
  built.search_module = function(name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    local text = modules[name]
    if text == nil then
      return nil
    end
    return (name:gsub("%.", "/")) .. ".tl", teal.served(text)
  end
  local env = assert(built.new_env({ defaults = teal.defaults() }))
  teal.strip(env)
  return env
end

--- A module that returns anything but a name its own top-level type
--- declaration declares (here a parenthesized one) keeps every statement.
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
    -- The one-line function keeps its `end` at the column it had.
    if i == 12 then
      assert(stubbed[i]:match("^M%.g = function%(s: string%): string +end$") ~= nil and
          stubbed[i]:find("end", 1, true) == #"M.g = function(s: string): string return s .. 'x' " + 1,
        "line 12: " .. stubbed[i])
    else
      assert(stubbed[i] == line, "line " .. i .. ": " .. stubbed[i])
    end
  end
end

--- A module that returns a record it declares keeps what the record's
--- type names, and leaves out what only bodies read: a require, a local,
--- a helper, an assignment.
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

--- A returned name declared again as a value after its record is that
--- value, whose type an assignment may infer, so its module keeps every
--- statement.
local function test_a_record_name_declared_again_as_a_value_keeps_every_statement()
  local stubbed = stub_of(source(
    "local record M end",
    "local M = {}",
    "M.x = 1",
    "return M"))
  assert(stubbed:find("M.x = 1", 1, true), stubbed)
end

local function test_a_never_function_s_stub_body_raises()
  local stubbed = stub_of(source(
    "local record M end",
    "local function stop(): never error('stop') end",
    "function M.die(why: string): never",
    "  error(why)",
    "end",
    "function M.quit(): never error('x') end",
    "function M.halt(): never stop() end",
    "return M"))
  assert(stubbed:find("function M.die(why: string): never\n  error()\nend", 1, true), stubbed)
  assert(stubbed:find("function M.quit(): never error()    end", 1, true), stubbed)
  -- A body with no room for `error()` on its line is kept.
  assert(stubbed:find("function M.halt(): never stop() end", 1, true), stubbed)
  local env = environment({})
  local checked = built.check_string(stubbed, env, "m.tl", "tl")
  assert(#checked.type_errors == 0, checked.type_errors[1] and checked.type_errors[1].msg)
end

local function test_a_function_inside_a_top_level_value_loses_its_body()
  local stubbed = stub_of(source(
    "local handlers: {string:function(integer): integer} = {",
    "  double = function(n: integer): integer",
    "    return n * 2",
    "  end,",
    "}",
    "return handlers"))
  assert(stubbed:find("n * 2", 1, true) == nil, stubbed)
  assert(stubbed:find("double = function(n: integer): integer\n\n  end,", 1, true), stubbed)
end

local function test_the_difference_names_where_two_types_part()
  local env = environment({
    a = source("local record A", "  n: integer", "  f: function(string): {string}", "end", "return A"),
    b = source("local record A", "  n: integer", "  f: function(string): {integer}", "end", "return A"),
  })
  local a = built.check_string('return require("a")', env, "x.tl", "tl")
  local again = built.check_string(source("local record A", "  n: integer",
    "  f: function(string): {string}", "end", "return A"), env, "y.tl", "tl")
  local b = built.check_string('return require("b")', env, "z.tl", "tl")
  assert(stub.difference(a.type, again.type) == nil, "the same type declared twice")
  local found = stub.difference(a.type, b.type)
  local said = assert(found, "two types that differ")
  assert(said:find("f", 1, true), said)
  assert(said:find("elements", 1, true), said)
end

--- What the checker says of `program` when each standard-library module
--- is answered by `text_of` its name.
local function said(program: string, text_of: function(string): string | nil): {string}
  built.search_module = function(name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    local text = name:sub(1, 7) == "cosmic." and text_of(name) or nil
    if text == nil then
      return nil
    end
    return (name:gsub("%.", "/")) .. ".tl", teal.served(text)
  end
  local env = assert(built.new_env({ defaults = teal.defaults() }))
  teal.strip(env)
  local checked = built.check_string(program, env, "app.tl", "tl")
  local out: {string} = {}
  for _, e in ipairs(checked.type_errors) do
    out[#out + 1] = tostring(e.filename) .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg
  end
  return out
end

local function test_a_project_misusing_the_web_types_is_told_the_same_from_stubs()
  local program = source(
    'local Web = require("cosmic.web")',
    "local app = Web.app{",
    "  routes = {",
    '    Web.get("/", function(req: Web.Request): Web.Response',
    "      local n: integer = req.path",
    "      return Web.text(n)",
    "    end),",
    "  },",
    "}",
    "local r: Web.Response = Web.json({}, { status = 'ok' })",
    "app:nope()",
    "return app")
  local from_sources = said(program, function(name: string): string | nil
    local text, _ = Store.source(name)
    return text
  end)
  local from_stubs = said(program, function(name: string): string | nil
    -- A declaration's stub is the declaration less its comments, as
    -- its source is all the checker reads of it either way.
    local text, _ = Store.source(name)
    if text == nil then
      return nil
    end
    return stub.made((assert(ast.parse(built, text, name)))).text
  end)
  assert(#from_sources >= 3, table.concat(from_sources, "\n"))
  assert(table.concat(from_stubs, "\n") == table.concat(from_sources, "\n"),
    "from sources:\n" .. table.concat(from_sources, "\n") .. "\nfrom stubs:\n" ..
      table.concat(from_stubs, "\n"))
end

--- A function literal with no return list takes its return types from
--- its context, which its body is checked against, so it keeps its body:
--- left out, the stub would be refused for a missing return.
local function test_a_literal_typed_by_its_context_keeps_its_body()
  local text = source(
    "local record M",
    "  f: function(integer): integer",
    "  stop: function(string): never",
    "  g: function(integer): integer",
    "end",
    "M.f = function(n) return n end",
    "M.stop = function(why) error(why) end",
    "M.g = function(n: integer): integer return n end",
    -- Not a name, so its assignments are kept (see the first test).
    "return (M)")
  local stubbed = stub_of(text)
  -- A literal with a return list loses its body as any function does.
  assert(stubbed:find("M.f = function(n) return n end", 1, true), stubbed)
  assert(stubbed:find("M.stop = function(why) error(why) end", 1, true), stubbed)
  assert(stubbed:find("M%.g = function%(n: integer%): integer +end"), stubbed)
  local checked = built.check_string(stubbed, environment({}), "m.tl", "tl")
  assert(#checked.type_errors == 0, checked.type_errors[1] and checked.type_errors[1].msg)
end

local function test_a_stub_is_declaration_only_where_the_module_returns_its_type()
  local function prunes(text: string): boolean
    return stub.made((assert(ast.parse(built, text, "m.tl")))).pruned
  end
  assert(prunes(source("local record M end", "return M")))
  assert(prunes(source("local type M = string", "return M")))
  assert(prunes(source("local function main(): integer return 0 end", "return main")))
  assert(prunes(source("local record R end", "local m: R = {}", "return m")))
  assert(not prunes(source("local m = {}", "return m")), "a local of an inferred type")
  assert(not prunes(source("local record R end", "local m, n: R, R = {}, {}", "return m")),
    "a local declared beside another")
  assert(not prunes(source("local record M end", "return (M)")), "a parenthesized name")
  assert(not prunes(source("local record M end", "local M = {}", "return M")),
    "a name declared last as a value")
  assert(not prunes(source("return {}")), "a table")
end

--- A module returning a local of a written type keeps the declaration and
--- what it names, and types the same as its source.
local function test_a_stub_of_a_module_returning_a_typed_local_types_it_the_same()
  local text = source(
    'local Json = require("cosmic.json")',
    "local record M",
    "  f: function(integer): integer",
    "end",
    "local function f(n: integer): integer return Json.encode(n) and n or 0 end",
    "local m: M = { f = f }",
    "return m")
  local stubbed = stub_of(text)
  assert(stubbed:find("cosmic.json", 1, true) == nil, stubbed)
  assert(stubbed:find("local m: M = { f = f }", 1, true), stubbed)
  local from_source = built.check_string(text, environment({ ["cosmic.json"] =
      assert(Store.source("cosmic.json")) }), "m.tl", "tl")
  local from_stub = built.check_string(stubbed, environment({}), "m.tl", "tl")
  assert(#from_stub.type_errors == 0, from_stub.type_errors[1] and from_stub.type_errors[1].msg)
  assert(stub.difference(from_source.type, from_stub.type) == nil)
end

--- A checker run where this test runs -- a sealed worker's database
--- among them ([`build.test`]) -- reads a standard-library module this
--- module requires from its stub, as a project's checker does.
local function test_a_standard_module_this_test_requires_is_served_from_its_stub()
  local served = teal.standard_text("cosmic.web")
  assert(served ~= nil and served.stubbed, "cosmic.web was served from its source")
end

local function test_a_stub_of_every_statement_drops_bodies_alone()
  local text = source('local Json = require("cosmic.json")', "local record M end",
    "local unused = Json.encode({})", "function M.f(): integer return 1 end", "return M")
  local parsed = assert(ast.parse(built, text, "m.tl"))
  local pruned = stub.made(parsed)
  assert(pruned.pruned and pruned.text:find("unused", 1, true) == nil, pruned.text)
  local every = stub.made(parsed, true)
  assert(not every.pruned, "every statement is kept")
  assert(every.text:find("local unused = Json.encode({})", 1, true), every.text)
  assert(every.text:find("return 1", 1, true) == nil, "a body is left out: " .. every.text)
end

--- What tl reads of `text` that no position says: each token, and whether
--- it starts a line of its own, as the parser tells a `(` that is a call
--- from one that starts a statement.
local function reading_of(text: string): {string}
  local parsed = assert(ast.parse(built, text, "m.tl"))
  local out: {string} = {}
  local last_y = 0
  for _, token in ipairs(parsed.tokens) do
    if token.y > last_y then
      out[#out + 1] = "\n"
    end
    out[#out + 1] = token.tk
    local _, breaks = token.tk:gsub("\n", "")
    last_y = token.y + breaks
  end
  return out
end

--- A record with an enum of `value`, which a stub keeps and a project's
--- checker reads the type of.
local function with_enum(value: string): string
  return source("local record M", "  enum E", "    " .. value, "  end", "  n: integer", "end", "return M")
end

local function test_a_canonical_stub_does_not_hold_where_its_tokens_stand()
  local text = with_enum('"a  b"')
  local shifted = source("-- noted", "", "local record M", "", "  enum E", "    -- a comment", "",
    '    "a  b"', "  end", "  n: integer", "", "", "end", "return M")
  assert(stub_of(text) ~= stub_of(shifted), "the stubs do not stand where each other's do")
  assert(stub.canonical(stub_of(text)) == stub.canonical(stub_of(shifted)),
    stub.canonical(stub_of(text)) .. "\n---\n" .. stub.canonical(stub_of(shifted)))
  local indented = text:gsub("\n  ", "\n        ")
  assert(stub.canonical(stub_of(text)) == stub.canonical(stub_of(indented)))
end

local function test_a_canonical_stub_keeps_what_tl_reads_of_it()
  local canonical = stub.canonical(stub_of(with_enum('"a  b"')))
  assert(canonical:find('"a  b"', 1, true), canonical)
  -- Each is a different type or a different parse.
  for name, other in pairs({
      ["a token"] = with_enum('"a  c"'):gsub("integer", "number"),
      ["a value"] = with_enum('"a  c"'),
      ["a space in a string"] = with_enum('"a b"'),
  }) do
    assert(stub.canonical(stub_of(other)) ~= canonical, name)
  end
  local function long(value: string): string
    return stub.canonical(stub_of(source("local s = " .. value, "return s")))
  end
  assert(long("[[a\nb]]") ~= long("[[a  b]]"))
  assert(long("[==[a]]  b]==]"):find("a]]  b", 1, true))
  assert(stub.canonical(stub_of(with_enum("'it\\'s  here'"))):find("it\\'s  here", 1, true))
  -- A `(` on a line of its own is not a call of what is before it.
  local call = stub.canonical(stub_of(source("local function g(): integer return 1 end", "local x = g", "(print)(1)", "return x")))
  local same_line = stub.canonical(stub_of(source("local function g(): integer return 1 end", "local x = g (print)(1)", "return x")))
  assert(call ~= same_line, "the line break before a ( is kept")
  -- An unfinished string is answered as it is.
  assert(stub.canonical("local s = 'a\n  b") == "local s = 'a\n  b")
end

--- Every token of a stub, and every line break between two of them, is as
--- tl read it of the stub the canonical text came from.
local function test_a_canonical_stub_is_read_as_its_stub_is()
  local names: {string} = { "cosmic.json", "cosmic.zip", "cosmic.fs", "cosmic.path", "cosmic.web" }
  local checked = 0
  for _, name in ipairs(names) do
    local text = Store.source(name)
    if text ~= nil then
      local stubbed = stub_of(text)
      local stood = reading_of(stubbed)
      local canonical = reading_of(stub.canonical(stubbed))
      assert(#stood == #canonical, name .. ": " .. #stood .. " tokens, " .. #canonical .. " canonical")
      for i, token in ipairs(stood) do
        assert(token == canonical[i], name .. ": token " .. i .. " is " .. token .. ", " .. canonical[i])
      end
      checked = checked + 1
    end
  end
  assert(checked > 0, "no module of the standard library was read")
end
