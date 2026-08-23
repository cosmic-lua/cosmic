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
local gh = require("_work.gh")
local flow = require("_work.flow")
local item = require("_work.item")
local review = require("_work.review")
local spec = require("_work.spec")
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
---
--- `vacated` names a phase the SAME mutation empties a slot in. When
--- it is the phase being entered, occupancy is unchanged once the
--- mutation lands, and a limit that counted only the arrival would
--- refuse the very drain it exists to force: decomposing a workable
--- leaf de-phases the parent in the same commit, so a full column
--- still admits the child that empties it.
--- @param b flow.Board The board
--- @param from string Current phase, or nil for an entry
--- @param to string Target phase
--- @param vacated string Phase this mutation frees a slot in, or nil
--- @return string | nil The refusal
local function wip_refusal(b: flow.Board, from: string, to: string,
    vacated?: string): string
  local limit = flow.LIMITS[to]
  if limit == nil or #(b[to] or {}) < limit
  or flow.admits_over_limit(from, to) or vacated == to then
    return nil
  end
  return ("%s is at %d/%d — drain it before pulling more"):format(
    to, #(b[to] or {}), limit)
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

--- Save an item and publish the commit, re-checking the WIP gate
--- against the merged state when the push loses a race. Everything
--- one mutation touches goes in through `also`, so a refusal after a
--- lost race drops the whole mutation rather than half of it.
--- @param s store.Store The store
--- @param it item.Item The mutated item
--- @param body string Replacement spec markdown, or nil to leave the sidecar alone
--- @param message string Commit subject
--- @param from string Phase the mutation left; equal to `it.phase` for
---   a write that moves nothing, nil for an entry
--- @param also {item.Item} Further items the same mutation writes
--- @param force boolean True when --force authorised this mutation
--- @param vacated string Phase this mutation frees a slot in, or nil
--- @return boolean True once committed (and pushed, given a remote)
--- @return string Error message
local function commit_and_publish(s: store.Store, it: item.Item, body: string,
    message: string, from: string, also?: {item.Item}, force?: boolean,
    vacated?: string): boolean, string
  local saved, serr = store.save(s, it, message, body, also)
  if not saved then
    return false, serr
  end
  return store.publish(s, function(): string
      local merged = store.list(s)
      if merged == nil then
        return "state repository unreadable after rebase"
      end
      -- A force is an authorisation the verb already granted, and
      -- losing the push race does not withdraw it: the up-front gate
      -- was skipped, so the one here is skipped with it, or the repair
      -- a force exists to make would fail on any concurrent commit.
      if force then
        return nil
      end
      -- The mutated item is already IN the merged state; ask whether its
      -- phase ended up over-limit with an ARRIVAL the limit may refuse —
      -- a write that leaves the item where it stands must stay editable
      -- even on a full column, or the mutations that drain it (spec
      -- refinement, blocker bookkeeping) could never run. `vacated`
      -- carries the net-zero credit `wip_refusal` grants up front, so a
      -- decomposition that empties a slot in the column it enters is
      -- admitted after the rebase exactly as it was before.
      local limit = flow.LIMITS[it.phase]
      local b = flow.board(merged)
      if limit ~= nil and #(b[it.phase] or {}) > limit
      and flow.is_arrival(from, it.phase)
      and not flow.admits_over_limit(from, it.phase)
      and vacated ~= it.phase then
        return ("%s is over %d and this mutation arrives into it"):format(
          it.phase, limit)
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

--- The refusal a handover into `check` earns from GitHub, or nil when
--- the request is worth a reviewer's time: open, not a draft, joined
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
  local index = flow.by_id(all)
  local out = flow.item_problems(it, all, index)
  local r = flow.role(it, all)
  if r ~= "work" then
    out[#out + 1] = ("%s is a %s, not workable"):format(it.id:sub(1, 8), r)
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
    out[#out + 1] = ("spec section missing or empty: %s"):format(gap)
  end
  -- A blocker stated only in prose is one `next` cannot see, so the
  -- slice pulls as if nothing were sequenced before it.
  if spec.claims_blocker(body) and #(it.blocked_by or {}) == 0 then
    out[#out + 1] = "Enablement names a blocker, but blocked_by is empty — "
    .. "record it with `gitboard block <id> <blocker>`"
  end
  return out
end

--- The parent a closing item hands the board back to: the item it
--- decomposed, if that parent is now out of open children. A
--- decomposition de-phases its parent, and nothing restored the phase
--- when the decomposition finished — so the parent sat open, workable
--- and unphased, invisible to `status` and `next` while still making
--- its goal look driven. It comes back to `backlog`, where verifying
--- the outcome the children were supposed to deliver is queued and
--- placed like any other work. `backlog` and not `plan` because this
--- re-phase rides on the commit that CLOSES the last child: a bounded
--- target could refuse that mutation, and a `done` that cannot land
--- because the parent has nowhere to go is the drain refusing itself.
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
  parent.phase = "backlog"
  return {parent}
end

--- The refusal that keeps an item out of `land` without a standing
--- accept, nil when it carries one.
---
--- `land` is the phase whose one remaining act is a merge, and
--- `gitboard land` reads the item's verdict and PR to check that the
--- merge happened. An arrival carrying neither would sit where `next`
--- answers `finish` forever and `land` refuses forever, so the
--- arrival is what gets refused. The two grounds are reported
--- separately because they are different repairs: one needs a review,
--- the other needs a PR number.
--- @param it item.Item The item arriving in land
--- @return string | nil The refusal
local function land_refusal(it: item.Item): string
  if (it.verdict or "") ~= "accept" then
    local has = it.verdict
    if has == "" then
      has = "no verdict"
    end
    return ("a move into land carries a standing accept — %s has %s"):format(
      it.id:sub(1, 8), has)
  end
  if (it.pr or 0) == 0 then
    return ("a move into land names its PR — %s names none"):format(
      it.id:sub(1, 8))
  end
  return nil
end

--- Write `claim`/`pr` onto an item without moving it, and publish.
---
--- A same-phase `move` used to refuse and SWALLOW its field flags: the
--- command exited 0 and nothing said the write had not happened. So
--- correcting a claim took a leftward-then-rightward round trip, which
--- writes two transitions a flow instrument later reads as real dwell.
--- With a field to set this sets it; with none it still refuses,
--- because a move that neither moves nor writes is a typo.
--- @param s store.Store The store
--- @param it item.Item The item, already loaded and validated as workable
--- @param claim string The session to record, "" to leave it
--- @param pr integer The PR to record, 0 to leave it
--- @return integer Exit code
local function set_in_place(s: store.Store, it: item.Item, claim: string,
    pr: integer): integer
  local where = it.phase
  if (claim or "") == "" and (pr or 0) == 0 then
    return verdict_line("move", false,
      ("%s is already in %s"):format(it.id:sub(1, 8), where))
  end
  if (claim or "") ~= "" then
    it.claim = claim
  end
  if (pr or 0) ~= 0 then
    it.pr = pr
  end
  local wrong = item.problems(it)
  if #wrong > 0 then
    return verdict_line("move", false, table.concat(wrong, "; "))
  end
  local ok, err = commit_and_publish(s, it, nil,
    ("set %s in %s"):format(it.id:sub(1, 8), where), where)
  if not ok then
    return verdict_line("move", false, err)
  end
  return verdict_line("move", true,
    ("%s stays in %s"):format(it.id:sub(1, 8), where))
end

local record gitgate
  verdict_line: function(verb: string, ok: boolean, detail: string): integer
  wip_refusal: function(b: flow.Board, from: string, to: string,
  vacated?: string): string
  force_refusal: function(force: boolean, why: string): string
  forced_suffix: function(force: boolean, why: string): string
  commit_and_publish: function(s: store.Store, it: item.Item, body: string,
  message: string, from: string, also?: {item.Item}, force?: boolean,
  vacated?: string): boolean, string
  dephased_container: function(parent: item.Item): {item.Item}
  rephased_parent: function(it: item.Item, all: {item.Item}): {item.Item}
  handover_refusal: function(s: store.Store, id: string,
  number: integer, repo: string | nil): string
  land_refusal: function(it: item.Item): string
  set_in_place: function(s: store.Store, it: item.Item, claim: string,
  pr: integer): integer
  ready_problems: function(s: store.Store, it: item.Item,
  all: {item.Item}): {string}
end

local M: gitgate = {
  verdict_line = verdict_line,
  wip_refusal = wip_refusal,
  force_refusal = force_refusal,
  forced_suffix = forced_suffix,
  commit_and_publish = commit_and_publish,
  dephased_container = dephased_container,
  rephased_parent = rephased_parent,
  handover_refusal = handover_refusal,
  land_refusal = land_refusal,
  set_in_place = set_in_place,
  ready_problems = ready_problems,
}

return M
