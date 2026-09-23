--- Structural Teal parsing, walking, matching, and rewriting, over the
--- vendored compiler's real AST. Every function that reaches the
--- compiler takes the loaded capsule (`build.teal.load()`) as its first
--- argument, which is why this lives under `build/`: nothing hands that
--- capsule to user code yet.
local type compiler = require("build.compiler")
local ast_node = require("build.ast.node")
local ast_walk = require("build.ast.walk")
local ast_match = require("build.ast.match")
local ast_rewrite = require("build.ast.rewrite")
local ast_requires = require("build.ast.requires")

local type Node = ast_node.Node
local type TypeNode = ast_node.TypeNode
local type Parsed = ast_node.Parsed
local type RewriteResult = ast_rewrite.RewriteResult

local record AstModule
  type Node = Node
  type TypeNode = TypeNode
  type Parsed = Parsed
  parse: function(built: compiler, source: string, name: string,
                  lang?: string): Parsed | nil, string
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  compile_pattern: function(built: compiler, pattern_src: string): Node | nil, string
  all_requires: function(built: compiler, parsed: Parsed): {string} | nil, string
  line_starts: function(source: string): {integer}
  offset_of: function(starts: {integer}, y: integer, x: integer): integer
  rewrite: function(built: compiler, source: string, name: string, pattern: Node,
  replacement: string): RewriteResult | nil, string
end

local M: AstModule = {
  parse = ast_node.parse,
  walk = ast_walk.walk,
  span_start = ast_walk.span_start,
  compile_pattern = ast_match.compile_pattern,
  all_requires = ast_requires.all_requires,
  line_starts = ast_rewrite.line_starts,
  offset_of = ast_rewrite.offset_of,
  rewrite = ast_rewrite.rewrite,
}

return M
