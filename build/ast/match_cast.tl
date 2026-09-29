--- Cast-position matching for `build.ast.match`'s `$X as $T` support.
---
--- `$T` in type position desugars to the identifier `_T`, a valid Teal
--- type name, so the compiled pattern's `casttype` is a nominal type
--- that only its spelling tells from a real one-word type name (`Foo`).
--- `capture_name` tells the two apart. For a capture, `match` binds the
--- whole candidate `cast` node, so a `$T:PATTERN` predicate or a
--- rewrite item can reach the site's rendered type text. Otherwise it
--- compares the two casts' rendered type text for equality, the only
--- type-aware comparison this feature makes.
local node_mod = require("build.ast.node")

local type Node = node_mod.Node

--- Narrow a generic type/node value to a string-keyed view. A cast's
--- `casttype` and its nested type fields (`elements`, `keys`, `values`,
--- `types`, `names`) are tl-parser fields no `Node` record names,
--- since the payload is a parsed type, not an AST node.
--- @param t any A generic type/node value
--- @return {string: any} The same value, viewed as a string-keyed map
local function type_view(t: any): {string: any}
  return t as {string: any} -- cast: tl-parser field this Node kind doesn't name
end

--- `t` viewed as an array: `names` (a nominal type's dotted parts) and
--- `types` (a union's members) are plain Lua arrays on a type view.
--- @param t any A type-view field expected to be an array
--- @return {any} The same value, viewed as an array
local function type_array(t: any): {any}
  return t as {any} -- cast: array view of a generic type-node field
end

--- Is `t` (a cast's `casttype`) a capture in type position (`$T` in
--- `EXPR as $T`)? A nominal type spelled like a capture is one.
--- @param t any A parsed type node (a cast's `casttype`), or nil
--- @return string|nil The capture name (`_T`), or nil when `t` is not one
local function capture_name(t: any): string | nil
  if t == nil then
    return nil
  end
  local tv = type_view(t)
  if tv["typename"] ~= "nominal" then
    return nil
  end
  local names = type_array(tv["names"])
  if #names ~= 1 then
    return nil
  end
  local nm = names[1]
  if nm is string and nm:match("^_[A-Z][A-Z0-9_]*$") ~= nil then
    return nm
  end
  return nil
end

--- Render a parsed Teal type as source-shaped text, to compare a cast
--- site's type with a pattern's literal type text. Handles primitive
--- names, dotted nominals, arrays, maps and unions; any other type
--- (a function, a tuple) renders as its `typename`. That suffices for
--- equality, but it is not a full type-to-string. The text comes from
--- the parsed structure, so `{string: any}` and `{string:any}` render
--- alike.
--- @param t any A parsed type node (a cast's `casttype`), or nil
--- @return string The type's source-shaped text (`""` for nil)
local function render(t: any): string
  if t == nil then
    return ""
  end
  local tv = type_view(t)
  local tn = tv["typename"]
  if tn == "nominal" then
    local names = type_array(tv["names"])
    local parts: {string} = {}
    for _, nm in ipairs(names) do
      parts[#parts + 1] = tostring(nm)
    end
    return table.concat(parts, ".")
  elseif tn == "array" then
    return "{" .. render(tv["elements"]) .. "}"
  elseif tn == "map" then
    return "{" .. render(tv["keys"]) .. ": " .. render(tv["values"]) .. "}"
  elseif tn == "union" then
    local types = type_array(tv["types"])
    local parts: {string} = {}
    for _, one in ipairs(types) do
      parts[#parts + 1] = render(one)
    end
    return table.concat(parts, " | ")
  end
  return tostring(tn)
end

--- Match a pattern `cast` node against a candidate `cast` node.
--- `build.ast.match`'s `match_value` calls this once both sides have
--- `kind == "cast"`.
--- @param pv {any: any} The pattern's own `cast` node
--- @param nv {any: any} The candidate `cast` node
--- @param caps {string: Node} Capture bindings accumulated so far
--- @param capture_predicates {any: string} `:PATTERN` predicates, by pattern node id
--- @return boolean
local function match(pv: {any: any}, nv: {any: any}, caps: {string: Node},
    capture_predicates: {any: string}): boolean
  local cap = capture_name(pv["casttype"])
  if not cap then
    return render(pv["casttype"]) == render(nv["casttype"])
  end
  local pred = capture_predicates[pv]
  if pred and not render(nv["casttype"]):match(pred) then
    return false
  end
  local prev = caps[cap]
  if prev then
    -- linear pattern: a repeated $T must bind the same subtree twice
    return prev.kind == nv["kind"] and prev.tk == nv["tk"]
  end
  caps[cap] = nv as Node -- cast: a matched candidate node is a real Node
  return true
end

local record MatchCastModule
  capture_name: function(t: any): string | nil
  match: function(pv: {any: any}, nv: {any: any}, caps: {string: Node},
  capture_predicates: {any: string}): boolean
end

local M: MatchCastModule = {
  capture_name = capture_name,
  match = match,
}

return M
