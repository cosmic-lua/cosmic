--- The one answer to "what should I do now": a pure function from the
--- item list (plus the spec sidecars) to a single action. The graph
--- rules it reads are `_work.flow`; this module is only the decision,
--- split out so the rules module is not also the policy that consults
--- them.
---
--- There is ONE worker and one ordering. Work flows right to left —
--- whatever is closest to completion moves first, because finishing
--- beats starting — so an accepted PR is merged before a verdict is
--- written, a verdict before a build is finished, and finishing
--- before pulling. Only then does anything new enter, and those rungs
--- are `_work.intake`: triage, refinement, and decomposition.
---
--- Doing SEVERAL actions is running this again after each one. The
--- board moved, so the answer may have moved with it: nothing here
--- plans a batch, and a caller that wants five actions asks five
--- times.
---
--- Which is why every action this returns must be one the verb gates
--- would ACCEPT: a pull is offered only under the doing bound and
--- only for items that pass the spec bar, or asking again would
--- return the same refused answer forever. When nothing in flight is
--- this session's to move and nothing passes, the ordering falls
--- through to the intake half — triage and refinement are real work
--- and no gate refuses them — and if that is empty too, the answer is
--- `none` with the binding fact named.
---
--- Every queue this reads is PRIORITY order with age as the last
--- word (`_work.priority`), so "the next todo item" is really "the
--- most important one, oldest among equals".
---
--- A claim is a LOCK, and this is where that means something twice
--- over: a session that names itself is never handed work another
--- session's live claim holds, and never handed a diff another
--- session's live review claim is reading. Neither skip applies to a
--- session that names nothing: it has nobody to collide with, so it
--- is handed the claimed item anyway rather than stepped past it.
local decision = require("_work.decision")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local health = require("_work.health")
local intake = require("_work.intake")
local item = require("_work.item")
local prio = require("_work.priority")

local type Item = item.Item
local type Action = decision.Action
local type Specs = intake.Specs

--- Whether a doing item is this session's to finish: unclaimed, its
--- own, or under a claim gone stale. A live foreign claim is a
--- builder mid loop on a machine the board cannot see.
--- @param i Item The item
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @return boolean True when this session may act on it
local function is_mine(i: Item, session: string, ages: health.Ages): boolean
  if (i.claim or "") == "" or session == "" or i.claim == session then
    return true
  end
  return health.is_stale(i, ages)
end

--- What the in-flight half decided, and what it stepped over on the
--- way. The counts ride on the record rather than in further return
--- slots: an absent `action` is the interesting case, and a caller
--- cannot read past slot two.
local record Phased
  --- The decision, absent when nothing in flight is this session's.
  action: Action
  --- Items held by other sessions' live claims.
  held: integer
  --- Items under another session's live review claim.
  reviewing: integer
  --- Blocked, bar-passing todo items stepped over, and the
  --- highest-placed of them: a queue nothing can enter must surface
  --- its chain, not vanish into a generic stall.
  parked: integer
  stuck: Item
  --- Pullable items the saturated doing bound refused to offer: the
  --- bound must name itself, or the stall reads as an empty queue.
  suppressed: integer
  --- Accepted DIFFS skipped because a blocker still binds: a
  --- deliberate hold on the merge, not an empty queue either.
  merge_held: integer
  --- Accepted research HANDOVERS skipped for the same reason — no PR
  --- to hold a merge back, so it is `done ID` that stays withheld
  --- until the blocker resolves.
  done_held: integer
end

--- How many candidates one ask hands out, the primary included.
--- Sized to the concurrent-session count observed in practice: past
--- it the list is stale before anyone reaches its tail.
local CANDIDATES < const >: integer = 4

--- The doing items another session's live claim holds, as one
--- readable list ("3I3z2gOF @claude-scheduled"). Built only for the
--- terminal reason that reports them.
--- @param doing {Item} The doing queue
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @return string The held items, empty when none are
local function held_names(doing: {Item}, session: string,
    ages: health.Ages): string
  local out: {string} = {}
  for _, i in ipairs(doing) do
    if not is_mine(i, session, ages) then
      out[#out + 1] = ("%s @%s"):format(i.id:sub(1, 8), i.claim)
    end
  end
  return table.concat(out, ", ")
end

--- Whether a todo item passes the pure half of the spec bar: placed
--- in the priority order, spec sections filled. The take gate asks
--- more (blocker ids exist, the chain traces); this is the half a
--- pure walk can answer, and a candidate the gate still refuses
--- surfaces as one refused take, not a loop.
--- @param i Item The item
--- @param specs Specs Spec sidecar body, by item id
--- @param pos {string: prio.Position} Position by item id
--- @return boolean True when the item may be offered as a pull
local function passes_bar(i: Item, specs: Specs,
    pos: {string: prio.Position}): boolean
  if not prio.is_placed(pos, i.id) then
    return false
  end
  return #flow.ready_gaps(specs[i.id] or "") == 0
end

--- The decision over the ONE queue (`flow.unified`): walk it head to
--- tail, offering what this session can act on at each stage — merge,
--- review, finish, repair, pull — so rung order is the queue's stage
--- order rather than a second statement of it. The decision is a
--- LIST: the best action first and up to `CANDIDATES` more behind it,
--- so a session that loses the claim race on the first has somewhere
--- to go without another round trip.
--- @param items {Item} All items
--- @param specs Specs Spec sidecar body, by item id
--- @param index flow.Index Items by id
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @param seed string Per-session tie-break seed, "" for age order
--- @return Phased The decision and what it stepped over
local function phased_action(items: {Item}, specs: Specs, index: flow.Index,
    session: string, pos: {string: prio.Position}, ages: health.Ages,
    seed: string): Phased
  local queue = flow.unified(items, pos, seed)
  local doing_n = 0
  for _, i in ipairs(queue) do
    if flow.stage_rank(i) < flow.STAGE_REPAIR then
      doing_n = doing_n + 1
    end
  end
  local room = flow.DOING_LIMIT - doing_n
  local acts: {Action} = {}
  local held = 0
  local reviewing = 0
  local merge_held = 0
  local done_held = 0
  local parked = 0
  local stuck: Item = nil
  local suppressed = 0
  -- Ordinary pulls are capped by the room the doing bound leaves and
  -- by the candidate slots the finishing stages left behind, computed
  -- at the first ordinary todo item — the queue's stage order
  -- guarantees every earlier stage has claimed its slots by then.
  local cap = -1
  for _, i in ipairs(queue) do
    local stage = flow.stage_rank(i)
    if stage == flow.STAGE_ACCEPTED then
      if flow.is_blocked(i, index) then
        -- A blocker records landing order: hold the finish back and
        -- count it so the terminal answer can name the hold. A
        -- handover has no PR to hold a merge back — count it apart,
        -- so the terminal answer never claims a merge for it.
        if (i.result or "") ~= "" then
          done_held = done_held + 1
        else
          merge_held = merge_held + 1
        end
      elseif #acts < CANDIDATES then
        -- A handover has no PR to merge — `done` skips that read when
        -- `pr` is 0 — so its accepted reason names the verb that
        -- actually ends it rather than a merge it will never await.
        local reason = ("%s is accepted, awaiting merge — finishing beats "
          .. "starting"):format(i.id:sub(1, 8))
        if (i.result or "") ~= "" then
          reason = ("%s is accepted — `done ID` ends it"):format(
            i.id:sub(1, 8))
        end
        acts[#acts + 1] = {
          kind = "finish",
          item = i,
          reason = reason,
        }
      end
    elseif stage == flow.STAGE_REVIEW then
      if gate.distance_refusal(i, session) ~= nil then
        -- session built or specced this item — the same distance
        -- `take` refuses, so `next` never offers it either: offered
        -- to nobody here, and not another session's hold.
      elseif (i.reviewer or "") ~= "" and session ~= ""
      and i.reviewer ~= session
      and not health.is_review_stale(i, ages) then
        reviewing = reviewing + 1
      elseif #acts < CANDIDATES then
        -- What awaits the verdict is a diff or a spec, never both
        -- (`item.problems`), and the reason names which so the
        -- reviewer reaches for the right one.
        local awaiting = "a PR"
        if (i.result or "") ~= "" then
          awaiting = "a research handover"
        end
        acts[#acts + 1] = {
          kind = "review",
          item = i,
          reason = ("%s awaits a verdict — verdicts before new work"):format(
            awaiting),
        }
      end
    elseif stage == flow.STAGE_REWORK or stage == flow.STAGE_BUILDING then
      if not is_mine(i, session, ages) then
        held = held + 1
      elseif #acts < CANDIDATES then
        local whose = ""
        if session ~= "" and (i.claim or "") ~= "" and i.claim ~= session then
          whose = (" (claim stale %dh — take it over: `take ID`, on the "
            .. "record)"):format(health.stale_hours(i, ages))
        elseif (i.claim or "") ~= "" then
          whose = (" (claimed by %s)"):format(i.claim)
        end
        acts[#acts + 1] = {
          kind = "finish",
          item = i,
          reason = ("%s is %s — finish before pulling%s"):format(
            i.id:sub(1, 8), flow.substate(i), whose),
        }
      end
    elseif not passes_bar(i, specs, pos) then
      -- A todo item below the bar is refinement's to answer, and the
      -- intake half owns that; the queue steps past it silently.
    elseif flow.is_blocked(i, index) then
      -- Counted only while the bound has room: at saturation the
      -- honest bottleneck is the bound, and the terminal answer
      -- should name it rather than send a session at a chain no
      -- freed blocker could admit.
      if room > 0 then
        parked = parked + 1
        if stuck == nil then
          stuck = i
        end
      end
    elseif stage == flow.STAGE_REPAIR then
      -- A red lane's repair is the pull that cannot wait: never
      -- capped by the doing bound — the same lane bypass the take
      -- gate holds (`flow.doing_refusal`).
      if #acts < CANDIDATES then
        acts[#acts + 1] = {
          kind = "pull",
          item = i,
          reason = ("lane repair: %s"):format(i.lane),
        }
      end
    elseif room <= 0 then
      -- The bound refused to offer anything: count what it withheld,
      -- so the terminal answer names the bound, not an empty queue.
      suppressed = suppressed + 1
    else
      if cap < 0 then
        cap = math.min(room, math.max(CANDIDATES - #acts, 0))
      end
      if cap > 0 then
        acts[#acts + 1] = {
          kind = "pull",
          item = i,
          reason = "highest-priority todo item passing the spec bar "
          .. "with no open blocker",
        }
        cap = cap - 1
      end
    end
  end
  if #acts > 0 then
    local primary = acts[1]
    if #acts > 1 then
      local alts: {Action} = {}
      for k = 2, #acts do
        alts[#alts + 1] = acts[k]
      end
      primary.alternates = alts
    end
    return {action = primary, held = held, reviewing = reviewing,
      parked = parked, stuck = stuck, suppressed = suppressed,
      merge_held = merge_held, done_held = done_held}
  end
  return {held = held, reviewing = reviewing, parked = parked,
    stuck = stuck, suppressed = suppressed, merge_held = merge_held,
    done_held = done_held}
end

--- The one action to take now, right to left. Ages are optional the
--- way the session is: a caller without git in reach (the pure tests)
--- omits them, and the lease reporting stands down rather than
--- guessing.
--- @param items {Item} All items
--- @param specs Specs Spec sidecar body, by item id
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @param seed string Per-session tie-break seed, "" for age order
--- @return Action The decision
local function next_action(items: {Item}, specs: Specs, session?: string,
    ages?: health.Ages, seed?: string): Action
  local who = session or ""
  local aged = ages or {}
  local salt = seed or ""
  local index = flow.by_id(items)
  local pos = prio.positions(items)
  local ph = phased_action(items, specs, index, who, pos, aged, salt)
  local phased = ph.action
  if phased then
    return phased
  end
  -- Bar-passing work held up by blockers outranks taking anything new
  -- in: the queue is stuck, and decomposing more onto it would only
  -- deepen what cannot move.
  if ph.stuck ~= nil then
    local bottom = health.chain_root(index, ph.stuck)
    return {kind = "unblock", item = bottom,
      reason = ("%d takeable item(s) wait on open blockers; the chain "
        .. "bottoms at %s %s"):format(
        ph.parked, bottom.id:sub(1, 8), bottom.title)}
  end
  -- Pullable work the saturated bound withheld outranks intake
  -- advice: the honest answer is the bound, named — a session sent
  -- to decompose while ten builds are in flight and work waits at
  -- the gate would only deepen what cannot enter.
  if ph.suppressed > 0 then
    return {
      kind = "none",
      reason = ("doing is at %d/%d and %d pullable item(s) wait — the "
        .. "bound throttles starting; nothing here is yours until "
        .. "something in flight finishes"):format(
        #flow.in_state(items, "doing", pos), flow.DOING_LIMIT,
        ph.suppressed),
    }
  end
  -- Accepted work a blocker is deliberately holding back outranks
  -- intake advice too: the honest answer names the hold, not an
  -- empty queue that would send a session past the recorded landing
  -- order. A handover has no merge to hold — `done ID` is what stays
  -- withheld — so the wording is chosen by what is actually waiting,
  -- never a merge claimed on a handover's behalf.
  if ph.merge_held > 0 or ph.done_held > 0 then
    local total = ph.merge_held + ph.done_held
    local reason: string
    if ph.done_held == 0 then
      reason = ("%d accepted item(s) wait on open blockers — resolve "
        .. "the blockers; their merges are held"):format(total)
    elseif ph.merge_held == 0 then
      reason = ("%d accepted item(s) wait on open blockers — resolve "
        .. "the blockers; `done ID` is withheld until they do"):format(total)
    else
      reason = ("%d accepted item(s) wait on open blockers — resolve the "
        .. "blockers; %d merge(s) and %d `done ID`(s) are withheld"):format(
        total, ph.merge_held, ph.done_held)
    end
    return {kind = "none", reason = reason}
  end
  local taking = intake.intake_action(items, specs, index, pos)
  if taking then
    return taking
  end
  if ph.reviewing > 0 then
    return {
      kind = "none",
      reason = ("nothing here is this session's to move: %d item(s) are "
        .. "under another session's live review — their verdicts land "
        .. "elsewhere"):format(ph.reviewing),
    }
  end
  if ph.held > 0 then
    local doing = flow.in_state(items, "doing", pos)
    return {
      kind = "none",
      reason = ("%d item(s) are other sessions' live claims and nothing "
        .. "else fires: %s — a claim past its lease is anyone's again")
      :format(ph.held, held_names(doing, who, aged)),
    }
  end
  return {
    kind = "none",
    reason = "nothing in flight, nothing passing the spec bar, and "
    .. "nothing to triage, refine, or decompose",
  }
end

local record action
  type Action = Action
  type Phased = Phased
  type Specs = Specs
  passes_bar: function(i: Item, specs: Specs,
  pos: {string: prio.Position}): boolean
  phased_action: function(items: {Item}, specs: Specs, index: flow.Index,
  session: string, pos: {string: prio.Position}, ages: health.Ages,
  seed: string): Phased
  next_action: function(items: {Item}, specs: Specs, session?: string,
  ages?: health.Ages, seed?: string): Action
end

local M: action = {
  passes_bar = passes_bar,
  phased_action = phased_action,
  next_action = next_action,
}

return M
