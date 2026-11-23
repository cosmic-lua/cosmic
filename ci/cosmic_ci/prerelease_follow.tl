--- What follows a completed run of ci on main, for prerelease.yml's
--- `follow` job (`driver.tl prerelease-follow`). Only a run that tests all
--- four legs, the daily scheduled run or a manual one, publishes a
--- prerelease, so:
---
--- - after a push run that passed, where no such run of main started in
---   the last `window` hours, it starts a manual run of main, so a
---   prerelease follows main within hours, not at the next daily run,
---   which GitHub starts hours after its cron line;
--- - after such a run's first attempt failed, it re-runs the failed jobs
---   once, so one flaky test does not cost the prerelease. The first
---   attempt's failure stays in the run's history, for the flaky list.
---
--- It reads the run from its environment: EVENT, CONCLUSION, ATTEMPT,
--- RUN_ID and BRANCH, the triggering run's (github.event.workflow_run),
--- and REPOSITORY, with the client GH_TOKEN makes. A missing input, a
--- request GitHub refuses or one that gets no answer fails the job.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Report = require("cosmic_ci.report")
local Shape = require("cosmic.shape")
local Clock = require("cosmic.clock")

local record PrereleaseFollow
  --- The triggering run, and what `follow` needs to act on it.
  record Context
    client: GithubApi.Client
    repository: string
    event: string
    conclusion: string
    attempt: integer
    run_id: string
    branch: string
    --- The time, in seconds since the epoch.
    now: integer
    --- How long after a full run's start no other is started, in seconds.
    window: integer
  end
end

--- What `follow` reads of a `.../runs` answer.
local record RunItem
  event: string
  created_at: string
end
local record RunsAnswer
  workflow_runs: {RunItem}
end
local RUNS <const> = Shape.record_of("RunsAnswer")

--- The runs that test all four legs and so publish a prerelease
--- (prerelease.yml's `publish`).
local full_events <const>: {string:boolean} = { schedule = true, workflow_dispatch = true }

--- Six hours: at most four runs a day this starts, beside the daily one.
local default_window <const> = 6 * 3600

--- The start of the newest full run of main in `runs`, nil where none.
local function newest_full(runs: {RunItem}): integer?
  local newest: integer? = nil
  for _, run in ipairs(runs) do
    if full_events[run.event] == true then
      local at = Report.seconds_of(run.created_at)
      if at ~= nil and (newest == nil or at > newest) then newest = at end
    end
  end
  return newest
end

--- Acts on the run `c` names, and says what it did, for the log.
function PrereleaseFollow.follow(c: PrereleaseFollow.Context): string
  if c.branch ~= "main" then return "a run of " .. c.branch .. ": nothing follows" end
  local base = "repos/" .. c.repository .. "/actions"
  if full_events[c.event] == true then
    if c.conclusion ~= "failure" then
      return "a full run that ended " .. c.conclusion .. ": nothing follows"
    end
    if c.attempt ~= 1 then
      return "attempt " .. tostring(c.attempt) .. " of a full run failed: it is not tried again"
    end
    local reply = assert(GithubApi.request(c.client, "POST", base .. "/runs/" .. c.run_id .. "/rerun-failed-jobs"))
    assert(reply.status == 201, "re-running the failed jobs answered " .. tostring(reply.status) .. ": " .. reply.body)
    return "the first attempt of full run " .. c.run_id .. " failed: its failed jobs run again"
  end
  if c.event ~= "push" or c.conclusion ~= "success" then
    return "a " .. c.event .. " run that ended " .. c.conclusion .. ": nothing follows"
  end
  local runs: mut {RunItem} = {}
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    local text = assert(GithubApi.get(c.client, base .. "/workflows/ci.yml/runs?branch=main&event=" .. event ..
        "&per_page=5"))
    for _, run in ipairs(assert(RUNS:decode_into(text)).workflow_runs) do runs[#runs + 1] = run end
  end
  local newest = newest_full(runs)
  if newest ~= nil and c.now - newest < c.window then
    return "a full run of main started " .. tostring((c.now - newest) // 60) .. " minutes ago: none is started"
  end
  local reply = assert(GithubApi.request(c.client, "POST", base .. "/workflows/ci.yml/dispatches", { ref = "main" }))
  assert(reply.status == 204, "dispatching ci.yml on main answered " .. tostring(reply.status) .. ": " .. reply.body)
  return "no full run of main in the last " .. tostring(c.window // 3600) .. " hours: one is started"
end

--- The context the job's environment `env` gives.
function PrereleaseFollow.context(env: {string:string}): PrereleaseFollow.Context
  local client = assert(GithubApi.live(env))
  local function need(name: string): string
    local value = env[name] or ""
    assert(value ~= "", name .. " is not set")
    return value
  end
  return {
    client = client,
    repository = need("REPOSITORY"),
    event = need("EVENT"),
    conclusion = need("CONCLUSION"),
    attempt = assert(math.tointeger(tonumber(need("ATTEMPT"))), "ATTEMPT is not a whole number"),
    run_id = need("RUN_ID"),
    branch = need("BRANCH"),
    now = Clock.now_ns() // 1000000000,
    window = default_window,
  }
end

--- `driver.tl prerelease-follow`.
function PrereleaseFollow.command(argv: {string}, context?: PrereleaseFollow.Context): integer
  local ran, answer = pcall(function(): string
    assert(argv[1] == nil, "usage: driver.tl prerelease-follow")
    return PrereleaseFollow.follow(context or PrereleaseFollow.context(Env.all()))
  end)
  if not ran then
    local _, _ = Fs.put(Fs.stderr, "prerelease-follow: " .. tostring(answer) .. "\n")
    return 1
  end
  assert(Fs.put(Fs.stdout, tostring(answer) .. "\n"))
  return 0
end

return PrereleaseFollow
