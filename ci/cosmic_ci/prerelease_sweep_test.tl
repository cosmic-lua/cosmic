local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local PrereleaseSweep = require("cosmic_ci.prerelease_sweep")

local base <const> = "https://api.test/repos/owner/repo"
--- 2026-11-24T12:00:00Z, in seconds since the epoch.
local noon <const> = 1795521600

--- A client whose `send` returns `runs` for the list of ci.yml's runs,
--- `releases` for the list of releases, `status` (201 where nil) for a
--- POST, and records each request as "METHOD path".
local function fake(runs: string, releases: string, status?: integer): GithubApi.Client, {string}
  local calls: mut {string} = {}
  return {
    base = "https://api.test",
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      local path = request.url:sub(#base + 1)
      calls[#calls + 1] = request.method .. " " .. path
      if request.method ~= "GET" then
        return { status = status or 201, headers = {}, body = "" }, ""
      end
      if path:find("^/releases") ~= nil then
        return { status = 200, headers = {}, body = releases }, ""
      end
      return { status = 200, headers = {}, body = runs }, ""
    end,
    fetch = function(_url: string, _to: string): boolean, string return false, "no fetch" end,
  }, calls
end

--- A run of the list, as JSON: `by` started it.
local function run_of(id: integer, by: string, created: string, status: string, conclusion: string,
                      attempt: integer, event: string, branch: string): string
  local ended = if conclusion == "" then "null" else '"' .. conclusion .. '"' end
  return '{"id":' .. tostring(id) .. ',"event":"' .. event .. '","head_branch":"' .. branch ..
    '","status":"' .. status .. '","conclusion":' .. ended ..
    ',"run_attempt":' .. tostring(attempt) .. ',"head_sha":"sha' .. tostring(id) ..
    '","created_at":"' .. created .. '","triggering_actor":{"login":"' .. by .. '"}}'
end

--- A manual run of main.
local function run(id: integer, by: string, created: string, status: string, conclusion: string,
                   attempt: integer): string
  return run_of(id, by, created, status, conclusion, attempt, "workflow_dispatch", "main")
end

local function runs_of(...: string): string
  local items: mut {string} = {}
  for _, item in ipairs({ ... }) do items[#items + 1] = item end
  return '{"workflow_runs":[' .. table.concat(items, ",") .. "]}"
end

local bot <const> = "github-actions[bot]"

local function context(client: GithubApi.Client, output: string): PrereleaseSweep.Context
  return { client = client, repository = "owner/repo", output = output, now = noon }
end

--- A green run follow started, with no prerelease of its commit, is
--- written out for `publish`; one a person started is not the sweep's.
local function test_a_green_unpublished_run_is_written_out(tmp: string)
  local output = tmp .. "/output"
  local client, calls = fake(runs_of(run(8, "whilp", "2026-11-24T11:00:00Z", "completed", "success", 1),
    run(7, bot, "2026-11-24T06:00:00Z", "completed", "success", 1)), '[{"tag_name":"20261123-sha6"}]')
  local said = PrereleaseSweep.sweep(context(client, output))
  assert(said:find("publish follows", 1, true), said)
  local written = assert(Fs.read(output))
  assert(written == "run_id=7\nhead_sha=sha7\n", written)
  assert(#calls == 2 and calls[1] == "GET /actions/workflows/ci.yml/runs?branch=main&per_page=50", table.concat(calls, "|"))
end

--- A run whose commit a prerelease names writes nothing.
local function test_a_published_run_writes_nothing(tmp: string)
  local output = tmp .. "/output"
  local client = fake(runs_of(run(7, bot, "2026-11-24T06:00:00Z", "completed", "success", 1)),
    '[{"tag_name":"20261124-sha70"},{"tag_name":"20261124-sha7"}]')
  local said = PrereleaseSweep.sweep(context(client, output))
  assert(said:find("is published", 1, true), said)
  assert(not assert(Fs.status(output)).exists, "an output was written")
end

--- A first attempt that failed re-runs its failed jobs; a second, a run
--- still going and one older than a day are left alone.
local function test_only_a_failed_first_attempt_runs_again(tmp: string)
  local client, calls = fake(runs_of(run(7, bot, "2026-11-24T06:00:00Z", "completed", "failure", 1)), "[]")
  local said = PrereleaseSweep.sweep(context(client, tmp .. "/output"))
  assert(said:find("run again", 1, true), said)
  assert(calls[2] == "POST /actions/runs/7/rerun-failed-jobs", table.concat(calls, "|"))
  local cases: {string} = { run(7, bot, "2026-11-24T06:00:00Z", "completed", "failure", 2),
    run(7, bot, "2026-11-24T06:00:00Z", "completed", "cancelled", 1),
    run(7, bot, "2026-11-23T11:00:00Z", "completed", "failure", 1) }
  for _, case in ipairs(cases) do
    local quiet, asked = fake(runs_of(case), "[]")
    said = PrereleaseSweep.sweep(context(quiet, tmp .. "/output"))
    assert(said:find("nothing to do", 1, true), said)
    assert(#asked == 1, table.concat(asked, "|"))
  end
end

--- A refused re-run fails the command, naming the status.
local function test_a_refused_request_fails_the_command(tmp: string)
  local client = fake(runs_of(run(7, bot, "2026-11-24T06:00:00Z", "completed", "failure", 1)), "[]", 403)
  local ok, why = pcall(PrereleaseSweep.sweep, context(client, tmp .. "/output"))
  assert(not ok, "a refused re-run passed")
  assert(tostring(why):find("answered 403", 1, true), tostring(why))
  assert(PrereleaseSweep.command({}, context(client, tmp .. "/output")) == 1)
  assert(PrereleaseSweep.command({ "extra" }, context(client, tmp .. "/output")) == 1)
end

--- Of the token's runs, the newest full run of main counts: a push run, a
--- run of another branch and an older run do not; a run still going is
--- left alone.
local function test_the_newest_full_run_of_main_counts(tmp: string)
  local output = tmp .. "/output"
  local client = fake(runs_of(run_of(9, bot, "2026-11-24T11:00:00Z", "completed", "success", 1, "push", "main"),
    run_of(8, bot, "2026-11-24T10:00:00Z", "completed", "success", 1, "workflow_dispatch", "topic"),
    run(5, bot, "2026-11-24T05:00:00Z", "completed", "success", 1),
    run_of(6, bot, "2026-11-24T08:00:00Z", "completed", "success", 2, "schedule", "main")), "[]")
  local said = PrereleaseSweep.sweep(context(client, output))
  assert(said:find("run 6 of sha6 passed", 1, true), said)
  local going = fake(runs_of(run(7, bot, "2026-11-24T06:00:00Z", "in_progress", "", 1)), "[]")
  said = PrereleaseSweep.sweep(context(going, tmp .. "/other"))
  assert(said:find("is in_progress", 1, true), said)
end
