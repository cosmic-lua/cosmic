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
  --- Accepted, awaiting-merge items skipped because a blocker still
  --- binds: a deliberate hold, not an empty queue either.
  merge_held: integer
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

--- The first open, unclaimed, unblocked, bar-passing lane-repair item
--- in queue order, or nil. The todo queue already excludes claimed
--- items, so "unclaimed" needs no separate check; a blocked one waits
--- on its blocker like any other pull rather than jumping it. The
--- spec bar applies here exactly as it does to an ordinary pull —
--- `_work.lanes.file_repair` mints every repair with a sidecar that
--- clears it, so this is never the reason a live repair goes unoffered;
--- what it catches is a hand-edited or pre-migration item with none,
--- which `take` would refuse anyway. Offering only what `take` would
--- admit is the whole point: a repair `next` offers and `take` refuses
--- is the gap this closes.
--- @param todo {Item} The todo queue, already priority-ordered
--- @param specs Specs Spec sidecar body, by item id
--- @param index flow.Index Items by id
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The repair item to offer
local function lane_repair(todo: {Item}, specs: Specs, index: flow.Index,
    pos: {string: prio.Position}): Item | nil
  for _, i in ipairs(todo) do
    if (i.lane or "") ~= "" and not flow.is_blocked(i, index)
    and passes_bar(i, specs, pos) then
      return i
    end
  end
  return nil
end

--- The in-flight half of the ordering — land, review, finish — and
--- the pull that starts new work under the doing bound. The decision
--- is a LIST: the best action first and up to `CANDIDATES` more
--- behind it, so a session that loses the claim race on the first has
--- somewhere to go without another round trip. Rung order holds
--- within the list.
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
  local doing = flow.in_state(items, "doing", pos, seed)
  local acts: {Action} = {}
  local held = 0
  local reviewing = 0
  local merge_held = 0
  for _, i in ipairs(doing) do
    if flow.substate(i) == "accepted" then
      if flow.is_blocked(i, index) then
        -- A blocker records landing order, not a build or review to
        -- finish: hold this merge back rather than offer it, and
        -- count it so the terminal answer can name the hold.
        merge_held = merge_held + 1
      elseif #acts < CANDIDATES then
        acts[#acts + 1] = {
          kind = "finish",
          item = i,
          reason = ("%s is accepted, awaiting merge — finishing beats "
            .. "starting"):format(i.id:sub(1, 8)),
        }
      end
    end
  end
  for _, i in ipairs(doing) do
    if flow.substate(i) == "review" then
      if gate.distance_refusal(i, session) ~= nil then
        -- session built or specced this item — the same distance
        -- `take` refuses, so `next` never offers it either: offered to
        -- nobody here, and not counted as another session's hold,
        -- because it is not one.
      elseif (i.reviewer or "") ~= "" and session ~= "" and i.reviewer ~= session
      and not health.is_review_stale(i, ages) then
        reviewing = reviewing + 1
      elseif #acts < CANDIDATES then
        acts[#acts + 1] = {
          kind = "review",
          item = i,
          reason = "a PR awaits a verdict — verdicts before new work",
        }
      end
    end
  end
  for _, i in ipairs(doing) do
    local sub = flow.substate(i)
    if sub == "building" or sub == "rework" then
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
            i.id:sub(1, 8), sub, whose),
        }
      end
    end
  end
  -- A red lane's repair is the pull that cannot wait: offered ahead
  -- of ordinary pulls (below finishing, above starting), and never
  -- capped by the doing bound the way an ordinary pull is — the take
  -- gate admits it the same way (`flow.doing_refusal`'s lane bypass).
  local todo = flow.in_state(items, "todo", pos, seed)
  local repair = lane_repair(todo, specs, index, pos)
  if repair ~= nil and #acts < CANDIDATES then
    acts[#acts + 1] = {
      kind = "pull",
      item = repair,
      reason = ("lane repair: %s"):format(repair.lane),
    }
  end
  local parked = 0
  local stuck: Item = nil
  local suppressed = 0
  local room = flow.DOING_LIMIT - #doing
  if room > 0 then
    local cap = math.min(room, CANDIDATES - #acts)
    for _, i in ipairs(todo) do
      if i ~= repair and passes_bar(i, specs, pos) then
        if flow.is_blocked(i, index) then
          parked = parked + 1
          if stuck == nil then
            stuck = i
          end
        elseif cap > 0 then
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
  else
    -- The bound refused to offer anything: count what it withheld,
    -- so the terminal answer can name the bound instead of reading
    -- as an empty queue.
    for _, i in ipairs(todo) do
      if i ~= repair and passes_bar(i, specs, pos)
      and not flow.is_blocked(i, index) then
        suppressed = suppressed + 1
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
      merge_held = merge_held}
  end
  return {held = held, reviewing = reviewing, parked = parked,
    stuck = stuck, suppressed = suppressed, merge_held = merge_held}
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
  -- order.
  if ph.merge_held > 0 then
    return {
      kind = "none",
      reason = ("%d accepted item(s) wait on open blockers — resolve "
        .. "the blockers; their merges are held"):format(ph.merge_held),
    }
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
