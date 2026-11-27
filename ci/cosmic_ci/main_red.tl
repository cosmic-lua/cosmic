--- Tells of a red main, for main-red.yml (`driver.tl main-red`): after
--- each push run of ci on main ends, it opens an issue labelled
--- `main-red` where the run failed, comments on the open one where main
--- is still red, and closes it once a run passes again.
---
--- A failed push run is what the merge queue missed, and nothing else
--- told of it: #3999's broke every push run for 3 hours (2026-11-23),
--- and the 3 push runs from #4499's on (2026-11-27 00:51 to 02:21) failed
--- with no one told. GitHub tells the repository's watchers of a new
--- issue, and build/batch.tl's `stack` names an open one, so the batch
--- that would land on a red main hears of it first.
---
--- A cancelled or skipped run says nothing of main. A run speaks for
--- main only when it is the newest push run of main (by when it was
--- made) that passed or failed, so a run of an older commit, made again,
--- neither closes the issue while a newer commit is red nor opens one
--- while it is green.
---
--- It reads the run from its environment: EVENT, CONCLUSION, BRANCH,
--- SHA, TITLE (the run's head commit's first line), URL, RUN_ID and
--- REPOSITORY (the triggering run's, github.event.workflow_run), with
--- the client GH_TOKEN makes. A request GitHub refuses fails the job.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Shape = require("cosmic.shape")

local record MainRed
  --- The triggering run, and what `follow` needs to act on it.
  record Context
    client: GithubApi.Client
    repository: string
    event: string
    conclusion: string
    branch: string
    sha: string
    title: string
    url: string
    run_id: string
  end
  --- The label of the issue that tells of a red main.
  label: string
end

MainRed.label = "main-red"

--- What `follow` reads of an issue.
local record Issue
  number: integer
  --- Set where the item is a pull request, which the issues API lists too.
  pull_request?: any
end
local ISSUES <const> = Shape.list(Shape.record_of("Issue").spec)

--- What `follow` reads of a run's jobs.
local record Job
  name: string
  conclusion?: string
end
local record Jobs
  jobs: {Job}
end
local JOBS <const> = Shape.record_of("Jobs")

--- What `follow` reads of a run.
local record Run
  id: integer
  conclusion?: string
end
local record Runs
  workflow_runs: {Run}
end
local RUNS <const> = Shape.record_of("Runs")

--- The conclusions that say whether main is red.
local FAILED <const>: {string: boolean} = { failure = true, timed_out = true }

local function failed(conclusion: string): boolean
  return FAILED[conclusion] == true
end

local function first_line(text: string): string
  return text:match("^[^\n]*") or ""
end

--- The open issue labelled `main-red`, nil where there is none.
local function open_issue(c: MainRed.Context): integer?
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/issues?state=open&labels=" ..
      MainRed.label .. "&per_page=20"))
  local issues = assert(Shape.decode_into(text, ISSUES))
  for _, issue in ipairs(issues) do
    if issue.pull_request == nil then return issue.number end
  end
  return nil
end

--- The names of the run's jobs that failed, the `ci` gate left out: it
--- fails whenever one of them does.
local function failed_jobs(c: MainRed.Context): {string}
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/actions/runs/" .. c.run_id ..
      "/jobs?filter=latest&per_page=100"))
  local read = assert(JOBS:decode_into(text))
  local names: mut {string} = {}
  for _, job in ipairs(read.jobs) do
    if job.name ~= "ci" and failed(job.conclusion or "") then names[#names + 1] = job.name end
  end
  table.sort(names)
  return names
end

local record LabelBody
  name: string
  color: string
  description: string
end

--- Whether the run is the newest push run of main (by when it was made)
--- that passed or failed, so that a run made again, or one whose
--- workflow_run came late, does not speak for main. True where none of
--- the 20 newest completed runs passed or failed: nothing newer spoke.
local function newest(c: MainRed.Context): boolean
  local text = assert(GithubApi.get(c.client, "repos/" .. c.repository ..
      "/actions/workflows/ci.yml/runs?branch=main&event=push&status=completed&per_page=20"))
  local read = assert(RUNS:decode_into(text))
  for _, run in ipairs(read.workflow_runs) do
    local conclusion = run.conclusion or ""
    if conclusion == "success" or failed(conclusion) then return tostring(run.id) == c.run_id end
  end
  return true
end

--- Makes the label, so the issue carries it: a POST of an issue does not
--- always make a label it names. One that is there already is a 422.
local function ensure_label(c: MainRed.Context)
  local made: LabelBody = { name = MainRed.label, color = "b60205",
    description = "a push run of ci on main failed (main-red.yml)" }
  local reply = assert(GithubApi.request(c.client, "POST", "repos/" .. c.repository .. "/labels", made))
  assert(reply.status == 201 or reply.status == 422, "POST labels answered " .. tostring(reply.status) ..
      ": " .. reply.body)
end

local function post(c: MainRed.Context, path: string, value: any)
  assert(GithubApi.object(c.client, "POST", "repos/" .. c.repository .. path, value))
end

local record IssueBody
  title: string
  body: string
  labels: {string}
end
local record CommentBody
  body: string
end
local record StateBody
  state: string
end

--- Acts on the run `c` names, and says what it did, for the log.
function MainRed.follow(c: MainRed.Context): string
  if c.event ~= "push" or c.branch ~= "main" then
    return "a " .. c.event .. " run of " .. c.branch .. ": nothing follows"
  end
  local short = c.sha:sub(1, 9)
  if not failed(c.conclusion) and c.conclusion ~= "success" then
    return "a push run that ended " .. c.conclusion .. " says nothing of main"
  end
  local open = open_issue(c)
  if (open ~= nil or failed(c.conclusion)) and not newest(c) then
    return "main's run at " .. short .. " ended " .. c.conclusion .. ", but a newer push run ended since, " ..
      "which spoke for main"
  end
  if failed(c.conclusion) then
    local jobs = failed_jobs(c)
    local names = if #jobs == 0 then "no job named" else table.concat(jobs, ", ") end
    local said = "The push run of main at " .. short .. " (" .. first_line(c.title) .. ") ended " ..
      c.conclusion .. ": " .. c.url .. "\n\nFailed: " .. names .. "."
    if open == nil then
      local made: IssueBody = { title = "main is red: " .. names .. " at " .. short,
        body = said .. "\n\nThis issue closes when a push run of main passes again " ..
          "(.github/workflows/main-red.yml).",
        labels = { MainRed.label } }
      ensure_label(c)
      post(c, "/issues", made)
      return "main is red at " .. short .. ": opened an issue (" .. names .. ")"
    end
    local still: CommentBody = { body = "Still red. " .. said }
    post(c, "/issues/" .. tostring(open) .. "/comments", still)
    return "main is still red at " .. short .. ": commented on #" .. tostring(open)
  end
  if open == nil then return "main is green at " .. short .. ": no issue is open" end
  local green: CommentBody = { body = "Green again: the push run of main at " .. short ..
      " (" .. first_line(c.title) .. ") passed: " .. c.url }
  post(c, "/issues/" .. tostring(open) .. "/comments", green)
  local closed: StateBody = { state = "closed" }
  assert(GithubApi.object(c.client, "PATCH", "repos/" .. c.repository .. "/issues/" .. tostring(open), closed))
  return "main is green again at " .. short .. ": closed #" .. tostring(open)
end

--- The context the job's environment `env` gives.
function MainRed.context(env: {string:string}): MainRed.Context
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
    branch = need("BRANCH"),
    sha = need("SHA"),
    title = env["TITLE"] or "",
    url = need("URL"),
    run_id = need("RUN_ID"),
  }
end

--- `driver.tl main-red`.
function MainRed.command(argv: {string}, context?: MainRed.Context): integer
  local ran, answer = pcall(function(): string
    assert(argv[1] == nil, "usage: driver.tl main-red")
    return MainRed.follow(context or MainRed.context(Env.all()))
  end)
  if not ran then
    local _, _ = Fs.put(Fs.stderr, "main-red: " .. tostring(answer) .. "\n")
    return 1
  end
  assert(Fs.put(Fs.stdout, tostring(answer) .. "\n"))
  return 0
end

return MainRed
