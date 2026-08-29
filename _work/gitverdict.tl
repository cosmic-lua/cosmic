--- The review verdict: one verb, one commit, recording what a
--- fresh-context reviewer judged and what that does to the item.
---
--- A verdict judges a PR, so it binds only where one stands with no
--- verdict already on it — an accept given anywhere else would carry
--- unreviewed work to a merge past the one gate in front of it. The
--- head guard keeps a verdict informative rather than ceremonial: a
--- head already judged has nothing new to say.
---
--- Three kinds, three effects, all derived-state moves with no column
--- to cross:
---
---   accept           the item awaits its merge (`land` finishes it);
---                    a PR found already merged ends the item here
---   request changes  the send-back stands on the item; the claimant
---                    reworks on the same PR and `take --pr` re-opens
---                    the verdict for the new head
---   reject           the approach was wrong: claim, PR and verdict
---                    clear together, the item is todo again, and the
---                    learning goes in its spec — wrong work merged
---                    is expensive, rejection is cheap by design
---
--- `--session` is the audit half. Nothing here refuses on it: the
--- name it gives rides in the commit subject — every board commit is
--- authored as one fixed identity, so the subject is the only place
--- the log can record who judged.
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local item = require("_work.item")
local publish = require("_work.publish")
local review = require("_work.review")
local spec = require("_work.spec")
local store = require("_work.store")

--- The spellings people actually type for the middle verdict: the
--- GitHub hyphenation and the skill's noun. Both mean "request
--- changes" — without them a guessed spelling falls through to the
--- unknown-kind error, and the next guess a reviewer reaches for is
--- reject, which is much harsher.
local KIND_ALIASES: {string: string} = {
  ["request-changes"] = "request changes",
  ["rework"] = "request changes",
}

local KINDS: {string: boolean} = {
  ["accept"] = true,
  ["request changes"] = true,
  ["reject"] = true,
}

--- The refusal for a head+spec pair judged before. Some cures happen
--- OUTSIDE the PR — a fix landing elsewhere can make the spec's claims
--- true with the head and spec both unmoved — and the doctrine for
--- that stays record-the-cure-on-the-spec rather than a new guard
--- surface, so the refusal names that way forward instead of dead-
--- ending: append what changed to the item's spec, then judge again.
--- @param id string The item under verdict
--- @param head string The head already judged
--- @return string The refusal
local function already_judged_refusal(id: string, head: string): string
  return ("%s's head %s was already judged with this spec — neither "
    .. "the diff nor the spec has moved since. If something outside "
    .. "the PR cured it, append a short Rework note to the item's "
    .. "spec (`gitboard spec`) and record the verdict again."):format(
    id:sub(1, 8), head:sub(1, 7))
end

--- @param s store.Store The store
--- @param id string The item under verdict
--- @param kind string accept | request changes | reject (aliases apply)
--- @param pr integer The PR the verdict judges, 0 to use the item's own
--- @param head string The head commit the verdict judges
--- @param session string | nil The reviewing session; rides in the subject
--- @param force boolean | nil Record over the distance guard — repair only
--- @param why string | nil Why --force was needed
--- @return integer Exit code
local function cmd_verdict(s: store.Store, id: string, kind: string,
    pr: integer, head: string, session?: string, force?: boolean,
    why?: string): integer
  local frc = force or false
  local rsn = why or ""
  local forced = gate.force_refusal(frc, rsn)
  if forced then
    return gate.verdict_line("verdict", false, "REFUSED: " .. forced)
  end
  kind = KIND_ALIASES[kind] or kind
  if not KINDS[kind] then
    return gate.verdict_line("verdict", false,
      ("unknown verdict: %s — the kinds are accept, 'request changes' "
        .. "(request-changes and rework are aliases) and reject "
        .. "(claim and PR clear; the item is todo again)"):format(kind))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("verdict", false, lerr)
  end
  -- The distance guard, same predicate the review-claim derivation
  -- refuses on — here with `--force --why` as the audited repair
  -- escape, since a verdict already recorded is a fact to correct on
  -- the log, not a claim to take over.
  if not frc then
    local distance = gate.distance_refusal(it, session or "")
    if distance then
      return gate.verdict_line("verdict", false, distance)
    end
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("verdict", false, aerr)
  end
  if (it.pr or 0) == 0 and (pr or 0) == 0 then
    return gate.verdict_line("verdict", false,
      ("%s has no PR — a verdict judges a diff"):format(id:sub(1, 8)))
  end
  if (it.verdict or "") == "accept" then
    return gate.verdict_line("verdict", false,
      ("REFUSED: %s already carries an accept — land it"):format(id:sub(1, 8)))
  end
  -- The head is verified before anything downstream treats it as
  -- true: the shape half always, because a non-hex value would just
  -- make the pair guard and `head_moved` silently never match; the PR
  -- half whenever a request stands to check against, because a gate
  -- that waves a head through when it cannot see the PR is worse than
  -- no gate at all.
  local judged = (pr or 0) ~= 0 and pr or it.pr
  local shape_err = review.head_refusal(nil, head)
  if shape_err then
    return gate.verdict_line("verdict", false, "REFUSED: " .. shape_err)
  end
  -- Hoisted so the accept path below reuses this same read instead of
  -- fetching the PR again: one snapshot decides both which head was
  -- judged and whether it is fit to land.
  local p: review.Pull | nil = nil
  if publish.has_origin(s) then
    local perr: string
    p, perr = gh.pull(s, judged, it.repo)
    if p == nil then
      return gate.verdict_line("verdict", false,
        ("REFUSED: cannot verify --head against PR #%d: %s"):format(
          judged, perr or ""))
    end
    local head_err = review.head_refusal(p, head)
    if head_err then
      return gate.verdict_line("verdict", false, "REFUSED: " .. head_err)
    end
    -- The PR's own full head is canonical; the caller may have passed
    -- a short prefix.
    head = p.head_sha
  end
  -- A verdict judges a head AND the spec that head is measured
  -- against: a rework can answer a bounce by rewriting the spec,
  -- which moves no commit. Judging the same PAIR twice says nothing
  -- new happened between them — that is "nothing to judge" rather
  -- than a fresh round. An unrecorded revision refuses nothing: the
  -- board cannot say what spec an older verdict read.
  local judged_spec = spec.revision(store.read_spec(s, id))
  if (head or "") ~= "" and head == (it.verdict_head or "")
  and (it.verdict_spec or "") ~= "" and judged_spec == it.verdict_spec then
    return gate.verdict_line("verdict", false,
      "REFUSED: " .. already_judged_refusal(id, head))
  end
  -- An accept asserts the work is fit to land, so it is the one
  -- verdict whose truth depends on the request's own state. Checking
  -- it here collapses two cases the landing step handles badly: a
  -- merged request needs no land at all, and a closed unmerged one
  -- has no land that could succeed. `p` is the same read the head
  -- guard above already made — one snapshot for both decisions — so
  -- there is nothing further to fetch or fail here; no origin (or no
  -- PR) just means the ordinary path carries on and `land` stays the
  -- backstop it already is.
  local merged_sha = ""
  if kind == "accept" and judged ~= 0 and p ~= nil then
    local blocked = review.blocks_accept(p)
    if blocked then
      return gate.verdict_line("verdict", false, "REFUSED: " .. blocked)
    end
    if p.merged then
      merged_sha = p.merge_sha
    end
  end
  -- The judgment consumes the review claim, whoever held it: the
  -- claim is mutual exclusion over the reading, and the reading is
  -- over.
  it.reviewer = ""
  it.verdict_head = head or ""
  it.verdict_spec = judged_spec
  if pr ~= nil and pr ~= 0 then
    it.pr = pr
  end
  local outcome = "recorded"
  if kind == "accept" then
    outcome = "awaiting merge — land it"
  elseif kind == "request changes" then
    outcome = "rework — the claimant fixes on the same PR"
  end
  if kind == "reject" then
    -- Nothing stands after a reject: the item is todo again, and the
    -- spec (plus the closed PR) carries what was learned.
    it.verdict = ""
    it.verdict_head = ""
    it.verdict_spec = ""
    it.claim = ""
    it.pr = 0
    outcome = "reject — todo again"
  else
    it.verdict = kind
  end
  local also: {item.Item} = {}
  local landed = ""
  if merged_sha ~= "" then
    -- Already merged: the landing this accept authorises has
    -- happened, so the item ends HERE rather than waiting for a
    -- `land` whose only remaining act is to notice the same thing.
    -- The merge commit goes in the subject — the log says which merge
    -- completed the item without `Item` growing a field for it.
    it.resolution = "completed"
    it.claim = ""
    landed = (", merged %s"):format(merged_sha:sub(1, 7))
    outcome = "accept — completed"
  end
  -- The reviewer rides in the subject rather than the author: every
  -- board commit is the one fixed identity, so without this the log
  -- cannot show whether an accept was written by the builder, and the
  -- distance is unauditable after the fact.
  local by = ""
  if (session or "") ~= "" then
    by = (" by %s"):format(session)
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("verdict %s %s%s%s%s"):format(id:sub(1, 8), kind, by, landed,
      gate.forced_suffix(frc, rsn)), also)
  if not ok then
    return gate.verdict_line("verdict", false, err)
  end
  local note = ""
  if merged_sha ~= "" then
    note = (" (PR #%d was already merged)"):format(it.pr)
  end
  return gate.verdict_line("verdict", true,
    ("%s on %s: %s%s"):format(kind, id:sub(1, 8), outcome, note))
end

local record gitverdict
  cmd_verdict: function(s: store.Store, id: string, kind: string,
  pr: integer, head: string, session?: string, force?: boolean,
  why?: string): integer
  already_judged_refusal: function(id: string, head: string): string
end

local M: gitverdict = {
  cmd_verdict = cmd_verdict,
  already_judged_refusal = already_judged_refusal,
}

return M
