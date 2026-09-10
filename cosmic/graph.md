# graph

 Directed-graph algorithms over a plain adjacency map.

 A graph is `{string: {string}}`: each key is a node id, and its
 value is the list of nodes it points to. A neighbour that is not
 itself a key in the map is a dangling edge — an id nothing defines,
 like a typo — and every function here ignores it rather than
 treating it as a node: it is never added to a result and never
 walked from.

 Every traversal is iterative, over an explicit stack or queue, so a
 long chain (thousands of nodes deep) cannot exhaust the Lua
 C-stack the way a recursive walk would.

 Example usage:
   local graph = require("cosmic.graph")
   local g: graph.Graph = {a = {"b"}, b = {"c"}, c = {}}
   graph.reach(g, "a")             -- {b = true, c = true}
   graph.would_cycle(g, "c", "a")  -- true: a already reaches c
   graph.toposort(g)               -- {"a", "b", "c"}

## Types

### Frame

 One stack frame of an iterative DFS: the node, and the index of the
 next of its out-edges still to visit.

```teal
local record Frame
  node: string
  next_idx: integer
end
```

### GraphModule

```teal
local record GraphModule
  reach: function(g: Graph, id: string): {string: boolean}
  closure: function(g: Graph): {string: {string: boolean}}
  would_cycle: function(g: Graph, from: string, to: string): boolean
  ancestors: function(g: Graph, id: string): {string}
  has_cycle: function(g: Graph): boolean
  cycles: function(g: Graph): {{string}}
  toposort: function(g: Graph): {string} | nil, {string}
end
```

## Functions

### reach

```teal
function reach(g: Graph, id: string): {string: boolean}
```

 Every id reachable from `id`, directly or transitively. `id` itself
 appears in the result only when a cycle leads back to it — that is
 the cycle test, not a special case.

**Parameters:**

- `g` (Graph) - The graph
- `id` (string) - The node to walk from

**Returns:**

- {string: - boolean} Reached ids, possibly empty

### closure

```teal
function closure(g: Graph): {string: {string: boolean}}
```

 `reach` from every node the graph defines.

**Parameters:**

- `g` (Graph) - The graph

**Returns:**

- {string: - {string: boolean}} Reached-set by node id

### would_cycle

```teal
function would_cycle(g: Graph, from: string, to: string): boolean
```

 Whether adding an edge `from -> to` would close a cycle. True for a
 self-edge, and true whenever `to` already reaches `from` — the new
 edge would then complete the loop back through `from`. This does
 not check that either id is a node the graph already knows: an edge
 into or out of an unknown id cannot close a cycle, so the answer is
 honestly false rather than an error.

**Parameters:**

- `g` (Graph) - The graph before the edge is added
- `from` (string) - The edge's source
- `to` (string) - The edge's destination

**Returns:**

- boolean - True when the edge would make the graph cyclic

### ancestors

```teal
function ancestors(g: Graph, id: string): {string}
```

 The ids `id` points to, in order, walked outward until an id with
 no further edge is reached or an id repeats. A repeat means the
 chain loops rather than ending, so the walk stops there instead of
 spinning — the same bound a recursive parent-chain walk needs a
 depth limit for, made unnecessary by tracking what was already
 seen. When `id` has more than one outgoing edge, only the first is
 followed: this is the single-parent chain a tree's ancestors form,
 not a general traversal.

**Parameters:**

- `g` (Graph) - The graph
- `id` (string) - The node whose chain is wanted

**Returns:**

- {string} - The chain, nearest first; empty when `id` is a root

### has_cycle

```teal
function has_cycle(g: Graph): boolean
```

 Whether the graph contains a cycle anywhere.

**Parameters:**

- `g` (Graph) - The graph

**Returns:**

- boolean - True when some node reaches itself

### cycles

```teal
function cycles(g: Graph): {{string}}
```

 One representative cycle per strongly connected component that
 holds one, for reporting. Never averaged or repaired — a cycle
 means some edge should be reconsidered, and that is the caller's
 call to make.

**Parameters:**

- `g` (Graph) - The graph

**Returns:**

- {{string}} - Cycles, sorted by their first id; possibly empty

### toposort

```teal
function toposort(g: Graph): {string} | nil, {string}
```

 A topological order of every node the graph defines, or nil with
 one cycle when the graph is not a DAG. Kahn's algorithm: repeatedly
 take a node with no remaining incoming edge; ties break on id, so
 the order is the same on every machine.

**Parameters:**

- `g` (Graph) - The graph

**Returns:**

- {string}|nil - A topological order
- {string} - One cycle, when the graph is not a DAG
