--- Examples for the cosmic.graph module.
--- Demonstrates reachability, cycle detection, and a topological order
--- over the same small adjacency map.

-- Example_reach demonstrates transitive closure over one node: a
-- comparison at the top of a chain settles everything beneath it.
local function Example_reach()
  local graph = require("cosmic.graph")
  local g: graph.Graph = {a = {"b"}, b = {"c"}, c = {}}
  local reached = graph.reach(g, "a")
  print(reached.b, reached.c, reached.a)
  -- Output:
  -- true	true	nil
end

-- Example_would_cycle demonstrates the check a caller makes before
-- recording a new edge: would it close a loop the graph does not
-- already have?
local function Example_would_cycle()
  local graph = require("cosmic.graph")
  local g: graph.Graph = {a = {"b"}, b = {"c"}, c = {}}
  print(graph.would_cycle(g, "c", "a"))
  print(graph.would_cycle(g, "a", "c"))
  -- Output:
  -- true
  -- false
end

-- Example_toposort demonstrates ordering a dependency graph so that
-- every node comes before whatever it points to, and reports a cycle
-- instead of an order when the graph is not a DAG.
local function Example_toposort()
  local graph = require("cosmic.graph")
  local g: graph.Graph = {main = {"util"}, util = {}}
  local order = graph.toposort(g)
  if order then
    print(table.concat(order, " "))
  end
  local cyclic: graph.Graph = {a = {"b"}, b = {"a"}}
  local failed, cycle = graph.toposort(cyclic)
  print(failed == nil, cycle ~= nil and #cycle)
  -- Output:
  -- main util
  -- true	2
end

-- Suppress unused warnings for examples
local _ = {Example_reach, Example_would_cycle, Example_toposort}
