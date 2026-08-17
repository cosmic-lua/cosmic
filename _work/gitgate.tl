--- The gate between the flow rules and the verbs: the WIP refusal an
--- arrival earns, the ready bar an item must meet, the items a
--- mutation writes besides its subject, and the commit-and-publish
--- that records them. Every verb's verdict line is here too, so the
--- read verbs need nothing from the mutating ones.
---
--- The rule these share: ONE mutation is ONE commit. A refused
--- publish drops a single commit, so anything a mutation touches
--- beyond its subject travels with it rather than being committed
--- alongside — a de-phased parent committed on its own would survive
--- the refusal of the child that caused it.
local flow = require("_work.flow")
local item = require("_work.item")
local store = require("_work.store")

--- Print a verb's verdict line and return its exit code.
--- @param verb string The verb
--- @param ok boolean Whether it succeeded
--- @param detail string What happened
--- @return integer 0 on success, 1 otherwise
local function verdict_line(verb: string, ok: boolean, detail: string): integer
  print(("gitboard-%s: %s"):format(verb, detail))
  if ok then
    return 0
  end
  return 1
end

--- The WIP refusal an arrival in a phase earns, or nil when it may
--- enter. The one gate `new` and `move` share.
--- @param b flow.Board The board
--- @param from string Current phase, or nil for an entry
--- @param to string Target phase
--- @return string | nil The refusal
local function wip_refusal(b: flow.Board, from: string, to: string): string
  local limit = flow.LIMITS[to]
  if limit == nil or #(b[to] or {}) < limit
  or flow.admits_over_limit(from, to) then
    return nil
  end
  return ("%s is at %d/%d — drain it before pulling more"):format(
    to, #(b[to] or {}), limit)
end

--- Save an item and publish the commit, re-checking the WIP gate
--- against the merged state when the push loses a race. Everything
--- one mutation touches goes in through `also`, so a refusal after a
--- lost race drops the whole mutation rather than half of it.
--- @param s store.Store The store
--- @param it item.Item The mutated item
--- @param spec string Replacement spec, or nil to leave the sidecar alone
--- @param message string Commit subject
--- @param from string Phase the mutation left, or nil for an entry
--- @param also {item.Item} Further items the same mutation writes
--- @return boolean True once committed (and pushed, given a remote)
--- @return string Error message
local function commit_and_publish(s: store.Store, it: item.Item, spec: string,
    message: string, from: string, also?: {item.Item}): boolean, string
  local saved, serr = store.save(s, it, message, spec, also)
  if not saved then
    return false, serr
  end
  return store.publish(s, function(): string
      local merged = store.list(s)
      if merged == nil then
        return "state repository unreadable after rebase"
      end
      -- The mutated item is already IN the merged state; ask whether its
      -- phase ended up over-limit with an arrival the limit may refuse.
      local limit = flow.LIMITS[it.phase]
      local b = flow.board(merged)
      if limit ~= nil and #(b[it.phase] or {}) > limit
      and not flow.admits_over_limit(from, it.phase) then
        return ("%s is over %d after a concurrent move"):format(it.phase, limit)
      end
      return nil
    end)
end

--- The items a decomposition writes besides the child: the parent
--- that just gained one, de-phased because it is no longer workable
--- and leaves the board. Its claim clears with the phase.
---
--- Returned rather than saved, so the caller commits it TOGETHER with
--- the child. Committed on its own it would survive a refused child —
--- a parent silently off the board with nothing decomposing it.
--- @param parent item.Item The item that gained a child
--- @return {item.Item} The parent when it changed, empty otherwise
local function dephased_container(parent: item.Item): {item.Item}
  if (parent.phase or "") == "" then
    return {}
  end
  parent.phase = ""
  parent.claim = ""
  return {parent}
end

--- The problems that keep an item from `ready`: it must be workable,
--- its spec must fill the ready-bar sections, and the whole graph
--- must be traceable. The one list `check` reports and `move ID
--- ready` enforces.
--- @param s store.Store The store
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @return {string} Problems, empty when the item meets the bar
local function ready_problems(s: store.Store, it: item.Item,
    all: {item.Item}): {string}
  local out = flow.item_problems(it, all, flow.by_id(all))
  local r = flow.role(it, all)
  if r ~= "work" then
    out[#out + 1] = ("%s is a %s, not workable"):format(it.id:sub(1, 8), r)
  end
  for _, gap in ipairs(flow.ready_gaps(store.read_spec(s, it.id))) do
    out[#out + 1] = ("spec section missing or empty: %s"):format(gap)
  end
  return out
end

--- The parent a closing item hands the board back to: the item it
--- decomposed, if that parent is now out of open children. A
--- decomposition de-phases its parent, and nothing restored the phase
--- when the decomposition finished — so the parent sat open, workable
--- and unphased, invisible to `status` and `next` while still making
--- its goal look driven. It comes back to `plan`, which is where the
--- planner verifies the outcome the children were supposed to deliver
--- and ends it.
--- @param it item.Item The item being closed
--- @param all {item.Item} Every item, as loaded before the close
--- @return {item.Item} The re-phased parent, or empty
local function rephased_parent(it: item.Item, all: {item.Item}): {item.Item}
  local parent = flow.by_id(all)[it.parent or ""]
  if parent == nil or not item.is_open(parent) or item.is_root(parent) then
    return {}
  end
  if (parent.phase or "") ~= "" then
    return {}
  end
  for _, other in ipairs(all) do
    if other.parent == parent.id and other.id ~= it.id and item.is_open(other) then
      return {}
    end
  end
  parent.phase = "plan"
  return {parent}
end

local record gitgate
  verdict_line: function(verb: string, ok: boolean, detail: string): integer
  wip_refusal: function(b: flow.Board, from: string, to: string): string
  commit_and_publish: function(s: store.Store, it: item.Item, spec: string,
  message: string, from: string, also?: {item.Item}): boolean, string
  dephased_container: function(parent: item.Item): {item.Item}
  rephased_parent: function(it: item.Item, all: {item.Item}): {item.Item}
  ready_problems: function(s: store.Store, it: item.Item, all: {item.Item}):
  {string}
end

local M: gitgate = {
  verdict_line = verdict_line,
  wip_refusal = wip_refusal,
  commit_and_publish = commit_and_publish,
  dephased_container = dephased_container,
  rephased_parent = rephased_parent,
  ready_problems = ready_problems,
}

return M
