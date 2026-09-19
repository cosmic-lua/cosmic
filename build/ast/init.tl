--- Structural Teal parsing, walking, matching, and rewriting, over the
--- vendored compiler's real AST.
---
--- This lives under `build/`, not `cosmic/`, even though design.md's
--- own tier list already names `cosmic.ast` as a public core-tier
--- module (alongside `cosmic.check`, `cosmic.fs`, ...): every function
--- here that touches source at all needs a loaded compiler capsule
--- (`build.teal.load()`, typed `build.compiler`), and that capsule is
--- a privileged, build-time-only value with no safe way for an
--- arbitrary user script to reach it today -- there is no `require`
--- that hands one out, only `build.teal`'s own loader, itself gated to
--- the build/test machinery. Promoting this module to `cosmic.ast`
--- has to wait for whatever mechanism eventually exposes compiler
--- access safely to user code, tracked already in roadmap.md's
--- "second: ast, checking, formatting" phase. This mirrors an existing
--- precedent exactly: `test` and `coverage` are also named in
--- design.md's public core tier, and both live under `build/`
--- (`build/test.tl`) rather than `cosmic/` today, for the same reason
--- -- `ls build/` and `ls cosmic/` both confirm it.
---
--- Ported from cosmic (v1)'s `cosmic.ast`: parsing, walking, and
--- structural pattern matching over Teal's AST, unchanged in spirit --
--- every function that reaches the compiler now takes the loaded
--- capsule as its own explicit first argument instead of doing
--- `require("tl")` internally, since v2 has no such global to reach
--- for. `build/ast/node.tl` is the one shard that actually calls into
--- it (`built.lex`/`built.parse_program`); everything else here
--- reaches the compiler only by calling `node.parse`.
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
  parse: function(built: compiler, source: string, name: string,
                  lang?: string): Parsed | nil, string
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {compiler.Token}): integer, integer
  desugar: function(pattern_src: string): string
  compile_pattern: function(built: compiler, pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
  find_all: function(ast: Node, pattern: Node): {Hit}
  requires: function(built: compiler, parsed: Parsed): {string: string} | nil, string
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
  span_end = ast_walk.span_end,
  desugar = ast_match.desugar,
  compile_pattern = ast_match.compile_pattern,
  match = ast_match.match,
  find_all = ast_rewrite.find_all,
  requires = ast_requires.requires,
  all_requires = ast_requires.all_requires,
  line_starts = ast_rewrite.line_starts,
  offset_of = ast_rewrite.offset_of,
  rewrite = ast_rewrite.rewrite,
}

return M
