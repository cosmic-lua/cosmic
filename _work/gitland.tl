--- The landing: verify that an accepted item's pull request is
--- merged, then end the item.
---
--- The merge itself belongs to whoever runs the board, by whatever
--- route their credentials allow — a GitHub tool, the merge button,
--- `gh pr merge`. `land` is the board-side half: it reads the
--- request, refuses while nothing is merged, and ends the item once
--- the merge is there. A checkout whose token could merge on its own
--- pays for that separation with a second step; what it buys is a
--- verb that behaves identically wherever the board is driven from,
--- and a board that never claims work the base branch does not carry.
---
--- Ending after the merge, never before, and never without reading
--- it: an item ended over an unmerged request says the work landed
--- when it did not, and nothing downstream would catch it. The
--- reverse — a merge whose `done` then fails — leaves an accepted,
--- merged item sitting in `land`, which the next session sees and
--- finishes.
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local review = require("_work.review")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

--- land: verify the accepted PR is merged, then end the item.
--- @param s store.Store The store
--- @param id string The item to land
--- @param force boolean Skip the accept and phase checks
--- @param why string Why --force was needed
--- @return integer 0 on success, 1 otherwise
local function cmd_land(s: store.Store, id: string, force: boolean,
    why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("land", false, "REFUSED: " .. forced)
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("land", false, lerr)
  end
  if not force then
    if it.phase ~= "land" then
      return gate.verdict_line("land", false,
        ("REFUSED: %s is in %s — only an accepted item lands"):format(
          id:sub(1, 8), it.phase == "" and "no phase" or it.phase))
    end
    if it.verdict ~= "accept" then
      return gate.verdict_line("land", false,
        ("REFUSED: %s carries no accept — the planner's verdict is what "
          .. "authorises a merge"):format(id:sub(1, 8)))
    end
  end
  if (it.pr or 0) == 0 then
    return gate.verdict_line("land", false,
      ("REFUSED: %s names no PR to land"):format(id:sub(1, 8)))
  end
  -- Whether the merge happened is the one fact the board cannot hold
  -- itself, so the request is read every time. A read that fails is a
  -- refusal rather than an assumption: ending an item over a merge
  -- nobody confirmed is exactly what this verb exists to prevent.
  local p, perr = gh.pull(s, it.pr, it.repo)
  if p == nil then
    return gate.verdict_line("land", false,
      ("cannot read PR #%d: %s"):format(it.pr, perr))
  end
  local blocked = review.blocks_land(p, it.verdict_head, id)
  if blocked then
    return gate.verdict_line("land", false, "REFUSED: " .. blocked)
  end
  print(("gitboard-land: PR #%d was already merged"):format(it.pr))
  -- A merge cannot be undone, so a head that moved past the one the
  -- accept judged is not a refusal here: refusing would strand the
  -- item forever. Say it loudly instead, so the substitution is in
  -- the log rather than nowhere.
  if review.head_moved(p, it.verdict_head) then
    print(("gitboard-land: WARNING PR #%d merged at %s but the accept "
        .. "judged %s"):format(it.pr, (p.head_sha or ""):sub(1, 7),
        (it.verdict_head or ""):sub(1, 7)))
  end
  return verbs.cmd_done(s, id, "completed", force, why)
end

local record gitland
  cmd_land: function(s: store.Store, id: string, force: boolean,
  why: string): integer
end

local M: gitland = {
  cmd_land = cmd_land,
}

return M
