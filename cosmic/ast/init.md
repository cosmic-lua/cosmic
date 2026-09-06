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
end
```

### Node

alias of `cosmic.ast.node.Node` — field and method table: `cosmic --docs cosmic.ast.node.Node`

### Parsed

alias of `cosmic.ast.node.Parsed` — field and method table: `cosmic --docs cosmic.ast.node.Parsed`
