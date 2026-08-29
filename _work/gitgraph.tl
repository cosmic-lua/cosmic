--- The graph verbs: `new`, `attach`, `block` and its `unblock` half —
--- the mutations that shape the item GRAPH (an item's existence, a
--- parent edge, a blocker edge) rather than moving work state, which
--- is `_work.gitverbs`. Verbs receive FULL ids — the dispatcher
--- resolves prefixes — and every verb prints a `gitboard-<verb>:`
--- verdict line and returns its exit code. Mutations commit locally
--- and publish through `publish.publish`, whose rejected-push path
--- drops the mutation whole, re-syncs, and refuses — re-running the
--- verb re-applies every gate against the merged board.
---
--- Decomposition and triage are both `attach`: giving an item a
--- parent is the whole operation, because roles derive from the graph
--- — a captured item becomes work by gaining a parent, and a workable
--- item becomes a container the moment a child attaches under it.
--- Priority is the other half of triage and has its own verb,
--- `compare`, because an item can be placed without being adopted and
--- adopted without being compared.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")

local function cmd_new(s: store.Store, title: string, parent: string,
    spec: string, repo: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("new", false, aerr)
  end
  local index = flow.by_id(all)
  local parent_item: item.Item = nil
  if parent ~= "" then
    parent_item = index[parent]
    if parent_item == nil then
      return gate.verdict_line("new", false, ("no item %s"):format(parent))
    end
  end
  local it: item.Item = {
    id = ksuid.new(), title = title, parent = parent, repo = repo or "",
    beats = {},
    blocked_by = {}, claim = "", pr = 0, verdict = "",
    verdict_head = "", resolution = "",
  }
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("new", false, table.concat(bad, "; "))
  end
  -- No gate: a filed child always enters `todo`, which is unbounded
  -- by design — the queue intake writes into can always accept,
  -- which is what keeps the cheap decision cheap. The bound binds at
  -- take, where committing to work is the expensive decision.
  local also: {item.Item} = {}
  if parent_item ~= nil then
    also = gate.containered(parent_item)
  end
  local ok, err = gate.commit_and_publish(s, it, spec,
    ("new %s %s"):format(it.id:sub(1, 8), title), also)
  if not ok then
    return gate.verdict_line("new", false, err)
  end
  local entered = "triage — attach it under something, or compare it"
  if parent ~= "" then
    entered = "todo"
  end
  return gate.verdict_line("new", true, ("%s enters %s"):format(it.id, entered))
end

local function cmd_attach(s: store.Store, id: string, parent: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("attach", false, aerr)
  end
  local index = flow.by_id(all)
  local it = index[id]
  local parent_item = index[parent]
  if it == nil then
    return gate.verdict_line("attach", false, ("no item %s"):format(id))
  end
  if parent_item == nil then
    return gate.verdict_line("attach", false, ("no item %s"):format(parent))
  end
  if id == parent then
    return gate.verdict_line("attach", false, "an item cannot parent itself")
  end
  local up = flow.root_of(parent_item, index)
  if up == nil then
    return gate.verdict_line("attach", false,
      ("%s's own parent chain is broken"):format(parent:sub(1, 8)))
  end
  local cur = parent_item
  while cur ~= nil do
    if cur.id == id then
      return gate.verdict_line("attach", false,
        ("attaching under %s would make a cycle"):format(parent:sub(1, 8)))
    end
    cur = index[cur.parent or ""]
  end
  it.parent = parent
  -- Adoption makes a leaf workable: it is todo by derivation, with
  -- nothing to write. Triage answers one cheap question — is this
  -- real, and under which outcome — and placing an item is not
  -- committing to build it; the expensive decision is the take, where
  -- the spec bar and the doing bound bind.
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("attach", false, table.concat(bad, "; "))
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("attach %s under %s"):format(id:sub(1, 8), parent:sub(1, 8)),
    gate.containered(parent_item))
  if not ok then
    return gate.verdict_line("attach", false, err)
  end
  local workable = ""
  if not flow.has_open_children(all, id) then
    workable = " — workable, in todo"
  end
  return gate.verdict_line("attach", true,
    ("%s now under %s%s"):format(id:sub(1, 8), parent:sub(1, 8), workable))
end

--- block/unblock: the `blocked_by` field as a verb, so the landing
--- order between two slices is recorded the same way every other
--- board fact is — one mutation, one commit, one refusal when it does
--- not hold. Hand-editing the field was the standing workaround, and
--- it wrote duplicate ids and ids of items that do not exist; both
--- are refused here, and an existing duplicate is collapsed by the
--- next write.
---
--- A block RECORDS ITS REASON: one cheap command sequences whole
--- chains behind the blocker, and an edge nobody can later judge —
--- does this still bind, or did the spec grow its own workaround? —
--- can only be resolved by whoever remembers writing it. The reason
--- travels on the item (`block_reason`), rendered by `show`, and is
--- what a session weighs before dropping the edge.
--- @param s store.Store The store
--- @param id string The waiting item
--- @param blocker string The item it waits on
--- @param remove boolean True to drop the blocker instead of adding it
--- @param reason string What concretely cannot proceed; required to add
--- @return integer 0 on success, 1 otherwise
local function cmd_block(s: store.Store, id: string, blocker: string,
    remove: boolean, reason: string): integer
  local verb = remove and "unblock" or "block"
  if not remove and (reason or ""):match("%S") == nil then
    return gate.verdict_line(verb, false,
      "REFUSED: a block records why the edge binds — pass --reason "
      .. "'<what concretely cannot proceed until the blocker ends>'")
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line(verb, false, aerr)
  end
  local index = flow.by_id(all)
  local it = index[id]
  if it == nil then
    return gate.verdict_line(verb, false, ("no item %s"):format(id))
  end
  if index[blocker] == nil then
    return gate.verdict_line(verb, false, ("no item %s"):format(blocker))
  end
  if id == blocker then
    return gate.verdict_line(verb, false, "an item cannot block itself")
  end
  -- A blocker that already waits on this item, through any chain,
  -- would leave both permanently unpullable — and `next` would say
  -- nothing, because it just skips what is blocked.
  if not remove and flow.waits_on(index, blocker, id) then
    return gate.verdict_line(verb, false,
      ("%s already waits on %s — blocking would deadlock both"):format(
        blocker:sub(1, 8), id:sub(1, 8)))
  end
  local kept: {string} = {}
  local seen: {string: boolean} = {}
  local had = false
  for _, b in ipairs(it.blocked_by or {}) do
    if b == blocker then
      had = true
    elseif not seen[b] then
      seen[b] = true
      kept[#kept + 1] = b
    end
  end
  if remove and not had then
    return gate.verdict_line(verb, false,
      ("%s does not wait on %s"):format(id:sub(1, 8), blocker:sub(1, 8)))
  end
  -- Refused rather than re-recorded: a second block with a new reason
  -- would silently rewrite the first one's, and the reason is the
  -- record a later unblock is judged against.
  if not remove and had then
    return gate.verdict_line(verb, false,
      ("%s already waits on %s"):format(id:sub(1, 8), blocker:sub(1, 8)))
  end
  if not remove then
    kept[#kept + 1] = blocker
  end
  it.blocked_by = kept
  local reasons = it.block_reason or {}
  if remove then
    reasons[blocker] = nil
  else
    reasons[blocker] = reason
  end
  it.block_reason = reasons
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("%s %s on %s"):format(verb, id:sub(1, 8), blocker:sub(1, 8)))
  if not ok then
    return gate.verdict_line(verb, false, err)
  end
  local shape = "now waits on"
  if remove then
    shape = "no longer waits on"
  end
  return gate.verdict_line(verb, true,
    ("%s %s %s (%d blocker(s))"):format(id:sub(1, 8), shape,
      blocker:sub(1, 8), #kept))
end

local record gitgraph
  cmd_new: function(s: store.Store, title: string, parent: string,
  spec: string, repo: string): integer
  cmd_attach: function(s: store.Store, id: string, parent: string): integer
  cmd_block: function(s: store.Store, id: string, blocker: string,
  remove: boolean, reason: string): integer
end

local M: gitgraph = {
  cmd_new = cmd_new,
  cmd_attach = cmd_attach,
  cmd_block = cmd_block,
}

return M
