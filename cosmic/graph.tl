--- Directed-graph algorithms over a plain adjacency map.
---
--- A graph is `{string: {string}}`: each key is a node id, and its
--- value is the list of nodes it points to. A neighbour that is not
--- itself a key in the map is a dangling edge — an id nothing defines,
--- like a typo — and every function here ignores it rather than
--- treating it as a node: it is never added to a result and never
--- walked from.
---
--- Every traversal is iterative, over an explicit stack or queue, so a
--- long chain (thousands of nodes deep) cannot exhaust the Lua
--- C-stack the way a recursive walk would.
---
--- Example usage:
---   local graph = require("cosmic.graph")
---   local g: graph.Graph = {a = {"b"}, b = {"c"}, c = {}}
---   graph.reach(g, "a")             -- {b = true, c = true}
---   graph.would_cycle(g, "c", "a")  -- true: a already reaches c
---   graph.toposort(g)               -- {"a", "b", "c"}

--- A directed graph: node id to the ids it points to.
local type Graph = {string: {string}}

--- One stack frame of an iterative DFS: the node, and the index of the
--- next of its out-edges still to visit.
local record Frame
  node: string
  next_idx: integer
end

--- Every id reachable from `id`, directly or transitively. `id` itself
--- appears in the result only when a cycle leads back to it — that is
--- the cycle test, not a special case.
--- @param g Graph The graph
--- @param id string The node to walk from
--- @return {string: boolean} Reached ids, possibly empty
local function reach(g: Graph, id: string): {string: boolean}
  local seen: {string: boolean} = {}
  local stack: {string} = {id}
  while #stack > 0 do
    local cur = table.remove(stack)
    for _, n in ipairs(g[cur] or {}) do
      if g[n] ~= nil and not seen[n] then
        seen[n] = true
        stack[#stack + 1] = n
      end
    end
  end
  return seen
end

--- `reach` from every node the graph defines.
--- @param g Graph The graph
--- @return {string: {string: boolean}} Reached-set by node id
local function closure(g: Graph): {string: {string: boolean}}
  local out: {string: {string: boolean}} = {}
  for id in pairs(g) do
    out[id] = reach(g, id)
  end
  return out
end

--- Whether adding an edge `from -> to` would close a cycle. True for a
--- self-edge, and true whenever `to` already reaches `from` — the new
--- edge would then complete the loop back through `from`. This does
--- not check that either id is a node the graph already knows: an edge
--- into or out of an unknown id cannot close a cycle, so the answer is
--- honestly false rather than an error.
--- @param g Graph The graph before the edge is added
--- @param from string The edge's source
--- @param to string The edge's destination
--- @return boolean True when the edge would make the graph cyclic
local function would_cycle(g: Graph, from: string, to: string): boolean
  if from == to then
    return true
  end
  return reach(g, to)[from] == true
end

--- The ids `id` points to, in order, walked outward until an id with
--- no further edge is reached or an id repeats. A repeat means the
--- chain loops rather than ending, so the walk stops there instead of
--- spinning — the same bound a recursive parent-chain walk needs a
--- depth limit for, made unnecessary by tracking what was already
--- seen. When `id` has more than one outgoing edge, only the first is
--- followed: this is the single-parent chain a tree's ancestors form,
--- not a general traversal.
--- @param g Graph The graph
--- @param id string The node whose chain is wanted
--- @return {string} The chain, nearest first; empty when `id` is a root
local function ancestors(g: Graph, id: string): {string}
  local out: {string} = {}
  local seen: {string: boolean} = {[id] = true}
  local cur = id
  while true do
    local outs = g[cur]
    if not outs or #outs == 0 then
      break
    end
    local nxt = outs[1]
    if seen[nxt] then
      break
    end
    seen[nxt] = true
    out[#out + 1] = nxt
    cur = nxt
  end
  return out
end

--- Post-order DFS finish order over every node the graph defines,
--- iterative via an explicit stack of (node, next child index) frames.
--- Kosaraju's algorithm's first pass.
--- @param g Graph The graph
--- @return {string} Node ids, in the order each one finished
local function finish_order(g: Graph): {string}
  local visited: {string: boolean} = {}
  local order: {string} = {}
  local ids: {string} = {}
  for id in pairs(g) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, start in ipairs(ids) do
    if not visited[start] then
      visited[start] = true
      local stack: {Frame} = {{node = start, next_idx = 1}}
      while #stack > 0 do
        local frame = stack[#stack]
        local outs = g[frame.node] or {}
        if frame.next_idx <= #outs then
          local child = outs[frame.next_idx]
          frame.next_idx = frame.next_idx + 1
          if g[child] ~= nil and not visited[child] then
            visited[child] = true
            stack[#stack + 1] = {node = child, next_idx = 1}
          end
        else
          order[#order + 1] = frame.node
          stack[#stack] = nil
        end
      end
    end
  end
  return order
end

--- The graph with every edge reversed. Dangling edges (a neighbour the
--- graph does not define) are dropped, the same as everywhere else
--- here.
--- @param g Graph The graph
--- @return Graph The reverse
local function reverse(g: Graph): Graph
  local rg: Graph = {}
  for id in pairs(g) do
    rg[id] = {}
  end
  for id, outs in pairs(g) do
    for _, n in ipairs(outs) do
      if g[n] ~= nil then
        rg[n][#rg[n] + 1] = id
      end
    end
  end
  return rg
end

--- The graph's strongly connected components, each a list of node ids.
--- Kosaraju's algorithm: a finish-order DFS over the graph, then a
--- second DFS over the reverse graph in reverse finish order, one
--- component per tree that pass grows.
--- @param g Graph The graph
--- @return {{string}} Components, each a non-empty list of ids
local function components(g: Graph): {{string}}
  local order = finish_order(g)
  local rg = reverse(g)
  local visited: {string: boolean} = {}
  local comps: {{string}} = {}
  for i = #order, 1, -1 do
    local start = order[i]
    if not visited[start] then
      visited[start] = true
      local comp: {string} = {start}
      local stack: {string} = {start}
      while #stack > 0 do
        local cur = table.remove(stack)
        for _, n in ipairs(rg[cur] or {}) do
          if not visited[n] then
            visited[n] = true
            comp[#comp + 1] = n
            stack[#stack + 1] = n
          end
        end
      end
      comps[#comps + 1] = comp
    end
  end
  return comps
end

--- One cycle within a strongly connected component, starting at
--- `start`. Every member can reach every other member, so following
--- the lexicographically smallest in-component neighbour from `start`
--- is a deterministic walk over a finite set of ids: by the pigeonhole
--- principle it revisits some id within `#members` steps, and that
--- repeat closes a real cycle.
--- @param g Graph The graph
--- @param members {string: boolean} The component's node ids
--- @param start string A member to start from
--- @return {string} The cycle, in order
local function find_cycle(g: Graph, members: {string: boolean},
    start: string): {string}
  local path: {string} = {}
  local index_of: {string: integer} = {}
  local cur = start
  while not index_of[cur] do
    index_of[cur] = #path + 1
    path[#path + 1] = cur
    local best: string = nil
    for _, n in ipairs(g[cur] or {}) do
      if members[n] and (best == nil or n < best) then
        best = n
      end
    end
    cur = best
  end
  local out: {string} = {}
  for i = index_of[cur], #path do
    out[#out + 1] = path[i]
  end
  return out
end

--- Whether a component is actually cyclic: more than one member, or
--- one member with an edge to itself.
--- @param g Graph The graph
--- @param comp {string} A component from components()
--- @return boolean True when the component contains a cycle
local function is_cyclic(g: Graph, comp: {string}): boolean
  if #comp > 1 then
    return true
  end
  local only = comp[1]
  for _, n in ipairs(g[only] or {}) do
    if n == only then
      return true
    end
  end
  return false
end

--- Whether the graph contains a cycle anywhere.
--- @param g Graph The graph
--- @return boolean True when some node reaches itself
local function has_cycle(g: Graph): boolean
  for _, comp in ipairs(components(g)) do
    if is_cyclic(g, comp) then
      return true
    end
  end
  return false
end

--- One representative cycle per strongly connected component that
--- holds one, for reporting. Never averaged or repaired — a cycle
--- means some edge should be reconsidered, and that is the caller's
--- call to make.
--- @param g Graph The graph
--- @return {{string}} Cycles, sorted by their first id; possibly empty
local function cycles(g: Graph): {{string}}
  local out: {{string}} = {}
  for _, comp in ipairs(components(g)) do
    if is_cyclic(g, comp) then
      table.sort(comp)
      local members: {string: boolean} = {}
      for _, n in ipairs(comp) do
        members[n] = true
      end
      out[#out + 1] = find_cycle(g, members, comp[1])
    end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean
      return a[1] < b[1]
    end)
  return out
end

--- A topological order of every node the graph defines, or nil with
--- one cycle when the graph is not a DAG. Kahn's algorithm: repeatedly
--- take a node with no remaining incoming edge; ties break on id, so
--- the order is the same on every machine.
--- @param g Graph The graph
--- @return {string}|nil A topological order
--- @return {string} One cycle, when the graph is not a DAG
local function toposort(g: Graph): {string} | nil, {string}
  local indegree: {string: integer} = {}
  for id in pairs(g) do
    indegree[id] = 0
  end
  for _, outs in pairs(g) do
    for _, n in ipairs(outs) do
      if indegree[n] ~= nil then
        indegree[n] = indegree[n] + 1
      end
    end
  end
  local ready: {string} = {}
  for id, deg in pairs(indegree) do
    if deg == 0 then
      ready[#ready + 1] = id
    end
  end
  table.sort(ready)
  local order: {string} = {}
  local head = 1
  while head <= #ready do
    local cur = ready[head]
    head = head + 1
    order[#order + 1] = cur
    local freed: {string} = {}
    for _, n in ipairs(g[cur] or {}) do
      if indegree[n] ~= nil then
        indegree[n] = indegree[n] - 1
        if indegree[n] == 0 then
          freed[#freed + 1] = n
        end
      end
    end
    table.sort(freed)
    for _, n in ipairs(freed) do
      ready[#ready + 1] = n
    end
  end
  local total = 0
  for _ in pairs(indegree) do
    total = total + 1
  end
  if #order == total then
    return order
  end
  return nil, cycles(g)[1]
end

local record GraphModule
  type Graph = Graph

  reach: function(g: Graph, id: string): {string: boolean}
  closure: function(g: Graph): {string: {string: boolean}}
  would_cycle: function(g: Graph, from: string, to: string): boolean
  ancestors: function(g: Graph, id: string): {string}
  has_cycle: function(g: Graph): boolean
  cycles: function(g: Graph): {{string}}
  toposort: function(g: Graph): {string} | nil, {string}
end

local M: GraphModule = {
  reach = reach,
  closure = closure,
  would_cycle = would_cycle,
  ancestors = ancestors,
  has_cycle = has_cycle,
  cycles = cycles,
  toposort = toposort,
}

return M
