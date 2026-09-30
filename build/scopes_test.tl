local ast = require("build.ast")
local scopes = require("build.scopes")
local teal = require("build.teal")

local built = assert(teal.load())

--- Joins lines the way a real source file would read.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

--- What `in_scope` answers at each of `places`, `line:column`, of
--- `source`: its names, sorted, each `name=module` for an alias.
local function scopes_at(source: string, places: {string}): {string}
  local parsed = assert(ast.parse(built, source, "fixture.tl"))
  local bindings = scopes.bindings_of(parsed)
  local out: {string} = {}
  for _, place in ipairs(places) do
    local y, x = place:match("^(%d+):(%d+)$")
    local names: {string} = {}
    for name, module in pairs(scopes.in_scope(bindings, math.tointeger(tonumber(y)),
        math.tointeger(tonumber(x)))) do
      names[#names + 1] = module ~= "" and name .. "=" .. module or name
    end
    table.sort(names)
    out[#out + 1] = place .. " " .. table.concat(names, " ")
  end
  return out
end

--- A name is in scope from the line of the statement that binds it, or
--- from a parameter or loop variable itself, to the end of its block;
--- the innermost binding of a name is the one in scope.
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
  }), { "1:1", "3:1", "3:30", "4:1", "6:5", "8:3", "9:1", "10:1" })
  local want = {
    "1:1 Fs=cosmic.fs",
    "3:1 C=build.compiler Fs=cosmic.fs f",
    "3:30 C=build.compiler Fs f",
    "4:1 C=build.compiler Fs f inner n",
    "6:5 C=build.compiler Fs each f i inner n",
    "8:3 C=build.compiler Fs f inner n",
    "9:1 C=build.compiler Fs f inner n",
    "10:1 C=build.compiler Fs=cosmic.fs after f",
  }
  assert(table.concat(got, "\n") == table.concat(want, "\n"), table.concat(got, "\n"))
end
