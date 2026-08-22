--- What a pull request must be before an item may sit in `check`, as
--- pure functions over an already-fetched request. The fetching is
--- `_work.gh`; the judgment is here, so every rule below is testable
--- without a token and without a network.
---
--- These are review PRECONDITIONS, not the review: a planner still
--- reads the diff and gives the verdict. What they enforce is that a
--- reviewer is never handed something there is no point reading yet —
--- a draft, a request that names no item, or one whose CI has already
--- concluded that it fails.
local record Pull
  number: integer
  --- Still a draft: the author has not offered it for review.
  draft: boolean
  body: string
  head_sha: string
  --- "open" | "closed"
  state: string
  --- Already merged, by any route.
  merged: boolean
  --- The merge commit, "" until the request is merged.
  merge_sha: string
end

--- One CI check on a head commit, reduced to what a gate reads.
local record CheckRun
  name: string
  --- "queued" | "in_progress" | "completed"
  status: string
  --- "success" | "failure" | "cancelled" | ...; "" while running.
  conclusion: string
end

--- Conclusions that mean the head is known bad. A cancelled or skipped
--- run is not a failure, and a run still going is not a verdict — an
--- in-flight check is a reason to come back, never a reason to refuse.
local FAILED: {string: boolean} = {
  ["failure"] = true, ["timed_out"] = true, ["action_required"] = true,
  ["startup_failure"] = true,
}

--- The refusal a pull request earns before it may carry an item into
--- `check`, or nil when it may.
--- @param p Pull The fetched pull request
--- @param id string The item's id
--- @return string | nil The refusal
local function blocks_check(p: Pull, id: string): string
  if p.state ~= "open" then
    return ("PR #%d is %s — a closed request carries nothing to review")
    :format(p.number, p.state)
  end
  if p.draft then
    return ("PR #%d is a draft — offer it for review before handing it over")
    :format(p.number)
  end
  local body = p.body or ""
  if not body:find("Board: " .. id, 1, true)
  and not body:find("Board: " .. id:sub(1, 8), 1, true) then
    return ("PR #%d's body does not carry `Board: %s`, so nothing joins the "
      .. "request to its item"):format(p.number, id:sub(1, 8))
  end
  return nil
end

--- The refusal a head's CI earns, or nil when nothing has concluded
--- failure. Silence is not success and is not refused here: a head
--- with no runs yet, or runs still going, passes this gate and meets
--- the planner's own reading instead, which asks for a green run on
--- the CURRENT head.
--- @param runs {CheckRun} The head's check runs
--- @return string | nil The refusal
local function blocks_on_ci(runs: {CheckRun}): string
  local failed: {string} = {}
  for _, r in ipairs(runs) do
    if r.status == "completed" and FAILED[r.conclusion or ""] then
      failed[#failed + 1] = r.name
    end
  end
  if #failed == 0 then
    return nil
  end
  return ("CI has already concluded failure on this head (%s) — fix it "
    .. "before asking for a verdict"):format(table.concat(failed, ", "))
end

--- The refusal an ACCEPT earns from the state of its pull request, or
--- nil when the accept may proceed.
---
--- An accept asserts that the work is fit to land, so the one state it
--- cannot survive is a request that is closed with nothing merged:
--- there is no diff to land and no `land` step that could produce one.
--- Routing such an item onward puts it in `land` carrying an accept,
--- where the merge PUT is refused and `next` re-answers the same
--- finish forever.
---
--- A merged request is NOT refused — it is the opposite case, where
--- the landing has already happened; the caller reads `merged` and
--- ends the item. Open is the ordinary path.
--- @param p Pull The request the accept judges
--- @return string The refusal, nil when the accept may proceed
local function blocks_accept(p: Pull): string
  if p.state ~= "open" and not p.merged then
    return ("PR #%d is %s and unmerged — there is nothing to land; reopen "
      .. "it, or reject the item"):format(p.number, p.state)
  end
  return nil
end

--- The refusal a LANDING earns from the head it is about to merge, or
--- nil when the merge may proceed.
---
--- An accept is a judgment of one head. If the request has moved since
--- — the builder pushed again after the verdict — merging lands a diff
--- no reviewer read, and nothing anywhere records the substitution.
--- Comparing the two shas is the whole rule.
---
--- An empty `verdict_head` is not refused: an item accepted before the
--- verdict recorded a head has nothing to compare, and refusing those
--- would strand them with no way forward but `--force`.
--- @param p Pull The request about to be merged
--- @param verdict_head string The head the accept judged
--- @return string The refusal, nil when the merge may proceed
local function blocks_land(p: Pull, verdict_head: string): string
  local judged = verdict_head or ""
  if judged == "" then
    return nil
  end
  if judged == p.head_sha then
    return nil
  end
  return ("PR #%d has moved since the accept — judged %s, now %s; "
    .. "re-review the current head or --force")
  :format(p.number, judged:sub(1, 7), (p.head_sha or ""):sub(1, 7))
end

local record review
  type Pull = Pull
  type CheckRun = CheckRun
  blocks_check: function(p: Pull, id: string): string
  blocks_accept: function(p: Pull): string
  blocks_land: function(p: Pull, verdict_head: string): string
  blocks_on_ci: function(runs: {CheckRun}): string
end

local M: review = {
  blocks_check = blocks_check,
  blocks_accept = blocks_accept,
  blocks_land = blocks_land,
  blocks_on_ci = blocks_on_ci,
}

return M
