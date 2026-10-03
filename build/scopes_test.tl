local ast = require("build.ast")
local scopes = require("build.scopes")
local teal = require("build.teal")

local built = assert(teal.load())

--- Joins lines the way a real source file would read.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

--- What `in_scope` answers at each of `places`, `line:column`, of
--- `source`, `line:column:doc` for a doc comment's place: its names,
--- sorted, each `name=module` for an alias.
local function scopes_at(source: string, places: {string}): {string}
  local parsed = assert(ast.parse(built, source, "fixture.tl"))
  local bindings = scopes.bindings_of(parsed)
  local out: {string} = {}
  for _, place in ipairs(places) do
    local y, x, doc = place:match("^(%d+):(%d+)(:?d?o?c?)$")
    local names: {string} = {}
    for name, module in pairs(scopes.in_scope(bindings, math.tointeger(tonumber(y)),
        math.tointeger(tonumber(x)), doc == ":doc")) do
      names[#names + 1] = module ~= "" and name .. "=" .. module or name
    end
    table.sort(names)
    out[#out + 1] = place .. " " .. table.concat(names, " ")
  end
  return out
end

--- A local is in scope from past the statement that binds it (a
--- function's or a type's from its name, a parameter or loop variable
--- from itself) to the end of its block, and to a doc comment above
--- that statement; the innermost binding of a name is the one in scope.
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

--- Every statement the parser makes is read: a function among the
--- expressions of one that binds nothing of a scope's (a global's
--- declaration, a call, a `return`) binds its parameters and locals,
--- and a macroexp binds its name and parameters.
local function test_every_statement_kind_is_walked()
  local source = lines({
    "global gfn = function(gp: integer): integer local gl = gp return gl end",
    "local macroexp twice(mp: integer): integer return mp + mp end",
    "print(function(cp: integer) end)",
    "global type G = integer",
    "::top::",
    "do goto top end",
    "while true do break end",
    "return function(rp: integer) end",
  })
  local parsed = assert(ast.parse(built, source, "fixture.tl"))
  local kinds: {string} = {}
  for _, stmt in ipairs(parsed.node) do kinds[#kinds + 1] = stmt.kind end
  local want_kinds = "global_declaration local_macroexp op global_type label do while return"
  assert(table.concat(kinds, " ") == want_kinds, table.concat(kinds, " "))
  local got = scopes_at(source, { "1:60", "2:50", "3:30", "8:30" })
  local want = {
    "1:60 gl gp",
    "2:50 mp twice",
    "3:30 cp twice",
    "8:30 rp twice",
  }
  assert(table.concat(got, "\n") == table.concat(want, "\n"), table.concat(got, "\n"))
end

--- The walk passes by a name, a literal and `...` without looking inside:
--- none of them holds a node, in any spelling tl reads.
local function test_a_leaf_expression_holds_no_node()
  local parsed = assert(ast.parse(built, lines({
    "local function f(...: any): any",
    "  local a, b, c, d, e = 1, 2.5, 0x10, \"s\", [[long]]",
    "  local g, h, i = true, false, nil",
    "  return a, b, c, d, e, g, h, i, ..., 'q', 1e3, -1",
    "end",
    "return f",
  }), "leaves.tl"))
  local seen: {string: boolean} = {}
  ast.walk(parsed.node, function(node: ast.Node)
    local kind = node.kind
    if kind == "variable" or kind == "string" or kind == "number" or kind == "integer" or
        kind == "boolean" or kind == "nil" or kind == "..." then
      seen[kind] = true
      assert(#ast.children(node) == 0, kind .. " holds a node")
    end
  end)
  for _, kind in ipairs({ "variable", "string", "number", "integer", "boolean", "nil", "..." }) do
    assert(seen[kind], "no " .. kind .. " was read")
  end
end
