--- `next --take`: the offer and the lock in one invocation. Bare
--- `next` is a read, and the claim that makes its answer exclusive is
--- a later mutation — a window in which every concurrent session's
--- `next`, reading boards that do not carry the claim yet, hands out
--- the same item. Take-mode closes it: the decision's candidate list
--- is walked in order, each claimable candidate is claimed on the
--- spot (`review` for a review, `move do --claim` for a pull, a
--- same-phase `move plan --claim` for a refine), and a
--- refusal — the compare-and-swap losing, or a claim already landed —
--- falls to the next candidate instead of fighting. When the list
--- exhausts, the board is synced and the decision recomputed once:
--- losing every candidate means the board moved under this session,
--- and the fresh read is the answer.
---
--- A kind with no lock (finish, unblock, promote, sweep, triage,
--- intake, none) reports exactly as bare `next` does — there is
--- nothing to fuse. Refinement IS locked: two sessions handed the
--- same plan item refine it twice and the second write is refused
--- after the work, so the claim moves to where the collision starts.
local act = require("_work.action")
local decision = require("_work.decision")
local gate = require("_work.gitgate")
local guide = require("_work.guidance")
local health = require("_work.health")
local item = require("_work.item")
local rev = require("_work.gitreview")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local type Action = decision.Action

--- Claim ages for the lease checks, from each item's last board
--- commit. The same read `gitview` does for bare `next`.
--- @param s store.Store The store
--- @param all {item.Item} Every item
--- @return health.Ages Seconds since last commit, by id
local function claim_ages(s: store.Store, all: {item.Item}): health.Ages
  local ages: health.Ages = {}
  local now = os.time()
  for _, i in ipairs(all) do
    if (i.claim or "") ~= "" or (i.reviewer or "") ~= "" then
      local t = store.touched_at(s, i.id)
      if t ~= nil and t <= now then
        ages[i.id] = now - t
      end
    end
  end
  return ages
end

--- Render one action the way `next` does: the headline and the
--- guidance for its kind.
--- @param action Action The action to render
--- @param note string A take-mode prefix, "" for none
--- @return string The report
local function render(action: Action, note: string): string
  local target = ""
  if action.item then
    target = (" %s %s"):format(action.item.id:sub(1, 8), action.item.title)
  end
  local out: {string} = {
    ("%s%s%s — %s"):format(note, action.kind, target, action.reason),
  }
  for _, line in ipairs(guide.lines(action.kind)) do
    out[#out + 1] = "  " .. line
  end
  return table.concat(out, "\n")
end

--- Attempt the claim a candidate's kind calls for. The claim verbs
--- print their own verdict lines, which is deliberate: a lost race is
--- visible in the transcript rather than swallowed. A refine claim is
--- a same-phase move, so `set_in_place` writes it and refuses a live
--- foreign claim; one this session already holds is already taken,
--- with nothing to record.
--- @param s store.Store The store
--- @param c Action The candidate
--- @param session string The claiming session
--- @return boolean True when the claim landed
local function claimed(s: store.Store, c: Action, session: string): boolean
  if c.kind == "review" then
    return rev.cmd_review(s, c.item.id, session, false, "") == 0
  end
  if c.kind == "pull" then
    return verbs.cmd_move(s, c.item.id, "do", session, 0, false, "",
      false, session) == 0
  end
  if c.kind == "refine" then
    if (c.item.claim or "") == session then
      return true
    end
    return verbs.cmd_move(s, c.item.id, "plan", session, 0, false, "",
      false, session) == 0
  end
  return false
end

--- Whether take-mode has a lock to try for this kind.
--- @param c Action The candidate
--- @return boolean True for the claimable kinds
local function claimable(c: Action): boolean
  return c.kind == "review" or c.kind == "pull" or c.kind == "refine"
end

--- The take loop: decide, claim down the candidate list, and on a
--- fully lost list sync and decide once more.
--- @param s store.Store The store
--- @param session string The claiming session, "" refused
--- @return integer Exit code
local function cmd_take(s: store.Store, session: string): integer
  if (session or "") == "" then
    return gate.verdict_line("next", false,
      "REFUSED: --take claims work, and a claim names its session — set "
      .. "GITBOARD_SESSION or pass --session")
  end
  for attempt = 1, 2 do
    local all, aerr = store.list(s)
    if all == nil then
      return gate.verdict_line("next", false, aerr)
    end
    local action = act.next_action(all, session, claim_ages(s, all), session)
    if not claimable(action) then
      return gate.verdict_line("next", true, render(action, ""))
    end
    local list: {Action} = {action}
    for _, alt in ipairs(action.alternates or {}) do
      list[#list + 1] = alt
    end
    for _, c in ipairs(list) do
      if claimable(c) and claimed(s, c, session) then
        return gate.verdict_line("next", true,
          render(c, ("took (%s) "):format(session)))
      end
    end
    -- Every candidate was refused: the board moved under this
    -- session. Once is a race; recompute against the merged state.
    -- Twice says contention is total right now, and the honest
    -- answer is to come back rather than spin.
    if attempt == 1 then
      local synced, serr = store.sync(s)
      if not synced then
        return gate.verdict_line("next", false, serr)
      end
    end
  end
  return gate.verdict_line("next", true,
    "every candidate was claimed by another session first — ask again")
end

local record gittake
  cmd_take: function(s: store.Store, session: string): integer
end

local M: gittake = {
  cmd_take = cmd_take,
}

return M
