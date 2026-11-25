--- What follows a completed run of ci on main, for prerelease.yml's
--- `follow` job (`driver.tl prerelease-follow`). Only a run that tests all
--- four legs, the daily scheduled run or a manual one, publishes a
--- prerelease, so:
---
--- - after a push run that passed, where no such run of main that
---   [`counts`] started in the last `window` hours, it starts a manual run
---   of main, so a
---   prerelease follows main within hours, not at the next daily run,
---   which GitHub starts hours after its cron line;
--- - after such a run's first attempt failed, it re-runs the failed jobs
---   once, so one flaky test does not cost the prerelease. The first
---   attempt's failure stays in the run's history, for the flaky list;
--- - after a push run that failed, it opens the issue "main is red",
---   naming the run and its commit, where none is open, so a break on
---   main is seen within minutes, not at the next prerelease; the next
---   push run that passes closes it.
---
--- It reads the run from its environment: EVENT, CONCLUSION, ATTEMPT,
--- RUN_ID, BRANCH and HEAD_SHA, the triggering run's
--- (github.event.workflow_run),
--- and REPOSITORY, with the client GH_TOKEN makes. A missing input, a
--- request GitHub refuses or one that gets no response fails the job.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
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
    head_sha: string
    --- The time, in seconds since the epoch.
    now: integer
    --- How long after a full run's start no other is started, in seconds.
    window: integer
  end
end

--- What `follow` reads of a `.../runs` response.
local record RunItem
  event: string
  created_at: string
  status: string
  conclusion?: string
  run_attempt: integer
end
local record RunsAnswer
  workflow_runs: {RunItem}
end
local RUNS <const> = Shape.record_of("RunsAnswer")

--- What `follow` reads of an `.../issues` response.
local record IssueItem
  number: integer
  title: string
end
local ISSUE <const> = Shape.record_of("IssueItem")

--- The title of the issue a red push run of main opens.
local red_title <const> = "main is red"

--- The number of the open issue `red_title` names, nil where none is open.
local function red_issue(c: PrereleaseFollow.Context): integer?
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository ..
      "/issues?state=open&creator=github-actions%5Bbot%5D&per_page=100"))
  local issues = assert(Shape.decode_into(text, Shape.list(ISSUE.spec)))
  for _, issue in ipairs(issues) do
    if issue.title == red_title then return issue.number end
  end
  return nil
end

--- The run `c` names, as a link.
local function run_url(c: PrereleaseFollow.Context): string
  return "https://github.com/" .. c.repository .. "/actions/runs/" .. c.run_id
end

--- After a red push run: opens the issue where none is open.
--- TODO: a re-run of an older push run ends out of order, so it may open
--- the issue while main's tip is green, or close it while the tip is red;
--- comparing `head_sha` with main's tip waits on a case that needs it.
local function report_red(c: PrereleaseFollow.Context): string
  local open = red_issue(c)
  if open ~= nil then return "main is red: issue #" .. tostring(open) .. " is open already" end
  local reply = assert(GithubApi.request(c.client, "POST", "repos/" .. c.repository .. "/issues", {
    title = red_title,
    body = "The push run " .. run_url(c) .. " of " .. c.head_sha .. " on main failed. " ..
      "Until a push run passes, no manual run follows main's pushes, so a prerelease waits for the " ..
      "daily run; the push run that passes closes this issue.",
  }))
  assert(reply.status == 201, "opening the issue answered " .. tostring(reply.status) .. ": " .. reply.body)
  return "main is red: an issue is opened"
end

--- After a green push run: closes the issue where one is open, and says
--- so, or "" where none is.
local function report_green(c: PrereleaseFollow.Context): string
  local open = red_issue(c)
  if open == nil then return "" end
  local path = "repos/" .. c.repository .. "/issues/" .. tostring(open)
  local said = assert(GithubApi.request(c.client, "POST", path .. "/comments",
    { body = "The push run " .. run_url(c) .. " of " .. c.head_sha .. " passed." }))
  assert(said.status == 201, "commenting on the issue answered " .. tostring(said.status) .. ": " .. said.body)
  local closed = assert(GithubApi.request(c.client, "PATCH", path, { state = "closed" }))
  assert(closed.status == 200, "closing the issue answered " .. tostring(closed.status) .. ": " .. closed.body)
  return "main is green: issue #" .. tostring(open) .. " is closed; "
end

--- The runs that test all four legs and so publish a prerelease
--- (prerelease.yml's `publish`).
local full_events <const>: {string:boolean} = { schedule = true, workflow_dispatch = true }

--- Six hours: at most four runs a day this starts, beside the daily one.
local default_window <const> = 6 * 3600

--- Whether `run` keeps another full run from starting: any but one that
--- can publish nothing any more, which failed again, was cancelled or
--- timed out. A first attempt that failed is tried once more.
local function counts(run: RunItem): boolean
  if run.status ~= "completed" then return true end
  local conclusion = run.conclusion or ""
  if conclusion == "failure" then return run.run_attempt == 1 end
  return conclusion ~= "cancelled" and conclusion ~= "timed_out"
end

--- The start of the newest full run of main in `runs` that [`counts`],
--- nil where none.
local function newest_full(runs: {RunItem}): integer?
  local newest: integer? = nil
  for _, run in ipairs(runs) do
    if full_events[run.event] == true and counts(run) then
      local at = Report.seconds_of(run.created_at)
      if at ~= nil and (newest == nil or at > newest) then newest = at end
    end
  end
  return newest
end

--- After a green push run: starts a full run of main where none started
--- in the window, and says what it did.
local function start_full(c: PrereleaseFollow.Context, base: string): string
  local runs: mut {RunItem} = {}
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    local text = assert(GithubApi.get(c.client, base .. "/workflows/ci.yml/runs?branch=main&event=" .. event ..
        "&per_page=5"))
    for _, run in ipairs(assert(RUNS:decode_into(text)).workflow_runs) do runs[#runs + 1] = run end
  end
  local newest = newest_full(runs)
  if newest ~= nil and c.now - newest < c.window then
    return "a full run of main started " .. Plural.count((c.now - newest) // 60, "minute") .. " ago: none is started"
  end
  local reply = assert(GithubApi.request(c.client, "POST", base .. "/workflows/ci.yml/dispatches", { ref = "main" }))
  assert(reply.status == 204, "dispatching ci.yml on main answered " .. tostring(reply.status) .. ": " .. reply.body)
  return "no full run of main in the last " .. Plural.count(c.window // 3600, "hour") .. ": one is started"
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
  if c.event == "push" and c.conclusion == "failure" then return report_red(c) end
  if c.event ~= "push" or c.conclusion ~= "success" then
    return "a " .. c.event .. " run that ended " .. c.conclusion .. ": nothing follows"
  end
  -- The full run first, so a refused issue request costs no prerelease.
  local said = start_full(c, base)
  return report_green(c) .. said
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
    head_sha = need("HEAD_SHA"),
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
