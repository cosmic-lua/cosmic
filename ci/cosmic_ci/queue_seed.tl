--- The merge queue's result, which a push to main reuses rather than
--- testing the same commit again (README.md's "the queue's result"), and
--- the run ahead of a queue run in the queue, whose verdicts it takes.
--- Both ask the API through [`Github.Host`] and never fail their step: a
--- full run, or none of the verdicts ahead, costs time, never a result.
---
--- `find`, ci.yml's `reuse` job on a push to main: asks the API
--- (GH_TOKEN, with actions: read) for REPOSITORY's merge_group runs of
--- ci.yml whose head_sha is SHA, and writes to $GITHUB_OUTPUT `run=<id>`
--- and `url=<its page>` of the newest whose head_sha is SHA, on a
--- gh-readonly-queue/main/ branch, that completed with success and holds
--- an unexpired seed-<leg> artifact for each of LEGS (the names of the
--- platform legs and of the checked job, blank-separated, each a job that
--- keeps a cache; a re-run a day later finds them expired); `run=` and
--- `url=` where it did not, and the push runs the full scope. The queue
--- lands its merge the moment the `ci` check passes, a moment before its
--- run completes, so while such a run is still queued or in progress, or
--- while the API fails, it asks again, every WAIT_SECONDS (20), up to
--- TRIES (6) times. Each call is cut off after CALL_SECONDS (15), and a
--- round makes at most two, so the lookup takes at most
--- TRIES * (WAIT_SECONDS + 2 * CALL_SECONDS), under the `reuse` job's
--- timeout-minutes (build/workflows_test.tl holds the defaults below to
--- it).
---
--- `ahead`, a merge_group run's job before its suite (ci.yml's "find the
--- run ahead in the queue"): finds the run ahead of this one in the
--- queue, the merge_group run of ci.yml on a gh-readonly-queue/main/
--- branch whose head_sha is BASE, this run's base
--- (github.event.merge_group.base_sha), asking the API as `find` does,
--- and writes `run=<id>` to $GITHUB_OUTPUT where that run holds an
--- unexpired ARTIFACT, the verdicts its job JOB keeps once its suite
--- passes, for this run to take (ci.yml's `verdicts-ahead`); `run=` where
--- it does not. While that run is in progress and JOB in it has not
--- completed, or while the API fails, it asks again every WAIT_SECONDS
--- until WITHIN_SECONDS (150) have passed since it started; a round makes
--- at most three calls, each cut off as `find`'s are, so it ends within
--- WITHIN_SECONDS + 3 * CALL_SECONDS, which ci.yml holds under the step's
--- timeout (build/workflows_test.tl). Where READY_SECONDS is set, JOB is
--- taken to keep ARTIFACT that long after it started: one not started
--- yet, or that would keep it only after the wait ends, is not waited
--- for. Where SUITE_STEP is set, the name of JOB's step after which it
--- keeps ARTIFACT (its suite), a JOB ahead that has not begun that step
--- is not waited for either: one not started, still building, or itself
--- waiting on the run ahead of it, whose ARTIFACT is more than a short
--- wait away. None is found at once where the checkout's change moves
--- build/harness_epoch.tl from BASE's, when every suite runs every test
--- (--all) and stands on no verdict; where BASE heads no queue run (it is
--- main's already: ci.yml skips the step where the restore took BASE's
--- own entry, and a base that landed after the restore finds its run,
--- whose verdicts merge as rows mostly held already); and where the run,
--- or JOB, completed without ARTIFACT.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Time = require("cosmic.time")

local record QueueSeed
  --- `find` or `ahead` in `env` (the process's environment) over `host`:
  --- 0, or 2 for a line it cannot read.
  find: function(env: {string:string}, host: Github.Host): integer
  ahead: function(env: {string:string}, host: Github.Host): integer
  --- `driver.tl queue-find` and `queue-ahead`, in the process's
  --- environment.
  find_command: function(argv: {string}): integer
  ahead_command: function(argv: {string}): integer
end

local QUEUE <const> = "gh-readonly-queue/main/"

--- A whole number `env` names, `default` where it names none (a variable
--- set to nothing is none, as the shell's `${NAME:-default}` has it), and
--- nil and why where it is no whole number.
local function whole(env: {string:string}, name: string, default: integer | nil): integer | nil, string
  local text = env[name]
  if text == nil or text == "" then return default, "" end
  local value = math.tointeger(tonumber(text))
  if value == nil or value < 0 then
    return nil, name .. " is no whole number of seconds: " .. text
  end
  return value, ""
end

--- What `find` and `ahead` read of `env`.
local record Settings
  repository: string
  call: integer
  wait: integer
end

local function settings(env: {string:string}, who: string): Settings | nil, string
  local repository = env.REPOSITORY
  if repository == nil or repository == "" then return nil, who .. ": no REPOSITORY" end
  local call, why = whole(env, "CALL_SECONDS", 15)
  if call == nil then return nil, who .. ": " .. why end
  local wait: integer | nil
  wait, why = whole(env, "WAIT_SECONDS", 20)
  if wait == nil then return nil, who .. ": " .. why end
  return { repository = repository, call = call, wait = wait }, ""
end

--- A JSON value as the shell's `jq -r` prints it in a string: null is "null".
local function printed(value: any): string
  if value == nil then return "null" end
  if value is number then return tostring(math.tointeger(value) or value) end
  return tostring(value)
end

local record Run
  id: string
  status: string
  conclusion: string
  sha: string
  branch: string
  url: string
  event: string
end

--- The workflow runs `pages` list, as `.workflow_runs[]` reads them in
--- the API's order (newest first), or nil where an answer holds no
--- list of runs.
local function runs_of(pages: {any}): {Run} | nil
  local out: {Run} = {}
  for _, page in ipairs(pages) do
    local list = type(page) == "table" and (page as {string:any}).workflow_runs or nil
    if type(list) ~= "table" then return nil end
    for _, item in ipairs(list as {any}) do
      if type(item) ~= "table" then return nil end
      local run = item as {string:any}
      out[#out + 1] = { id = printed(run.id), status = printed(run.status),
        conclusion = run.conclusion == nil and "none" or printed(run.conclusion),
        sha = printed(run.head_sha), branch = printed(run.head_branch),
        url = printed(run.html_url), event = printed(run.event) }
    end
  end
  return out
end

--- The names of a run's artifacts that have not expired, as a set, or
--- nil where the answer holds no list of artifacts.
local function artifact_names(pages: {any}): {string:boolean} | nil
  local names: {string:boolean} = {}
  for _, page in ipairs(pages) do
    local list = type(page) == "table" and (page as {string:any}).artifacts or nil
    if type(list) ~= "table" then return nil end
    for _, item in ipairs(list as {any}) do
      if type(item) ~= "table" then return nil end
      local artifact = item as {string:any}
      -- `select(.expired | not)`: only an artifact marked expired is out.
      if artifact.expired == nil or artifact.expired == false then
        names[printed(artifact.name)] = true
      end
    end
  end
  return names
end

local record Job
  status: string
  --- Seconds since the epoch where it has started.
  started: integer | nil
  --- Whether it has begun the suite step, where one is named.
  reached: boolean
  name: string
end

--- The jobs `pages` list, in the API's order, each with whether it has
--- begun the step `suite` (in progress or completed; always false where
--- `suite` is ""), or nil where an answer holds no list of jobs or
--- a job's start is no time.
local function jobs_of(pages: {any}, suite: string): {Job} | nil
  local out: {Job} = {}
  for _, page in ipairs(pages) do
    local list = type(page) == "table" and (page as {string:any}).jobs or nil
    if type(list) ~= "table" then return nil end
    for _, item in ipairs(list as {any}) do
      if type(item) ~= "table" then return nil end
      local job = item as {string:any}
      local started: integer | nil = nil
      if job.started_at ~= nil and job.started_at ~= "" then
        local ns = Time.parse_rfc3339(printed(job.started_at))
        if ns == nil then return nil end
        started = ns // 1000000000
      end
      local reached = false
      local steps = job.steps
      if suite ~= "" and type(steps) == "table" then
        for _, step in ipairs(steps as {any}) do
          if type(step) == "table" then
            local entry = step as {string:any}
            if entry.name == suite and (entry.status == "in_progress" or entry.status == "completed") then
              reached = true
            end
          end
        end
      end
      out[#out + 1] = { status = printed(job.status), started = started, reached = reached,
        name = printed(job.name) }
    end
  end
  return out
end

--- The run ahead's lookup, and a run's, by `path`.
local function runs_path(s: Settings, head: string): string
  return "repos/" .. s.repository .. "/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" ..
    head .. "&per_page=20"
end

local function run_path(s: Settings, id: string, what: string): string
  return "repos/" .. s.repository .. "/actions/runs/" .. id .. "/" .. what .. "?per_page=100"
end

function QueueSeed.find(env: {string:string}, host: Github.Host): integer
  local s, why = settings(env, "queue-find")
  if s == nil then
    local _, _ = Fs.put(Fs.stderr, why .. "\n")
    return 2
  end
  local legs: {string} = {}
  for leg in (env.LEGS or ""):gmatch("%S+") do legs[#legs + 1] = leg end
  local sha = env.SHA or ""
  if #legs == 0 or sha == "" then
    local _, _ = Fs.put(Fs.stderr, "queue-find: no " .. (#legs == 0 and "LEGS" or "SHA") .. "\n")
    return 2
  end
  local tries, trouble = whole(env, "TRIES", 6)
  if tries == nil then
    local _, _ = Fs.put(Fs.stderr, "queue-find: " .. trouble .. "\n")
    return 2
  end
  local round = 0
  local found, url = "", ""
  while true do
    round = round + 1
    found, url = "", ""
    local pending = false
    local candidate, candidate_url = "", ""
    local pages = Github.ask(host, runs_path(s, sha), false, s.call)
    local runs = pages and runs_of(pages) or nil
    if runs ~= nil then
      for _, run in ipairs(runs) do
        if run.sha == sha and run.branch:sub(1, #QUEUE) == QUEUE then
          if run.status ~= "completed" then
            pending = true
          elseif run.conclusion == "success" and candidate == "" then
            candidate, candidate_url = run.id, run.url
          end
        end
      end
    else
      pending = true
    end
    -- The newest passing run, where it holds every leg's seed.
    if candidate ~= "" then
      local listed = Github.ask(host, run_path(s, candidate, "artifacts"), false, s.call)
      local names = listed and artifact_names(listed) or nil
      if names ~= nil then
        local missing = ""
        for _, leg in ipairs(legs) do
          if not names["seed-" .. leg] then missing = missing .. " " .. leg end
        end
        if missing == "" then
          found, url = candidate, candidate_url
        else
          host.print("run " .. candidate .. " has no seed for:" .. missing)
        end
      else
        pending = true
      end
    end
    if found ~= "" or not pending or round >= tries then break end
    host.sleep(s.wait)
  end
  host.output("run=" .. found)
  host.output("url=" .. url)
  if found ~= "" then
    Github.say(host, sha .. " passed the merge queue in " .. url .. ": its legs' caches and products are reused.")
  else
    Github.say(host, sha .. " has no passing merge queue run with every leg's seed to reuse: the full scope runs.")
  end
  return 0
end

function QueueSeed.ahead(env: {string:string}, host: Github.Host): integer
  local function refuse(why: string): integer
    local _, _ = Fs.put(Fs.stderr, "queue-ahead: " .. why .. "\n")
    return 2
  end
  local artifact, job = env.ARTIFACT or "", env.JOB or ""
  if artifact == "" or job == "" then return refuse("no ARTIFACT or JOB") end
  local s, why = settings(env, "queue-ahead")
  if s == nil then
    local _, _ = Fs.put(Fs.stderr, why .. "\n")
    return 2
  end
  local within: integer | nil
  local ready: integer | nil
  local trouble: string
  within, trouble = whole(env, "WITHIN_SECONDS", 150)
  if within == nil then return refuse(trouble) end
  ready, trouble = whole(env, "READY_SECONDS", nil)
  if trouble ~= "" then return refuse(trouble) end
  local suite = env.SUITE_STEP or ""
  local base = env.BASE or ""
  local found, said = "", ""
  local deadline = host.now() + within
  if not Github.is_commit(base) then
    said = "no base to find the run ahead by: the restore's verdicts alone."
  elseif host.moved(base) then
    said = "build/harness_epoch.tl moved from " .. base .. "'s: every test runs (--all), and stands on no verdict."
  end
  while said == "" do
    -- At most three calls a round, each cut off at CALL_SECONDS.
    local pending = false
    local run, status = "", ""
    local pages = Github.ask(host, runs_path(s, base), false, s.call)
    local runs = pages and runs_of(pages) or nil
    if runs ~= nil then
      -- The newest, where a run was retried.
      for _, candidate in ipairs(runs) do
        if candidate.event == "merge_group" and candidate.sha == base and run == "" and
            candidate.branch:sub(1, #QUEUE) == QUEUE then
          run, status = candidate.id, candidate.status
        end
      end
      if run == "" then
        said = base .. " is no merge queue run's head: the restore's verdicts alone."
      end
    else
      pending = true
    end
    if run ~= "" then
      local listed = Github.ask(host, run_path(s, run, "artifacts"), false, s.call)
      local names = listed and artifact_names(listed) or nil
      if names == nil then
        pending = true
      elseif names[artifact] then
        found = run
      elseif status == "completed" then
        said = "the run ahead, " .. run .. ", completed without " .. artifact .. ": the restore's verdicts alone."
      else
        local answered = Github.ask(host, run_path(s, run, "jobs"), false, s.call)
        local jobs = answered and jobs_of(answered, suite) or nil
        if jobs == nil then
          pending = true
        else
          local mine: Job | nil = nil
          for _, candidate in ipairs(jobs) do
            if candidate.name == job then
              mine = candidate
              break
            end
          end
          if mine ~= nil and mine.status == "completed" then
            said = job .. " of the run ahead, " .. run .. ", completed without " .. artifact ..
              ": the restore's verdicts alone."
          else
            pending = true
            -- A job with none listed has not started: nor reached its suite.
            local reached = mine ~= nil and mine.reached
            local started = mine ~= nil and mine.started or nil
            if suite ~= "" and not reached then
              said = job .. " of the run ahead, " .. run .. ", has not begun '" .. suite ..
                "' (not started, building, or waiting on its own run ahead): the restore's verdicts alone."
            elseif ready ~= nil then
              if started == nil then
                said = job .. " of the run ahead, " .. run .. ", has not started: the restore's verdicts alone."
              elseif started + ready > deadline then
                said = job .. " of the run ahead, " .. run .. ", keeps " .. artifact ..
                  " only after the wait: the restore's verdicts alone."
              end
            end
          end
        end
      end
    end
    if found ~= "" or said ~= "" or not pending or host.now() + s.wait > deadline then break end
    host.sleep(s.wait)
  end
  host.output("run=" .. found)
  if found ~= "" then
    said = "the run ahead, " .. found .. ", holds " .. artifact .. ": this run takes its verdicts."
  elseif said == "" then
    said = "the run ahead of " .. base .. " left no " .. artifact .. " in time: the restore's verdicts alone."
  end
  Github.say(host, said)
  return 0
end

function QueueSeed.find_command(_argv: {string}): integer
  local env = Env.all()
  return QueueSeed.find(env, Github.live(env))
end

function QueueSeed.ahead_command(_argv: {string}): integer
  local env = Env.all()
  return QueueSeed.ahead(env, Github.live(env))
end

return QueueSeed
