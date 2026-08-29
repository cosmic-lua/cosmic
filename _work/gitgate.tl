--- The gate between the flow rules and the verbs: the doing-bound
--- refusal a new take earns, the spec bar an item must meet before it
--- is taken, and the commit-and-publish every mutation goes through.
--- Every verb's verdict line is here too, so the read verbs need
--- nothing from the mutating ones.
---
--- The rule these share: ONE mutation is ONE commit. A refused
--- publish drops a single commit, so anything a mutation touches
--- beyond its subject travels with it rather than being committed
--- alongside.
local gh = require("_work.gh")
local flow = require("_work.flow")
local item = require("_work.item")
local prio = require("_work.priority")
local review = require("_work.review")
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

--- The refusal a bare `--force` earns, or nil when the mutation may
--- proceed. `--force` is for repair, never for flow — and a forced
--- mutation with no stated reason is indistinguishable in the log from
--- an ordinary one, which is exactly what makes that rule
--- unenforceable after the fact.
--- @param force boolean Whether --force was passed
--- @param why string The stated reason
--- @return string | nil The refusal
local function force_refusal(force: boolean, why: string): string
  if not force or (why or ""):match("%S") ~= nil then
    return nil
  end
  return "--force needs --why <reason>: a forced mutation is a repair, "
  .. "and the log has to say what it repaired"
end

--- The suffix a forced mutation adds to its commit subject, so the
--- reason travels with the change rather than with the session.
--- @param force boolean Whether --force was passed
--- @param why string The stated reason
--- @return string The suffix, "" when nothing was forced
local function forced_suffix(force: boolean, why: string): string
  if not force then
    return ""
  end
  return (" (forced: %s)"):format(why)
end

--- Save an item and publish the commit. Everything one mutation
--- touches goes in through `also`, so a lost race drops the whole
--- mutation rather than half of it. There is no post-race re-check
--- here: a lost push comes back as `store.LOST_RACE` with the
--- mutation dropped and the checkout synced, and the verb is run
--- again — which re-applies EVERY gate it decided with against the
--- merged board.
--- @param s store.Store The store
--- @param it item.Item The mutated item
--- @param body string Replacement spec markdown, or nil to leave the sidecar alone
--- @param message string Commit subject
--- @param also {item.Item} Further items the same mutation writes
--- @return boolean True once committed (and pushed, given a remote)
--- @return string Error message; `store.LOST_RACE` for a lost race
local function commit_and_publish(s: store.Store, it: item.Item, body: string,
    message: string, also?: {item.Item}): boolean, string
  local saved, serr = store.save(s, it, message, body, also)
  if not saved then
    return false, serr
  end
  return store.publish(s)
end

--- The locks a decomposition clears on the parent that just gained a
--- child: it is no longer workable, so a claim or review standing on
--- it locks nothing anyone can build.
---
--- Returned rather than saved, so the caller commits it TOGETHER with
--- the child; committed on its own it would survive a refused child.
--- @param parent item.Item The item that gained a child
--- @return {item.Item} The parent when it changed, empty otherwise
local function containered(parent: item.Item): {item.Item}
  if (parent.claim or "") == "" and (parent.reviewer or "") == "" then
    return {}
  end
  parent.claim = ""
  parent.reviewer = ""
  return {parent}
end

--- The refusal a PR handover earns from GitHub, or nil when the
--- request is worth a reviewer's time: open, not a draft, joined
--- to its item by a `Board:` line, and not already known to fail CI.
---
--- A missing token is itself a refusal rather than a silent pass —
--- a gate that waves things through when it cannot see is worse than
--- no gate — and `--force` is the way past it, exactly as with every
--- other refusal here.
--- @param s store.Store The store
--- @param id string The item being handed over
--- @param number integer The PR number
--- @param repo string | nil The item's repo field, when it carries one
--- @return string | nil The refusal
local function handover_refusal(s: store.Store, id: string,
    number: integer, repo: string | nil): string
  -- A local-only board has no pull requests to ask about, the same
  -- reason publishing there is a no-op.
  if not store.has_origin(s) then
    return nil
  end
  local p, perr = gh.pull(s, number, repo)
  if p == nil then
    return ("cannot read PR #%d: %s; --force to hand it over anyway"):format(
      number, perr)
  end
  local blocked = review.blocks_check(p, id)
  if blocked then
    return blocked
  end
  local runs, cerr = gh.checks(s, p.head_sha, repo)
  if runs == nil then
    return ("cannot read CI for %s: %s; --force to hand it over anyway")
    :format(p.head_sha:sub(1, 7), cerr)
  end
  return review.blocks_on_ci(runs)
end

--- The problems that keep an item from being taken: it must be
--- workable, placed in the priority order, its spec must fill the
--- spec-bar sections, and its own chain must be traceable. The one
--- list `check` reports and `take` enforces.
--- @param s store.Store The store
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @return {string} Problems, empty when the item meets the bar
local function ready_problems(s: store.Store, it: item.Item,
    all: {item.Item}): {string}
  local index = flow.by_id(all)
  local out = flow.item_problems(it, index)
  local r = flow.role(it, all)
  if r ~= "work" then
    out[#out + 1] = ("%s is a %s, not workable"):format(it.id:sub(1, 8), r)
  end
  -- Placement is ordinal — where does this sit against everything
  -- else — so an item nothing has been compared against, at any
  -- height, has no answer to it and cannot be queued honestly.
  if not prio.is_placed(prio.positions(all), it.id) then
    out[#out + 1] = ("%s has no position in the priority order — compare "
      .. "it against something with `gitboard compare <id> <id>`, or attach "
      .. "it under an item that has one"):format(it.id:sub(1, 8))
  end
  -- A blocker id with no item behind it never blocks (`flow.is_blocked`
  -- reasons about state the board holds), so a mistyped one reads as
  -- "sequenced" and pulls anyway. The bar is where that is caught.
  for _, b in ipairs(it.blocked_by or {}) do
    if index[b] == nil then
      out[#out + 1] = ("blocked_by names %s, which is not an item"):format(b)
    end
  end
  local body = store.read_spec(s, it.id)
  for _, gap in ipairs(flow.ready_gaps(body)) do
    out[#out + 1] = ("spec: %s"):format(gap)
  end
  return out
end

local record gitgate
  verdict_line: function(verb: string, ok: boolean, detail: string): integer
  force_refusal: function(force: boolean, why: string): string
  forced_suffix: function(force: boolean, why: string): string
  commit_and_publish: function(s: store.Store, it: item.Item, body: string,
  message: string, also?: {item.Item}): boolean, string
  containered: function(parent: item.Item): {item.Item}
  handover_refusal: function(s: store.Store, id: string,
  number: integer, repo: string | nil): string
  ready_problems: function(s: store.Store, it: item.Item,
  all: {item.Item}): {string}
end

local M: gitgate = {
  verdict_line = verdict_line,
  force_refusal = force_refusal,
  forced_suffix = forced_suffix,
  commit_and_publish = commit_and_publish,
  containered = containered,
  handover_refusal = handover_refusal,
  ready_problems = ready_problems,
}

return M
