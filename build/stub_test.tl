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

local built = assert(teal.load())

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local function stub_of(text: string): string
  return stub.of((assert(ast.parse(built, text, "m.tl"))))
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
  built.path = ""
  built.search_module = function(name: string, _search_all: boolean): string | nil, any
    local text = modules[name]
    if text == nil then
      return nil
    end
    return (name:gsub("%.", "/")) .. ".tl", {
      read = function(_self: any, _what: string): string return text end,
      close = function(_self: any): boolean return true end,
    }
  end
  local env = assert(built.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  }))
  teal.strip(env)
  return env
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
    "return M")))
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
    "return M",
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
  assert(stubbed:find("function M.die(why: string): never\n  error()\nend", 1, true) ~= nil, stubbed)
  assert(stubbed:find("function M.quit(): never error()    end", 1, true) ~= nil, stubbed)
  -- A body with no room for `error()` on its line is kept.
  assert(stubbed:find("function M.halt(): never stop() end", 1, true) ~= nil, stubbed)
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
  assert(stubbed:find("n * 2", 1, true) == nil and
      stubbed:find("double = function(n: integer): integer\n\n  end,", 1, true) ~= nil, stubbed)
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
  assert(found ~= nil and found:find("f", 1, true) ~= nil and found:find("elements", 1, true) ~= nil,
    tostring(found))
end

--- What the checker says of `program` when each standard-library module
--- is answered by `text_of` its name.
local function said(program: string, text_of: function(string): string | nil): {string}
  built.path = ""
  built.search_module = function(name: string, _search_all: boolean): string | nil, any
    local text = name:sub(1, 7) == "cosmic." and text_of(name) or nil
    if text == nil then
      return nil
    end
    return (name:gsub("%.", "/")) .. ".tl", {
      read = function(_self: any, _what: string): string return text end,
      close = function(_self: any): boolean return true end,
    }
  end
  local env = assert(built.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  }))
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
    local text, _ = Store.source(name)
    if text == nil or name:sub(1, 16) == "cosmic.internal." then
      return text
    end
    return stub.of((assert(ast.parse(built, text, name))))
  end)
  assert(#from_sources >= 3, table.concat(from_sources, "\n"))
  assert(table.concat(from_stubs, "\n") == table.concat(from_sources, "\n"),
    "from sources:\n" .. table.concat(from_sources, "\n") .. "\nfrom stubs:\n" ..
      table.concat(from_stubs, "\n"))
end
