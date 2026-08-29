--- The review claim: the reviewer's counterpart to `take`, pushed
--- BEFORE the reading starts so two sessions never verify one diff.
---
--- The builder's claim survives the handover, but it names who BUILT
--- the thing — it excludes nobody from reviewing, so under concurrent
--- sessions every session that asked `next` was handed the same top
--- item, and the second learned of the first only when its verdict
--- was refused, after the whole verification. The board's
--- own doctrine already says what fixes this — the claim is the
--- lock, and the board commit is what makes it visible — so this
--- verb applies it to reviews: `review ID` stamps the session, the
--- publish is the compare-and-swap, and a session that loses the
--- race is told before it has read a line.
---
--- The claim is a LEASE on `_work.health`'s review horizon — short,
--- because a review's dwell is minutes — and mutual exclusion only:
--- it does not make the claimant the one valid judge. A verdict from
--- any session stands and consumes the claim, or a takeover would
--- wedge on the authority of the session it is replacing.
local gate = require("_work.gitgate")
local health = require("_work.health")
local store = require("_work.store")

--- Claim ID's review for `session`.
--- @param s store.Store The store
--- @param id string The item whose review is claimed
--- @param session string The reviewing session, "" when unnamed
--- @param force boolean Take over a LIVE foreign claim
--- @param why string Why --force was needed
--- @return integer Exit code
local function cmd_review(s: store.Store, id: string, session: string,
    force: boolean, why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("review", false, "REFUSED: " .. forced)
  end
  -- A claim by nobody excludes nobody: an unnamed session collides
  -- with no one by design, and stamping "" would read as unclaimed to
  -- every other session while this one believes it holds the lock.
  if (session or "") == "" then
    return gate.verdict_line("review", false,
      "REFUSED: a review claim names its session — set GITBOARD_SESSION "
      .. "or pass --session")
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("review", false, lerr)
  end
  if (it.pr or 0) == 0 then
    return gate.verdict_line("review", false,
      ("REFUSED: %s has no PR — a review claims a diff awaiting a "
        .. "verdict"):format(id:sub(1, 8)))
  end
  if (it.verdict or "") ~= "" then
    return gate.verdict_line("review", false,
      ("REFUSED: %s already carries a %s verdict — %s"):format(
        id:sub(1, 8), it.verdict,
        it.verdict == "accept" and "land it" or
        "the rework returns for review when its builder hands it back"))
  end
  if (it.reviewer or "") == session then
    return gate.verdict_line("review", true,
      ("%s's review is already yours"):format(id:sub(1, 8)))
  end
  -- A standing foreign claim splits on the lease: a live one is a
  -- reviewer mid read-verify-verdict, taken over only on the record;
  -- a stale one is a session that stopped moving the board, and the
  -- diff is anyone's again — the takeover is noted, never gated.
  local taken = ""
  if (it.reviewer or "") ~= "" then
    local ages: health.Ages = {}
    local now = os.time()
    local t = store.touched_at(s, it.id)
    if t ~= nil and t <= now then
      ages[it.id] = now - t
    end
    if not health.is_review_stale(it, ages) and not force then
      return gate.verdict_line("review", false,
        ("REFUSED: %s is under review by %s — take over a live review "
          .. "with --force --why"):format(id:sub(1, 8), it.reviewer))
    end
    taken = (" (taken over from %s)"):format(it.reviewer)
  end
  it.reviewer = session
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("review %s claimed by %s"):format(id:sub(1, 8), session))
  if not ok then
    return gate.verdict_line("review", false, err)
  end
  return gate.verdict_line("review", true,
    ("%s's review is yours%s — verdict when done consumes the claim")
    :format(id:sub(1, 8), taken))
end

local record gitreview
  cmd_review: function(s: store.Store, id: string, session: string,
  force: boolean, why: string): integer
end

local M: gitreview = {
  cmd_review = cmd_review,
}

return M
