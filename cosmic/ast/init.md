# ast

 Public parent for the cosmic.ast.* shards: parsing, walking, and
 structural pattern matching over Teal's AST.

## Types

### AstModule

```teal
local record AstModule
  parse: function(source: string, name: string, lang?: string): Parsed | nil, string
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {tl.Token}): integer, integer
  desugar: function(pattern_src: string): string
  compile_pattern: function(pattern_src: string): Node | nil, string
  match: function(pattern: Node, node: Node): {string: Node} | nil
  find_all: function(ast: Node, pattern: Node): {Hit}
  line_starts: function(source: string): {integer}
  offset_of: function(starts: {integer}, y: integer, x: integer): integer
  rewrite: function(source: string, name: string, pattern: Node,
  replacement: string): RewriteResult | nil, string
end
```

### Node

alias of `cosmic.ast.node.Node` — field and method table: `cosmic --docs cosmic.ast.node.Node`

### Parsed

alias of `cosmic.ast.node.Parsed` — field and method table: `cosmic --docs cosmic.ast.node.Parsed`

### Hit

alias of `cosmic.ast.rewrite.Hit` — field and method table: `cosmic --docs cosmic.ast.rewrite.Hit`

### Refusal

alias of `cosmic.ast.rewrite.Refusal` — field and method table: `cosmic --docs cosmic.ast.rewrite.Refusal`

### RewriteResult

alias of `cosmic.ast.rewrite.RewriteResult` — field and method table: `cosmic --docs cosmic.ast.rewrite.RewriteResult`
