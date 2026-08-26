--- The one answer to "what should I do now": a pure function from the
--- item list to a single action. The graph rules it reads are
--- `_work.flow`; this module is only the decision, split out so the
--- rules module is not also the policy that consults them.
---
--- There is ONE worker and one ordering. Work flows right to left —
--- whatever is closest to completion moves first, because finishing
--- beats starting — so an accepted PR is merged before a verdict is
--- written, a verdict before work is finished, and finishing before
--- pulling. Only then does anything new enter, and those rungs are
--- `_work.intake`: a triage drain past its bound, refinement of what
--- is already committed, promotion of the next thing, a sweep of what
--- has rotted, the triage remainder, and decomposition last. An inbox
--- nobody empties is a channel that only takes, which is why the
--- bound jumps its queue ahead of refinement.
---
--- Doing SEVERAL actions is running this again after each one. The
--- board moved, so the answer may have moved with it: nothing here
--- plans a batch, and a caller that wants five actions asks five
--- times.
---
--- Which is why every action this returns must be one the verb gates
--- would ACCEPT. An action naming a move the WIP gate refuses does not
--- move the board, so asking again returns the same answer, and the
--- loop never terminates. Each branch below therefore checks the phase
--- its move ARRIVES in, not just the one it leaves: `finish` from `do`
--- and `pull` both need room in `check`, and `pull` needs room in `do`
--- as well. When the room is not there the ordering falls through to
--- the intake half — refining, triage and decomposition are real work
--- and no gate refuses them — and if that is empty too, the answer is
--- `none` with the binding phase named. A stall the session can see is
--- worth more than an instruction it cannot carry out.
---
--- Every queue this reads is PRIORITY order with age as the last
--- word (`_work.priority`), so "the next ready item" is really "the
--- most important one, oldest among equals".
---
--- A claim is a LOCK, and this is where that means something twice
--- over. `do` holds five because five sessions run at once, so a
--- session that names itself is never handed work another session
--- claimed. The claim survives the move into `check`, so it also
--- names who BUILT the thing awaiting a verdict — and this hands that
--- item to somebody else, because a review is worth what the distance
--- between builder and reviewer is worth. Neither skip applies to a
--- session that names nothing: it has nobody to collide with and no
--- distance to keep, and sees every claim rendered in the reason
--- instead.
local decision = require("_work.decision")
local flow = require("_work.flow")
local health = require("_work.health")
local intake = require("_work.intake")
local item = require("_work.item")
local prio = require("_work.priority")

local type Item = item.Item
local type Action = decision.Action

--- Whether an item carries a standing verdict that sent it BACK. A
--- `request changes` verdict returns the item to `do` with the claim
--- naming who built it. A LIVE claim over rework is the builder mid
--- build-test-push loop — the board sees none of that activity, so
--- liveness is the lease's to judge, the same as every other claim;
--- a rework whose claimant stopped waking surfaces when the lease
--- expires and is taken over through the same --force takeover any
--- stale claim gets. This predicate only decorates the takeover
--- guidance with whose build it was.
--- @param i Item The item
--- @return boolean True when a non-accept verdict stands on it
local function is_rework(i: Item): boolean
  local verdict = i.verdict or ""
  return verdict ~= "" and verdict ~= "accept"
end

--- The first item of a phase this session may take, and how many it
--- stepped over because another session holds them. An unclaimed item
--- is anyone's; a session's own claim is its own; with no session
--- named nothing is held.
---
--- Rework is anyone's too. A claim is a lock on work in progress, and
--- a send-back ends the progress it was locking: the item is back in
--- the queue with concrete gaps named on its PR, which is a thing any
--- session can pick up. The claim stays put rather than being cleared,
--- because it is also the record of who BUILT the item and that is
--- what keeps the next verdict at arm's length — so a session taking
--- over a rework hands it back with `--claim <itself>`, which the
--- reason line says.
---
--- A STALE claim is anyone's for the same reason: the lease
--- (`_work.health`) expiring means the claiming session stopped
--- moving the board, and the sessions that claim work here cannot
--- return an item when they die — so the lock outliving its holder is
--- the expected failure, not an edge case. Absent ages disable the
--- lease rather than guessing.
--- @param b flow.Board The board
--- @param phase string The phase to draw from
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return Item | nil The item to act on
--- @return integer How many held items were skipped
local function unheld(b: flow.Board, phase: string, session: string,
    pos: {string: prio.Position}, ages: health.Ages): Item | nil, integer
  local first: Item = nil
  local held = 0
  for _, i in ipairs(flow.queued(b, phase, pos)) do
    if (i.claim or "") ~= "" and session ~= "" and i.claim ~= session
    and not health.is_stale(i, ages) then
      held = held + 1
    elseif first == nil then
      first = i
    end
  end
  return first, held
end

--- The `do` items another session holds, as one readable list
--- ("3I3z2gOF @claude-scheduled"). Built only for the terminal reason
--- that reports them, so the ordering's hot path never pays for it.
--- @param b flow.Board The board
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return string The held items, empty when none are
local function held_names(b: flow.Board, session: string,
    pos: {string: prio.Position}, ages: health.Ages): string
  local out: {string} = {}
  for _, i in ipairs(flow.queued(b, "do", pos)) do
    if (i.claim or "") ~= "" and session ~= "" and i.claim ~= session
    and not health.is_stale(i, ages) then
      out[#out + 1] = ("%s @%s"):format(i.id:sub(1, 8), i.claim)
    end
  end
  return table.concat(out, ", ")
end

--- Whether `session` has built this item: it holds the claim now, or
--- it held the claim at some point.
---
--- The claim alone is not the answer. It is a LEASE — a return clears
--- it and the next pull writes a new one — so an item built by A,
--- returned, and re-pulled by B reads as B's while A's diff is what
--- sits in `check`. `builders` is the durable half, and consulting
--- both is what makes "no session accepts its own work" hold across a
--- handover rather than only while nobody collides.
--- @param i Item The item in check
--- @param session string This session's name, never ""
--- @return boolean True when this session built it
local function built_by(i: Item, session: string): boolean
  if (i.claim or "") == session then
    return true
  end
  for _, name in ipairs(i.builders or {}) do
    if name == session then
      return true
    end
  end
  return false
end

--- The first item awaiting a verdict that this session did not build,
--- and how many it stepped over as its own. Near-inverse of `unheld`:
--- there, another session holding the LEASE is what disqualifies an
--- item; here, this session having ever held it is.
--- @param b flow.Board The board
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The item to review
--- @return integer How many of this session's own were skipped
local function reviewable(b: flow.Board, session: string,
    pos: {string: prio.Position}): Item | nil, integer
  local first: Item = nil
  local mine = 0
  for _, i in ipairs(flow.queued(b, "check", pos)) do
    if session ~= "" and built_by(i, session) then
      mine = mine + 1
    elseif first == nil then
      first = i
    end
  end
  return first, mine
end

--- The first ready item this session may pull: no open blocker, and
--- not held by another session.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @return Item | nil The pullable item
local function first_pullable(b: flow.Board, index: flow.Index,
    session: string, pos: {string: prio.Position}): Item | nil
  for _, i in ipairs(flow.queued(b, "ready", pos)) do
    local held = (i.claim or "") ~= "" and session ~= "" and i.claim ~= session
    if not held and not flow.is_blocked(i, index) then
      return i
    end
  end
  return nil
end

--- What the phased half of the ordering decided, and what it stepped
--- over on the way. The counts ride on the record rather than in
--- further return slots: an absent `action` is the interesting case,
--- and a caller cannot read past slot two.
local record Phased
  --- The decision, absent when the board holds nothing this session
  --- may move.
  action: Action
  --- Items held by other sessions.
  held: integer
  --- Items in `check` this session built.
  mine: integer
end

--- The phased half of the ordering: land, review, finish, pull.
--- @param b flow.Board The board
--- @param index flow.Index Items by id
--- @param session string This session's name, "" when unnamed
--- @param pos {string: prio.Position} Position by item id
--- @param ages health.Ages Seconds since last board commit, by id
--- @return Phased The decision and what it stepped over
local function phased_action(b: flow.Board, index: flow.Index, session: string,
    pos: {string: prio.Position}, ages: health.Ages): Phased
  local landing = flow.queued(b, "land", pos)
  if #landing > 0 then
    return {action = {
        kind = "finish",
        item = landing[1],
        reason = ("land holds %d — %s is accepted, awaiting merge"):format(
          #landing, landing[1].id:sub(1, 8)),
      }, held = 0, mine = 0}
  end
  local judging, mine = reviewable(b, session, pos)
  if judging then
    return {action = {
        kind = "review",
        item = judging,
        reason = "check is the rightmost phase awaiting a decision — "
        .. "verdicts before new work",
      }, held = 0, mine = mine}
  end
  -- A handover into `check` is a move the WIP gate refuses once check
  -- is full, and pulling adds work whose only exit is that same move.
  -- Reaching here with check full means every item in it is this
  -- session's (`reviewable` would have returned any other), so no
  -- verdict this session may write can drain it. Handing out either
  -- action would name a move the gate rejects, and `next` would repeat
  -- it forever; fall through to the intake half instead, which is
  -- still real work, and let `next_action` say what is holding.
  local handover_open = #(b["check"] or {}) < flow.LIMITS["check"]
  -- And `do` has to have room for the pull itself. Reaching the pull
  -- branch with `do` full means every slot is another session's claim
  -- (an unheld one would have been finished above), so the limit binds
  -- against this session and the move would be refused.
  local pull_open = #(b["do"] or {}) < flow.LIMITS["do"]
  local doing, held = unheld(b, "do", session, pos, ages)
  if doing and handover_open then
    local whose = ""
    if session ~= "" and (doing.claim or "") ~= ""
    and doing.claim ~= session then
      -- An offered item holding another session's claim is stale by
      -- construction (a live foreign claim is held). The takeover
      -- moves the claim, so the guidance carries everything the move
      -- guard demands — --force --why, on the record.
      local kind = is_rework(doing) and
      ("rework of %s's build; "):format(doing.claim) or ""
      whose = (" (%sclaim stale %dh — take it over: move it with "
        .. "--claim %s --force --why <reason>)"):format(kind,
        health.stale_hours(doing, ages), session)
    elseif (doing.claim or "") ~= "" then
      whose = (" (claimed by %s)"):format(doing.claim)
    end
    return {action = {
        kind = "finish",
        item = doing,
        reason = ("do holds %d/%d — finish before pulling%s"):format(
          #(b["do"] or {}), flow.LIMITS["do"], whose),
      }, held = held, mine = mine}
  end
  local pullable = first_pullable(b, index, session, pos)
  if pullable and handover_open and pull_open then
    return {action = {
        kind = "pull",
        item = pullable,
        reason = "highest-priority ready item with no open blocker",
      }, held = held, mine = mine}
  end
  return {held = held, mine = mine}
end

--- The one action to take now, right to left. Ages are optional the
--- way the session is: a caller without git in reach (the pure tests)
--- omits them, and the lease and starvation reporting stand down
--- rather than guessing.
--- @param items {Item} All items
--- @param session string This session's name, "" when unnamed
--- @param ages health.Ages Seconds since last board commit, by id
--- @return Action The decision
local function next_action(items: {Item}, session?: string,
    ages?: health.Ages): Action
  local who = session or ""
  local aged = ages or {}
  local b = flow.board(items)
  local index = flow.by_id(items)
  local pos = prio.positions(items)
  local ph = phased_action(b, index, who, pos, aged)
  local phased = ph.action
  if phased then
    return phased
  end
  -- Starvation outranks the intake half: with every ready item
  -- blocked, a promotion feeds a column no pull can drain, and the
  -- refinement it displaces resumes the moment the chain root moves.
  -- `next` names the root instead of silently skipping the blocked
  -- (which is how a stalled board used to answer "refine" forever).
  local root, starving = health.starved(b, index, aged)
  if root ~= nil then
    return {kind = "unblock", item = root, reason = starving}
  end
  local taking = intake.intake_action(items, b, index, pos, aged)
  if taking then
    return taking
  end
  if ph.mine > 0 then
    -- Full and all this session's is not "somebody will get to it": no
    -- verdict this session may write drains check, and the gate refuses
    -- every handover until one does. Say that a second session is
    -- required, not merely preferable.
    if #(b["check"] or {}) >= flow.LIMITS["check"] then
      return {
        kind = "none",
        reason = ("check is at %d/%d and every item in it was built by "
          .. "this session — nothing can be handed over until another "
          .. "session writes a verdict"):format(
          #(b["check"] or {}), flow.LIMITS["check"]),
      }
    end
    return {
      kind = "none",
      reason = ("%d item(s) in check were built by this session — another "
        .. "session reviews them"):format(ph.mine),
    }
  end
  if ph.held > 0 then
    -- Name them. A claim is a lock with no expiry, so an abandoned
    -- session's claim strands its item and everything waiting on it
    -- until a person takes it back; a bare count says something is
    -- held without saying what to go and look at.
    return {
      kind = "none",
      reason = ("%d do item(s) are claimed by other sessions and nothing "
        .. "is ready to pull: %s — take one over with `move <id> do "
        .. "--claim <session>`"):format(ph.held, held_names(b, who, pos, aged)),
    }
  end
  return {
    kind = "none",
    reason = "plan and ready are at limit, backlog holds nothing "
    .. "promotable, and there is nothing to check — implementation has "
    .. "to catch up before intake adds more",
  }
end

local record action
  type Action = Action
  type Phased = Phased
  unheld: function(b: flow.Board, phase: string, session: string,
  pos: {string: prio.Position}, ages: health.Ages): Item | nil, integer
  reviewable: function(b: flow.Board, session: string,
  pos: {string: prio.Position}): Item | nil, integer
  first_pullable: function(b: flow.Board, index: flow.Index, session: string,
  pos: {string: prio.Position}): Item | nil
  next_action: function(items: {Item}, session?: string,
  ages?: health.Ages): Action
end

local M: action = {
  unheld = unheld,
  reviewable = reviewable,
  first_pullable = first_pullable,
  next_action = next_action,
}

return M
