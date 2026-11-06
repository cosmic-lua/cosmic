--- [`CeilingsBase.ceilings_base`], which names the merge base of a run's
--- commit with main for the format check, against the API's JSON as the
--- API answers it (cosmic_ci/github_fake.tl).
local CeilingsBase = require("cosmic_ci.ceilings_base")
local GithubFake = require("cosmic_ci.github_fake")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local BASE <const> = "fedcba9876543210fedcba9876543210fedcba98"

--- What [`ceilings_base`] writes to $GITHUB_OUTPUT, said, and the calls it made, in `env` against the lookup's `answer`.
local function ceilings_base(env: {string: string}, answer?: string): string, string, {string}
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return answer end)
  local code = CeilingsBase.ceilings_base(env, fake.host)
  assert(code == 0, "the step never fails")
  return GithubFake.text(fake.outputs), GithubFake.text(fake.printed), fake.calls
end

local QUEUE <const>: {string: string} = { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/pr-1-" .. SHA, SHA = SHA,
  REPOSITORY = "o/r", BASE_REF = "refs/heads/main", QUEUE_BASE = "1111111111111111111111111111111111111111" }

--- The merge queue's run holds the markers to the merge base of its commit with main, which the API names, and not to its own base
--- (`merge_group.base_sha`), the entry ahead, which already holds that entry's markers.
local function test_the_queue_holds_the_markers_to_the_merge_base_with_main_not_to_its_own_base()
  local output, said, calls = ceilings_base(QUEUE, '{"merge_base_commit":{"sha":"' .. BASE .. '"},"commits":[]}')
  assert(output == "sha=" .. BASE .. "\n", output .. said)
  assert(#calls == 1 and calls[1] == "GET repos/o/r/compare/main..." .. SHA .. "?per_page=1", table.concat(calls, "\n"))
  assert(not output:find(QUEUE["QUEUE_BASE"] or "", 1, true), "the queue's own base was named")
end

--- A pull request's run and a manual run of a branch ask the same; main's own runs and a run that names no branch of the queue ask
--- nothing and name none, which fails the check where it must hold a base.
local function test_a_branch_run_asks_for_its_merge_base_and_main_and_an_unnamed_queue_ask_nothing()
  local answer = '{"merge_base_commit":{"sha":"' .. BASE .. '"}}'
  for _, case in ipairs({ { "workflow_dispatch", "refs/heads/topic" }, { "pull_request", "refs/pull/1/merge" } }) do
    local event = assert(case[1])
    local output, _, calls = ceilings_base({ EVENT = event, REF = assert(case[2]), SHA = SHA, REPOSITORY = "o/r" }, answer)
    assert(output == "sha=" .. BASE .. "\n" and #calls == 1 and calls[1] == "GET repos/o/r/compare/main..." .. SHA .. "?per_page=1",
      event .. ": " .. output .. table.concat(calls, "\n"))
  end
  local cases: {{string: string}} = {
    { EVENT = "push", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "workflow_dispatch", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "schedule", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x", SHA = SHA, REPOSITORY = "o/r" },
    { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x", SHA = SHA, REPOSITORY = "o/r", BASE_REF = "main..x" },
    {},
  }
  for _, env in ipairs(cases) do
    local none, _, asked = ceilings_base(env, answer)
    assert(none == "" and #asked == 0, tostring(env["EVENT"]) .. ": " .. none .. table.concat(asked, "\n"))
  end
  -- a lookup that fails or answers no whole commit names none, so the check fails and the run is repeated
  for _, bad in ipairs({ '{"merge_base_commit":{"sha":"abc"}}', '{"message":"Not Found"}', "not json" }) do
    local none, said = ceilings_base(QUEUE, bad)
    assert(none == "" and said:find("fails the check", 1, true) ~= nil, none .. said)
  end
  local failed, said = ceilings_base(QUEUE, nil)
  assert(failed == "" and said:find("fails the check", 1, true) ~= nil, failed .. said)
end

--- A step that cannot be read refuses, asking nothing.
local function test_an_unreadable_environment_is_refused()
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  assert(CeilingsBase.ceilings_base({ CALL_SECONDS = "soon" }, fake.host) == 2 and #fake.calls == 0)
end
