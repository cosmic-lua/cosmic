--- The landing: squash-merge an accepted item's pull request and end
--- the item, in that order. Two steps that were done by hand, with
--- nothing checking that the item being closed was the one that
--- merged.
---
--- Order matters and is not symmetric. The merge happens first,
--- because ending an item whose merge then fails leaves the board
--- claiming work that is not on main; the reverse — a merge whose
--- `done` fails — leaves an accepted, merged item still sitting in
--- `land`, which the next session sees and finishes. One of those is
--- recoverable by looking at the board; the other is not.
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

--- land: merge the accepted PR, then end the item.
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
      ("REFUSED: %s names no PR to merge"):format(id:sub(1, 8)))
  end
  -- Ask before merging: a PR merged by any other route (another
  -- credential, a maintainer's button) leaves nothing to merge, and
  -- re-attempting the PUT reports a refusal for work that is on main.
  -- The race window -- merged between this read and the PUT -- needs no
  -- classifier: the PUT fails generically and the re-run's read lands
  -- here. Land already needs the API for the PUT, so a failed read is
  -- the same wall, named.
  local p, perr = gh.pull(s, it.pr, it.repo)
  if p == nil then
    return gate.verdict_line("land", false,
      ("cannot read PR #%d: %s"):format(it.pr, perr))
  end
  if p.merged then
    print(("gitboard-land: PR #%d was already merged"):format(it.pr))
    return verbs.cmd_done(s, id, "completed", force, why)
  end
  local res, merr = gh.merge(s, it.pr, it.repo)
  if res == nil then
    return gate.verdict_line("land", false, merr)
  end
  if not gh.is_merged(res) then
    return gate.verdict_line("land", false, gh.refusal(it.pr, res))
  end
  print(("gitboard-land: merged PR #%d"):format(it.pr))
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
