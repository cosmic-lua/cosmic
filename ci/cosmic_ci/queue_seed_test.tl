--- `find`, which finds the merge queue's run a push to main reuses, and
--- `ahead`, which finds the run ahead of a queue run whose verdicts it
--- takes, against the API's JSON, through
--- cosmic_ci/github_fake.tl: no network and a clock that only
--- a wait moves.
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local GithubFake = require("cosmic_ci.github_fake")
local QueueSeed = require("cosmic_ci.queue_seed")
local Time = require("cosmic.time")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local QUEUE <const> = "gh-readonly-queue/main/pr-7-fedcba"
local START <const> = GithubFake.START

--- A run, as the API lists it: of `event`, else merge_group.
local function run(id: string, status: string, conclusion: string | nil, sha: string, branch: string,
                   event?: string): string
  return '{"id":' .. id .. ',"event":"' .. (event or "merge_group") .. '","status":"' .. status .. '","conclusion":' ..
    (conclusion and ('"' .. conclusion .. '"') or "null") .. ',"head_sha":"' .. sha ..
    '","head_branch":"' .. branch .. '","html_url":"https://github.com/o/r/actions/runs/' .. id .. '"}'
end

--- The API's list of the runs given.
local function listed(...: string): string
  return '{"total_count":' .. select("#", ...) .. ',"workflow_runs":[' .. table.concat({ ... }, ",") .. "]}"
end

--- The API's list of a run's artifacts: each of `names`, those in
--- `expired` expired.
local function artifacts(names: {string}, expired: {string: boolean}): string
  local items: {string} = {}
  for i, name in ipairs(names) do
    items[#items + 1] = '{"id":' .. i .. ',"name":"' .. name .. '","expired":' ..
      tostring(expired[name] == true) .. "}"
  end
  return '{"total_count":' .. #items .. ',"artifacts":[' .. table.concat(items, ",") .. "]}"
end

local SEEDED <const> = artifacts({ "ci-driver-a", "seed-a", "seed-b", "portable-product-a" }, {})

--- The name of the step after which a job keeps its verdicts, in the
--- `ahead` cases that name one (SUITE_STEP): spaced and quoted, as
--- ci.yml's is.
local SUITE <const> = "run the leg's suite"

--- A run's jobs, as the API lists them: each `status name`, or
--- `status name started` with `started` seconds ago, and then, where
--- given, the status of its step SUITE (after the step that finds the
--- run ahead, queued or not).
local function jobs(...: string): string
  local items: {string} = {}
  for _, job in ipairs({ ... }) do
    local status, name, ago, suite = job:match("^(%S+) (%S+) ?(%d*) ?(%S*)$")
    local started = ago ~= "" and ('"' .. Time.format_rfc3339((START - math.tointeger(tonumber(ago))) * 1000000000,
      nil, { digits = 0 }) .. '"') or "null"
    local steps = ""
    if suite ~= "" then
      steps = ',"steps":[{"name":"find the run ahead in the queue","status":"' ..
        (suite == "queued" and "in_progress" or "completed") .. '"},{"name":"' .. SUITE ..
        '","status":"' .. suite .. '"}]'
    end
    items[#items + 1] = '{"name":"' .. name .. '","status":"' .. status .. '","started_at":' .. started .. steps .. "}"
  end
  return '{"total_count":' .. #items .. ',"jobs":[' .. table.concat(items, ",") .. "]}"
end

--- What the fake API holds: the answers to the lookups of the runs, one
--- a lookup, the last again once they run out ("FAIL" fails one); the
--- k-th successful lookup of run <id>'s artifacts answers
--- `artifacts["<id>-<k>"]`, else `artifacts["<id>"]` (none where there is
--- no such entry), and fails once where `fail_once` names <id>; one of
--- its jobs answers `jobs["<id>"]` (none where there is none).
local record Spec
  runs: {string}
  artifacts: {string: string}
  jobs: {string: string}
  fail_once: {string}
end

local function serve(spec: Spec): GithubFake.Fake
  local runs_asked = 0
  local kept: {string: integer} = {}
  local failing: {string: boolean} = {}
  for _, id in ipairs(spec.fail_once or {}) do failing[id] = true end
  return GithubFake.new(function(path: string, _nth: integer): string | nil
    local id = path:match("/runs/(%d+)/artifacts")
    if id ~= nil then
      if failing[id] then
        failing[id] = nil
        return nil
      end
      kept[id] = (kept[id] or 0) + 1
      return spec.artifacts[id .. "-" .. kept[id]] or spec.artifacts[id] or artifacts({}, {})
    end
    id = path:match("/runs/(%d+)/jobs")
    if id ~= nil then return spec.jobs and spec.jobs[id] or jobs() end
    runs_asked = runs_asked + 1
    local text = spec.runs[math.min(runs_asked, #spec.runs)]
    if text == "FAIL" then return nil end
    return text
  end)
end

--- The lookups of the runs among `fake`'s calls.
local function lookups(fake: GithubFake.Fake): integer
  return GithubFake.count(fake, "workflows/ci.yml/runs")
end

local function outputs(fake: GithubFake.Fake): string
  return GithubFake.text(fake.outputs)
end

local function said(fake: GithubFake.Fake): string
  return GithubFake.text(fake.printed)
end

--- `find` for legs a and b against `spec`, three tries with no wait
--- between them: the fake, and the status.
local function find(spec: Spec): GithubFake.Fake, integer
  local fake = serve(spec)
  local code = QueueSeed.find({ REPOSITORY = "o/r", SHA = SHA, LEGS = "a b", WAIT_SECONDS = "0", TRIES = "3" },
    fake.host)
  return fake, code
end

local function found(id: string): string
  return "run=" .. id .. "\nurl=https://github.com/o/r/actions/runs/" .. id .. "\n"
end
local NONE <const> = "run=\nurl=\n"

--- The queue's passing run of this commit is found, by the commit and
--- the event, and named in the step summary.
local function test_a_passing_queue_run_is_found()
  local fake, code = find({ runs = { listed(run("42", "completed", "success", SHA, QUEUE)) },
    artifacts = { ["42"] = SEEDED } })
  assert(code == 0, said(fake))
  assert(outputs(fake) == found("42"), outputs(fake))
  assert(fake.calls[1] == "GET repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA ..
      "&per_page=20", fake.calls[1])
  assert(fake.calls[2] == "GET repos/o/r/actions/runs/42/artifacts?per_page=100", fake.calls[2])
  assert(#fake.calls == 2, table.concat(fake.calls, "\n"))
  assert(said(fake):find("passed the merge queue in https://github.com/o/r/actions/runs/42", 1, true), said(fake))
  assert(GithubFake.text(fake.summaries):find("runs/42", 1, true))
end

--- No run of this commit, or none that passed on main's queue with
--- every leg's seed, is none: the push runs the full scope, and the
--- lookup never fails it.
local function test_no_passing_seeded_queue_run_is_none()
  local cases: {{string: string}} = {
    { runs = listed(), why = "no run" },
    { runs = listed(run("42", "completed", "failure", SHA, QUEUE)), why = "a failed run" },
    { runs = listed(run("42", "completed", "cancelled", SHA, QUEUE)), why = "a cancelled run" },
    { runs = listed(run("42", "completed", "success", "f" .. SHA:sub(2), QUEUE)), why = "another commit's run" },
    { runs = listed(run("42", "completed", "success", SHA, "gh-readonly-queue/other/pr-7-x")),
      why = "another branch's queue" },
    { runs = listed(run("43", "completed", "success", SHA, QUEUE)), why = "a run with no seed" },
    { runs = listed(run("44", "completed", "success", SHA, QUEUE)), why = "a run with one leg's seed" },
    { runs = listed(run("45", "completed", "success", SHA, QUEUE)), why = "a run whose seed expired" },
  }
  for _, case in ipairs(cases) do
    local fake, code = find({ runs = { case.runs }, artifacts = {
      ["42"] = SEEDED, ["43"] = artifacts({ "portable-product-a" }, {}),
      ["44"] = artifacts({ "seed-a", "portable-product-b" }, {}),
      ["45"] = artifacts({ "seed-a", "seed-b" }, { ["seed-b"] = true }),
    } })
    assert(code == 0, case.why .. ": " .. said(fake))
    assert(outputs(fake) == NONE, case.why .. ": " .. outputs(fake))
    assert(said(fake):find("the full scope runs", 1, true), said(fake))
  end
  -- A run missing a leg's seed names the leg.
  local fake = find({ runs = { listed(run("44", "completed", "success", SHA, QUEUE)) },
    artifacts = { ["44"] = artifacts({ "seed-a" }, {}) } })
  assert(said(fake):find("run 44 has no seed for: b\n", 1, true), said(fake))
end

--- A run of this commit still in progress -- the queue lands its merge
--- the moment its check passes -- is asked after again, until it
--- completes, as is a failed call to the API; one that never completes,
--- or an API that keeps failing, is given up on after TRIES lookups.
local function test_a_run_in_progress_is_waited_for()
  local passed = listed(run("42", "completed", "success", SHA, QUEUE))
  local fake, code = find({ runs = { listed(run("42", "in_progress", nil, SHA, QUEUE)), "FAIL", passed },
    artifacts = { ["42"] = SEEDED } })
  assert(code == 0 and outputs(fake) == found("42"), outputs(fake) .. said(fake))
  assert(lookups(fake) == 3, table.concat(fake.calls, "\n"))
  -- The artifacts' lookup failing once is asked again, not taken as none.
  fake = find({ runs = { passed }, artifacts = { ["42"] = SEEDED }, fail_once = { "42" } })
  assert(outputs(fake) == found("42") and lookups(fake) == 2, outputs(fake) .. table.concat(fake.calls, "\n"))
  for _, stuck in ipairs({ listed(run("42", "queued", nil, SHA, QUEUE)), "FAIL" }) do
    fake, code = find({ runs = { stuck }, artifacts = {} })
    assert(code == 0 and outputs(fake) == NONE and lookups(fake) == 3, outputs(fake) .. table.concat(fake.calls, "\n"))
  end
end

--- Each round waits WAIT_SECONDS before the next, and none after the last.
local function test_each_round_waits_before_the_next()
  local fake = serve({ runs = { listed(run("42", "queued", nil, SHA, QUEUE)) } })
  local code = QueueSeed.find({ REPOSITORY = "o/r", SHA = SHA, LEGS = "a", WAIT_SECONDS = "7", TRIES = "3" },
    fake.host)
  assert(code == 0 and #fake.sleeps == 2 and fake.sleeps[1] == 7 and fake.sleeps[2] == 7, table.concat(fake.calls, "\n"))
end

--- The newest passing run is taken where another of the commit failed.
local function test_a_passing_run_beside_a_failed_one_is_found()
  local fake = find({ runs = { listed(run("42", "completed", "success", SHA, QUEUE),
    run("41", "completed", "failure", SHA, QUEUE)) }, artifacts = { ["41"] = SEEDED, ["42"] = SEEDED } })
  assert(outputs(fake) == found("42"), outputs(fake))
end

--- An answer that is no list of runs or of artifacts is a failed lookup,
--- asked again, and never a run found.
local function test_an_answer_with_no_list_is_a_failed_lookup()
  for _, answer in ipairs({ '{"message":"Bad credentials"}', '{"workflow_runs":null}', '{"workflow_runs":[1]}' }) do
    local fake, code = find({ runs = { answer } })
    assert(code == 0 and outputs(fake) == NONE and lookups(fake) == 3, answer .. ": " .. outputs(fake))
  end
  local fake = find({ runs = { listed(run("42", "completed", "success", SHA, QUEUE)) },
    artifacts = { ["42"] = '{"message":"Not Found"}' } })
  assert(outputs(fake) == NONE and lookups(fake) == 3, outputs(fake))
end

--- A step that cannot be read refuses, writing nothing and asking
--- nothing.
local function test_an_unreadable_environment_is_refused()
  local env: {{string: string}} = {
    { REPOSITORY = "o/r", SHA = SHA },
    { REPOSITORY = "o/r", LEGS = "a" },
    { SHA = SHA, LEGS = "a" },
    { REPOSITORY = "o/r", SHA = SHA, LEGS = "a", TRIES = "many" },
    { REPOSITORY = "o/r", SHA = SHA, LEGS = "a", WAIT_SECONDS = "-1" },
  }
  for _, one in ipairs(env) do
    local fake = serve({ runs = { listed() } })
    assert(QueueSeed.find(one, fake.host) == 2 and #fake.calls == 0 and #fake.outputs == 0)
  end
  for _, one in ipairs({ { REPOSITORY = "o/r", JOB = "a" }, { REPOSITORY = "o/r", ARTIFACT = "v" },
      { JOB = "a", ARTIFACT = "v" }, { REPOSITORY = "o/r", JOB = "a", ARTIFACT = "v", READY_SECONDS = "soon" } }) do
    local fake = serve({ runs = { listed() } })
    assert(QueueSeed.ahead(one, fake.host) == 2 and #fake.calls == 0 and #fake.outputs == 0)
  end
end

local KEPT <const> = artifacts({ "ci-driver-a", "verdicts-a", "verdicts-b" }, {})

--- `ahead` for job `a`'s artifact `verdicts-a`, with BASE `base`, against
--- `spec`, a wait of a second between rounds for five seconds in all; `extra`
--- sets more of the environment: the fake, and the status.
local function ahead(base: string, spec: Spec, extra?: {string: string}): GithubFake.Fake, integer
  local fake = serve(spec)
  local env: {string: string} = { REPOSITORY = "o/r", BASE = base, JOB = "a", ARTIFACT = "verdicts-a",
    WAIT_SECONDS = "1", WITHIN_SECONDS = "5" }
  for name, value in pairs(extra or {}) do env[name] = value end
  return fake, QueueSeed.ahead(env, fake.host)
end

--- The run ahead, whose head is this run's base, is found by the base
--- and the event, and taken where it holds the job's verdicts, whether
--- it is still running or done.
local function test_the_run_ahead_is_found_with_its_verdicts()
  for _, status in ipairs({ "in_progress", "completed" }) do
    local fake, code = ahead(SHA, { runs = { listed(run("42", status, nil, SHA, QUEUE),
      run("41", "completed", "cancelled", SHA, QUEUE)) }, artifacts = { ["42"] = KEPT } })
    assert(code == 0 and outputs(fake) == "run=42\n", outputs(fake) .. said(fake))
    assert(fake.calls[1] == "GET repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA ..
        "&per_page=20", fake.calls[1])
    assert(fake.calls[2] == "GET repos/o/r/actions/runs/42/artifacts?per_page=100", fake.calls[2])
    assert(lookups(fake) == 1 and GithubFake.count(fake, "/jobs") == 0, table.concat(fake.calls, "\n"))
    assert(said(fake):find("this run takes it.", 1, true), said(fake))
  end
end

--- A run ahead still running whose job has not kept its verdicts yet
--- is asked after again until it has, as is a failed call to the API.
local function test_the_run_ahead_is_waited_for()
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  -- The third round finds them, a wait between each.
  local fake, code = ahead(SHA, { runs = { running, "FAIL", running },
    artifacts = { ["42-1"] = artifacts({ "ci-driver-a" }, {}), ["42"] = KEPT },
    jobs = { ["42"] = jobs("in_progress a", "completed b") } }, { WITHIN_SECONDS = "15" })
  assert(code == 0 and outputs(fake) == "run=42\n", outputs(fake) .. said(fake))
  assert(lookups(fake) == 3, table.concat(fake.calls, "\n"))
  assert(#fake.sleeps == 2 and fake.sleeps[1] == 1 and fake.clock == START + 2, "the rounds did not wait between them")
  assert(GithubFake.count(fake, "GET repos/o/r/actions/runs/42/jobs?per_page=100") >= 1, table.concat(fake.calls, "\n"))
  -- One that never keeps them, or an API that keeps failing, is asked
  -- after again, then given up on when the time given has passed, and
  -- fails nothing: three rounds in the two seconds given, the last at
  -- the deadline.
  for _, stuck in ipairs({ running, "FAIL" }) do
    fake, code = ahead(SHA, { runs = { stuck }, artifacts = {}, jobs = { ["42"] = jobs("in_progress a") } },
      { WITHIN_SECONDS = "2" })
    assert(code == 0 and outputs(fake) == "run=\n" and lookups(fake) == 3, outputs(fake) .. table.concat(fake.calls, "\n"))
    assert(said(fake):find("left no verdicts-a in time", 1, true), said(fake))
  end
end

--- A run ahead that completed, or whose job completed, without the
--- job's verdicts -- its suite failed, or never ran -- is none at once,
--- with no wait; so is one whose artifact expired.
local function test_a_run_ahead_done_without_its_verdicts_is_none_at_once()
  local cases: {{string: string}} = {
    { runs = listed(run("42", "completed", "failure", SHA, QUEUE)), why = "a completed run" },
    { runs = listed(run("43", "in_progress", nil, SHA, QUEUE)), why = "a completed job" },
    { runs = listed(run("44", "completed", "success", SHA, QUEUE)), why = "an expired artifact" },
  }
  for _, case in ipairs(cases) do
    local fake, code = ahead(SHA, { runs = { case.runs },
      artifacts = { ["43"] = artifacts({ "verdicts-b" }, {}), ["44"] = artifacts({ "verdicts-a" }, { ["verdicts-a"] = true }) },
      jobs = { ["43"] = jobs("in_progress b", "completed a") } })
    assert(code == 0 and outputs(fake) == "run=\n", case.why .. ": " .. outputs(fake) .. said(fake))
    assert(lookups(fake) == 1 and #fake.sleeps == 0, case.why .. ": " .. table.concat(fake.calls, "\n"))
    assert(said(fake):find("completed without verdicts-a", 1, true), case.why .. ": " .. said(fake))
  end
end

--- Where the job ahead is taken to keep its verdicts some time after it
--- starts (READY_SECONDS, the checked job's), one that will not have
--- kept them before the wait ends, or has not started, is not waited
--- for; one that will is.
local function test_a_job_ahead_that_cannot_keep_them_in_time_is_not_waited_for()
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  local ready: {string: string} = { READY_SECONDS = "420", WITHIN_SECONDS = "90" }
  for _, case in ipairs({ { job = "in_progress a 60", why = "only after the wait" },
      { job = "queued a", why = "has not started" }, { job = "queued b", why = "has not started" } }) do
    local fake, code = ahead(SHA, { runs = { running }, artifacts = {}, jobs = { ["42"] = jobs(case.job) } }, ready)
    assert(code == 0 and outputs(fake) == "run=\n" and lookups(fake) == 1, case.job .. ": " .. outputs(fake))
    assert(said(fake):find(case.why, 1, true), case.job .. ": " .. said(fake))
  end
  local fake, code = ahead(SHA, { runs = { running }, artifacts = { ["42-1"] = artifacts({}, {}), ["42"] = KEPT },
    jobs = { ["42"] = jobs("in_progress a 400") } }, ready)
  assert(code == 0 and outputs(fake) == "run=42\n" and lookups(fake) == 2, outputs(fake) .. said(fake))
end

--- Where the job ahead names the step after which it keeps its
--- verdicts (SUITE_STEP, a leg's), one that has not begun it -- not
--- started, still building, or itself waiting on the run ahead of it
--- -- is not waited for; one in its suite, or past it, is. Verdicts
--- the run ahead holds already are taken whatever its job is doing.
local function test_a_job_ahead_before_its_suite_is_not_waited_for()
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  local suite: {string: string} = { SUITE_STEP = SUITE }
  for _, job in ipairs({ "in_progress a 60 queued", "in_progress a 60", "queued a", "queued b",
      "in_progress a 60 pending" }) do
    local fake, code = ahead(SHA, { runs = { running }, artifacts = {}, jobs = { ["42"] = jobs(job) } }, suite)
    assert(code == 0 and outputs(fake) == "run=\n" and lookups(fake) == 1, job .. ": " .. outputs(fake))
    assert(said(fake):find("has not begun '" .. SUITE .. "'", 1, true), job .. ": " .. said(fake))
  end
  for _, job in ipairs({ "in_progress a 60 in_progress", "in_progress a 60 completed" }) do
    local fake, code = ahead(SHA, { runs = { running },
      artifacts = { ["42-1"] = artifacts({}, {}), ["42"] = KEPT }, jobs = { ["42"] = jobs(job) } }, suite)
    assert(code == 0 and outputs(fake) == "run=42\n" and lookups(fake) == 2, job .. ": " .. outputs(fake) .. said(fake))
  end
  local fake, code = ahead(SHA, { runs = { running }, artifacts = { ["42"] = KEPT },
    jobs = { ["42"] = jobs("in_progress a 60 queued") } }, suite)
  assert(code == 0 and outputs(fake) == "run=42\n" and lookups(fake) == 1 and GithubFake.count(fake, "/jobs") == 0,
    outputs(fake) .. said(fake))
end

--- A base no queue run has for its head -- main's already, whose
--- verdicts the restore took -- is none at once, as is another
--- commit's, another queue's, and a push's run; with no base at all
--- nothing is asked.
local function test_a_base_that_heads_no_queue_run_is_none()
  for _, runs_listed in ipairs({ listed(), listed(run("42", "in_progress", nil, "f" .. SHA:sub(2), QUEUE)),
      listed(run("42", "in_progress", nil, SHA, "gh-readonly-queue/other/pr-7-x")),
      listed(run("42", "in_progress", nil, SHA, "main")),
      listed(run("42", "in_progress", nil, SHA, QUEUE, "push")) }) do
    local fake, code = ahead(SHA, { runs = { runs_listed }, artifacts = { ["42"] = KEPT } })
    assert(code == 0 and outputs(fake) == "run=\n" and lookups(fake) == 1, outputs(fake) .. said(fake))
    assert(GithubFake.count(fake, "/artifacts") == 0, table.concat(fake.calls, "\n"))
    assert(said(fake):find("is no merge queue run's head", 1, true), said(fake))
  end
  for _, base in ipairs({ "", "main", SHA:sub(2), SHA:upper() }) do
    local fake, code = ahead(base, { runs = { listed(run("42", "in_progress", nil, SHA, QUEUE)) },
      artifacts = { ["42"] = KEPT } })
    assert(code == 0 and outputs(fake) == "run=\n" and #fake.calls == 0 and #fake.asked == 0,
      base .. ": " .. outputs(fake))
  end
end

--- A checkout whose change moves build/harness_epoch.tl from the base's
--- runs every test (--all), standing on no verdict: nothing is asked.
--- One that leaves it asks as ever. (github_test.tl holds git's answer.)
local function test_a_change_that_moves_the_harness_takes_nothing()
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  local fake, code = ahead(SHA, { runs = { running }, artifacts = { ["42"] = KEPT } })
  assert(code == 0 and outputs(fake) == "run=42\n" and fake.asked[1] == SHA, outputs(fake) .. said(fake))
  fake = serve({ runs = { running }, artifacts = { ["42"] = KEPT } })
  fake.moved = true
  code = QueueSeed.ahead({ REPOSITORY = "o/r", BASE = SHA, JOB = "a", ARTIFACT = "verdicts-a" }, fake.host)
  assert(code == 0 and outputs(fake) == "run=\n" and #fake.calls == 0, outputs(fake) .. table.concat(fake.calls, "\n"))
  assert(said(fake):find("a suite runs every test (--all)", 1, true), said(fake))
end

--- The step's words reach where the live host writes them: $GITHUB_OUTPUT
--- and the summary are appended to.
local function test_the_live_host_appends_to_the_step_files(tmp: string)
  local env: {string: string} = { GITHUB_OUTPUT = tmp .. "/output", GITHUB_STEP_SUMMARY = tmp .. "/summary" }
  local host = Github.live(env)
  host.output("run=1")
  host.output("url=u")
  host.summary("said")
  assert(Fs.read(tmp .. "/output") == "run=1\nurl=u\n" and Fs.read(tmp .. "/summary") == "said\n")
end
