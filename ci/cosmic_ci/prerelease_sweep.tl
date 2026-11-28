--- What prerelease.yml's `sweep` job does, after each push run of main
--- and each hour (`driver.tl
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
--- - where its first attempt failed, it re-runs the failed jobs once,
---   unless the failure is the last failed full run's again: a run whose
---   failed jobs carry error annotations (`driver.tl failures` writes one
---   per failing test or finding), every one of which the newest earlier
---   failed full run of main carried too, fails the same way each time,
---   and a re-run costs a runner for nothing.
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

--- What `sweep` reads of a job of a run, and of an annotation of a job.
local record JobItem
  id: integer
  conclusion?: string
end
local record JobsAnswer
  jobs: {JobItem}
end
local JOBS <const> = Shape.record_of("JobsAnswer")
local record AnnotationItem
  annotation_level?: string
  message?: string
end
local ANNOTATION <const> = Shape.record_of("AnnotationItem")

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

--- The runs of ci.yml on main, newest first as GitHub lists them.
local function main_runs(c: PrereleaseSweep.Context): {RunItem}
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository ..
      "/actions/workflows/ci.yml/runs?branch=main&per_page=50"))
  return assert(RUNS:decode_into(text)).workflow_runs
end

--- The newest full run of main the job's token last started among
--- `runs`, nil where none started within the horizon.
local function newest_started(c: PrereleaseSweep.Context, runs: {RunItem}): RunItem?
  local newest: RunItem? = nil
  local newest_at = 0
  for _, run in ipairs(runs) do
    local at = Report.seconds_of(run.created_at)
    local ours = run.triggering_actor.login == job_token_login and run.head_branch == "main" and
      full_events[run.event] == true
    if ours and at ~= nil and c.now - at < horizon and at > newest_at then
      newest, newest_at = run, at
    end
  end
  return newest
end

--- The error annotations of the failed jobs of the last attempt of `run`
--- (the lines `driver.tl failures` writes), as a set; empty where a job
--- failed with none (a runner lost, a time limit, a cancel).
local function failed_messages(c: PrereleaseSweep.Context, run: RunItem): {string:boolean}, boolean
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/actions/runs/" ..
      tostring(run.id) .. "/jobs?filter=latest&per_page=100"))
  local messages: mut {string:boolean} = {}
  local bare = false
  for _, job in ipairs(assert(JOBS:decode_into(text)).jobs) do
    local ended = job.conclusion or "none"
    if ended == "failure" then
      local said = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/check-runs/" ..
          tostring(job.id) .. "/annotations?per_page=100"))
      local any = false
      local notes = assert(Shape.decode_into(said, Shape.list(ANNOTATION.spec)))
      for _, note in ipairs(notes) do
        -- The runner's own line for any failed step says nothing of why.
        local said_why = note.message ~= nil and note.message:find("^Process completed with exit code") == nil
        if note.annotation_level == "failure" and note.message ~= nil and said_why then
          messages[note.message] = true
          any = true
        end
      end
      bare = bare or not any
    elseif ended ~= "success" and ended ~= "skipped" and ended ~= "neutral" then
      -- timed_out, cancelled, startup_failure: the runner's doing, so a re-run may help.
      bare = true
    end
  end
  return messages, bare
end

--- Whether the failure of `run` is one the newest earlier failed full run
--- among `runs` had: each of its failed jobs says what failed, and all of
--- it was said there too. False where there is no such run or a failed
--- job said nothing.
local function repeats(c: PrereleaseSweep.Context, run: RunItem, runs: {RunItem}): boolean
  local at = Report.seconds_of(run.created_at) or 0
  local earlier: RunItem? = nil
  local earlier_at = 0
  for _, each in ipairs(runs) do
    local when = Report.seconds_of(each.created_at)
    if each.id ~= run.id and each.conclusion == "failure" and full_events[each.event] == true and
        when ~= nil and when < at and when > earlier_at then
      earlier, earlier_at = each, when
    end
  end
  if earlier == nil then return false end
  local now, bare = failed_messages(c, run)
  if bare or next(now) == nil then return false end
  local before = failed_messages(c, earlier)
  for message in pairs(now) do
    if before[message] ~= true then return false end
  end
  return true
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
  local runs = main_runs(c)
  local run = newest_started(c, runs)
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
  if conclusion == "failure" and run.run_attempt == 1 and repeats(c, run, runs) then
    return named .. " failed as the last failed full run did: a re-run would fail again"
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
