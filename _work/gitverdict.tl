--- The review verdict and the move it implies: one verb, one commit,
--- recording what a planner judged and where that sends the item.
---
--- `check` is the only phase a verdict may end — that phase means
--- exactly "awaiting a planner verdict", and an accept given anywhere
--- else would carry unreviewed work into `land` past every gate
--- between them. The other two guards are what keep a verdict
--- informative rather than ceremonial: a head already judged has
--- nothing new to say, and a non-accept verdict files the
--- countermeasure its bounce is evidence for.
---
--- `--session` is the builder-distance half. A session that names
--- itself as the item's claimant is refused, and the name it gives
--- rides in the commit subject — every board commit is authored as
--- one fixed identity, so the subject is the only place the log can
--- record who judged.
---
--- An ACCEPT also reads the pull request it judges, because an accept
--- asserts the work is fit to land and two request states make that
--- assertion wrong in opposite directions. Already merged: the
--- landing has happened, so the item ends here rather than passing
--- through a `land` whose only remaining act is to notice that.
--- Closed and unmerged: there is nothing to land and no step that
--- could produce it, so the accept is refused rather than parked in
--- `land`, which would refuse it forever. A read that fails is
--- neither — the ordinary path carries on, so an outage cannot wedge
--- reviews and `land` stays the backstop it already is.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local item = require("_work.item")
local review = require("_work.review")
local store = require("_work.store")

--- The phase each verdict sends an item to: the three directions out
--- of check. A reject lands in `backlog` rather than `plan` — the
--- work is still placed and still real, but the commitment that
--- carried it into `plan` was spent on a spec the review turned down,
--- so re-committing to it is a decision to take again against
--- everything else in the queue.
local VERDICT_MOVES: {string: string} = {
  ["accept"] = "land",
  ["request changes"] = "do",
  ["reject"] = "backlog",
}

--- The spellings people actually type for the middle verdict: the
--- GitHub hyphenation and review.md's noun. Both mean "request
--- changes" — without them a guessed spelling falls through to the
--- unknown-kind error, and the next guess a reviewer reaches for is
--- reject, whose move is much harsher (backlog spends the commitment;
--- do keeps the builder's claim).
local KIND_ALIASES: {string: string} = {
  ["request-changes"] = "request changes",
  ["rework"] = "request changes",
}

--- Whether an `--enable` value is one of the two shapes a filed
--- countermeasure takes: the id of an item that exists, or `none`
--- carrying a reason. Anything else — a bare `none`, an id of nothing
--- — is the trailer not actually being filled in.
--- @param value string The --enable argument
--- @param index {string: item.Item} Items by id
--- @return boolean True when the value names a real countermeasure
local function is_enablement(value: string, index: {string: item.Item}): boolean
  local reason = value:match("^none[:%s]%s*(.+)$")
  if reason ~= nil then
    return reason:match("%S") ~= nil
  end
  return index[value] ~= nil
end

local function cmd_verdict(s: store.Store, id: string, kind: string,
    pr: integer, head: string, enable: string, session?: string): integer
  kind = KIND_ALIASES[kind] or kind
  local target = VERDICT_MOVES[kind]
  if target == nil then
    return gate.verdict_line("verdict", false,
      ("unknown verdict: %s — the kinds are accept, 'request changes' "
        .. "(to do, claim kept; request-changes and rework are "
        .. "aliases) and reject (to backlog, commitment spent)")
      :format(kind))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("verdict", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("verdict", false, aerr)
  end
  -- Prefixes resolve here rather than in the dispatcher, which cannot:
  -- an --enable value is either an id or a reasoned `none`, and only
  -- this verb knows which grammar it is looking at. Resolution failing
  -- is not an error yet — the enablement check below names both shapes.
  local filed = enable or ""
  if kind ~= "accept" and filed ~= ""
  and filed:match("^none[:%s]") == nil then
    local resolved = store.resolve(s, filed)
    if resolved ~= nil then
      filed = resolved
    end
  end
  -- Every non-accept verdict carries information about why a presumed
  -- ready item was not, and that information is lost unless it is
  -- filed. The trailer is where the planner names the countermeasure —
  -- or says, on the record, that this item's own spec was the fault.
  if kind ~= "accept" and not is_enablement(filed, flow.by_id(all)) then
    return gate.verdict_line("verdict", false,
      ("REFUSED: a %s verdict files its countermeasure — pass "
        .. "--enable <item-id> or --enable 'none: <reason>'"):format(kind))
  end
  -- `check` means exactly "awaiting a planner verdict", so it is the
  -- one phase a verdict may end. Judging from anywhere else would let
  -- an accept carry unreviewed work straight into land, past every
  -- gate between them.
  if (it.phase or "") ~= "check" then
    local where = it.phase
    if where == "" then
      where = "no phase"
    end
    return gate.verdict_line("verdict", false,
      ("%s is in %s — a verdict judges work in check"):format(
        id:sub(1, 8), where))
  end
  -- A verdict judges a head. Judging the same one twice says nothing
  -- new happened between them, which is the state review.md calls
  -- "nothing to judge" rather than a fresh round.
  if (head or "") ~= "" and head == (it.verdict_head or "") then
    return gate.verdict_line("verdict", false,
      ("REFUSED: %s already carries a %s verdict on head %s — nothing "
        .. "new to judge"):format(id:sub(1, 8), it.verdict, head:sub(1, 7)))
  end
  -- A review is worth the distance between the builder and the
  -- reviewer, and until now that distance was advice: `next
  -- --session` withheld the item, and nothing stopped a session from
  -- reaching for `verdict` directly. Naming yourself is what is
  -- checked — an unnamed session is not refused, so a repair written
  -- without one still works.
  if (session or "") ~= "" and session == (it.claim or "") then
    return gate.verdict_line("verdict", false,
      ("REFUSED: %s is %s's own build — no session accepts its own work")
      :format(id:sub(1, 8), session))
  end
  -- An accept asserts the work is fit to land, so it is the one
  -- verdict whose truth depends on the request's own state. Reading
  -- it here collapses two cases the landing step handles badly: a
  -- merged request needs no land at all, and a closed unmerged one
  -- has no land that could succeed. A read that FAILS is not a
  -- refusal — an outage must not wedge reviews — so the ordinary path
  -- carries on and `land` stays the backstop it already is.
  local merged_sha = ""
  if kind == "accept" and (it.pr or 0) ~= 0 and store.has_origin(s) then
    local p = gh.pull(s, it.pr, it.repo)
    if p ~= nil then
      local blocked = review.blocks_accept(p)
      if blocked then
        return gate.verdict_line("verdict", false, "REFUSED: " .. blocked)
      end
      if p.merged then
        merged_sha = p.merge_sha
      end
    end
  end
  local from = it.phase
  it.verdict = kind
  it.verdict_head = head or ""
  it.enable = ""
  if kind ~= "accept" then
    it.enable = filed
  end
  if pr ~= nil and pr ~= 0 then
    it.pr = pr
  end
  it.phase = target
  -- The reviewer rides in the subject rather than the author: every
  -- board commit is the one fixed identity, so without this the log
  -- cannot show whether an accept was written by the builder, and the
  -- distance is unauditable after the fact.
  local by = ""
  if (session or "") ~= "" then
    by = (" by %s"):format(session)
  end
  -- Already merged: the landing this accept authorises has happened,
  -- so the item ends HERE rather than passing through a `land` whose
  -- only remaining act is to notice the same thing. One mutation, and
  -- the merge commit goes in the subject — the log says which merge
  -- completed the item without `Item` growing a field for it.
  local also: {item.Item} = {}
  local landed = ""
  if merged_sha ~= "" then
    target = "completed"
    it.phase = ""
    it.resolution = "completed"
    -- A container whose last open child just ended returns to plan.
    -- Ending an item without this is what leaves a finished container
    -- de-phased and off every queue.
    also = gate.rephased_parent(it, all)
    landed = (", merged %s"):format(merged_sha:sub(1, 7))
  end
  -- A verdict is a decision already made: an accept enters land and a
  -- send-back is a return, so no WIP gate applies in any direction.
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("verdict %s %s (%s -> %s)%s%s"):format(id:sub(1, 8), kind, from, target,
      by, landed), from, also)
  if not ok then
    return gate.verdict_line("verdict", false, err)
  end
  local note = ""
  if merged_sha ~= "" then
    note = (" (PR #%d was already merged)"):format(it.pr)
  end
  return gate.verdict_line("verdict", true,
    ("%s on %s: %s -> %s%s"):format(kind, id:sub(1, 8), from, target, note))
end

local record gitverdict
  cmd_verdict: function(s: store.Store, id: string, kind: string,
  pr: integer, head: string, enable: string, session?: string): integer
end

local M: gitverdict = {
  cmd_verdict = cmd_verdict,
}

return M
