local GithubApi = require("cosmic_ci.github_api")
local PrereleaseFollow = require("cosmic_ci.prerelease_follow")

local base <const> = "https://api.test/repos/owner/repo/actions"
--- 2026-11-23T12:00:00Z, in seconds since the epoch.
local noon <const> = 1795435200

--- A client that answers `runs` for the list of ci.yml's runs, `status`
--- for any POST, and records each request as "METHOD path body".
local function fake(runs: string, status?: integer): GithubApi.Client, {string}
  local calls: mut {string} = {}
  return {
    base = "https://api.test",
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      local line = request.method .. " " .. request.url:sub(#base + 1) .. " " .. (request.body or "")
      calls[#calls + 1] = line
      if request.method == "GET" then return { status = 200, headers = {}, body = runs }, "" end
      return { status = status or 204, headers = {}, body = "" }, ""
    end,
    fetch = function(_url: string, _to: string): boolean, string return false, "no fetch" end,
  }, calls
end

local function context(client: GithubApi.Client, event: string, conclusion: string,
                       attempt?: integer, branch?: string): PrereleaseFollow.Context
  return { client = client, repository = "owner/repo", event = event, conclusion = conclusion,
    attempt = attempt or 1, run_id = "42", branch = branch or "main", now = noon, window = 6 * 3600 }
end

local function runs_text(...: string): string
  local items: mut {string} = {}
  for _, item in ipairs({ ... }) do items[#items + 1] = item end
  return '{"workflow_runs":[' .. table.concat(items, ",") .. "]}"
end

--- A green push with no full run of main in the window starts one.
local function test_a_green_push_starts_a_full_run_where_none_is_recent()
  local client, calls = fake(runs_text('{"event":"push","created_at":"2026-11-23T11:50:00Z"}',
    '{"event":"workflow_dispatch","created_at":"2026-11-23T05:59:00Z"}',
    '{"event":"schedule","created_at":"2026-11-22T12:00:00Z"}'))
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("one is started", 1, true), said)
  assert(#calls == 3 and calls[1] == "GET /workflows/ci.yml/runs?branch=main&event=schedule&per_page=5 " and
      calls[2] == "GET /workflows/ci.yml/runs?branch=main&event=workflow_dispatch&per_page=5 ", table.concat(calls, "|"))
  assert(calls[3] == 'POST /workflows/ci.yml/dispatches {"ref":"main"}', calls[3])
end

--- A full run that started within the window, a daily or a manual one,
--- whatever it ended, keeps a push from starting another.
local function test_a_recent_full_run_keeps_a_push_from_starting_another()
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    local client, calls = fake(runs_text('{"event":"' .. event .. '","created_at":"2026-11-23T06:01:00Z"}'))
    local said = PrereleaseFollow.follow(context(client, "push", "success"))
    assert(said:find("359 minutes ago", 1, true), said)
    assert(#calls == 2, table.concat(calls, "|"))
  end
end

--- A push that failed, a pull request's run and a run of another branch
--- start nothing and ask nothing.
local function test_nothing_follows_a_red_push_or_another_branch()
  local record Case
    event: string
    conclusion: string
    branch: string
  end
  local cases: {Case} = { { event = "push", conclusion = "failure", branch = "main" },
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
    assert(#calls == 1 and calls[1] == "POST /runs/42/rerun-failed-jobs ", calls[1])
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
  local client, calls = fake(runs_text('{"event":"schedule","created_at":"2026-11-23T06:00:00Z"}'))
  local said = PrereleaseFollow.follow(context(client, "push", "success"))
  assert(said:find("one is started", 1, true), said)
  assert(#calls == 3, table.concat(calls, "|"))
end
