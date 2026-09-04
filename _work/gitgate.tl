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
local health = require("_work.health")
local item = require("_work.item")
local owner = require("_work.gitowner")
local prio = require("_work.priority")
local publish = require("_work.publish")
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

--- Seconds since one item's claim was last touched, for the lease
--- checks — shared by every takeover path (`take`, `take_review`,
--- `drop`) and the one-claim-per-session guard alike.
--- @param s store.Store The store
--- @param it item.Item The item
--- @return health.Ages Seconds since last commit, for this item alone
local function age_of(s: store.Store, it: item.Item): health.Ages
  local ages: health.Ages = {}
  local now = os.time()
  local t = publish.touched_at(s, it.id)
  if t ~= nil and t <= now then
    ages[it.id] = now - t
  end
  return ages
end

--- Whether `session` already built or specced this item — the
--- distance a review needs from either half of the decision: the
--- diff (`builders`) or the spec it answers to (`speccers`). Shared by
--- the review-claim derivation, which refuses outright with no escape
--- (a fresh context cannot be forced into existing), and verdict
--- recording, which allows `--force --why` as the audited repair path.
--- @param it item.Item The item under review
--- @param session string The session asking
--- @return string | nil The refusal
local function distance_refusal(it: item.Item, session: string): string | nil
  if (session or "") == "" then
    return nil
  end
  for _, name in ipairs(it.builders or {}) do
    if name == session then
      return ("REFUSED: %s built/specced %s — the verdict needs a fresh "
        .. "context; recording it anyway needs --force --why"):format(
        session, it.id:sub(1, 8))
    end
  end
  for _, name in ipairs(it.speccers or {}) do
    if name == session then
      return ("REFUSED: %s built/specced %s — the verdict needs a fresh "
        .. "context; recording it anyway needs --force --why"):format(
        session, it.id:sub(1, 8))
    end
  end
  return nil
end

--- The visibly unactioned finishing work standing between a session
--- and anything the unified order ranks below it: items at
--- `flow.STAGE_REVIEW` with no reviewer recorded, at a distance from
--- the session (the same `distance_refusal` the review claim asks).
--- Review is the one stage whose neglect the board can SEE — an
--- empty reviewer field is proof nobody is on it — where an accepted
--- item's merge and a claimed build leave no such trace, so only
--- review debt turns the ranking into a refusal. Deliberately LAXER
--- than `next`'s review rung on one point: any recorded reviewer
--- clears an item here, stale or live, because staleness needs
--- per-item git ages this gate does not read — a stale review still
--- drains through `next`, which offers taking it over ahead of any
--- pull. Laxer is the safe direction: every pull `next` offers as a
--- primary must pass this gate.
--- @param items {item.Item} All items
--- @param session string The session asking to pull
--- @return {item.Item} The debt, possibly empty
local function review_debt(items: {item.Item},
    session: string): {item.Item}
  local out: {item.Item} = {}
  for _, i in ipairs(items) do
    if item.is_open(i) and flow.role(i, items) == "work"
    and flow.stage_rank(i) == flow.STAGE_REVIEW
    and (i.reviewer or "") == ""
    and distance_refusal(i, session) == nil then
      out[#out + 1] = i
    end
  end
  return out
end

--- The unified order as a take refusal, nil while the session may
--- take: refused when some debt item outranks the take by STAGE
--- (`flow.stage_rank`) — the same order `next` serves the head of,
--- so the refusal is the ranking made binding, not a second rule.
--- The named review is the debt's head in queue order. One stated
--- carve-out: a lane-repair take never asks — the same arrival the
--- doing bound never holds back, because a red lane's fix cannot
--- wait on a review queue it did not grow.
--- @param items {item.Item} All items
--- @param session string The session asking to pull
--- @param taking item.Item The item about to be taken
--- @return string | nil The refusal
local function review_debt_refusal(items: {item.Item}, session: string,
    taking: item.Item): string | nil
  if (taking.lane or "") ~= "" then
    return nil
  end
  local debt = review_debt(items, session)
  local ahead = 0
  for _, d in ipairs(debt) do
    if flow.stage_rank(d) < flow.stage_rank(taking) then
      ahead = ahead + 1
    end
  end
  if ahead == 0 then
    return nil
  end
  local first = debt[1]
  for _, i in ipairs(flow.unified(items, prio.positions(items))) do
    if flow.stage_rank(i) == flow.STAGE_REVIEW
    and (i.reviewer or "") == ""
    and distance_refusal(i, session) == nil then
      first = i
      break
    end
  end
  local noun = "diff"
  if (first.result or "") ~= "" then noun = "handover" end
  return ("%d %s(s) await a verdict you can give and outrank this "
    .. "take — verdicts before new work: `take %s` claims the first; "
    .. "a recorded reviewer clears it"):format(ahead, noun, first.id:sub(1, 8))
end

--- The refusal a NEW claim earns when `session` already holds a live
--- claim on another open item, or nil when it is free to claim. One
--- claim per name, so two runners sharing a session name collide
--- loudly here instead of silently corrupting mutual exclusion. Never
--- forced away — a collision is never repair, unlike a takeover — and
--- never asked about the item being claimed itself: a re-take of a
--- session's own item names no OTHER item and never refuses here.
--- @param s store.Store The store
--- @param all {item.Item} Every item
--- @param id string The item being claimed
--- @param session string The claiming session
--- @return string | nil The refusal
local function second_claim_refusal(s: store.Store, all: {item.Item},
    id: string, session: string): string | nil
  if (session or "") == "" then
    return nil
  end
  for _, other in ipairs(all) do
    if other.id ~= id and item.is_open(other) and other.claim == session
    and not health.is_stale(other, age_of(s, other)) then
      return ("REFUSED: %s already holds %s — one claim per worker; drop "
        .. "it or finish it first"):format(session, other.id:sub(1, 8))
    end
  end
  return nil
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
--- @return boolean True once committed (and pushed, given a remote), or a no-op
--- @return string Error; `store.LOST_RACE` for a lost race, `store.is_noop` for a no-op
local function commit_and_publish(s: store.Store, it: item.Item, body: string,
    message: string, also?: {item.Item}): boolean, string
  local saved, serr = store.save(s, it, message, body, also)
  if not saved or store.is_noop(serr) then
    return saved, serr
  end
  return publish.publish(s)
end

--- The locks a decomposition clears on the parent that just gained a
--- child: it is no longer workable, so a claim or review standing on
--- it locks nothing anyone can build. A hold clears the same way: new
--- evidence under a held root is the claim that its win condition no
--- longer holds, so the marker leaves in the commit that files it.
---
--- Returned rather than saved, so the caller commits it TOGETHER with
--- the child; committed on its own it would survive a refused child.
--- @param parent item.Item The item that gained a child
--- @return {item.Item} The parent when it changed, empty otherwise
local function containered(parent: item.Item): {item.Item}
  if (parent.claim or "") == "" and (parent.reviewer or "") == ""
  and not parent.is_held then
    return {}
  end
  parent.claim = ""
  parent.reviewer = ""
  parent.is_held = false
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

--- The repositories a spec reaches (`spec.reached_repos`) that are
--- neither the item's own `repo` field nor declared under its
--- `## Access` heading (`spec.declared_repos`) — an undeclared source
--- strands a claim before it starts and a review just as surely,
--- since neither session's grant is anything this board can see. The
--- item's own `repo` is the one exemption that needs no declaring: it
--- is where the diff lands, not a source read on the side.
--- @param it item.Item The item
--- @param body string Its spec sidecar
--- @return {string} Undeclared repo slugs, in first-seen order
local function undeclared_repos(it: item.Item, body: string): {string}
  local declared = spec.declared_repos(body)
  local own = (it.repo or ""):lower()
  local out: {string} = {}
  for _, repo in ipairs(spec.reached_repos(body)) do
    if repo ~= own and not declared[repo] then
      out[#out + 1] = repo
    end
  end
  return out
end

--- The problems that keep an item from being taken: it must be
--- workable, placed in the priority order, its spec must fill the
--- spec-bar sections, its own chain must be traceable, and its
--- `repo` must be somewhere a claiming session can land a diff. The
--- one list `check` reports and `take` enforces.
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
  for _, repo in ipairs(undeclared_repos(it, body)) do
    out[#out + 1] = ("spec reaches %s with no declared read access — name "
      .. "it under \"## Access\"; undeclared, it strands the claim now "
      .. "and the review just as surely"):format(repo)
  end
  -- The item's own `repo` is exempt above because it is where the diff
  -- lands — which is exactly why it must be somewhere the claiming
  -- session can land one (`_work.gitowner`).
  local foreign = owner.repo_problem(s, it.repo, body, it.id)
  if foreign then
    out[#out + 1] = foreign
  end
  return out
end

local record gitgate
  verdict_line: function(verb: string, ok: boolean, detail: string): integer
  force_refusal: function(force: boolean, why: string): string
  forced_suffix: function(force: boolean, why: string): string
  base_refusal: function(current: string, base: string, id: string): string
  spec_refusal: function(it: item.Item, session: string): string
  age_of: function(s: store.Store, it: item.Item): health.Ages
  distance_refusal: function(it: item.Item, session: string): string
  review_debt: function(items: {item.Item}, session: string): {item.Item}
  review_debt_refusal: function(items: {item.Item}, session: string,
  taking: item.Item): string
  second_claim_refusal: function(s: store.Store, all: {item.Item},
  id: string, session: string): string
  commit_and_publish: function(s: store.Store, it: item.Item, body: string,
  message: string, also?: {item.Item}): boolean, string
  containered: function(parent: item.Item): {item.Item}
  handover_refusal: function(s: store.Store, id: string,
  number: integer, repo: string | nil, base: string | nil): string
  pr_collision_refusal: function(all: {item.Item}, id: string,
  number: integer): string
  undeclared_repos: function(it: item.Item, body: string): {string}
  ready_problems: function(s: store.Store, it: item.Item,
  all: {item.Item}): {string}
end

local M: gitgate = {
  verdict_line = verdict_line,
  force_refusal = force_refusal,
  forced_suffix = forced_suffix,
  base_refusal = base_refusal,
  spec_refusal = spec_refusal,
  age_of = age_of,
  distance_refusal = distance_refusal,
  review_debt = review_debt,
  review_debt_refusal = review_debt_refusal,
  second_claim_refusal = second_claim_refusal,
  commit_and_publish = commit_and_publish,
  containered = containered,
  handover_refusal = handover_refusal,
  pr_collision_refusal = pr_collision_refusal,
  undeclared_repos = undeclared_repos,
  ready_problems = ready_problems,
}

return M
