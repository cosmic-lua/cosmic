--- Tests of [`build.syntax_scopes`]: where each binding is in scope, as the readers of the analyzer's references and a
--- comment's names ask it, and each member read through an alias that still names its module.
local Node = require("build.syntax_node")
local Lexical = require("build.syntax_scopes")
local Test = require("cosmic.test")

Test.policy{}

--- Joins lines the way a real source file would read.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

local function bindings_of(source: string): {Lexical.Binding}
  local chunk = assert(Node.parse(source, "fixture.tl"))
  return Lexical.bindings_of(chunk, Node.scope(chunk, "fixture.tl"))
end

--- What `in_scope` answers at each of `places`, `line:column`, of `source`, `line:column:doc` for a doc comment's place:
--- its names, sorted, each `name=module` for an alias.
local function scopes_at(source: string, places: {string}): {string}
  local bindings = bindings_of(source)
  local out: mut {string} = {}
  for _, place in ipairs(places) do
    local y, x, doc = place:match("^(%d+):(%d+)(:?d?o?c?)$")
    local names: mut {string} = {}
    for name, module in pairs(Lexical.in_scope(bindings, math.tointeger(tonumber(y)), math.tointeger(tonumber(x)),
        doc == ":doc")) do
      names[#names + 1] = if module ~= "" then name .. "=" .. module else name end
    end
    table.sort(names)
    out[#out + 1] = place .. " " .. table.concat(names, " ")
  end
  return out
end

--- The members `walk` is handed for `source`, sorted.
local function members(source: string): string
  local chunk = assert(Node.parse(source, "fixture.tl"))
  local read: mut {string} = {}
  Lexical.walk(chunk, Node.scope(chunk, "fixture.tl"), function(module: string, name: string, line: integer)
    read[#read + 1] = module .. "." .. name .. ":" .. line
  end)
  table.sort(read)
  return table.concat(read, " ")
end

local function test_names_are_in_scope_from_their_binding_to_their_blocks_end()
  local got = scopes_at(lines({
    "local Fs = require(\"cosmic.fs\")",
    "local type C = require(\"build.compiler\")",
    "local function f(Fs: integer, n: integer): integer",
    "  local inner = n",
    "  for i = 1, n do",
    "    local each = i",
    "  end",
    "  return inner + Fs",
    "end",
    "local after = 1",
  }), { "1:1", "3:1", "3:1:doc", "3:30", "4:3", "4:3:doc", "6:5", "8:3", "9:1", "10:1" })
  local want = {
    "1:1 ",
    "3:1 C=build.compiler Fs=cosmic.fs",
    "3:1:doc C=build.compiler Fs=cosmic.fs f",
    "3:30 C=build.compiler Fs f",
    "4:3 C=build.compiler Fs f n",
    "4:3:doc C=build.compiler Fs f inner n",
    "6:5 C=build.compiler Fs f i inner n",
    "8:3 C=build.compiler Fs f inner n",
    "9:1 C=build.compiler Fs f inner n",
    "10:1 C=build.compiler Fs=cosmic.fs f",
  }
  assert(table.concat(got, "\n") == table.concat(want, "\n"), table.concat(got, "\n"))
end

local function test_every_statement_kind_binds_what_it_declares()
  local source = lines({
    "local record R",
    "  n: integer",
    "end",
    "local function top(tp: integer): integer local tl = tp return tl end",
    "print(function(cp: integer) end)",
    "do local d = 1 end",
    "while true do local w = 1 break end",
    "repeat local u = 1 until u",
    "match top(1) do",
    "  | (true, m) then print(m)",
    "  | (false, e) then print(e)",
    "end",
    "return function(rp: integer) end",
  })
  local names: mut {string} = {}
  for _, each in ipairs(bindings_of(source)) do
    names[#names + 1] = each.name
  end
  table.sort(names)
  local got = table.concat(names, " ")
  assert(got:find("R cp d e m rp tl top tp u w", 1, true) ~= nil, got)
end

local function test_a_type_nested_in_a_record_and_a_type_parameter_bind_nothing_of_a_block()
  local names: mut {string} = {}
  for _, each in ipairs(bindings_of(lines({
      "local record Outer",
      "  record Inner",
      "    n: integer",
      "  end",
      "  inner: Inner",
      "end",
      "local function id<T>(x: T): T return x end",
  }))) do
    names[#names + 1] = each.name
  end
  table.sort(names)
  assert(table.concat(names, " ") == "Outer id x", table.concat(names, " "))
end

local function test_a_loops_variable_is_in_scope_from_its_own_name()
  local got = scopes_at(lines({
    "for _, k in ipairs({",
    "    1, 2 }) do",
    "  print(k)",
    "end",
  }), { "2:5", "3:3" })
  assert(got[1] == "2:5 _ k" and got[2] == "3:3 _ k", table.concat(got, "|"))
end

local function test_the_bindings_say_which_are_the_chunks_which_are_aliases_and_which_are_annotated()
  local found: mut {string: Lexical.Binding} = {}
  for _, each in ipairs(bindings_of(lines({
      "local Fs = require(\"cosmic.fs\")",
      "local B: Fs.Stat = require(\"cosmic.b\")",
      "local function f()",
      "  local Fs = 1",
      "  return Fs",
      "end",
  }))) do
    found[each.name .. (if each.top then "" else "!" end)] = each
  end
  assert(found["Fs"].module == "cosmic.fs" and found["Fs"].top and not found["Fs"].annotated)
  assert(found["B"].module == "cosmic.b" and found["B"].annotated)
  assert(found["Fs!"].module == "" and not found["Fs!"].top)
  assert(found["f"].head == Lexical.position(3, 0) and found["Fs!"].head == Lexical.position(4, 0))
end

local function test_a_member_is_read_through_an_alias_and_through_a_require()
  local got = members(lines({
    "local fs = require(\"m\")",
    "local a = (fs.read)",
    "local b = { fs.write, k = fs.stat }",
    "print(#(fs.list), -(fs.size), not fs.ok, (function(p: integer): integer return p end)(1))",
    "print(require(\"n\").deep)",
    "return fs:method()",
  }))
  assert(got == "m.list:4 m.ok:4 m.read:2 m.size:4 m.stat:3 m.write:3 n.deep:5", got)
end

local function test_a_parameter_that_shadows_the_alias_is_no_reference()
  assert(members(lines({
    "local fs = require(\"m\")",
    "local function f(fs: integer): integer return fs.x end",
    "local g = fs.y",
  })) == "m.y:3")
  assert(members(lines({
    "local require = function(name: string): string return name end",
    "print(require(\"n\").deep)",
  })) == "")
end

local function test_an_assignment_to_the_alias_ends_the_reads_that_count_from_the_end_of_its_statement()
  assert(members(lines({
    "local fs = require(\"m\")",
    "local a = fs.before",
    "fs = other",
    "local b = fs.after",
  })) == "m.before:2")
  assert(members(lines({
    "local fs = require(\"m\")",
    "fs = fs.same_statement",
    "local function f() return fs.later end",
  })) == "m.same_statement:2")
end

local function test_a_field_an_assignment_writes_is_no_reference()
  assert(members(lines({
    "local fs = require(\"m\")",
    "fs.stderr = 1",
    "fs.deep.stderr = fs.other",
    "local read = fs.stdout",
  })) == "m.other:3 m.stdout:4")
end
