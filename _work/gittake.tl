--- The two takes `take` reaches by derivation rather than by a verb
--- of their own — an item's facts, never a declaration, say which one
--- a take is (`_work.gitverbs.cmd_take` is the dispatch):
---
---   take_review  an item awaiting a verdict, taken by a session that
---                is not its builder: the review claim, the lock
---                pushed BEFORE the reading starts
---   take_result  `take ID --result`, the claim holder handing a
---                research slice over for that verdict — the mirror
---                of `take ID --pr N` for work whose deliverable is
---                board state, not a diff
---
--- Both are motion on work already in flight and ask neither of the
--- pull's gates. Split from `_work.gitverbs`, which sits against the
--- file cap.
local gate = require("_work.gitgate")
local health = require("_work.health")
local item = require("_work.item")
local spec = require("_work.spec")
local store = require("_work.store")

--- The review claim: the lock pushed BEFORE the
--- reading starts, so two sessions never verify one diff. Reached by
--- derivation, not by a verb of its own — an item awaiting a verdict,
--- taken by a session that is not its builder, can only mean the
--- review. The claim is a lease (`health`'s review horizon — short,
--- because a review's dwell is minutes) and mutual exclusion only: a
--- verdict from any session stands and consumes it.
--- @param s store.Store The store
--- @param it item.Item The item whose review is claimed
--- @param session string The reviewing session
--- @param force boolean Take over a LIVE foreign review claim
--- @param why string Why --force was needed
--- @return integer Exit code
local function take_review(s: store.Store, it: item.Item, session: string,
    force: boolean, why: string): integer
  -- The distance guard binds here with no --force escape: a fresh
  -- context cannot be forced into existing, so a session that already
  -- built or specced this item never claims its review, live or stale.
  local distance = gate.distance_refusal(it, session)
  if distance then
    return gate.verdict_line("take", false, distance)
  end
  local id8 = it.id:sub(1, 8)
  if (it.reviewer or "") == session then
    return gate.verdict_line("take", true,
      ("%s's review is already yours"):format(id8))
  end
  -- A standing foreign claim splits on the lease: a live one is a
  -- reviewer mid read-verify-verdict, taken over only on the record;
  -- a stale one is a session that stopped moving the board, and the
  -- diff is anyone's again — the takeover is noted, never gated.
  local taken = ""
  if (it.reviewer or "") ~= "" then
    if not health.is_review_stale(it, gate.age_of(s, it)) and not force then
      return gate.verdict_line("take", false,
        ("REFUSED: %s is under review by %s — take over a live review "
          .. "with --force --why"):format(id8, it.reviewer))
    end
    taken = (" (taken over from %s)"):format(it.reviewer)
  end
  it.reviewer = session
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("review %s claimed by %s%s"):format(id8, session,
      gate.forced_suffix(force, why)))
  if not ok then
    return gate.verdict_line("take", false, err)
  end
  return gate.verdict_line("take", true,
    ("%s's review is yours%s — verdict when done consumes the claim")
    :format(id8, taken))
end

--- The research handover: what `take --pr N` is for a diff, for an
--- item whose deliverable is the board — the spec as it stands once
--- the recommendation is applied (`spec`, then `new`/`attach`/`block`
--- per capture). Nothing on the item's fields could otherwise tell
--- "applied, awaiting a verdict" from "builder mid-flight": both are
--- claimed, PR-less, with builders on record. So the handover is
--- declared, and what it records is the sidecar's revision
--- (`spec.revision`, the same digest a verdict stores as
--- `verdict_spec`): the reviewer judges THAT spec, and `verdict`
--- refuses one that moved since, the way a moved PR head is refused.
---
--- Only the live claim holder hands over — a handover asserts the
--- holder's own work is done, so there is no takeover here and no
--- gate to force — and never over a PR: an item's deliverable is a
--- diff or board state, never both (`item.problems` holds the same
--- rule on every write). The verdict moves exactly as `--pr` moves
--- it: a handover clears a `request changes` (the rework answered, a
--- new thing to judge) whether or not the spec moved — the same spec
--- handed over again is a no-op only while no send-back stands — and
--- an accept is never touched by a take: it is landed, and `verdict`
--- refuses to re-judge it.
--- @param s store.Store The store
--- @param it item.Item The item handed over
--- @param session string The handing-over session
--- @param pr integer The `--pr` given alongside, 0 for none
--- @return integer Exit code
local function take_result(s: store.Store, it: item.Item, session: string,
    pr: integer): integer
  local id8 = it.id:sub(1, 8)
  if (pr or 0) ~= 0 then
    return gate.verdict_line("take", false,
      "REFUSED: --pr and --result together — a deliverable is a diff or "
      .. "board state, never both")
  end
  if (it.pr or 0) ~= 0 then
    return gate.verdict_line("take", false,
      ("REFUSED: %s already carries PR #%d — its deliverable is that diff; "
        .. "a research handover records none"):format(id8, it.pr))
  end
  if (it.claim or "") ~= session then
    local holder = "unclaimed"
    if (it.claim or "") ~= "" then
      holder = ("claimed by %s"):format(it.claim)
    end
    return gate.verdict_line("take", false,
      ("REFUSED: %s is %s — the handover is the claim holder's; take it "
        .. "first"):format(id8, holder))
  end
  local body = store.read_spec(s, it.id)
  if body == "" then
    return gate.verdict_line("take", false,
      ("REFUSED: %s has no spec sidecar — a research handover hands the "
        .. "spec over, and there is none"):format(id8))
  end
  local digest = spec.revision(body)
  local verdict = it.verdict or ""
  local standing = "awaiting review"
  if verdict ~= "" then
    standing = ("its %s stands"):format(verdict)
  end
  if digest == (it.result or "") and verdict ~= "request changes" then
    return gate.verdict_line("take", true,
      ("%s already records this spec's handover — %s"):format(id8, standing))
  end
  it.result = digest
  if verdict == "request changes" then
    it.verdict = ""
    standing = "awaiting review"
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("take %s by %s result:%s"):format(id8, session, digest:sub(1, 7)))
  if not ok then
    return gate.verdict_line("take", false, err)
  end
  return gate.verdict_line("take", true,
    ("%s is yours result:%s — %s"):format(id8, digest:sub(1, 7), standing))
end

local record gittake
  take_review: function(s: store.Store, it: item.Item, session: string,
  force: boolean, why: string): integer
  take_result: function(s: store.Store, it: item.Item, session: string,
  pr: integer): integer
end

local M: gittake = {
  take_review = take_review,
  take_result = take_result,
}

return M
