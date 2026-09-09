--- Owned compiled AST patterns.
---
--- `cosmic.ast.match` keeps its original Node-based API for compatibility,
--- while this module packages a compiled root with a private snapshot of
--- its capture predicates. A Pattern can therefore be retained and used
--- after other patterns are compiled without consulting mutable global
--- predicate state.
local ast_node = require("cosmic.ast.node")
local ast_match = require("cosmic.ast._match_engine")

local type Node = ast_node.Node

local record Pattern
  root: Node
  predicates: {any: string}
  wildcard: boolean
end

--- Compile one surface pattern and own its predicate metadata.
--- @param source string `$NAME`/`$$$NAME` pattern source
--- @return Pattern|nil The compiled pattern, or nil and a parse error
--- @return string Error message on failure, nil on success
local function compile(source: string): Pattern | nil, string
  local root, err = ast_match.compile_pattern(source)
  if not root then
    return nil, err
  end
  local tk = root.tk
  local wildcard = root.kind == "variable"
  and tk is string and tk:match("^_[A-Z][A-Z0-9_]*$") ~= nil
  return {root = root, predicates = ast_match.predicates_for(root), wildcard = wildcard}, nil
end

--- Match an owned Pattern against one AST node.
--- @param pattern Pattern A value returned by `compile`
--- @param node Node Candidate AST node
--- @return {string: Node}|nil Capture bindings, or nil on mismatch
local function match(pattern: Pattern, node: Node): {string: Node} | nil
  return ast_match.match_with_predicates(pattern.root, node, pattern.predicates)
end

local function is_wildcard(pattern: Pattern): boolean
  return pattern.wildcard
end

local record PatternModule
  type Pattern = Pattern
  compile: function(source: string): Pattern | nil, string
  match: function(pattern: Pattern, node: Node): {string: Node} | nil
  is_wildcard: function(pattern: Pattern): boolean
end

local M: PatternModule = {
  compile = compile,
  match = match,
  is_wildcard = is_wildcard,
}

return M
