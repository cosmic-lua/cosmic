--- The flow rules over the item graph: pure functions over a list of
--- items, no network and no filesystem. There are no kinds — an
--- item's ROLE derives from its position in the graph, and this
--- module is where that derivation lives:
---
---   container an item with open children (being decomposed)
---   root      a parentless item, organizing or awaiting a decision
---   work      a parented leaf — the only role with a state
---
--- A workable item's STATE derives from the facts it carries, never
--- from a declared column:
---
---   todo    open, unclaimed, no PR — pullable once its spec passes
---           the bar (`_work.spec.ready_gaps`, asked at take)
---   doing   open with a claim or a PR; within it the same facts say
---           what happens next (`substate`): building, review,
---           rework, accepted
---
--- ONE WIP bound, `DOING_LIMIT`, covers the whole in-flight span:
--- taking NEW work is refused at the limit, finishing motions never
--- are. Capacity otherwise spreads by worker — one claim per session
--- — so there is no per-column table and nothing to tune per phase.
---
--- There is no goal tier: what makes one item outrank another is a
--- committed comparison (`_work.priority`), so a queue is priority
--- order with age as the last word.
---
--- What a session should DO with all this is `_work.action`: the
--- rules and the policy that consults them are separate modules, so
--- growing one never crowds the other against the file-length cap.
local it = require("_work.item")
local prio = require("_work.priority")
local spec = require("_work.spec")

local type Item = it.Item

--- Items indexed by id.
local type Index = {string: Item}

--- The most open doing items the board holds before a new take is
--- refused. One number over the whole in-flight span (building,
--- awaiting review, rework, awaiting merge): claims and open PRs
--- outlive the sessions that made them, so with no bound a fleet of
--- come-and-go workers accumulates half-finished work faster than
--- reviews retire it. Inherits the envelope the retired per-phase
--- limits allowed in practice; re-tuned by measurement over the
--- board's own log, as a reviewed change here.
local DOING_LIMIT < const >: integer = 10

--- The most parent hops a trace walks before calling the chain
--- cyclic; deeper nesting than this is its own design smell.
local MAX_DEPTH < const > = 16

--- Whether an open workable item is in flight: a claim or a PR makes
--- it `doing`, and nothing else does.
--- @param i Item The item
--- @return boolean True when a claim or a PR stands on it
local function is_doing(i: Item): boolean
  return (i.claim or "") ~= "" or (i.pr or 0) ~= 0
end

--- What a doing item's own facts say happens next.
--- @param i Item The item
--- @return string "accepted" | "rework" | "review" | "building"
local function substate(i: Item): string
  if (i.verdict or "") == "accept" then
    return "accepted"
  end
  if (i.verdict or "") == "request changes" then
    return "rework"
  end
  if (i.pr or 0) ~= 0 then
    return "review"
  end
  return "building"
end

--- The stage half of the unified order: how close an item is to
--- done, lower ranks first. ONE declaration — every queue, offer,
--- and refusal that says "finishing beats starting" derives from
--- this ranking rather than restating it: accepted work merges
--- before verdicts land, verdicts before rework, rework before
--- builds, and only then does anything new start — a red lane's
--- repair first (the pull that cannot wait), ordinary todo last.
local STAGE_ACCEPTED < const >: integer = 1
local STAGE_REVIEW < const >: integer = 2
local STAGE_REWORK < const >: integer = 3
local STAGE_BUILDING < const >: integer = 4
local STAGE_REPAIR < const >: integer = 5
local STAGE_TODO < const >: integer = 6

--- An open workable item's stage rank.
--- @param i Item The item
--- @return integer The rank, STAGE_ACCEPTED through STAGE_TODO
local function stage_rank(i: Item): integer
  if is_doing(i) then
    local sub = substate(i)
    if sub == "accepted" then
      return STAGE_ACCEPTED
    end
    if sub == "review" then
      return STAGE_REVIEW
    end
    if sub == "rework" then
      return STAGE_REWORK
    end
    return STAGE_BUILDING
  end
  if (i.lane or "") ~= "" then
    return STAGE_REPAIR
  end
  return STAGE_TODO
end

--- Items indexed by id.
--- @param items {Item} All items
--- @return Index The index
local function by_id(items: {Item}): Index
  local out: Index = {}
  for _, i in ipairs(items) do
    out[i.id] = i
  end
  return out
end

--- Whether an item has an open child.
--- @param items {Item} All items
--- @param id string The candidate parent's id
--- @return boolean True when some open item names it as parent
local function has_open_children(items: {Item}, id: string): boolean
  for _, i in ipairs(items) do
    if i.parent == id and it.is_open(i) then
      return true
    end
  end
  return false
end

--- The role an item's graph position gives it. A root with children
--- and a parented one with children are both something being
--- decomposed, so nothing distinguishes them here.
--- @param i Item The item
--- @param items {Item} All items
--- @return string "container" | "root" | "work"
local function role(i: Item, items: {Item}): string
  if has_open_children(items, i.id) then
    return "container"
  end
  if it.is_root(i) then
    return "root"
  end
  return "work"
end

--- The open workable items in one derived state, in queue order:
--- priority first, age last.
--- @param items {Item} All items
--- @param state string "todo" or "doing"
--- @param pos {string: prio.Position} Position by item id
--- @param seed string Per-session tie-break seed, "" for age order
--- @return {Item} Sorted items, possibly empty
local function in_state(items: {Item}, state: string,
    pos: {string: prio.Position}, seed?: string): {Item}
  local out: {Item} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and role(i, items) == "work"
    and (is_doing(i) and "doing" or "todo") == state then
      out[#out + 1] = i
    end
  end
  return prio.sorted(out, pos, seed)
end

--- Every open workable item in ONE queue: stage first (`stage_rank`),
--- then the priority order within a stage — the comparison relation,
--- blocker lift, age last (`prio.sorted`). `next` offers this queue's
--- head and the take gate refuses what its prefix outranks, so the
--- right-to-left doctrine is this derivation, not restated advice.
--- @param items {Item} All items
--- @param pos {string: prio.Position} Position by item id
--- @param seed string Per-session tie-break seed, "" for age order
--- @return {Item} The queue, closest-to-done first
local function unified(items: {Item},
    pos: {string: prio.Position}, seed?: string): {Item}
  local buckets: {integer: {Item}} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and role(i, items) == "work" then
      local rank = stage_rank(i)
      local bucket = buckets[rank]
      if bucket == nil then
        bucket = {}
        buckets[rank] = bucket
      end
      bucket[#bucket + 1] = i
    end
  end
  local out: {Item} = {}
  for rank = STAGE_ACCEPTED, STAGE_TODO do
    for _, i in ipairs(prio.sorted(buckets[rank] or {}, pos, seed)) do
      out[#out + 1] = i
    end
  end
  return out
end

--- The refusal a NEW take earns from the doing bound, or nil while
--- the board has room. Only a take of todo work asks — a takeover of
--- in-flight work adds nothing to the count, and finishing motions
--- never ask at all. A lane-repair item is the other arrival the
--- bound never holds back: the fix for a red lane cannot wait on a
--- queue depth it did not cause, the same admits-over-limit hole an
--- accept into land once used before the phase model retired.
--- @param items {Item} All items
--- @param taking Item The item about to be taken; nil when only
--- reporting the bound, never bypassed
--- @return string | nil The refusal
local function doing_refusal(items: {Item}, taking?: Item): string | nil
  if taking ~= nil and (taking.lane or "") ~= "" then
    return nil
  end
  local n = 0
  for _, i in ipairs(items) do
    if it.is_open(i) and is_doing(i) and role(i, items) == "work" then
      n = n + 1
    end
  end
  if n < DOING_LIMIT then
    return nil
  end
  return ("doing is at %d/%d — finish something before taking more")
  :format(n, DOING_LIMIT)
end

--- Whether one recorded blocker edge still holds its item up. A
--- blocker id with no item behind it does not block, and neither does
--- one whose item has ended. Every reader of a `blocked_by` edge asks
--- THIS, so a mark, a skipped take and a rendered heading cannot
--- disagree about what "blocked" means.
--- @param index Index Items by id
--- @param id string The blocker's id
--- @return boolean True when that blocker is an open item
local function binds(index: Index, id: string): boolean
  local blocker = index[id]
  return blocker ~= nil and it.is_open(blocker)
end

--- Whether an item waits on an open blocker.
--- @param i Item The item
--- @param index Index Items by id
--- @return boolean True when some named blocker still binds
local function is_blocked(i: Item, index: Index): boolean
  for _, b in ipairs(i.blocked_by or {}) do
    if binds(index, b) then
      return true
    end
  end
  return false
end

--- Whether `from` waits on `target`, directly or through a chain of
--- blockers. Bounded by the items already walked, so a cycle already
--- in the data cannot spin here — which is what lets the `block` verb
--- ask this question of data that may already hold one.
--- @param index Index Items by id
--- @param from string The waiting item's id
--- @param target string The id it might be waiting on
--- @param seen {string: boolean} Ids already walked; nil to start
--- @return boolean True when a blocker chain leads from `from` to `target`
local function waits_on(index: Index, from: string, target: string,
    seen?: {string: boolean}): boolean
  local walked = seen or {}
  if walked[from] then
    return false
  end
  walked[from] = true
  local i = index[from]
  if i == nil then
    return false
  end
  for _, b in ipairs(i.blocked_by or {}) do
    if b == target or waits_on(index, b, target, walked) then
      return true
    end
  end
  return false
end

--- The root an item's parent chain reaches, or nil for a broken or
--- cyclic chain.
--- @param i Item The item
--- @param index Index Items by id
--- @return Item | nil The root
local function root_of(i: Item, index: Index): Item | nil
  local cur = i
  for _ = 1, MAX_DEPTH do
    if it.is_root(cur) then
      return cur
    end
    cur = index[cur.parent]
    if cur == nil then
      return nil
    end
  end
  return nil
end

--- ONE item's graph problems: a parent that does not exist, and a
--- chain that never reaches a root. Placement is not asked here —
--- an unplaced item is the triage queue's to report, and the take
--- gate is where placement refuses work — so an unrelated item's
--- broken chain can never refuse a take that has nothing to do with
--- it. `status` asks this of everything, which is where board-wide
--- health belongs.
--- @param i Item The item
--- @param index Index Items by id
--- @return {string} Problems, possibly empty
local function item_problems(i: Item, index: Index): {string}
  local out: {string} = {}
  if not it.is_root(i) and index[i.parent] == nil then
    out[#out + 1] = ("%s: parent %s does not exist"):format(i.id, i.parent)
    return out
  end
  if not it.is_open(i) then
    return out
  end
  if root_of(i, index) == nil then
    out[#out + 1] = ("%s: parent chain is broken or cyclic"):format(i.id)
  end
  return out
end

--- Every item's graph problems, plus any cycle the priority edges
--- hold, for board-wide health.
--- @param items {Item} All items
--- @return {string} Problems, possibly empty
local function graph_problems(items: {Item}): {string}
  local index = by_id(items)
  local out: {string} = {}
  for _, i in ipairs(items) do
    for _, p in ipairs(item_problems(i, index)) do
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(prio.cycle_problems(items)) do
    out[#out + 1] = p
  end
  return out
end

--- The open roots that have a POSITION, in priority order, each with
--- whether live work already drives it (an open item whose parent
--- chain reaches it). Nothing marks a root as important: having been
--- compared against something is the only claim to importance the
--- board recognises.
--- @param items {Item} All items
--- @return {Item} Open placed roots, priority order
--- @return {string: boolean} root id -> has live work
local function roots(items: {Item}): {Item}, {string: boolean}
  local index = by_id(items)
  local at = prio.positions(items)
  local out: {Item} = {}
  local live: {string: boolean} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) then
      if it.is_root(i) then
        if prio.is_placed(at, i.id) then
          out[#out + 1] = i
        end
      else
        local root = root_of(i, index)
        if root ~= nil then
          live[root.id] = true
        end
      end
    end
  end
  return prio.sorted(out, at), live
end

--- The triage queue: open, childless, parentless items that no
--- comparison has placed. Captured evidence, nothing decomposing it,
--- nothing having adopted it, and no claim yet about how much it
--- matters — which is exactly the state triage exists to resolve, by
--- attaching it under something placed, comparing it, or ending it.
---
--- Placement is what separates this queue from intake: a root
--- somebody HAS compared is an outcome the planner decomposes
--- (`roots`), even with no children yet.
--- @param items {Item} All items
--- @return {Item} Unplaced roots, age order
local function untriaged(items: {Item}): {Item}
  local at = prio.positions(items)
  local out: {Item} = {}
  for _, i in ipairs(items) do
    if it.is_open(i) and it.is_root(i)
    and not has_open_children(items, i.id)
    and not prio.is_placed(at, i.id) then
      out[#out + 1] = i
    end
  end
  return prio.sorted(out, at)
end

local record flow
  type Item = Item
  type Index = Index
  DOING_LIMIT: integer
  STAGE_ACCEPTED: integer
  STAGE_REVIEW: integer
  STAGE_REWORK: integer
  STAGE_BUILDING: integer
  STAGE_REPAIR: integer
  STAGE_TODO: integer
  is_doing: function(i: Item): boolean
  substate: function(i: Item): string
  stage_rank: function(i: Item): integer
  unified: function(items: {Item}, pos: {string: prio.Position},
  seed?: string): {Item}
  by_id: function(items: {Item}): Index
  has_open_children: function(items: {Item}, id: string): boolean
  role: function(i: Item, items: {Item}): string
  in_state: function(items: {Item}, state: string,
  pos: {string: prio.Position}, seed?: string): {Item}
  doing_refusal: function(items: {Item}, taking?: Item): string | nil
  is_blocked: function(i: Item, index: Index): boolean
  binds: function(index: Index, id: string): boolean
  waits_on: function(index: Index, from: string, target: string,
  seen?: {string: boolean}): boolean
  root_of: function(i: Item, index: Index): Item | nil
  item_problems: function(i: Item, index: Index): {string}
  graph_problems: function(items: {Item}): {string}
  roots: function(items: {Item}): {Item}, {string: boolean}
  untriaged: function(items: {Item}): {Item}
  ready_gaps: function(body: string): {string}
end

local M: flow = {
  DOING_LIMIT = DOING_LIMIT,
  STAGE_ACCEPTED = STAGE_ACCEPTED,
  STAGE_REVIEW = STAGE_REVIEW,
  STAGE_REWORK = STAGE_REWORK,
  STAGE_BUILDING = STAGE_BUILDING,
  STAGE_REPAIR = STAGE_REPAIR,
  STAGE_TODO = STAGE_TODO,
  is_doing = is_doing,
  substate = substate,
  stage_rank = stage_rank,
  unified = unified,
  by_id = by_id,
  has_open_children = has_open_children,
  role = role,
  in_state = in_state,
  doing_refusal = doing_refusal,
  is_blocked = is_blocked,
  binds = binds,
  waits_on = waits_on,
  root_of = root_of,
  item_problems = item_problems,
  graph_problems = graph_problems,
  roots = roots,
  untriaged = untriaged,
  ready_gaps = spec.ready_gaps,
}

return M
