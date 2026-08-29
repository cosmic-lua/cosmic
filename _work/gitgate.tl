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
local fs = require("cosmic.fs")
local gh = require("_work.gh")
local flow = require("_work.flow")
local item = require("_work.item")
local prio = require("_work.priority")
local publish = require("_work.publish")
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

--- The refusal a stale base earns, or nil when the write may proceed.
---
--- `spec` replaces the WHOLE sidecar, so the write has to say which
--- text it is replacing. The push half is a compare-and-swap already,
--- but it compares COMMITS: a session that synced between reading a
--- spec and writing its refinement back rebases cleanly over the write
--- it is erasing. The base is the missing half — the text the caller
--- read, compared against the text that is there.
---
--- One rule covers both calls, because an item with no sidecar reads
--- back "" and that is what a call with no `--base` compares against:
--- the FIRST write of a spec needs no flag, and every later one does.
--- @param current string The sidecar as it stands
--- @param base string The base file's path, "" when none was given
--- @param id string The item's full id, for the message and the path
--- @return string | nil The refusal
local function base_refusal(current: string, base: string,
    id: string): string | nil
  local claimed = ""
  if base ~= "" then
    local read, rerr = fs.read(base)
    if read == nil then
      return ("REFUSED: --base %s is unreadable: %s"):format(base, rerr)
    end
    claimed = read
  end
  if claimed == current then
    return nil
  end
  local id8 = id:sub(1, 8)
  if base == "" then
    return ("REFUSED: %s already has a spec — pass --base FILE holding the "
      .. "text you read; a write with no base is last-write-wins"):format(id8)
  end
  return ("REFUSED: %s's spec changed since you read it — re-read "
    .. "items/%s.md, re-apply your edit, and pass the re-read text as "
    .. "--base (the trail is `gitboard show %s`)"):format(id8, id, id8)
end

--- The refusal a foreign session's spec write earns on an item that is
--- in flight under someone else's claim, or nil when the write may
--- proceed. An in-flight item's spec is its claim holder's to move —
--- spec-only rework answering a bounce is a designed path, at any
--- point in the holder's own build — and a write to an unclaimed item
--- (todo, or dropped back to it) is nobody's to gate. Only a foreign
--- LIVE claim earns this: rewriting it needs `--force --why`, same as
--- taking one over.
--- @param it item.Item The item whose spec would be rewritten
--- @param session string The session making the write
--- @return string | nil The refusal
local function spec_refusal(it: item.Item, session: string): string | nil
  if not flow.is_doing(it) then
    return nil
  end
  if (it.claim or "") == "" then
    return nil
  end
  if it.claim == (session or "") then
    return nil
  end
  return ("REFUSED: %s is claimed by %s — rewriting another session's "
    .. "live build needs --force --why"):format(it.id:sub(1, 8), it.claim)
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
  return publish.publish(s)
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
--- to its item by a `Board:` line, targeting the item's own `base`
--- when it names one, and not already known to fail CI.
---
--- A missing token is itself a refusal rather than a silent pass —
--- a gate that waves things through when it cannot see is worse than
--- no gate — and `--force` is the way past it, exactly as with every
--- other refusal here.
--- @param s store.Store The store
--- @param id string The item being handed over
--- @param number integer The PR number
--- @param repo string | nil The item's repo field, when it carries one
--- @param base string | nil The item's base field, when it carries one
--- @return string | nil The refusal
local function handover_refusal(s: store.Store, id: string,
    number: integer, repo: string | nil, base: string | nil): string
  -- A local-only board has no pull requests to ask about, the same
  -- reason publishing there is a no-op.
  if not publish.has_origin(s) then
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
  local off_base = review.blocks_base(p, base or "")
  if off_base then
    return off_base
  end
  local runs, cerr = gh.checks(s, p.head_sha, repo)
  if runs == nil then
    return ("cannot read CI for %s: %s; --force to hand it over anyway")
    :format(p.head_sha:sub(1, 7), cerr)
  end
  return review.blocks_on_ci(runs)
end

--- The refusal a PR handover earns when another OPEN item already
--- records the same number, or nil when it is free to take. One pull
--- request couples one item's verdict, so recording a number an open
--- item already holds would let a single diff answer for two — a DONE
--- item's PR is spent and names nothing.
--- @param all {item.Item} Every item
--- @param id string The item recording the PR
--- @param number integer The PR number being recorded
--- @return string | nil The refusal
local function pr_collision_refusal(all: {item.Item}, id: string,
    number: integer): string | nil
  for _, other in ipairs(all) do
    if other.id ~= id and item.is_open(other) and (other.pr or 0) == number then
      return ("PR #%d is already %s's — one PR, one item; --force --why "
        .. "to override for repair"):format(number, other.id:sub(1, 8))
    end
  end
  return nil
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
  base_refusal: function(current: string, base: string, id: string): string
  spec_refusal: function(it: item.Item, session: string): string
  commit_and_publish: function(s: store.Store, it: item.Item, body: string,
  message: string, also?: {item.Item}): boolean, string
  containered: function(parent: item.Item): {item.Item}
  handover_refusal: function(s: store.Store, id: string,
  number: integer, repo: string | nil, base: string | nil): string
  pr_collision_refusal: function(all: {item.Item}, id: string,
  number: integer): string
  ready_problems: function(s: store.Store, it: item.Item,
  all: {item.Item}): {string}
end

local M: gitgate = {
  verdict_line = verdict_line,
  force_refusal = force_refusal,
  forced_suffix = forced_suffix,
  base_refusal = base_refusal,
  spec_refusal = spec_refusal,
  commit_and_publish = commit_and_publish,
  containered = containered,
  handover_refusal = handover_refusal,
  pr_collision_refusal = pr_collision_refusal,
  ready_problems = ready_problems,
}

return M
