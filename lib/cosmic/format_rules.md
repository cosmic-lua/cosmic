# format_rules

 Formatting rules and classification functions for the code formatter.
 Contains lookup tables, token classifiers, and indent computation.

## Types

### Item

```teal
local record Item
  y: integer
  x: integer
  tk: string
  kind: string
end
```

### FormatRulesModule

```teal
local record FormatRulesModule
  is_long_comment: function(tk: string): boolean
  needs_space: function(prev_prev: any, prev: any, cur: any, next_item: any): boolean
  compute_indent_change: function(line_items: {any}): integer, integer
end
```

## Functions

### is_long_comment

```teal
function is_long_comment(tk: string): boolean
```

 Check if a comment is a long comment.

### needs_space

```teal
function needs_space(prev_prev: Item, prev: Item, cur: Item, next_item: Item): boolean
```

 Determine if we need a space between two adjacent items on the same line.

### compute_indent_change

```teal
function compute_indent_change(line_items: {Item}): integer, integer
```

 Compute the net indent change for all items on a line.
 Returns (pre_change, post_change).
