--- The `global` declarations a source holds, read off its syntax tree
--- where it is parsed ([`build.derivation`]), so a build refuses them
--- ([`build.compilation`]'s `refuse_globals`) from rows kept by the
--- source's hash rather than reading every source again.

local ast = require("build.ast")
local scopes = require("build.scopes")
local type compiler = require("build.compiler")

local record globals
  --- Where a declaration starts.
  record Place
    line: integer
    column: integer
  end
end

--- Whether `tokens` hold a word that can start a global declaration:
--- `global`, or `function NAME(` with no `local` before it, which tl
--- reads as a global function where no local of that name is in scope.
--- A source without one has none to find, and its tree is not walked.
local function has_candidate(tokens: {compiler.Token}): boolean
  for i, t in ipairs(tokens) do
    if t.tk == "global" then
      return true
    end
    if t.tk == "function" then
      local name, after, before = tokens[i + 1], tokens[i + 2], tokens[i - 1]
      if name ~= nil and name.kind == "identifier" and after ~= nil and
          (after.tk == "(" or after.tk == "<") and not (before ~= nil and before.tk == "local") then
        return true
      end
    end
  end
  return false
end

--- Where the declaration `n` of a global starts: its `global` keyword,
--- which tl's tree puts the node at only for some kinds, the name's own
--- position for others. A `function f` with no keyword starts at the node.
local function start_of(tokens: {compiler.Token}, n: ast.Node): integer, integer
  if n.implicit_global_function then
    return n.y, n.x
  end
  for i, t in ipairs(tokens) do
    if t.y == n.y and t.x == n.x then
      -- `global`, `global type T`, `global function f`: the keyword is
      -- at most two tokens before the name.
      for back = i, math.max(1, i - 2), -1 do
        if tokens[back].tk == "global" then
          return tokens[back].y, tokens[back].x
        end
      end
      break
    end
  end
  return n.y, n.x
end

--- Where each global `parsed` declares starts, in source order: `global
--- x`, `global function`, `global record` and the other `global` forms,
--- and a `function f()` with no local `f` in scope there (with one, it
--- assigns to it, and is no declaration).
function globals.found(parsed: ast.Parsed): {globals.Place}
  local found: {globals.Place} = {}
  if not has_candidate(parsed.tokens) then
    return found
  end
  local bindings: {scopes.Binding} = {}
  local walked = false
  ast.walk(parsed.node, function(n: ast.Node)
    -- `global x: T = v` also holds a "global_declaration" the parser made
    -- of the same text, which has no position of its own.
    if n.kind:sub(1, 7) ~= "global_" or n.y == nil then
      return
    end
    if n.implicit_global_function then
      if not walked then
        bindings, walked = scopes.bindings_of(parsed), true
      end
      local name = n.name ~= nil and n.name.tk or nil
      if name ~= nil and scopes.in_scope(bindings, n.y, n.x, false)[name] ~= nil then
        return
      end
    end
    local y, x = start_of(parsed.tokens, n)
    found[#found + 1] = { line = y, column = x }
  end)
  table.sort(found, function(a: globals.Place, b: globals.Place): boolean
    return a.line < b.line or (a.line == b.line and a.column < b.column)
  end)
  return found
end

return globals
