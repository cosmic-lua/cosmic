--- What prerelease.yml's hourly `sweep` job does (`driver.tl
--- prerelease-sweep`). A full run of ci that `follow` started with the
--- job's own token fires no workflow_run when it ends: GitHub starts no
--- workflow from an event that token caused. So neither `publish` nor
--- `follow` sees it end. Nor does a daily run that `follow` re-ran with
--- that token. The sweep acts for them, on the newest full run of main
--- that token last started, within the last day:
---
--- - where it passed and no prerelease names its commit, it writes the
---   run's `run_id` and `head_sha` to $GITHUB_OUTPUT, which `publish`
---   publishes from;
--- - where its first attempt failed, it re-runs the failed jobs once.
---
--- It reads REPOSITORY and GITHUB_OUTPUT from its environment, with the
--- client GH_TOKEN makes. A missing input, a request GitHub refuses or
--- one that gets no response fails the job.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Report = require("cosmic_ci.report")
local Shape = require("cosmic.shape")
local Clock = require("cosmic.clock")

local record PrereleaseSweep
  --- What `sweep` needs to look for the run and act on it.
  record Context
    client: GithubApi.Client
    repository: string
    --- The file the job's outputs go to.
    output: string
    --- The time, in seconds since the epoch.
    now: integer
  end
end

--- What `sweep` reads of a run in a `.../runs` response.
local record Actor
  login: string
end
local record RunItem
  id: integer
  event: string
  head_branch: string
  status: string
  conclusion?: string
  run_attempt: integer
  head_sha: string
  created_at: string
  triggering_actor: Actor
end
local record RunsAnswer
  workflow_runs: {RunItem}
end
local RUNS <const> = Shape.record_of("RunsAnswer")

--- What `sweep` reads of a release in a `.../releases` response.
local record ReleaseItem
  tag_name: string
end
local RELEASE <const> = Shape.record_of("ReleaseItem")

--- The login a run started with the job's own token shows.
local job_token_login <const> = "github-actions[bot]"

--- How old a run the sweep still acts on may be, in seconds.
local horizon <const> = 24 * 3600

--- The runs that test all four legs and so publish a prerelease.
local full_events <const>: {string:boolean} = { schedule = true, workflow_dispatch = true }

--- The newest full run of main the job's token last started, nil where
--- none started within the horizon.
local function newest_started(c: PrereleaseSweep.Context): RunItem?
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository ..
      "/actions/workflows/ci.yml/runs?branch=main&per_page=50"))
  local newest: RunItem? = nil
  local newest_at = 0
  for _, run in ipairs(assert(RUNS:decode_into(text)).workflow_runs) do
    local at = Report.seconds_of(run.created_at)
    local ours = run.triggering_actor.login == job_token_login and run.head_branch == "main" and
      full_events[run.event] == true
    if ours and at ~= nil and c.now - at < horizon and at > newest_at then
      newest, newest_at = run, at
    end
  end
  return newest
end

--- Whether a prerelease names the commit `sha` (its tag is `<date>-<sha>`).
local function published(c: PrereleaseSweep.Context, sha: string): boolean
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/releases?per_page=50"))
  local releases = assert(Shape.decode_into(text, Shape.list(RELEASE.spec)))
  for _, release in ipairs(releases) do
    if release.tag_name:sub(-#sha - 1) == "-" .. sha then return true end
  end
  return false
end

--- Acts on the newest run `follow` started, and says what it did, for
--- the log.
function PrereleaseSweep.sweep(c: PrereleaseSweep.Context): string
  local run = newest_started(c)
  if run == nil then
    return "no full run of main that the job's token started in the last day: nothing to do"
  end
  local named = "run " .. tostring(run.id) .. " of " .. run.head_sha
  if run.status ~= "completed" then return named .. " is " .. run.status .. ": nothing to do" end
  local conclusion = run.conclusion or "none"
  if conclusion == "success" then
    if published(c, run.head_sha) then return named .. " passed and is published: nothing to do" end
    assert(Fs.append(c.output, "run_id=" .. tostring(run.id) .. "\nhead_sha=" .. run.head_sha .. "\n"))
    return named .. " passed and is not published: publish follows"
  end
  if conclusion == "failure" and run.run_attempt == 1 then
    local reply = assert(GithubApi.request(c.client, "POST", "repos/" .. c.repository ..
        "/actions/runs/" .. tostring(run.id) .. "/rerun-failed-jobs"))
    assert(reply.status == 201, "re-running the failed jobs answered " .. tostring(reply.status) .. ": " .. reply.body)
    return named .. " failed its first attempt: its failed jobs run again"
  end
  return named .. " ended " .. conclusion .. " on attempt " .. tostring(run.run_attempt) .. ": nothing to do"
end

--- The context the job's environment `env` gives.
function PrereleaseSweep.context(env: {string:string}): PrereleaseSweep.Context
  local function need(name: string): string
    local value = env[name] or ""
    assert(value ~= "", name .. " is not set")
    return value
  end
  return {
    client = assert(GithubApi.live(env)),
    repository = need("REPOSITORY"),
    output = need("GITHUB_OUTPUT"),
    now = Clock.now_ns() // 1000000000,
  }
end

--- `driver.tl prerelease-sweep`.
function PrereleaseSweep.command(argv: {string}, context?: PrereleaseSweep.Context): integer
  local ran, answer = pcall(function(): string
    assert(argv[1] == nil, "usage: driver.tl prerelease-sweep")
    return PrereleaseSweep.sweep(context or PrereleaseSweep.context(Env.all()))
  end)
  if not ran then
    local _, _ = Fs.put(Fs.stderr, "prerelease-sweep: " .. tostring(answer) .. "\n")
    return 1
  end
  assert(Fs.put(Fs.stdout, tostring(answer) .. "\n"))
  return 0
end

return PrereleaseSweep
