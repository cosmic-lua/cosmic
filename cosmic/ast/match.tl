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
---
--- A capture may also carry a Lua pattern predicate on its own name:
--- `$F:^test_` binds like `$F` but only against a candidate whose own
--- `tk` matches `^test_`. The predicate cannot survive inside the
--- identifier tl actually parses (`_F:^test_` would lex as a method
--- call), so `desugar` strips it before parsing and records it in
--- `last_predicates`, keyed by the desugared name; `compile_pattern`
--- reads that table right after parsing and re-attaches each predicate
--- to the SPECIFIC capture node it belongs to, in `capture_predicates`
--- (keyed by node identity, since two occurrences of the same name
--- could each carry a different predicate, or none). Both tables are
--- module-level rather than fields on `Node` -- `Node` is a closed
--- record `compile_pattern`'s two-slot fallible return cannot widen to
--- carry a third value, per the naming charter's fallible-returns rule.
---
--- A capture may also appear in a cast's TYPE position (`$X as $T`,
--- `$X as $T:^{`) -- `cosmic.ast.match_cast` holds that half (its own
--- casttype rendering and matching), since this file had no line
--- budget left for it; `capture_predicates` is keyed by `any` rather
--- than by `Node` alone so the SAME table also serves a `cast` node's
--- identity, with no separate store or cast to widen it.
local node_mod = require("cosmic.ast.node")
local ast_walk = require("cosmic.ast.walk")
local match_cast = require("cosmic.ast.match_cast")
local ast_equal = require("cosmic.ast.equal")

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
  tk = true, typeid = true, if_parent = true,
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

--- Name -> Lua pattern predicate, populated as a side effect of the
--- MOST RECENT `desugar` call whose surface syntax carried a
--- `$NAME:PATTERN` predicate metavariable, keyed by the desugared name
--- (`_F`). `compile_pattern` reads it immediately after calling
--- `desugar` (the two always run back-to-back there) and consumes it
--- into `capture_predicates` before returning -- a LATER `desugar` call
--- on unrelated text (e.g. `rewrite.tl` desugaring a replacement
--- template) overwrites it harmlessly, since compile_pattern has
--- already read what it needed by then.
local last_predicates: {string: string} = {}

--- Predicate lookup for one capture node inside a compiled pattern's
--- OWN tree, keyed by the specific node's identity rather than by name
--- -- two occurrences of the same capture name in one pattern could
--- each carry a different predicate (or none). Populated once, by
--- `compile_pattern`; consulted by `match_value` for every capture it
--- binds. Keyed by `any`, not `Node`, because a cast-position capture
--- (see `cosmic.ast.match_cast`) is keyed by its `cast` node while
--- still narrowed to `{any: any}`, not `Node`, at the point it is
--- looked up.
local capture_predicates: {any: string} = {}

--- Rewrite ast-grep-style `$NAME`/`$$$NAME` metavariables into valid
--- Teal identifiers so the pattern lexes as real source (`$` is not a
--- legal Teal identifier character). Safe because pattern text is
--- only ever MATCHED, never spliced back into anything -- the byte
--- positions this substitution shifts have no effect on output.
---
--- A plain capture may carry a `:PATTERN` predicate suffix (`$F:^test_`)
--- -- stripped here (it cannot survive lexing) and recorded in
--- `last_predicates` under the desugared name, terminated at the next
--- whitespace, `(`, `)`, or `,` so a predicate like `^test_` in
--- `$F:^test_()` does not swallow the call's own parentheses.
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return string The same pattern with metavariables rewritten to identifiers
local function desugar(pattern_src: string): string
  last_predicates = {}
  local out = pattern_src:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  out = out:gsub("%$([%u_][%w_]*):([^%s%(%),]+)", function(nm: string, pred: string): string
      last_predicates["_" .. nm] = pred
      return "_" .. nm
    end)
  out = out:gsub("%$([%u_][%w_]*)", "_%1")
  return out
end

--- Attach every entry of `names` (desugared capture name -> predicate)
--- onto its own capture node(s) inside `root`'s tree, into
--- `capture_predicates`. A no-op walk when `names` is empty -- the
--- common case, since most patterns carry no predicate at all.
--- @param root Node A freshly compiled pattern's own top node
--- @param names {string: string} `last_predicates`, snapshotted right after parsing
--- @return Node `root`, unchanged -- returned for a one-line call site
local function attach_predicates(root: Node, names: {string: string}): Node
  if next(names) == nil then
    return root
  end
  ast_walk.walk(root, function(n: Node)
      local tk = n.tk
      if (n.kind == "variable" or n.kind == "identifier") and tk is string then
        local pred = names[tk]
        if pred then
          capture_predicates[n] = pred
        end
      elseif n.kind == "cast" then
        local cap = match_cast.capture_name((n as {any: any})["casttype"]) -- cast: tl-parser field this Node kind doesn't name
        if cap then
          local pred = names[cap]
          if pred then
            capture_predicates[n] = pred
          end
        end
      end
    end)
  return root
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

local match_value: function(pv: any, nv: any, caps: {string: Node},
seen: {any: {any: boolean}}, predicates: {any: string}): boolean

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
    seen: {any: {any: boolean}}, predicates: {any: string}): boolean
  if #pa > 0 then
    local last_raw = pa[#pa]
    local rest_name = rest_capture_name(last_raw)
    if rest_name then
      local prefix_n = #pa - 1
      if #na < prefix_n then
        return false
      end
      for i = 1, prefix_n do
        if not match_value(pa[i], na[i], caps, seen, predicates) then
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
    if not match_value(pa[i], na[i], caps, seen, predicates) then
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
match_value = function(pv: any, nv: any, caps: {string: Node},
    seen: {any: {any: boolean}}, predicates: {any: string}): boolean
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
    local pnode = pv as Node -- cast: capture leaf is a node from the compiled pattern's own tree
    local pred = predicates[pnode]
    local nv_tk = nv["tk"]
    if pred and not (nv_tk is string and nv_tk:match(pred) ~= nil) then
      return false
    end
    local name = pv["tk"] as string -- cast: narrowed to string by is_capture's own check
    local prev = caps[name]
    if prev then
      -- Linear pattern: a repeated $X must bind the same full subtree,
      -- including nested operands and fields, rather than just its shape.
      return ast_equal.equal(prev, nv)
    end
    caps[name] = nv as Node -- cast: a matched candidate node is a real Node
    return true
  end
  if not (nv is {any: any}) then
    return false
  end
  -- Pairwise cycle guard: a candidate can be reached through several
  -- fields, and a candidate-only guard would let a later, mismatching
  -- pattern subtree pass without being checked.
  local prior = seen[pv]
  if prior and prior[nv] then
    return true
  end
  if not prior then
    prior = {}
    seen[pv] = prior
  end
  prior[nv] = true
  local pkind = pv["kind"]
  if pkind and pkind ~= nv["kind"] then
    return false
  end
  if pkind == "variable" or pkind == "identifier" or pkind == "string" then
    return pv["tk"] == nv["tk"]
  end
  if pkind == "cast" then
    return match_cast.match(pv, nv, caps, predicates)
  end
  if not match_list(arr(pv), arr(nv), caps, seen, predicates) then
    return false
  end
  for k, sub_pv in pairs(pv) do
    if not (k is integer) and not IGNORE_KEYS[k as string] then -- cast: non-integer key is a field name
      if not match_value(sub_pv, nv[k], caps, seen, predicates) then
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
---
--- A cast (`$X as $T`) or any other non-call expression is neither: it
--- is not a valid Teal STATEMENT on its own, exactly as in real Teal
--- (`x as integer` alone is a syntax error; only `return x as integer`
--- parses, same as only a function call may stand alone as a
--- statement). On a direct parse failure this retries wrapped in a
--- `return`, then unwraps to the RETURNED expression instead of the
--- wrapping `return` statement -- so a call/statement pattern's own
--- top node is unaffected, and this path only ever runs once the
--- direct parse already failed.
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return Node|nil The pattern's own top node, or nil on a parse failure
--- @return string Error message on failure, nil on success
local function compile_pattern(pattern_src: string): Node | nil, string
  local desugared = desugar(pattern_src)
  local parsed, err = node_mod.parse(desugared, "<pattern>")
  if parsed then
    return attach_predicates(parsed.node[1], last_predicates), nil
  end
  local wrapped = node_mod.parse("return " .. desugared, "<pattern>")
  if not wrapped then
    return nil, err
  end
  local exps = wrapped.node[1].exps
  if not exps or exps[1] == nil then
    return nil, err
  end
  return attach_predicates(exps[1], last_predicates), nil
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
local function match_with_predicates(pattern: Node, node: Node,
    predicates: {any: string}): {string: Node} | nil
  local caps: {string: Node} = {}
  if match_value(pattern, node, caps, {}, predicates) then
    return caps
  end
  return nil
end

--- Match with the legacy module-owned predicate table. New callers should
--- prefer `cosmic.ast.pattern`, which owns its metadata per compiled value.
local function match(pattern: Node, node: Node): {string: Node} | nil
  return match_with_predicates(pattern, node, capture_predicates)
end

--- Snapshot predicates attached to one compiled pattern. The returned map
--- belongs to the caller and is safe to retain after another pattern is
--- compiled.
--- @param root Node A compiled pattern root
--- @return {any: string} Predicate metadata keyed by pattern node identity
local function predicates_for(root: Node): {any: string}
  local out: {any: string} = {}
  ast_walk.walk(root, function(n: Node)
      local predicate = capture_predicates[n]
      if predicate then
        out[n] = predicate
      end
    end)
  return out
end

local record MatchModule
  desugar: function(pattern_src: string): string
  compile_pattern: function(pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
  match_with_predicates: function(pattern: Node, node: Node,
  predicates: {any: string}): {string: Node} | nil
  predicates_for: function(root: Node): {any: string}
end

local M: MatchModule = {
  desugar = desugar,
  compile_pattern = compile_pattern,
  match = match,
  match_with_predicates = match_with_predicates,
  predicates_for = predicates_for,
}

return M
