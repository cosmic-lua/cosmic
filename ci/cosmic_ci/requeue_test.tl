local GithubApi = require("cosmic_ci.github_api")
local Requeue = require("cosmic_ci.requeue")

local base <const> = "https://api.test"
local bot <const> = "whilpbot[bot]"
--- When the triggering run was made.
local started <const> = "2026-11-24T00:30:00Z"

--- A pull request as REST answers it, with the JSON values `fields`
--- gives in place of the defaults (open, not a draft, not merged,
--- mergeable, head "head1").
local function pull_text(fields?: {string:string}): string
  local given = fields or {}
  local parts: mut {string} = {}
  for _, field in ipairs({ { "node_id", '"PR_1"' }, { "state", '"open"' }, { "draft", "false" },
      { "merged", "false" }, { "mergeable_state", '"blocked"' }, { "head", '{"sha":"head1"}' } }) do
    local name = assert(field[1])
    parts[#parts + 1] = '"' .. name .. '":' .. (given[name] or assert(field[2]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- A timeline event of `kind` at `at`, by `login` (none where nil).
local function event(kind: string, at: string, login?: string): string
  local actor = if login == nil then "null" else '{"login":"' .. login .. '"}' end
  return '{"event":"' .. kind .. '","created_at":"' .. at .. '","actor":' .. actor .. "}"
end
local added_by_person <const> = event("added_to_merge_queue", "2026-11-24T00:20:00Z", "whilp")
local removed_by_queue <const> = event("removed_from_merge_queue", "2026-11-24T00:40:00Z", "github-merge-queue[bot]")

local function joined(...: string): string
  return table.concat({ ... }, ",")
end

--- A runs answer of `runs`, each "branch@created_at".
local function runs_text(...: string): string
  local items: mut {string} = {}
  for _, run in ipairs({ ... }) do
    local branch, at = run:match("^(.*)@(.*)$")
    items[#items + 1] = '{"head_branch":"' .. assert(branch) .. '","created_at":"' .. assert(at) .. '"}'
  end
  return '{"workflow_runs":[' .. table.concat(items, ",") .. "]}"
end

--- What a fake answers, beside the pull request: its timeline, read by
--- read (the last again once they run out), the queue's runs, the pull
--- request runs of its head, and the mutation.
local record Answers
  timelines: {string}
  queued?: string
  tested?: string
  enqueued?: string
  enqueue_status?: integer
end

--- A run context whose client answers `pull` and `answers`, recording
--- each request as "METHOD path" and each wait as "sleep N".
local function fake(pull: string, answers: Answers, event_name?: string, conclusion?: string,
                    branch?: string): Requeue.Context, {string}
  local calls: mut {string} = {}
  local read = 0
  local client: GithubApi.Client = {
    base = base,
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      local path = request.url:sub(#base + 1)
      local call = request.method .. " " .. path
      calls[#calls + 1] = call
      local function ok(body: string): GithubApi.Reply?, string
        return { status = 200, headers = {}, body = body }, ""
      end
      if path:find("/timeline", 1, true) ~= nil then
        read = read + 1
        local events = answers.timelines[read] or assert(answers.timelines[#answers.timelines])
        return ok("[" .. events .. "]")
      end
      if path:find("event=merge_group", 1, true) ~= nil then
        return ok(answers.queued or runs_text("gh-readonly-queue/main/pr-4038-aaa@" .. started))
      end
      if path:find("event=pull_request", 1, true) ~= nil then
        return ok(answers.tested or runs_text("claude/x@2026-11-24T00:10:00Z", "claude/x@2026-11-24T00:15:00Z"))
      end
      if request.method == "GET" then return ok(pull) end
      return { status = answers.enqueue_status or 200, headers = {},
        body = answers.enqueued or '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"state":"QUEUED"}}}}' }, ""
    end,
    fetch = function(_url: string, _to: string): boolean, string return false, "no fetch" end,
  }
  local c: Requeue.Context = { client = client, repository = "owner/repo", event = event_name or "merge_group",
    conclusion = conclusion or "success", branch = branch or "gh-readonly-queue/main/pr-4038-5744abc",
    started = started, bot = bot,
    sleep = function(seconds: integer)
      local call = "sleep " .. tostring(seconds)
      calls[#calls + 1] = call
    end }
  return c, calls
end

local function enqueued(calls: {string}): boolean
  for _, call in ipairs(calls) do
    if call == "POST /graphql" then return true end
  end
  return false
end

--- A pull request the queue dropped after this run began goes back, as
--- its head, by its id.
local function test_a_pull_request_the_queue_dropped_goes_back()
  local c, calls = fake(pull_text(), { timelines = { joined(added_by_person, removed_by_queue) } })
  local said = Requeue.follow(c)
  assert(said:find("#4038 is back in the merge queue", 1, true) ~= nil, said)
  assert(table.concat(calls, "|") == "GET /repos/owner/repo/pulls/4038|" ..
      "GET /repos/owner/repo/issues/4038/timeline?per_page=100|" ..
      "GET /repos/owner/repo/actions/workflows/ci.yml/runs?event=merge_group&per_page=100|" ..
      "GET /repos/owner/repo/actions/workflows/ci.yml/runs?event=pull_request&head_sha=head1&per_page=100|" ..
      "POST /graphql", table.concat(calls, "|"))
end

--- The enqueue names the pull request's id and the head the queue took.
local function test_the_enqueue_names_the_pull_request_and_its_head()
  local c, _ = fake(pull_text({ node_id = '"PR_9"', head = '{"sha":"head9"}' }),
    { timelines = { joined(added_by_person, removed_by_queue) } })
  local body = ""
  local send = c.client.send
  local client: GithubApi.Client = { base = base, fetch = c.client.fetch,
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      if request.method == "POST" then body = request.body or "" end
      return send(request)
    end }
  local named: Requeue.Context = { client = client, repository = c.repository, event = c.event,
    conclusion = c.conclusion, branch = c.branch, started = c.started, bot = c.bot, sleep = c.sleep }
  assert(Requeue.follow(named):find("back in the merge queue", 1, true) ~= nil)
  assert(body:find('"id":"PR_9"', 1, true) ~= nil and body:find('"head":"head9"', 1, true) ~= nil, body)
end

--- A removal that comes after the run ended is waited for, a few times.
local function test_a_removal_that_comes_late_is_waited_for()
  local c, calls = fake(pull_text(), { timelines = { added_by_person, joined(added_by_person, removed_by_queue) } })
  local said = Requeue.follow(c)
  assert(said:find("is back in the merge queue", 1, true) ~= nil, said)
  assert(calls[3] == "sleep 15" and calls[#calls] == "POST /graphql", table.concat(calls, "|"))
  local still, waits = fake(pull_text(), { timelines = { added_by_person } })
  said = Requeue.follow(still)
  assert(said:find("it is still in the queue", 1, true) ~= nil, said)
  local slept = 0
  for _, call in ipairs(waits) do
    if call:find("^sleep") ~= nil then slept = slept + 1 end
  end
  assert(slept == 3 and not enqueued(waits), table.concat(waits, "|"))
end

--- A pull request stays out of the queue where a person took it out, it
--- is closed, merged, a draft or in conflict, the removal is not this
--- run's, its head is not the one the queue took, or this job put it
--- back twice already.
local function test_a_pull_request_stays_out_where_it_should()
  local record Case
    pull?: string
    events: string
    queued?: string
    tested?: string
    why: string
  end
  local dropped = joined(added_by_person, removed_by_queue)
  local again = event("added_to_merge_queue", "2026-11-24T00:41:00Z", bot)
  local cases: {Case} = {
    { events = joined(added_by_person, event("removed_from_merge_queue", "2026-11-24T00:40:00Z", "whilp")),
      why = "whilp took it out" },
    { events = joined(added_by_person, removed_by_queue, event("head_ref_force_pushed", "2026-11-24T00:45:00Z", "whilp")),
      why = "force-pushed since" },
    { events = event("committed", "2026-11-24T00:10:00Z"), why = "no event of it" },
    { events = joined(dropped, event("merged", "2026-11-24T00:40:00Z", "whilp"),
      event("closed", "2026-11-24T00:40:00Z", "whilp")), why = "it was merged" },
    { events = joined(added_by_person, event("removed_from_merge_queue", "2026-11-24T00:25:00Z", "github-merge-queue[bot]")),
      why = "came before this run began" },
    { events = dropped, queued = runs_text("gh-readonly-queue/main/pr-4038-aaa@" .. started,
      "gh-readonly-queue/main/pr-4038-bbb@2026-11-24T00:35:00Z"), why = "a later queue run of it began" },
    { events = dropped, tested = runs_text("claude/x@2026-11-24T00:45:00Z"), why = "pushed after it was last added" },
    { events = dropped, tested = runs_text(), why = "no pull request run of ci tested its head" },
    { pull = pull_text({ state = '"closed"', merged = "true" }), events = dropped, why = "it is merged" },
    { pull = pull_text({ state = '"closed"' }), events = dropped, why = "it is closed" },
    { pull = pull_text({ draft = "true" }), events = dropped, why = "it is a draft" },
    { pull = pull_text({ mergeable_state = '"dirty"' }), events = dropped, why = "in conflict" },
    { events = joined(dropped, again, removed_by_queue, again, removed_by_queue), why = "put it back 2 times already" },
  }
  for _, case in ipairs(cases) do
    local c, calls = fake(case.pull or pull_text(), { timelines = { case.events }, queued = case.queued,
      tested = case.tested })
    local said = Requeue.follow(c)
    assert(said:find("stays as it is", 1, true) ~= nil and said:find(case.why, 1, true) ~= nil, said)
    assert(not enqueued(calls), said)
  end
  -- Another App's adds are not this job's; a queue run of another pull
  -- request, or this one's from before, is not a later one of it.
  local other = event("added_to_merge_queue", "2026-11-24T00:20:00Z", "other[bot]")
  local c, _ = fake(pull_text(), { timelines = { joined(other, removed_by_queue, other, removed_by_queue) },
    queued = runs_text("gh-readonly-queue/main/pr-40380-ccc@2026-11-24T00:50:00Z",
      "gh-readonly-queue/main/pr-4038-ddd@2026-11-24T00:01:00Z") })
  local said = Requeue.follow(c)
  assert(said:find("is back in the merge queue", 1, true) ~= nil, said)
end

--- Nothing follows a run that is not a passing queue run of main.
local function test_nothing_follows_a_run_that_is_no_passing_queue_run()
  for _, case in ipairs({ { "push", "success" }, { "merge_group", "failure" }, { "pull_request", "success" } }) do
    local c, calls = fake("", { timelines = { "" } }, case[1], case[2])
    local said = Requeue.follow(c)
    assert(said:find("nothing follows", 1, true) ~= nil and #calls == 0, said)
  end
  for _, branch in ipairs({ "main", "gh-readonly-queue/release/pr-1-abc" }) do
    local c, calls = fake("", { timelines = { "" } }, nil, nil, branch)
    assert(Requeue.follow(c):find("names no pull request", 1, true) ~= nil, branch)
    assert(#calls == 0)
  end
end

--- An enqueue GitHub refuses, by its status or an error, fails the job.
local function test_a_refused_enqueue_fails_the_job()
  local dropped = joined(added_by_person, removed_by_queue)
  local c, _ = fake(pull_text(), { timelines = { dropped }, enqueued = '{"errors":[{"message":"no"}]}' })
  local ran, why = pcall(Requeue.follow, c)
  assert(not ran and tostring(why):find("GraphQL refused", 1, true) ~= nil, tostring(why))
  assert(Requeue.command({}, c) == 1)
  local refused, _ = fake(pull_text(), { timelines = { dropped }, enqueued = "{}", enqueue_status = 502 })
  ran, why = pcall(Requeue.follow, refused)
  assert(not ran and tostring(why):find("answered 502", 1, true) ~= nil, tostring(why))
end
