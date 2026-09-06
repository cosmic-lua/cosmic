--- Structural pattern matching over real Teal ASTs, ast-grep-style:
--- `$NAME`/`$$$NAME` metavariables in pattern source, matched against
--- `cosmic.ast.node.Node` trees produced by real parses.
---
--- The pattern is parsed with the SAME parser as the target, so it is
--- a real (partial) Teal AST rather than a regex. Matching is a fully
--- generic recursive structural walk: every named field the PATTERN
--- specifies must match (subset matching -- a partial pattern like
--- `if $C then ... end` need not spell out every elseif/else block),
--- so a statement/block pattern falls out of the same recursion that
--- handles a call's arguments, with no per-kind special-casing.
---
--- Ported from the `spike/teal-search-replace` branch's
--- `docs/design/ast-rewrite/tlgrep.tl`, minus that spike's span/splice
--- logic (the walk item's job) and its CLI/file-traversal driver (the
--- CLI item's job) -- this module is the matcher alone.
local node_mod = require("cosmic.ast.node")

local type Node = node_mod.Node

--- Array view of a generic AST-map value -- reused everywhere this
--- module needs a node's own array part (call args, `if_blocks`, a
--- block's statement list) as a plain Lua array, the same "AST as
--- `{any: any}`" shape `_tool/coverage/lines.tl`'s walk already needs,
--- for the same reason: a node's real shape depends on its `kind`,
--- which no declared record can express without one arm per kind.
--- @param t {any: any} A generic node/map view
--- @return {any} The same table, viewed as an array
local function arr(t: {any: any}): {any}
  return t as {any} -- cast: array view of a generic ast map
end

--- Positional/bookkeeping fields no pattern should ever compare
--- generically: source position (differs between pattern and target
--- by construction), a node's attached comments (not part of
--- structural identity), and `tk` -- which IS semantic on a
--- "variable"/"identifier"/"string" leaf (compared explicitly for
--- those kinds below) but is otherwise just whichever token happened
--- to open a compound node ("statements", "if_block") and differs
--- incidentally between pattern and target even on a genuine match:
--- an `if $C then $$$BODY() end` pattern matched nothing until `tk`
--- was added here.
local IGNORE_KEYS: {string: boolean} = {
  y = true, x = true, yend = true, xend = true, f = true, comments = true,
  tk = true,
}

--- Is `tk` a capture-name spelling: leading underscore, then
--- uppercase? (`$NAME` in surface syntax, rewritten before lexing --
--- see `desugar`.)
--- @param tk any A node's `tk` field
--- @return boolean
local function is_capture(tk: any): boolean
  return tk is string and tk:match("^_[A-Z][A-Z0-9_]*$") ~= nil
end

--- Is `tk` a rest-capture spelling: three leading underscores, then
--- uppercase -- matches a run of zero or more trailing list elements.
--- (`$$$NAME` in surface syntax.)
--- @param tk any A node's `tk` field
--- @return boolean
local function is_rest_capture(tk: any): boolean
  return tk is string and tk:match("^___[A-Z][A-Z0-9_]*$") ~= nil
end

--- Rewrite ast-grep-style `$NAME`/`$$$NAME` metavariables into valid
--- Teal identifiers so the pattern lexes as real source (`$` is not a
--- legal Teal identifier character). Safe because pattern text is
--- only ever MATCHED, never spliced back into anything -- the byte
--- positions this substitution shifts have no effect on output.
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return string The same pattern with metavariables rewritten to identifiers
local function desugar(pattern_src: string): string
  local out = pattern_src:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  out = out:gsub("%$([%u_][%w_]*)", "_%1")
  return out
end

--- The rest-capture NAME if `node` is a rest-capture marker, else nil.
--- Two surface shapes, because "a bare capture name" isn't always a
--- legal Teal statement: `$$$NAME` in an expression position (call
--- args, a table's items) desugars to the bare identifier `___NAME`,
--- which parses fine as an expression but NOT as a statement (Lua/Teal
--- has no bare-expression statements). In a statement-LIST position (a
--- block, an if-branch's body) the same `$$$NAME` marker instead needs
--- to look like `___NAME()` -- a zero-arg call, which IS a valid
--- statement -- so a block pattern like `if $C then $$$BODY() end` parses.
--- @param node any A pattern node, possibly a rest-capture marker
--- @return string|nil The capture name, or nil when `node` is not one
local function rest_capture_name(node: any): string | nil
  if not (node is {any: any}) then
    return nil
  end
  if node["kind"] == "variable" and is_rest_capture(node["tk"]) then
    return node["tk"] as string -- cast: narrowed to string by is_rest_capture's own check
  end
  if node["kind"] == "op" then
    local op = node["op"]
    local e1 = node["e1"]
    if op is {any: any} and e1 is {any: any} and op["op"] == "@funcall"
    and e1["kind"] == "variable" and is_rest_capture(e1["tk"])
    and #arr(node["e2"] as {any: any}) == 0 then -- cast: generic view of a call's args node
      return e1["tk"] as string -- cast: narrowed to string by is_rest_capture's own check
    end
  end
  return nil
end

--- The synthetic `Node` bound to a rest-capture: a bare list, in the
--- same "elements only, `kind` tags the shape" style tl's own
--- "expression_list"/"statements" nodes already use, so a captured
--- rest is a real `Node` even though nothing here computes a real
--- span for it -- that is the walk item's job, kept out of this
--- matcher on purpose. Position is borrowed from the pattern's own
--- capture marker, never read by anything in this module's own scope.
--- @param marker any The pattern's rest-capture marker node
--- @param elements {any} The matched trailing elements, in order
--- @return Node A bare-list node wrapping `elements`
local function rest_value(marker: any, elements: {any}): Node
  local mt = marker as {any: any} -- cast: generic ast node view
  local out: {any: any} = {kind = "rest_capture", f = mt["f"], y = mt["y"], x = mt["x"]}
  for i, e in ipairs(elements) do
    out[i] = e
  end
  return out as Node -- cast: synthetic bare-list node for a rest-capture's value
end

local match_value: function(pv: any, nv: any, caps: {string: Node}, seen: {any: boolean}): boolean

--- Match two arrays positionally. If the pattern's LAST element is a
--- rest-capture marker (see `rest_capture_name`), it swallows every
--- remaining candidate element (zero or more) instead of requiring
--- equal length -- reused both for a node's own array part (call
--- args, table items) and for any named array-shaped field
--- (`if_blocks`, a block's statement list), since both are plain Lua
--- arrays once extracted.
--- @param pa {any} The pattern's array
--- @param na {any} The candidate's array
--- @param caps {string: Node} Capture bindings accumulated so far
--- @param seen {any: boolean} Identity-keyed cycle guard
--- @return boolean
local function match_list(pa: {any}, na: {any}, caps: {string: Node},
    seen: {any: boolean}): boolean
  if #pa > 0 then
    local last_raw = pa[#pa]
    local rest_name = rest_capture_name(last_raw)
    if rest_name then
      local prefix_n = #pa - 1
      if #na < prefix_n then
        return false
      end
      for i = 1, prefix_n do
        if not match_value(pa[i], na[i], caps, seen) then
          return false
        end
      end
      local rest_elems: {any} = {}
      for i = prefix_n + 1, #na do
        rest_elems[#rest_elems + 1] = na[i]
      end
      caps[rest_name] = rest_value(last_raw, rest_elems)
      return true
    end
  end
  if #pa ~= #na then
    return false
  end
  for i = 1, #pa do
    if not match_value(pa[i], na[i], caps, seen) then
      return false
    end
  end
  return true
end

--- Match one pattern VALUE against one candidate value -- a node, a
--- named field's value (which might itself be a node, a list of
--- nodes, or a scalar like `op.op`), or an array element. This one
--- function replaces per-kind special-casing: a node is "kind + array
--- part + every other named field the pattern sets", recursively.
--- @param pv any A value from the pattern
--- @param nv any The corresponding value from the candidate
--- @param caps {string: Node} Capture bindings accumulated so far
--- @param seen {any: boolean} Identity-keyed cycle guard, own to this matcher
--- @return boolean
match_value = function(pv: any, nv: any, caps: {string: Node}, seen: {any: boolean}): boolean
  if pv == nil then
    return nv == nil
  end
  if not (pv is {any: any}) then
    return pv == nv -- scalar: string/number/boolean
  end
  -- a capture can appear as either kind: `$X` used as a value
  -- reference (`f($X)`) parses as "variable", but the SAME `$X` used
  -- as a member name (`cosmo.$X(...)`) parses as "identifier" -- tl's
  -- own grammar distinction between "a name that resolves" and "a
  -- name that just labels a field": `cosmo.$F($$$ARGS)` silently
  -- matched nothing until this check was widened to accept either kind.
  if (pv["kind"] == "variable" or pv["kind"] == "identifier") and is_capture(pv["tk"]) then
    if not (nv is {any: any}) then
      return false
    end
    local name = pv["tk"] as string -- cast: narrowed to string by is_capture's own check
    local prev = caps[name]
    if prev then
      -- linear pattern: a repeated $X must bind the same subtree twice
      local pt = prev as {any: any} -- cast: generic ast node view of a prior binding
      return pt["kind"] == nv["kind"] and pt["tk"] == nv["tk"]
    end
    caps[name] = nv as Node -- cast: a matched candidate node is a real Node
    return true
  end
  if not (nv is {any: any}) then
    return false
  end
  -- cycle guard: an if_block's `if_parent` points back at its own
  -- "if" statement, a real cycle tl's AST really carries, so
  -- unguarded field recursion loops forever. Treat a revisit as
  -- trivially matching -- own to this matcher, never shared with the
  -- walk module's own cycle guard.
  if seen[nv] then
    return true
  end
  seen[nv] = true
  local pkind = pv["kind"]
  if pkind and pkind ~= nv["kind"] then
    return false
  end
  if pkind == "variable" or pkind == "identifier" or pkind == "string" then
    return pv["tk"] == nv["tk"]
  end
  if not match_list(arr(pv), arr(nv), caps, seen) then
    return false
  end
  for k, sub_pv in pairs(pv) do
    if not (k is integer) and not IGNORE_KEYS[k as string] then -- cast: non-integer key is a field name
      if not match_value(sub_pv, nv[k], caps, seen) then
        return false
      end
    end
  end
  return true
end

--- Desugar, parse, and unwrap a pattern's source into its own top
--- node. A bare expression parses as a one-statement program whose
--- statement IS the expression -- an expression-statement -- so
--- unwrapping is needed for `program[1]`'s kind to be the pattern's
--- own ("op", "variable", ...) rather than "statements". A statement
--- pattern (`if ... end`) needs no unwrap either way: `program[1]` is
--- already the right node in both cases.
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return Node|nil The pattern's own top node, or nil on a parse failure
--- @return string Error message on failure, nil on success
local function compile_pattern(pattern_src: string): Node | nil, string
  local parsed, err = node_mod.parse(desugar(pattern_src), "<pattern>")
  if not parsed then
    return nil, err
  end
  return parsed.node[1], nil
end

--- Match `pattern` against `node`, returning the capture bindings on
--- success. Subset matching: every named field `pattern` sets must
--- match; a field `pattern` leaves unset is never consulted, so a
--- partial pattern matches without spelling out every field of the
--- kind it names. Capture keys carry the desugared `_` prefix (`$CMD`
--- binds as `_CMD`).
--- @param pattern Node A compiled pattern (see `compile_pattern`)
--- @param node Node A candidate node to test
--- @return {string: Node}|nil Capture bindings by name, or nil when `pattern` does not match `node`
local function match(pattern: Node, node: Node): {string: Node} | nil
  local caps: {string: Node} = {}
  if match_value(pattern, node, caps, {}) then
    return caps
  end
  return nil
end

local record MatchModule
  desugar: function(pattern_src: string): string
  compile_pattern: function(pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
end

local M: MatchModule = {
  desugar = desugar,
  compile_pattern = compile_pattern,
  match = match,
}

return M
