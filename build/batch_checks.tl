--- Whether a pull request's checks let build/batch.tl stack it: every
--- `ci` job at its head has finished and passed, macOS's suite among
--- them.
---
--- The checks are the check runs GitHub lists for the head, one for each
--- job of each ci run there (only ci.yml runs on a pull request). The
--- newest run of each name decides: a re-run, or the run that marking the
--- pull request ready starts, takes the place of the older one. The `ci`
--- gate alone does not: GitHub adds a run's gate only once its other jobs
--- end, so while a ready-for-review run's macOS suite runs, the newest
--- `ci` check is still the draft run's green one (batch 77 stacked #4484
--- so, and the queue's macOS leg failed it on a seatbelt test the PR's
--- own macOS run failed minutes later).
---
--- macOS's suite must have passed too: a draft runs Linux alone, and
--- tests of macOS's own paths (cosmic.sandbox_restrict_seatbelt_test)
--- skip on Linux, so a draft's green says nothing of them.
local record batch_checks
  record CheckRun
    name: string
    status: string
    conclusion: string?
    started_at: string
  end
  --- The job whose pass the stack asks for beside the `ci` gate.
  MACOS: string
end

batch_checks.MACOS = "macos-aarch64"

local PASSING <const>: {string: boolean} = { success = true, skipped = true, neutral = true }

--- Why the checks `runs` hold a pull request out of a batch, or nil when
--- they let it in.
--- @param runs the head's check runs, as GitHub lists them
--- @return the reason, or nil
function batch_checks.refusal(runs: {batch_checks.CheckRun}): string?
  local newest: mut {string: batch_checks.CheckRun} = {}
  local names: mut {string} = {}
  for _, check in ipairs(runs) do
    local known = newest[check.name]
    if known == nil then names[#names + 1] = check.name end
    if known == nil or check.started_at > known.started_at then newest[check.name] = check end
  end
  table.sort(names)
  if newest["ci"] == nil then return "no ci check at its head" end
  local running: mut {string} = {}
  for _, name in ipairs(names) do
    if newest[name]!.status ~= "completed" then running[#running + 1] = name end
  end
  if #running > 0 then return "its checks are still running: " .. table.concat(running, ", ") end
  -- A job's own failure first: the gate fails whenever one does.
  table.sort(names, function(a: string, b: string): boolean
    if (a == "ci") ~= (b == "ci") then return b == "ci" end
    return a < b
  end)
  for _, name in ipairs(names) do
    local conclusion = newest[name]!.conclusion
    if conclusion == nil or PASSING[conclusion] ~= true then
      return "its newest " .. name .. " check is " .. tostring(conclusion)
    end
  end
  local macos = newest[batch_checks.MACOS]
  if macos == nil or macos.conclusion ~= "success" then
    return "no passed " .. batch_checks.MACOS .. " check at its head: mark it ready for review, " ..
      "and stack it once that run passes"
  end
  return nil
end

return batch_checks
