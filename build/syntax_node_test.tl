--- Tests of [`build.syntax_node`]: a source read into the new syntax tree, a node's place and bytes, the walk in source
--- order, the parent of each node, and the modules a file requires.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")
local Test = require("cosmic.test")

Test.policy{}

local function parsed(source: string): Ast.Chunk
  local chunk, why = Node.parse(source, "t.tl")
  return (assert(chunk, why))
end

local function test_a_source_with_an_error_is_refused_with_its_first_error_and_its_fix()
  local chunk, why = Node.parse("local x = 1\nif x then\n", "broken.tl")
  assert(chunk == nil and why:find("^broken.tl:%d+:%d+: ") ~= nil, why)
  assert(why:find("(unclosed): ", 1, true) ~= nil, why)
  local declaration, trouble = Node.parse("global record Box\n  n: integer\nend\n", "box.d.tl")
  assert(declaration ~= nil, trouble)
  local program = Node.parse("global record Box\n  n: integer\nend\n", "box.tl")
  assert(program == nil, "a program declares no global")
end

local function test_a_node_reads_its_place_from_its_tokens()
  local chunk = parsed("local x = f(1,\n  2)\n")
  local stat = chunk.body.stats[1]
  assert((stat.kind == "Local"))
  local span = Node.span(chunk, stat)
  assert(span.y == 1 and span.x == 1 and span.yend == 2 and span.xend == 4, span.y .. ":" .. span.x)
  local range = Node.range(chunk, stat)
  local source = "local x = f(1,\n  2)\n"
  assert(source:sub(range.first, range.last) == "local x = f(1,\n  2)", source:sub(range.first, range.last))
end

local function test_walk_visits_each_node_once_in_source_order()
  local chunk = parsed("local a = 1\nif a then\n  print(a)\nend\n")
  local kinds: {string} = {}
  local ids: {integer} = {}
  Node.walk(chunk, function(node: Ast.Node)
    kinds[#kinds + 1] = Node.base(node).kind
    ids[#ids + 1] = Node.base(node).id
  end)
  assert(table.concat(kinds, " ") == "Chunk Block Local Binding Integer If Arm Name Block CallStat Call Name Name",
    table.concat(kinds, " "))
  for i, id in ipairs(ids) do
    assert(id == i, "the ids are the order of the walk")
  end
end

local function test_a_walk_can_leave_a_subtree_alone()
  local chunk = parsed("local f = function() return 1 end\nreturn f\n")
  local seen: {string} = {}
  Node.walk_until(chunk, function(node: Ast.Node): boolean
    seen[#seen + 1] = Node.base(node).kind
    return not ((node.kind == "FunctionLit"))
  end)
  assert(table.concat(seen, " ") == "Chunk Block Local Binding FunctionLit Return Name", table.concat(seen, " "))
end

local function test_a_chain_of_any_length_is_walked()
  local operands: mut {string} = {}
  for i = 1, 30000 do
    operands[i] = "a"
  end
  local chunk = parsed("local a = 1\nreturn " .. table.concat(operands, " + ") .. "\n")
  local seen = { count = 0 }
  Node.walk(chunk, function(_node: Ast.Node)
    seen.count = seen.count + 1
  end)
  assert(seen.count > 60000, tostring(seen.count))
end

local function test_the_parent_of_each_node_is_the_node_that_holds_it()
  local chunk = parsed("local x = f(1)\n")
  local parents = Node.parents(chunk)
  assert(parents[Node.base(chunk).id] == nil)
  local stat = chunk.body.stats[1]
  assert((stat.kind == "Local"))
  local call = stat.values[1]
  assert((call.kind == "Call"))
  assert(parents[Node.base(call).id] == stat and parents[Node.base(call.args[1]).id] == call)
  assert(parents[Node.base(stat).id] == chunk.body)
  assert(#Node.children(call) == 2)
end

local function test_a_name_is_resolved_against_the_globals_given()
  local chunk = parsed("local a = 1\nreturn a + b\n")
  local scoped = Node.scope(chunk, "t.tl", { b = { space = "value", const = true } })
  assert(#scoped.errors == 0 and scoped.globals["b"] ~= nil)
  local bare = Node.scope(chunk, "t.tl")
  assert(bare.errors[1] ~= nil and bare.errors[1].code == "unknown_variable")
end

local function required(source: string): string
  local chunk, why = Node.parse(source, "t.tl")
  return table.concat(Node.requires((assert(chunk, why))), " ")
end

local function test_every_literal_require_is_found_wherever_it_stands_in_source_order()
  local source = table.concat({
    "local A = require(\"a.first\")",
    "local type T = require(\"b.types\")",
    "local store: any = nil",
    "if A then",
    "  store = require(\"c.branch\")",
    "end",
    "local function f()",
    "  return require(\"d.inner\")",
    "end",
    "return A, T, store, f",
    "",
  }, "\n")
  assert(required(source) == "a.first b.types c.branch d.inner", required(source))
end

local function test_a_module_is_listed_once()
  assert(required("local a = require(\"m\")\nlocal b = require(\"m\")\nreturn a, b\n") == "m")
end

local function test_a_require_that_sits_in_text_is_no_dependency()
  local source = table.concat({
    "local text = 'require(\"in.string\")'",
    "-- require(\"in.comment\")",
    "-- pcall(require, \"in.comment\")",
    "return text",
    "",
  }, "\n")
  assert(required(source) == "", required(source))
end

local function test_a_pcall_of_require_with_a_literal_name_is_a_dependency_at_the_string_that_names_it()
  local source = table.concat({
    "local a = require(\"a.first\")",
    "local function probe(): boolean",
    "  local ok, _ = pcall(require, \"b.optional\")",
    "  return ok",
    "end",
    "local again, _ = pcall(require, 'a.first')",
    "return a, probe, again",
    "",
  }, "\n")
  assert(required(source) == "a.first b.optional", required(source))
  assert(required("local a = require((\"p.q\"))\nlocal b = require(((\"p.r\")))\nreturn a, b\n") == "p.q p.r")
  local sites: mut {string} = {}
  for _, site in ipairs(Node.require_sites(parsed(source))) do
    sites[#sites + 1] = ("%s@%d:%d"):format(site.name, site.y, site.x)
  end
  local got = table.concat(sites, " ")
  assert(got == "a.first@1:19 b.optional@3:32", got)
end

--- A source with a computed name and what its refusal says.
local record Refused
  source: string
  says: string
end

--- Each refusal names the require and quotes the expression that computes its name.
local function test_a_require_whose_name_is_computed_is_refused_naming_it_and_what_to_write()
  local cases: {Refused} = {
    { source = "local name = \"x\"\nlocal a = require(name)\n", says = "`require(name)` names its module by an expression" },
    { source = "local a = require(\"p\" .. \"q\")\n", says = "`require(\"p\" .. \"q\")` names its module" },
    { source = "local ok, a = pcall(require, mod)\n", says = "`pcall(require, mod)` names its module" },
    { source = "local ok, a = pcall(require, \"p.\" .. kind)\n", says = "`pcall(require, \"p.\" .. kind)` names its module" },
    { source = "local a = require(f())\n", says = "`require(f())` names its module" },
  }
  for _, case in ipairs(cases) do
    local chunk, why = Node.parse(case.source, "t.tl")
    assert(chunk == nil and why:find(case.says, 1, true) ~= nil and
      why:find("(computed_require): write the module's name as a string", 1, true) ~= nil, case.source .. " -> " .. why)
  end
  local declaration, trouble = Node.parse("local type T = require(\"m\")\nreturn T\n", "t.d.tl")
  assert(declaration ~= nil, trouble)
end

local function test_a_require_site_is_where_the_string_naming_its_module_stands()
  local source = table.concat({
    "local A = require(\"a.first\")",
    "local type T = require( 'b.types' )",
    "local function f()",
    "  return require(\"c.inner\"), require(\"a.first\")",
    "end",
    "return A, T, f",
    "",
  }, "\n")
  local chunk, why = Node.parse(source, "t.tl")
  local found: mut {string} = {}
  for _, site in ipairs(Node.require_sites((assert(chunk, why)))) do
    found[#found + 1] = ("%s@%d:%d"):format(site.name, site.y, site.x)
  end
  local got = table.concat(found, " ")
  assert(got == "a.first@1:19 b.types@2:25 c.inner@4:18", got)
end
