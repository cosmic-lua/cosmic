local GithubApi = require("cosmic_ci.github_api")
local PrereleaseFollow = require("cosmic_ci.prerelease_follow")

local base <const> = "https://api.test/repos/owner/repo"
--- 2026-11-23T12:00:00Z, in seconds since the epoch.
local noon <const> = 1795435200

--- What GitHub answers a request of `method` to `path` with where it
--- takes it.
local function accepted(method: string, path: string): integer
  if method == "PATCH" then return 200 end
  if path:find("/dispatches", 1, true) ~= nil then return 204 end
  return 201
end

--- A client that answers `runs` for the list of ci.yml's runs, `issues`
--- (none where nil) for the list of open issues, `status` for anything
--- else (where nil, what GitHub answers where it takes it), and records
--- each request as "METHOD path body".
local function fake(runs: string, status?: integer, issues?: string): GithubApi.Client, {string}
  local calls: mut {string} = {}
  return {
    base = "https://api.test",
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      local path = request.url:sub(#base + 1)
      calls[#calls + 1] = request.method .. " " .. path .. " " .. (request.body or "")
      if request.method == "GET" and path:find("^/issues") ~= nil then
        return { status = 200, headers = {}, body = issues or "[]" }, ""
      end
      if request.method == "GET" then return { status = 200, headers = {}, body = runs }, "" end
      return { status = status or accepted(request.method, path), headers = {}, body = "" }, ""
    end,
    fetch = function(_url: string, _to: string): boolean, string return false, "no fetch" end,
  }, calls
end

local function context(client: GithubApi.Client, event: string, conclusion: string,
                       attempt?: integer, branch?: string): PrereleaseFollow.Context
  return { client = client, repository = "owner/repo", event = event, conclusion = conclusion,
    attempt = attempt or 1, run_id = "42", branch = branch or "main", head_sha = "abc123", now = noon, window = 6 * 3600 }
end

local function runs_text(...: string): string
  local items: mut {string} = {}
  for _, item in ipairs({ ... }) do items[#items + 1] = item end
  return '{"workflow_runs":[' .. table.concat(items, ",") .. "]}"
end

--- A green push with no full run of main in the window starts one.
local function test_a_green_push_starts_a_full_run_where_none_is_recent()
  local client, calls = fake(runs_text('{"event":"push","created_at":"2026-11-23T11:50:00Z","status":"completed","conclusion":"success","run_attempt":1}',
    '{"event":"workflow_dispatch","created_at":"2026-11-23T05:59:00Z","status":"completed","conclusion":"success","run_attempt":1}',
    '{"event":"schedule","created_at":"2026-11-22T12:00:00Z","status":"completed","conclusion":"success","run_attempt":1}'))
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("one is started", 1, true), said)
  assert(#calls == 4 and calls[1] == "GET /actions/workflows/ci.yml/runs?branch=main&event=schedule&per_page=5 " and
      calls[2] == "GET /actions/workflows/ci.yml/runs?branch=main&event=workflow_dispatch&per_page=5 ", table.concat(calls, "|"))
  assert(calls[3] == 'POST /actions/workflows/ci.yml/dispatches {"ref":"main"}', calls[3])
  assert(calls[4] == "GET /issues?state=open&creator=github-actions%5Bbot%5D&per_page=100 ", calls[4])
end

--- A full run still going that started within the window, a daily or a
--- manual one, keeps a push from starting another.
local function test_a_recent_full_run_keeps_a_push_from_starting_another()
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    local client, calls = fake(runs_text('{"event":"' .. event .. '","created_at":"2026-11-23T06:01:00Z","status":"in_progress","conclusion":null,"run_attempt":1}'))
    local said = PrereleaseFollow.follow(context(client, "push", "success"))
    assert(said:find("359 minutes ago", 1, true), said)
    assert(#calls == 3, table.concat(calls, "|"))
  end
end

--- A pull request's run, a cancelled push and a run of another branch
--- start nothing and ask nothing.
local function test_nothing_follows_a_cancelled_push_or_another_branch()
  local record Case
    event: string
    conclusion: string
    branch: string
  end
  local cases: {Case} = { { event = "push", conclusion = "cancelled", branch = "main" },
    { event = "push", conclusion = "failure", branch = "topic" },
    { event = "pull_request", conclusion = "success", branch = "main" },
    { event = "push", conclusion = "success", branch = "topic" },
    { event = "schedule", conclusion = "success", branch = "main" },
    { event = "schedule", conclusion = "cancelled", branch = "main" },
    { event = "workflow_dispatch", conclusion = "failure", branch = "topic" } }
  for _, case in ipairs(cases) do
    local client, calls = fake(runs_text())
    local said = PrereleaseFollow.follow(context(client, case.event, case.conclusion, 1, case.branch))
    assert(said:find("nothing follows", 1, true), said)
    assert(#calls == 0, table.concat(calls, "|"))
  end
end

--- A full run's first failed attempt re-runs its failed jobs; a second
--- does not.
local function test_a_full_run_that_failed_once_is_tried_once_more()
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    local client, calls = fake(runs_text(), 201)
    local said = PrereleaseFollow.follow(context(client, event, "failure", 1))
    assert(said:find("run again", 1, true), said)
    assert(#calls == 1 and calls[1] == "POST /actions/runs/42/rerun-failed-jobs ", calls[1])
    local again, more = fake(runs_text(), 201)
    said = PrereleaseFollow.follow(context(again, event, "failure", 2))
    assert(said:find("not tried again", 1, true), said)
    assert(#more == 0, table.concat(more, "|"))
  end
end

--- A request GitHub refuses fails the command, naming the answer.
local function test_a_refused_request_fails_the_command()
  local client = fake(runs_text(), 403)
  local ok, why = pcall(PrereleaseFollow.follow, context(client, "schedule", "failure", 1))
  assert(not ok, "a refused re-run passed")
  assert(tostring(why):find("answered 403", 1, true), tostring(why))
  assert(PrereleaseFollow.command({}, context(client, "push", "success")) == 1)
  assert(PrereleaseFollow.command({ "extra" }, context(client, "push", "failure")) == 1)
end

--- A full run that started exactly the window ago no longer counts.
local function test_a_full_run_exactly_the_window_ago_does_not_count()
  local client, calls = fake(runs_text('{"event":"schedule","created_at":"2026-11-23T06:00:00Z","status":"completed","conclusion":"success","run_attempt":1}'))
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("one is started", 1, true), said)
  assert(#calls == 4, table.concat(calls, "|"))
end

--- A red push run opens the issue, naming the run and its commit, where
--- none is open, and only the bot's issue of that title counts; where
--- one is, it asks nothing more.
local function test_a_red_push_opens_the_issue_once()
  local client, calls = fake(runs_text(), nil, '[{"number":7,"title":"something else"}]')
  local said = PrereleaseFollow.follow(context(client, "push", "failure"))
  assert(said == "main is red: an issue is opened", said)
  assert(#calls == 2 and calls[1] == "GET /issues?state=open&creator=github-actions%5Bbot%5D&per_page=100 ",
    table.concat(calls, "|"))
  local opened = assert(calls[2])
  assert(opened:find("^POST /issues {") ~= nil, opened)
  assert(opened:find('"title":"main is red"', 1, true) ~= nil, opened)
  assert(opened:find("https://github.com/owner/repo/actions/runs/42 of abc123", 1, true) ~= nil, opened)
  local again, more = fake(runs_text(), nil, '[{"number":9,"title":"main is red"}]')
  said = PrereleaseFollow.follow(context(again, "push", "failure"))
  assert(said:find("#9 is open already", 1, true), said)
  assert(#more == 1, table.concat(more, "|"))
end

--- A green push run closes the open issue, saying which run passed, and
--- goes on to start a full run where none is recent.
local function test_a_green_push_closes_the_issue()
  local client, calls = fake(runs_text(), nil, '[{"number":9,"title":"main is red"}]')
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("issue #9 is closed", 1, true) and said:find("one is started", 1, true), said)
  assert(assert(calls[3]):find("/dispatches", 1, true) ~= nil, table.concat(calls, "|"))
  assert(assert(calls[4]):find("^GET /issues") ~= nil, table.concat(calls, "|"))
  local comment = assert(calls[5])
  assert(comment:find("^POST /issues/9/comments {") ~= nil, comment)
  assert(comment:find("runs/42 of abc123 passed", 1, true) ~= nil, comment)
  assert(calls[6] == 'PATCH /issues/9 {"state":"closed"}', calls[6])
  assert(#calls == 6, table.concat(calls, "|"))
end

--- A refused issue request fails the command, naming the answer; after
--- a green push, only once the full run is started.
local function test_a_refused_issue_fails_the_command()
  local client = fake(runs_text(), 403)
  local ok, why = pcall(PrereleaseFollow.follow, context(client, "push", "failure"))
  assert(not ok, "a refused issue passed")
  assert(tostring(why):find("opening the issue answered 403", 1, true), tostring(why))
  local green, calls = fake(runs_text(), nil, "not json")
  local passed, _ = pcall(PrereleaseFollow.follow, context(green, "push", "success"))
  assert(not passed, "an unreadable issue list passed")
  assert(calls[3] == 'POST /actions/workflows/ci.yml/dispatches {"ref":"main"}', table.concat(calls, "|"))
end

--- A recent full run that cannot publish any more, one that failed again,
--- was cancelled or timed out, keeps no push from starting another; one
--- that failed once, still to be tried again, does.
local function test_a_full_run_that_cannot_publish_keeps_nothing_back()
  for _, ended in ipairs({ '"failure","run_attempt":2', '"cancelled","run_attempt":1', '"timed_out","run_attempt":1' }) do
    local client = fake(runs_text('{"event":"schedule","created_at":"2026-11-23T11:00:00Z","status":"completed","conclusion":' ..
        ended .. "}"))
    local said = PrereleaseFollow.follow(context(client, "push", "success"))
    assert(said:find("no full run of main in the last", 1, true) == 1, ended .. ": " .. said)
  end
  local client = fake(runs_text('{"event":"schedule","created_at":"2026-11-23T11:00:00Z","status":"completed",' ..
      '"conclusion":"failure","run_attempt":1}'))
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("none is started", 1, true), said)
end
