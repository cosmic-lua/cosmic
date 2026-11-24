--- Puts a pull request back in the merge queue where the queue dropped it
--- though its own run passed, for requeue.yml (`driver.tl requeue`). The
--- queue sometimes removes an entry about when that entry's run passes,
--- and does not put it back; its auto-merge is gone with it, so the pull
--- request waits for a person to turn it on again.
---
--- After a merge queue run of ci that passed, it reads the pull request
--- the run tested, its timeline, and the runs of ci (REST) and puts it
--- back in the queue where all of these hold:
---
--- - it is open, not a draft, and not in conflict with main;
--- - the queue's last event of it is a removal, made by the queue itself
---   (`queue_bot`), not by a person, after this run began, and no other
---   queue run of it began after this one: the removal is this run's;
--- - its head was first tested by a pull request run of ci before it was
---   last added, and not force-pushed since, so it is the head the queue
---   took: the queue squashes, so this run's commit does not name it;
--- - this job's App ([`Context.bot`]) has added it fewer than `most`
---   times, so a queue that drops it each time cannot hold it in a loop.
---
--- The removal can come seconds after the run ends: where the pull
--- request is still in the queue, it reads it again, `tries` times in
--- all, `pause_s` seconds apart.
---
--- It reads the run from its environment: EVENT, CONCLUSION, BRANCH (the
--- queue's branch, `gh-readonly-queue/main/pr-<number>-<sha>`) and
--- STARTED (when it was made), the triggering run's
--- (github.event.workflow_run), REPOSITORY, and BOT, the App's login, with
--- the client GH_TOKEN makes. A request GitHub refuses fails the job.
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Plural = require("cosmic_ci.plural")
local Shape = require("cosmic.shape")

local record Requeue
  --- The triggering run, and what `follow` needs to act on it.
  record Context
    client: GithubApi.Client
    repository: string
    event: string
    conclusion: string
    branch: string
    --- When the run was made, as GitHub writes a time ("2026-11-24T01:02:03Z").
    started: string
    --- The login of the App this job acts as, as "<slug>[bot]".
    bot: string
    --- Waits `seconds`; a test passes one that only counts.
    sleep: function(seconds: integer)
  end
end

--- The most times this job puts one pull request back.
local most <const> = 2

--- How many times it reads a pull request still in the queue, and how
--- long it waits between.
local tries <const> = 4
local pause_s <const> = 15

--- The login the queue's own removals name.
local queue_bot <const> = "github-merge-queue[bot]"

--- What `follow` reads of `.../pulls/<number>`.
local record Pull
  node_id: string
  state: string
  draft: boolean
  merged: boolean
  mergeable_state?: string
  record Head
    sha: string
  end
  head: Head
end
local PULL <const> = Shape.record_of("Pull")

--- What `follow` reads of an event of `.../issues/<number>/timeline`.
local record Actor
  login?: string
end
local record Event
  event?: string
  actor?: Actor
  created_at?: string
end
local EVENT <const> = Shape.record_of("Event")

--- What `follow` reads of a `.../actions/runs` answer.
local record Run
  head_branch?: string
  created_at: string
end
local record Runs
  workflow_runs: {Run}
end
local RUNS <const> = Shape.record_of("Runs")

--- Why a pull request whose timeline is `events` stays out, for the run
--- `c` names; nil, and when it was last added, where it goes back.
--- "queued" where it is in the queue, which a later read may find
--- otherwise.
local function kept_out(events: {Event}, c: Requeue.Context): string?, string
  local last: Event? = nil
  local added_at = ""
  local pushed = false
  local ended = ""
  local put_back = 0
  for _, item in ipairs(events) do
    local kind = item.event
    if kind == "added_to_merge_queue" or kind == "removed_from_merge_queue" then
      last = item
      if kind == "added_to_merge_queue" then
        pushed = false
        added_at = item.created_at or ""
        local actor = item.actor
        if actor ~= nil and actor.login == c.bot then put_back = put_back + 1 end
      end
    elseif kind == "head_ref_force_pushed" then
      pushed = true
    elseif kind == "merged" or (kind == "closed" and ended ~= "merged") then
      ended = kind
    elseif kind == "reopened" then
      ended = ""
    end
  end
  if ended ~= "" then return "it was " .. ended, "" end
  if last == nil then return "the queue has no event of it", "" end
  if last.event == "added_to_merge_queue" then return "queued", "" end
  local actor = last.actor
  local remover = actor and actor.login or "nobody"
  if remover ~= queue_bot then return remover .. " took it out of the queue", "" end
  if (last.created_at or "") < c.started then
    return "the queue's last removal of it came before this run began", ""
  end
  if pushed then return "it was force-pushed since it was last added", "" end
  if put_back >= most then
    return "this job put it back " .. Plural.count(put_back, "time") .. " already", ""
  end
  return nil, added_at
end

--- Why the runs of ci say the pull request `number`, whose head is
--- `head` and which was last added at `added_at`, stays out; nil where
--- they do not.
local function runs_say(c: Requeue.Context, number: string, head: string, added_at: string): string?
  local base = "repos/" .. c.repository .. "/actions/workflows/ci.yml/runs"
  local queued_text = assert(GithubApi.get(c.client, base .. "?event=merge_group&per_page=100"))
  local queued = assert(RUNS:decode_into(queued_text))
  local prefix = "gh-readonly-queue/main/pr-" .. number .. "-"
  for _, run in ipairs(queued.workflow_runs) do
    if (run.head_branch or ""):sub(1, #prefix) == prefix and run.created_at > c.started then
      return "a later queue run of it began"
    end
  end
  local tested_text = assert(GithubApi.get(c.client, base .. "?event=pull_request&head_sha=" .. head .. "&per_page=100"))
  local tested = assert(RUNS:decode_into(tested_text))
  local first: string? = nil
  for _, run in ipairs(tested.workflow_runs) do
    if first == nil or run.created_at < first then first = run.created_at end
  end
  if first == nil then return "no pull request run of ci tested its head" end
  if first > added_at then return "its head was pushed after it was last added" end
  return nil
end

--- The pull request `number`'s timeline events, every page.
local function timeline(c: Requeue.Context, number: string): {Event}
  local pages = assert(GithubApi.pages(c.client, "repos/" .. c.repository .. "/issues/" .. number ..
      "/timeline?per_page=100"))
  local events: mut {Event} = {}
  for _, page in ipairs(pages) do
    local items = assert(Shape.decode_into(page, Shape.list(EVENT.spec)))
    for _, item in ipairs(items) do
      events[#events + 1] = item
    end
  end
  return events
end

--- What the enqueue sends, by GraphQL: REST has no call for it.
local enqueue_mutation <const> = [[
mutation($id: ID!, $head: GitObjectID!) {
  enqueuePullRequest(input: { pullRequestId: $id, expectedHeadOid: $head }) {
    mergeQueueEntry { state }
  }
}]]
local record EnqueueVariables
  id: string
  head: string
end
local record EnqueueRequest
  query: string
  variables: EnqueueVariables
end

--- Acts on the run `c` names, and says what it did, for the log.
function Requeue.follow(c: Requeue.Context): string
  if c.event ~= "merge_group" or c.conclusion ~= "success" then
    return "a " .. c.event .. " run that ended " .. c.conclusion .. ": nothing follows"
  end
  local number = c.branch:match("^gh%-readonly%-queue/main/pr%-(%d+)%-%x+$")
  if number == nil then
    return "the queue branch " .. c.branch .. " names no pull request: nothing follows"
  end
  local why: string? = "queued"
  local pull: Pull? = nil
  local added_at = ""
  for try = 1, tries do
    if try > 1 then c.sleep(pause_s) end
    local text = assert(GithubApi.get(c.client, "repos/" .. c.repository .. "/pulls/" .. number))
    local read = assert(PULL:decode_into(text))
    pull = read
    if read.state ~= "open" or read.merged then
      why = "it is " .. (if read.merged then "merged" else read.state end)
    elseif read.draft then
      why = "it is a draft"
    elseif read.mergeable_state == "dirty" then
      why = "it is in conflict with main"
    else
      why, added_at = kept_out(timeline(c, number), c)
    end
    if why ~= "queued" then break end
  end
  if why == "queued" then why = "it is still in the queue" end
  if why == nil then why = runs_say(c, number, assert(pull).head.sha, added_at) end
  if why ~= nil then return "#" .. number .. " stays as it is: " .. why end
  local taken = assert(pull)
  local asked: EnqueueRequest = { query = enqueue_mutation,
    variables = { id = taken.node_id, head = taken.head.sha } }
  local reply = assert(GithubApi.request(c.client, "POST", "graphql", asked))
  assert(reply.status == 200, "GraphQL answered " .. tostring(reply.status) .. ": " .. reply.body)
  assert(reply.body:find('"errors"', 1, true) == nil, "GraphQL refused the enqueue: " .. reply.body)
  return "#" .. number .. " is back in the merge queue: the queue dropped it, and this run of it passed"
end

--- The context the job's environment `env` gives.
function Requeue.context(env: {string:string}): Requeue.Context
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
    started = need("STARTED"),
    bot = need("BOT"),
    sleep = function(seconds: integer)
      local _, _ = Clock.sleep_ns(Clock.seconds(seconds))
    end,
  }
end

--- `driver.tl requeue`.
function Requeue.command(argv: {string}, context?: Requeue.Context): integer
  local ran, answer = pcall(function(): string
    assert(argv[1] == nil, "usage: driver.tl requeue")
    return Requeue.follow(context or Requeue.context(Env.all()))
  end)
  if not ran then
    local _, _ = Fs.put(Fs.stderr, "requeue: " .. tostring(answer) .. "\n")
    return 1
  end
  assert(Fs.put(Fs.stdout, tostring(answer) .. "\n"))
  return 0
end

return Requeue
