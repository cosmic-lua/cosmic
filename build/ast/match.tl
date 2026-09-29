--- Structural pattern matching over real Teal ASTs, ast-grep-style:
--- `$NAME`/`$$$NAME` metavariables in pattern source, matched against
--- `build.ast.node.Node` trees produced by real parses.
---
--- The pattern is parsed with the same parser as the target, so it is
--- a real (partial) Teal AST rather than a regex. Matching is a generic
--- recursive walk: every named field the pattern sets must match, and
--- a field it leaves unset is not consulted. A partial pattern like
--- `if $C then ... end` need not spell out every elseif or else block,
--- and a statement pattern needs no case of its own beyond the
--- recursion that handles a call's arguments.
---
--- A capture may carry a Lua pattern predicate on its own name:
--- `$F:^test_` binds like `$F` but only against a candidate whose own
--- `tk` matches `^test_`. The predicate cannot stay inside the
--- identifier tl parses (`_F:^test_` would lex as a method call), so
--- `desugar` strips it before parsing and records it in
--- `last_predicates`, keyed by the desugared name. `compile_pattern`
--- reads that table right after parsing and attaches each predicate to
--- the capture node it belongs to, in `capture_predicates`, keyed by
--- node identity because two occurrences of one name may carry
--- different predicates, or none. Both tables live in this module
--- because `Node` is a closed record and `compile_pattern`'s two-slot
--- return (doc/design.md) has no room for a third value.
---
--- A capture may also stand in a cast's type position (`$X as $T`,
--- `$X as $T:^{`); `build.ast.match_cast` holds that half.
--- `capture_predicates` is keyed by `any` so the same table serves a
--- `cast` node's identity.
local type compiler = require("build.compiler")
local node_mod = require("build.ast.node")
local ast_walk = require("build.ast.walk")
local match_cast = require("build.ast.match_cast")

local type Node = node_mod.Node

--- Array view of a generic AST-map value: a node's own array part (call
--- args, `if_blocks`, a block's statement list) as a plain Lua array.
--- A node's real shape depends on its `kind`, which no declared record
--- can express without one arm per kind.
--- @param t {any: any} A generic node/map view
--- @return {any} The same table, viewed as an array
local function arr(t: {any: any}): {any}
  return t as {any} -- cast: array view of a generic ast map
end

--- Positional/bookkeeping fields no pattern should ever compare
--- generically: source position (differs between pattern and target
--- by construction), a node's attached comments (not part of
--- structural identity), and `tk`. `tk` is semantic on a
--- "variable"/"identifier"/"string" leaf, which `match_value` compares
--- explicitly. On a compound node ("statements", "if_block") it is only
--- the token that opened the node, and differs between pattern and
--- target even on a genuine match.
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

--- Lua pattern predicates from the most recent `desugar` call, by
--- desugared capture name (`_F`). `compile_pattern` consumes it into
--- `capture_predicates` right after `desugar` returns, so a later
--- `desugar` of unrelated text (`rewrite.tl` desugaring a replacement
--- template) overwrites it harmlessly.
local last_predicates: {string: string} = {}

--- The predicate of each capture node in a compiled pattern, keyed by
--- node identity rather than name, since two occurrences of one name
--- may carry different predicates. `compile_pattern` fills it;
--- `match_value` reads it for every capture it binds. Keyed by `any`
--- because a cast-position capture (`build.ast.match_cast`) is keyed
--- by its `cast` node, which `match_value` holds as `{any: any}`.
local capture_predicates: {any: string} = {}

--- Rewrite ast-grep-style `$NAME`/`$$$NAME` metavariables into valid
--- Teal identifiers so the pattern lexes as real source (`$` is not a
--- legal Teal identifier character). The substitution shifts byte
--- positions, which is harmless because pattern text is only matched,
--- never spliced into output.
---
--- A plain capture may carry a `:PATTERN` predicate suffix (`$F:^test_`).
--- It ends at the next whitespace, `(`, `)`, or `,`, so `$F:^test_()`
--- does not swallow the call's parentheses. `desugar` strips it and
--- records it in `last_predicates` under the desugared name.
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return string The same pattern with metavariables rewritten to identifiers
local function desugar(pattern_src: string): string
  last_predicates = {}
  local out = pattern_src:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  out = out:gsub("%$([%u_][%w_]*):([^%s%(%),]+)",
    function(nm: string, pred: string): string
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
      -- cast: tl-parser field this Node kind doesn't name
      local cap = match_cast.capture_name((n as {any: any})["casttype"])
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

--- The rest-capture name if `node` is a rest-capture marker, else nil.
--- A marker has two shapes, because a bare name is not a Teal statement.
--- In an expression position (call args, a table's items) `$$$NAME`
--- desugars to the identifier `___NAME`. In a statement-list position (a
--- block, an if-branch's body) it is written `$$$NAME()` and parses as
--- the zero-argument call `___NAME()`, so `if $C then $$$BODY() end` is
--- valid source.
--- @param node any A pattern node, possibly a rest-capture marker
--- @return string|nil The capture name, or nil when `node` is not one
local function rest_capture_name(node: any): string | nil
  if not (node is {any: any}) then
    return nil
  end
  local tk = node["tk"]
  if node["kind"] == "variable" and tk is string and is_rest_capture(tk) then
    return tk
  end
  if node["kind"] == "op" then
    local op = node["op"]
    local e1 = node["e1"]
    local args = node["e2"]
    local name = e1 is {any: any} and e1["tk"] or nil
    if op is {any: any} and e1 is {any: any} and op["op"] == "@funcall"
    and e1["kind"] == "variable" and name is string and is_rest_capture(name)
    and args is {any: any} and #arr(args) == 0 then
      return name
    end
  end
  return nil
end

--- The synthetic `Node` bound to a rest-capture: a bare list of the
--- matched elements, shaped like tl's "expression_list" and
--- "statements" nodes. It has no span; `build.ast.walk` computes spans.
--- Its position is its first element's, so the span walk starts where
--- the matched source does. An empty rest keeps the pattern marker's
--- position and has no span to take (see `build.ast.rewrite`).
--- @param marker any The pattern's rest-capture marker node
--- @param elements {any} The matched trailing elements, in order
--- @return Node A bare-list node wrapping `elements`
local function rest_value(marker: any, elements: {any}): Node
  local out: Node = { kind = "rest_capture" }
  if marker is Node then
    out.f, out.y, out.x = marker.f, marker.y, marker.x
  end
  for i, e in ipairs(elements) do
    if e is Node then out[i] = e end
  end
  local first = elements[1]
  if first is Node and first.y ~= nil then
    out.y, out.x = first.y, first.x
  end
  return out
end

local match_value: function(pv: any, nv: any, caps: {string: Node},
  seen: {any: boolean}): boolean

--- Match two arrays positionally. A rest-capture marker as the
--- pattern's last element takes all remaining candidate elements (zero
--- or more) instead of requiring equal length. Serves a node's own
--- array part (call args, table items) and any array-shaped field
--- (`if_blocks`, a block's statement list).
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

--- Match one pattern value against one candidate value: a node, a
--- named field's value (a node, a list of nodes, or a scalar like
--- `op.op`), or an array element. A node matches on its kind, its array
--- part and every other named field the pattern sets, recursively.
--- @param pv any A value from the pattern
--- @param nv any The corresponding value from the candidate
--- @param caps {string: Node} Capture bindings accumulated so far
--- @param seen {any: boolean} Identity-keyed cycle guard, own to this matcher
--- @return boolean
match_value = function(pv: any, nv: any, caps: {string: Node},
    seen: {any: boolean}): boolean
  if pv == nil then
    return nv == nil
  end
  if not (pv is {any: any}) then
    return pv == nv -- scalar: string/number/boolean
  end
  -- A capture parses as "variable" where it references a value
  -- (`f($X)`) and as "identifier" where it names a field
  -- (`cosmo.$X(...)`).
  if (pv["kind"] == "variable" or pv["kind"] == "identifier")
  and is_capture(pv["tk"]) then
    if not (nv is {any: any}) then
      return false
    end
    local pred = capture_predicates[pv]
    local nv_tk = nv["tk"]
    if pred and not (nv_tk is string and nv_tk:match(pred) ~= nil) then
      return false
    end
    local name = pv["tk"]
    if not (name is string) then
      return false
    end
    local prev = caps[name]
    if prev then
      -- linear pattern: a repeated $X must bind the same subtree twice
      return prev.kind == nv["kind"] and prev.tk == nv["tk"]
    end
    caps[name] = nv as Node -- cast: a matched candidate node is a real Node
    return true
  end
  if not (nv is {any: any}) then
    return false
  end
  -- An if_block's `if_parent` points back at its "if" statement, so
  -- unguarded field recursion would loop. A revisit matches trivially.
  -- This guard is separate from `build.ast.walk`'s.
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
  if pkind == "cast" then
    return match_cast.match(pv, nv, caps, capture_predicates)
  end
  if not match_list(arr(pv), arr(nv), caps, seen) then
    return false
  end
  local typename = pv["typename"]
  for k, sub_pv in pairs(pv) do
    -- Type nodes carry fresh numeric allocation ids, not source shape.
    -- A record's fields map can also contain `typeid`, whose TYPE value
    -- is source-authored and must still be compared recursively.
    local is_typeid = k == "typeid" and sub_pv is integer and typename is string
    if k is string and not IGNORE_KEYS[k] and not is_typeid then
      if not match_value(sub_pv, nv[k], caps, seen) then
        return false
      end
    end
  end
  return true
end

--- Desugar, parse, and unwrap a pattern's source into its top node,
--- the first statement of the parsed program: a statement pattern
--- (`if ... end`) or a call.
---
--- A cast (`$X as $T`) or any other non-call expression is not a Teal
--- statement (`x as integer` alone is a syntax error; only
--- `return x as integer` parses). When the direct parse fails, the
--- source is parsed again as `return <source>` and the returned
--- expression is the top node.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param pattern_src string The pattern in its `$NAME`/`$$$NAME` surface syntax
--- @return Node|nil The pattern's own top node, or nil on a parse failure
--- @return string Error message on failure, "" on success
local function compile_pattern(built: compiler, pattern_src: string): Node | nil, string
  local desugared = desugar(pattern_src)
  local parsed, err = node_mod.parse(built, desugared, "<pattern>")
  if parsed then
    return attach_predicates(parsed.node[1], last_predicates), ""
  end
  -- Report the direct parse's error, not the retry's.
  local wrapped, _ = node_mod.parse(built, "return " .. desugared, "<pattern>")
  if not wrapped then
    return nil, err
  end
  local exps = wrapped.node[1].exps
  if not exps or exps[1] == nil then
    return nil, err
  end
  return attach_predicates(exps[1], last_predicates), ""
end

--- Match `pattern` against `node`, returning the capture bindings on
--- success. Subset matching: every named field `pattern` sets must
--- match; a field `pattern` leaves unset is never consulted, so a
--- partial pattern matches without spelling out every field of the
--- kind it names. Capture keys carry the desugared `_` prefix (`$CMD`
--- binds as `_CMD`).
--- @param pattern Node A compiled pattern (see `compile_pattern`)
--- @param node Node A candidate node to test
--- @return {string: Node}|nil Capture bindings by name, or nil when it does not match
local function match(pattern: Node, node: Node): {string: Node} | nil
  local caps: {string: Node} = {}
  if match_value(pattern, node, caps, {}) then
    return caps
  end
  return nil
end

local record MatchModule
  desugar: function(pattern_src: string): string
  compile_pattern: function(built: compiler, pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
end

local M: MatchModule = {
  desugar = desugar,
  compile_pattern = compile_pattern,
  match = match,
}

return M
