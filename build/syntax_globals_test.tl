--- Tests of [`build.syntax_globals`]: where a source declares a global.
local Globals = require("build.syntax_globals")
local Node = require("build.syntax_node")
local Test = require("cosmic.test")

Test.policy{}

--- The places `source`, a declaration file, declares globals at, as `line:column`.
local function found(source: string, name: string): string
  local chunk, why = Node.parse(source, name)
  local out: mut {string} = {}
  for _, place in ipairs(Globals.found((assert(chunk, why)))) do
    out[#out + 1] = place.line .. ":" .. place.column
  end
  return table.concat(out, " ")
end

local function test_every_form_of_global_declaration_is_found_where_its_keyword_stands()
  local source = table.concat({
    "global print: any",
    "global record Box",
    "  n: integer",
    "end",
    "  global enum Level",
    "    \"warn\"",
    "  end",
    "global type Name = string",
    "global Lib: any = require(\"lib\")",
    "",
  }, "\n")
  assert(found(source, "std.d.tl") == "1:1 2:1 5:3 8:1 9:1", found(source, "std.d.tl"))
end

local function test_a_source_without_a_global_declares_none()
  assert(found("local x = 1\nlocal function f() return x end\nreturn f\n", "m.tl") == "")
  assert(found("local record R\n  n: integer\nend\nreturn R\n", "m.tl") == "")
end

local function test_a_program_may_not_declare_a_global_so_a_source_that_declares_one_does_not_parse()
  local chunk, why = Node.parse("global x = 1\n", "m.tl")
  assert(chunk == nil and why:find("global_in_program", 1, true) ~= nil, why)
  local bare, trouble = Node.parse("function f() end\n", "m.tl")
  assert(bare == nil and trouble:find("bare_function", 1, true) ~= nil, trouble)
end

local function test_a_local_declaration_beside_a_global_one_is_no_global()
  local source = "local record Helper\n  n: integer\nend\nglobal record Box\n  h: Helper\nend\nlocal type Alias = Box\n"
  assert(found(source, "std.d.tl") == "4:1", found(source, "std.d.tl"))
end
