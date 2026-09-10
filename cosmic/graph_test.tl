--- Tests for cosmic.graph.
local graph = require("cosmic.graph")

local type Graph = graph.Graph

local function test_reach_is_transitive()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  local r = graph.reach(g, "a")
  assert(r.b, "a reaches its direct neighbour")
  assert(r.c, "a reaches b's neighbour transitively, nobody asked")
  assert(not r.a, "a does not reach itself when there is no cycle")
end

local function test_reach_ignores_dangling_neighbours()
  -- "ghost" is not a key in the graph: an id with no node behind it is
  -- a typo, not an edge, and must not be walked from either.
  local g: Graph = {a = {"ghost"}}
  local r = graph.reach(g, "a")
  assert(next(r) == nil, "a dangling neighbour is not reached")
end

local function test_reach_includes_self_only_through_a_cycle()
  local g: Graph = {a = {"b"}, b = {"a"}}
  local r = graph.reach(g, "a")
  assert(r.a, "the cycle brings a back to itself")
  assert(r.b, "and reaches its neighbour too")
end

local function test_closure_covers_every_node()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  local all = graph.closure(g)
  assert(all.a.b and all.a.c, "a's closure")
  assert(all.b.c and not all.b.a, "b's closure")
  assert(next(all.c) == nil, "c reaches nothing")
end

local function test_would_cycle_flags_the_closing_edge()
  -- a -> b -> c already stands; c -> a would close the loop.
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  assert(graph.would_cycle(g, "c", "a"),
    "c already outranks a transitively, so recording a -> c closed "
    .. "the other way would make the order cyclic")
end

local function test_would_cycle_allows_a_non_closing_edge()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  assert(not graph.would_cycle(g, "a", "c"),
    "an edge that contradicts no existing path is allowed")
end

local function test_would_cycle_treats_a_self_edge_as_a_cycle()
  local g: Graph = {a = {}}
  assert(graph.would_cycle(g, "a", "a"), "nothing outranks itself")
end

local function test_ancestors_walks_the_chain_to_the_root()
  local g: Graph = {leaf = {"mid"}, mid = {"top"}, top = {}}
  local chain = graph.ancestors(g, "leaf")
  assert(#chain == 2 and chain[1] == "mid" and chain[2] == "top",
    "nearest ancestor first, root last")
end

local function test_ancestors_is_empty_at_a_root()
  local g: Graph = {top = {}}
  assert(#graph.ancestors(g, "top") == 0, "a root has no ancestors")
end

local function test_ancestors_terminates_on_a_cycle()
  local g: Graph = {a = {"b"}, b = {"a"}}
  local chain = graph.ancestors(g, "a")
  assert(#chain == 1 and chain[1] == "b",
    "the walk stops the moment an id repeats: " .. #chain)
end

local function test_has_cycle_is_false_on_a_dag()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  assert(not graph.has_cycle(g))
end

local function test_has_cycle_and_cycles_report_a_two_node_loop()
  local g: Graph = {a = {"b"}, b = {"a"}}
  assert(graph.has_cycle(g), "a and b outrank each other")
  local cs = graph.cycles(g)
  assert(#cs == 1, "one component, one representative cycle: " .. #cs)
  local only = cs[1]
  assert(only ~= nil and #only == 2, "both members name it")
end

local function test_cycles_reports_a_self_loop()
  local g: Graph = {a = {"a"}}
  local cs = graph.cycles(g)
  assert(#cs == 1, "the self-loop is its own component")
  local only = cs[1]
  assert(only ~= nil and #only == 1 and only[1] == "a")
end

local function test_cycles_is_empty_on_a_dag()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  assert(#graph.cycles(g) == 0)
end

local function test_toposort_orders_a_dag()
  local g: Graph = {a = {"b"}, b = {"c"}, c = {}}
  local order = graph.toposort(g)
  assert(order ~= nil, "a dag always sorts")
  assert(order[1] == "a" and order[2] == "b" and order[3] == "c",
    "each node precedes what it points to")
end

local function test_toposort_breaks_ties_on_id()
  -- Two roots with no edge between them: the order between them is not
  -- forced by the graph, so it must still be the same on every machine.
  local g: Graph = {b = {}, a = {}}
  local order = graph.toposort(g)
  assert(order ~= nil and order[1] == "a" and order[2] == "b",
    "ties break on id, deterministically")
end

local function test_toposort_fails_on_a_cycle_with_a_witness()
  local g: Graph = {a = {"b"}, b = {"a"}}
  local order, cycle = graph.toposort(g)
  assert(order == nil, "no order exists for a cyclic graph")
  assert(cycle ~= nil and #cycle == 2, "and the witness names the loop")
end

-- The port from a recursive walk to an explicit stack is the point:
-- a chain this deep would blow the Lua C-stack recursively, and must
-- not here.
local function test_reach_and_toposort_handle_a_100k_node_chain()
  local n = 100000
  local g: Graph = {}
  for i = 1, n do
    local id = "n" .. i
    if i < n then
      g[id] = {"n" .. (i + 1)}
    else
      g[id] = {}
    end
  end

  local r = graph.reach(g, "n1")
  local reached = 0
  for _ in pairs(r) do
    reached = reached + 1
  end
  assert(reached == n - 1, "reach covers the whole chain: " .. reached)

  local chain = graph.ancestors(g, "n1")
  assert(#chain == n - 1, "ancestors walks the whole chain: " .. #chain)

  local order = graph.toposort(g)
  assert(order ~= nil and #order == n, "toposort covers every node")
  assert(order[1] == "n1" and order[n] == ("n" .. n),
    "the chain's own order is preserved")
end
