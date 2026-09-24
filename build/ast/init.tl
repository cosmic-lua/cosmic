--- Structural Teal parsing, walking, matching, and rewriting over the
--- vendored compiler's AST. Functions that parse source take the loaded
--- compiler capsule explicitly.
local type compiler = require("build.compiler")
local ast_node = require("build.ast.node")
local ast_walk = require("build.ast.walk")
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local ast_requires = require("build.ast.requires")

local type Node = ast_node.Node
local type TypeNode = ast_node.TypeNode
local type Parsed = ast_node.Parsed
local type Hit = ast_rewrite.Hit
local type Refusal = ast_rewrite.Refusal
local type RewriteResult = ast_rewrite.RewriteResult

local record AstModule
  type Node = Node
  type TypeNode = TypeNode
  type Parsed = Parsed
  type Hit = Hit
  type Refusal = Refusal
  type RewriteResult = RewriteResult
  parse: function(built: compiler, source: string, name: string): Parsed | nil, string
  walk: function(node: Node, visit: function(Node))
  children: function(node: Node, skipped?: {string: boolean}, passed?: {Node}): {Node}
  span_start: function(node: Node): integer, integer
  compile_pattern: function(built: compiler, pattern_src: string): Node | nil, string
  find_all: function(ast: Node, pattern: Node): {Hit}
  all_requires: function(built: compiler, parsed: Parsed): {string} | nil, string
  line_starts: function(source: string): {integer}
  offset_of: function(starts: {integer}, y: integer, x: integer): integer
  rewrite: function(built: compiler, source: string, name: string, pattern: Node,
  replacement: string, keep?: function(Node): boolean): RewriteResult | nil, string
end

local M: AstModule = {
  parse = ast_node.parse,
  walk = ast_walk.walk,
  children = ast_walk.children,
  span_start = ast_walk.span_start,
  compile_pattern = ast_match.compile_pattern,
  find_all = ast_rewrite.find_all,
  all_requires = ast_requires.all_requires,
  line_starts = ast_rewrite.line_starts,
  offset_of = ast_rewrite.offset_of,
  rewrite = ast_rewrite.rewrite,
}

return M
