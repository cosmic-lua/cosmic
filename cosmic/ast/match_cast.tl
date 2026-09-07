--- Cast-position matching for `cosmic.ast.match`'s `$X as $T` support:
--- whether a pattern's cast TYPE is a capture, and whether a pattern's
--- `cast` node matches a candidate site's `cast` node. Split out of
--- `match.tl` itself, which had no line budget left for it.
---
--- `$T` in type position desugars to the bare identifier `_T` -- a
--- valid Teal type name -- so the compiled pattern's own `casttype` is
--- a NOMINAL type spelled like a capture, indistinguishable from a
--- real one-word type name (`Foo`) except by that spelling.
--- `capture_name` tells the two apart; `match` binds the WHOLE
--- candidate `cast` node for a capture (so a later `$T:PATTERN`
--- predicate, or a rewrite item, can reach the site's rendered type
--- text) and otherwise compares two casts' rendered type text for
--- equality -- the only type-aware comparison this feature makes.
local node_mod = require("cosmic.ast.node")

local type Node = node_mod.Node

--- Narrow a generic type/node value to a plain string-keyed view -- a
--- cast's own type payload (`casttype`) and its nested type fields
--- (`elements`, `keys`, `values`, `types`, `names`) are tl-parser
--- fields no `Node` record names, since a cast's payload is a parsed
--- TYPE, not an AST node. One cast site, reused by every read below.
--- @param t any A generic type/node value
--- @return {string: any} The same value, viewed as a string-keyed map
local function type_view(t: any): {string: any}
  return t as {string: any} -- cast: tl-parser field this Node kind doesn't name
end

--- `t`'s own array part, viewed generically for indexed reads --
--- `names` (a nominal type's dotted parts) and `types` (a union's
--- members) are plain Lua arrays on a type-view table.
--- @param t any A type-view field expected to be an array
--- @return {any} The same value, viewed as an array
local function type_array(t: any): {any}
  return t as {any} -- cast: array view of a generic type-node field
end

--- Is `t` (a cast's `casttype`) a capture in TYPE position (`$T` in
--- `EXPR as $T`)? See the module doc for why a nominal type named like
--- a capture IS one.
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

--- Render a parsed Teal TYPE back to source-shaped text, for comparing
--- a cast site's actual type against a pattern's literal type text.
--- Handles the shapes `--find` patterns need to write -- primitive
--- names, dotted nominals, arrays, maps, unions -- and falls back to
--- the type's own `typename` for anything else (a function type, a
--- tuple): not a full type-to-string, but honest, and sufficient for
--- rendered-text EQUALITY, the only comparison this feature makes.
--- Building the text from the parsed type's own structure rather than
--- source tokens means `{string: any}` and `{string:any}` are already
--- the same rendering, with no separate whitespace pass.
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

--- Match one pattern `cast` node against one candidate `cast` node --
--- `cosmic.ast.match`'s own `match_value` calls this once it has
--- confirmed both sides carry `kind == "cast"`.
--- @param pv {any: any} The pattern's own `cast` node
--- @param nv {any: any} The candidate `cast` node
--- @param caps {string: Node} Capture bindings accumulated so far
--- @param capture_predicates {any: string} `:PATTERN` predicates, keyed by pattern node identity
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
    local pt = prev as {any: any} -- cast: generic ast node view of a prior binding
    return pt["kind"] == nv["kind"] and pt["tk"] == nv["tk"]
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
