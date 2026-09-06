--- Public parent for the cosmic.ast.* shards: parsing, walking, and
--- structural pattern matching over Teal's AST.
local tl = require("tl")
local ast_node = require("cosmic.ast.node")
local ast_walk = require("cosmic.ast.walk")
local ast_match = require("cosmic.ast.match")

local type Node = ast_node.Node
local type Parsed = ast_node.Parsed

local record AstModule
  type Node = Node
  type Parsed = Parsed
  parse: function(source: string, name: string, lang?: string): Parsed | nil, string
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {tl.Token}): integer, integer
  desugar: function(pattern_src: string): string
  compile_pattern: function(pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
end

local M: AstModule = {
  parse = ast_node.parse,
  walk = ast_walk.walk,
  span_start = ast_walk.span_start,
  span_end = ast_walk.span_end,
  desugar = ast_match.desugar,
  compile_pattern = ast_match.compile_pattern,
  match = ast_match.match,
}

return M
