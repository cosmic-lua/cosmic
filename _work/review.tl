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

local record review
  type Pull = Pull
  type CheckRun = CheckRun
  blocks_check: function(p: Pull, id: string): string
  blocks_on_ci: function(runs: {CheckRun}): string
end

local M: review = {
  blocks_check = blocks_check,
  blocks_on_ci = blocks_on_ci,
}

return M
