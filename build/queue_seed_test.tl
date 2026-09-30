--- .github/scripts/queue-seed.sh, which finds the merge queue's run a
--- push to main reuses (`find`), keeps in a queue run's leg what main
--- would have saved, under the keys it would have saved it under
--- (`stage`), and finds the run ahead of a queue run whose verdicts it
--- takes (`ahead`). `find` and `ahead` run against a fake `gh` holding
--- the API's JSON, which it answers through the script's own `--jq`
--- filters with the system's jq, one lookup at a time. Where the system
--- has no jq (CI's images), those cases return unchecked, and the
--- filters are held to their text alone.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The script, and the system's `sh`, jq and tools, which run it.
Test.needs{ reads = { ".github/scripts/queue-seed.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/queue-seed.sh"))

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local QUEUE <const> = "gh-readonly-queue/main/pr-7-fedcba"

--- The filters the script hands `gh api --jq`, as it writes them.
local RUNS_FILTER <const> = [[.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"]]
local ARTIFACTS_FILTER <const> = ".artifacts[] | select(.expired | not) | .name"
local AHEAD_RUNS_FILTER <const> = [[.workflow_runs[] | select(.event == "merge_group") | "\(.id) \(.status) \(.head_sha) \(.head_branch)"]]
local JOBS_FILTER <const> = [[.jobs[] | "\(.status) \(.started_at // "" | if . == "" then "none" else fromdateiso8601 end) \(.name)"]]

--- A fake `gh api URL --jq FILTER`: each lookup of the runs answers the
--- next of the lookups written (one "FAIL" fails), the last again once
--- they run out; the k-th lookup of run <id>'s artifacts answers
--- artifacts-<id>-<k>, else artifacts-<id> (none where there is no such
--- file), and fails once where artifacts-<id>.fail is there; one of its
--- jobs answers jobs-<id> (none where there is none). Each call's
--- arguments are logged to `calls`.
local FAKE <const> = [[#!/bin/sh
echo "$*" >> "$FAKE/calls"
[ "$1" = api ] && [ "$3" = --jq ] && [ $# -eq 4 ] || { echo "fake gh: $*" >&2; exit 2; }
case $2 in
  */artifacts*)
    id=${2%/artifacts*}; id=${id##*/}; file=$FAKE/artifacts-$id
    if [ -f "$file.fail" ]; then rm "$file.fail"; exit 1; fi
    k=$(($(cat "$file.n" 2>/dev/null || echo 0) + 1)); echo "$k" > "$file.n"
    [ ! -f "$file-$k" ] || file=$file-$k
    [ -f "$file" ] || file=$FAKE/no-artifacts ;;
  */jobs*)
    id=${2%/jobs*}; id=${id##*/}; file=$FAKE/jobs-$id
    [ -f "$file" ] || file=$FAKE/no-jobs ;;
  *)
    n=$(($(cat "$FAKE/n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$FAKE/n"
    file=$FAKE/lookup-$n; [ -f "$file" ] || file=$FAKE/lookup-last ;;
esac
[ "$(cat "$file")" != FAIL ] || exit 1
jq -r "$4" "$file"
]]

--- Whether the system has a jq to answer the filters through.
local function has_jq(): boolean
  local result = Child.run({ "/bin/sh", "-c", "command -v jq" }, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })
  return result ~= nil and result.code == 0
end

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

local runs = 0

--- What `find` writes to $GITHUB_OUTPUT, for legs a and b, the calls it
--- made to `gh`, its status and what it said; `fail` names the runs
--- whose artifacts' lookup fails once.
local function find(tmp: string, lookups: {string}, listing: {string: string}, fail?: {string}):
    string, string, integer, string
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/gh", FAKE))
  assert(Fs.chmod(dir .. "/bin/gh", 493))
  for i, text in ipairs(lookups) do
    assert(Fs.write(dir .. "/lookup-" .. (i == #lookups and "last" or tostring(i)), text))
  end
  assert(Fs.write(dir .. "/no-artifacts", artifacts({}, {})))
  for id, text in pairs(listing) do assert(Fs.write(dir .. "/artifacts-" .. id, text)) end
  for _, id in ipairs(fail or {}) do assert(Fs.write(dir .. "/artifacts-" .. id .. ".fail", "")) end
  local env: {string: string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"), FAKE = dir,
    GITHUB_OUTPUT = dir .. "/output", GITHUB_STEP_SUMMARY = dir .. "/summary",
    REPOSITORY = "o/r", SHA = SHA, LEGS = "a b", WAIT_SECONDS = "0", TRIES = "3",
  }
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "find" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  return Fs.read(dir .. "/output") or "", Fs.read(dir .. "/calls") or "", result.code,
    (result.stdout or "") .. (result.stderr or "")
end

local function found(id: string): string
  return "run=" .. id .. "\nurl=https://github.com/o/r/actions/runs/" .. id .. "\n"
end
local NONE <const> = "run=\nurl=\n"

--- The lookups of the runs among `calls`.
local function lookups(calls: string): integer
  return select(2, calls:gsub("workflows/ci.yml/runs", "")) as integer
end

--- The script hands gh these filters, which the fake answers through.
local function test_the_filters_are_the_scripts()
  local text = assert(Fs.read(SCRIPT))
  assert(text:find("--jq '" .. RUNS_FILTER .. "'", 1, true), "the runs' filter moved")
  assert(text:find("--jq '" .. ARTIFACTS_FILTER .. "'", 1, true), "the artifacts' filter moved")
  assert(text:find("--jq '" .. JOBS_FILTER .. "'", 1, true), "the jobs' filter moved")
  assert(text:find("--jq '" .. AHEAD_RUNS_FILTER .. "'", 1, true), "the run ahead's filter moved")
end

--- The queue's passing run of this commit is found, by the commit and
--- the event, and named in the step summary.
local function test_a_passing_queue_run_is_found(tmp: string)
  if not has_jq() then return end
  local output, calls, code, said = find(tmp, { listed(run("42", "completed", "success", SHA, QUEUE)) },
    { ["42"] = SEEDED })
  assert(code == 0, said)
  assert(output == found("42"), output)
  assert(calls:find("api repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA ..
    "&per_page=20 --jq " .. RUNS_FILTER, 1, true), calls)
  assert(calls:find("api repos/o/r/actions/runs/42/artifacts?per_page=100 --jq " .. ARTIFACTS_FILTER, 1, true), calls)
  assert(said:find("passed the merge queue in https://github.com/o/r/actions/runs/42", 1, true), said)
  assert((Fs.read(tmp .. "/run-" .. runs .. "/summary") or ""):find("runs/42", 1, true))
end

--- No run of this commit, or none that passed on main's queue with
--- every leg's seed, is none: the push runs the full scope, and the
--- lookup never fails it.
local function test_no_passing_seeded_queue_run_is_none(tmp: string)
  if not has_jq() then return end
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
    local output, _, code, said = find(tmp, { case.runs }, {
      ["42"] = SEEDED, ["43"] = artifacts({ "portable-product-a" }, {}),
      ["44"] = artifacts({ "seed-a", "portable-product-b" }, {}),
      ["45"] = artifacts({ "seed-a", "seed-b" }, { ["seed-b"] = true }),
    })
    assert(code == 0, case.why .. ": " .. said)
    assert(output == NONE, case.why .. ": " .. output)
    assert(said:find("the full scope runs", 1, true), said)
  end
end

--- A run of this commit still in progress -- the queue lands its merge
--- the moment its check passes -- is asked after again, until it
--- completes, as is a failed call to the API; one that never completes,
--- or an API that keeps failing, is given up on after TRIES lookups.
local function test_a_run_in_progress_is_waited_for(tmp: string)
  if not has_jq() then return end
  local passed = listed(run("42", "completed", "success", SHA, QUEUE))
  local output, calls, code, said = find(tmp, {
    listed(run("42", "in_progress", nil, SHA, QUEUE)), "FAIL", passed,
  }, { ["42"] = SEEDED })
  assert(code == 0 and output == found("42"), output .. said)
  assert(lookups(calls) == 3, calls)
  -- The artifacts' lookup failing once is asked again, not taken as none.
  output, calls = find(tmp, { passed }, { ["42"] = SEEDED }, { "42" })
  assert(output == found("42") and lookups(calls) == 2, output .. calls)
  for _, stuck in ipairs({ listed(run("42", "queued", nil, SHA, QUEUE)), "FAIL" }) do
    output, calls, code = find(tmp, { stuck }, {})
    assert(code == 0 and output == NONE and lookups(calls) == 3, output .. calls)
  end
end

--- The newest passing run is taken where another of the commit failed.
local function test_a_passing_run_beside_a_failed_one_is_found(tmp: string)
  if not has_jq() then return end
  local output = find(tmp, { listed(run("42", "completed", "success", SHA, QUEUE),
    run("41", "completed", "failure", SHA, QUEUE)) }, { ["41"] = SEEDED, ["42"] = SEEDED })
  assert(output == found("42"), output)
end

--- What `stage` keeps under $RUNNER_TEMP/seed, run with `env` and, where
--- `marker`, a passing driver check's marker, and its seed.keys.
local function stage(tmp: string, env: {string: string}, marker: boolean): string, string
  runs = runs + 1
  local temp = tmp .. "/stage-" .. runs
  assert(Fs.mkdirs(temp .. "/verdicts"))
  assert(Fs.write(temp .. "/verdicts/verdicts.db", "v"))
  assert(Fs.mkdirs(temp .. "/build-cache"))
  assert(Fs.write(temp .. "/build-cache/cache.db", "c"))
  if marker then
    assert(Fs.mkdirs(temp .. "/driver-checked"))
    assert(Fs.write(temp .. "/driver-checked/key", "driver-checked-v2-leg-x\n"))
  end
  local full: {string: string} = { PATH = Env.get("PATH") or "/usr/bin:/bin", RUNNER_TEMP = temp }
  for name, value in pairs(env) do full[name] = value end
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "stage" }, { env = full, cwd = temp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return temp .. "/seed", Fs.read(temp .. "/seed/seed.keys") or ""
end

--- Each cache is kept, under its prefix and digest, where the run moved
--- it from the entry it restored, and the driver check's marker where
--- the check ran; nothing else is kept.
local function test_stage_keeps_what_main_would_save(tmp: string)
  local seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    COMPILES_PREFIX = "compiles-leg-", COMPILES_DIGEST = "e1", COMPILES_RESTORED = "",
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\ncompiles=compiles-leg-e1\n" ..
    "driver-checked=driver-checked-v2-leg-x\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v" and Fs.read(seed .. "/build-cache/cache.db") == "c")
  assert(Fs.read(seed .. "/driver-checked/key") == "driver-checked-v2-leg-x\n")

  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d0", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    COMPILES_PREFIX = "compiles-leg-", COMPILES_DIGEST = "",
  }, false)
  assert(keys == "", keys)
  assert(not Fs.exists(seed .. "/verdicts") and not Fs.exists(seed .. "/build-cache") and
    not Fs.exists(seed .. "/driver-checked"))

  -- A job that keeps no compiles (ci.yml's `checked`) names none.
  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-checked-h-f-", VERDICTS_DIGEST = "d2", VERDICTS_RESTORED = "",
  }, false)
  assert(keys == "verdicts=verdicts-leg-checked-h-f-d2\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v" and not Fs.exists(seed .. "/build-cache"))
end

--- The verdicts are kept under the commit too (`verdicts-sha`), the key
--- main's push saves them under for a branch based on it. That copy is
--- kept even where their digest names the entry the run restored, which
--- main saves under no key of its own; a run whose trim named no digest
--- keeps none.
local function test_stage_keeps_the_verdicts_under_the_commit(tmp: string)
  local seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d0", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    SHA = SHA,
  }, false)
  assert(keys == "verdicts-sha=verdicts-leg-h-f-sha-" .. SHA .. "\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")

  seed, keys = stage(tmp, {
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "verdicts-leg-h-f-d0",
    SHA = SHA,
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\nverdicts-sha=verdicts-leg-h-f-sha-" .. SHA ..
    "\ndriver-checked=driver-checked-v2-leg-x\n", keys)
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")

  seed, keys = stage(tmp, { VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "", SHA = SHA }, false)
  assert(keys == "" and not Fs.exists(seed .. "/verdicts"), keys)
end

--- A run's jobs, as the API lists them: each `status name`, or
--- `status name started` with `started` seconds ago.
local function jobs(...: string): string
  local items: {string} = {}
  for _, job in ipairs({ ... }) do
    local status, name, ago = job:match("^(%S+) (%S+) ?(%d*)$")
    local started = ago ~= "" and ('"' .. Time.format_rfc3339(Time.now_ns() - math.tointeger(tonumber(ago)) * 1000000000,
      { digits = 0 }) .. '"')
      or "null"
    items[#items + 1] = '{"name":"' .. name .. '","status":"' .. status .. '","started_at":' .. started .. "}"
  end
  return '{"total_count":' .. #items .. ',"jobs":[' .. table.concat(items, ",") .. "]}"
end

--- What `ahead` writes to $GITHUB_OUTPUT for job `a`'s artifact
--- `verdicts-a`, with BASE `base`, the calls it made to `gh`, its status
--- and what it said; `answers` are the runs' lookups, as `find`'s are,
--- `listing` names each run's artifacts (`<id>`, or `<id>-<k>` for the
--- k-th lookup), `listed_jobs` its jobs, and `extra` sets more of the
--- environment, in `cwd` where given. It waits a second between rounds,
--- for five seconds in all.
local function ahead(tmp: string, base: string, answers: {string}, listing: {string: string},
    listed_jobs?: {string: string}, extra?: {string: string}, cwd?: string): string, string, integer, string
  runs = runs + 1
  local dir = tmp .. "/ahead-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/gh", FAKE))
  assert(Fs.chmod(dir .. "/bin/gh", 493))
  for i, text in ipairs(answers) do
    assert(Fs.write(dir .. "/lookup-" .. (i == #answers and "last" or tostring(i)), text))
  end
  assert(Fs.write(dir .. "/no-artifacts", artifacts({}, {})))
  assert(Fs.write(dir .. "/no-jobs", jobs()))
  for id, text in pairs(listing) do assert(Fs.write(dir .. "/artifacts-" .. id, text)) end
  for id, text in pairs(listed_jobs or {}) do assert(Fs.write(dir .. "/jobs-" .. id, text)) end
  local env: {string: string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"), FAKE = dir,
    GITHUB_OUTPUT = dir .. "/output", GITHUB_STEP_SUMMARY = dir .. "/summary",
    REPOSITORY = "o/r", BASE = base, JOB = "a", ARTIFACT = "verdicts-a", WAIT_SECONDS = "1",
    WITHIN_SECONDS = "5",
  }
  for name, value in pairs(extra or {}) do env[name] = value end
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "ahead" }, { env = env, cwd = cwd or dir,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  return Fs.read(dir .. "/output") or "", Fs.read(dir .. "/calls") or "", result.code,
    (result.stdout or "") .. (result.stderr or "")
end

local KEPT <const> = artifacts({ "ci-driver-a", "verdicts-a", "verdicts-b" }, {})

--- The run ahead, whose head is this run's base, is found by the base
--- and the event, and taken where it holds the job's verdicts, whether
--- it is still running or done.
local function test_the_run_ahead_is_found_with_its_verdicts(tmp: string)
  if not has_jq() then return end
  for _, status in ipairs({ "in_progress", "completed" }) do
    local output, calls, code, said = ahead(tmp, SHA, { listed(run("42", status, nil, SHA, QUEUE),
      run("41", "completed", "cancelled", SHA, QUEUE)) }, { ["42"] = KEPT })
    assert(code == 0 and output == "run=42\n", output .. said)
    assert(calls:find("api repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA ..
      "&per_page=20 --jq " .. AHEAD_RUNS_FILTER, 1, true), calls)
    assert(calls:find("api repos/o/r/actions/runs/42/artifacts?per_page=100 --jq " .. ARTIFACTS_FILTER, 1, true),
      calls)
    assert(lookups(calls) == 1 and not calls:find("/jobs", 1, true), calls)
    assert(said:find("this run takes its verdicts", 1, true), said)
  end
end

--- A run ahead still running whose job has not kept its verdicts yet
--- is asked after again until it has, as is a failed call to the API.
local function test_the_run_ahead_is_waited_for(tmp: string)
  if not has_jq() then return end
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  local output, calls, code, said = ahead(tmp, SHA, { running, "FAIL", running },
    { ["42-1"] = artifacts({ "ci-driver-a" }, {}), ["42"] = KEPT },
    { ["42"] = jobs("in_progress a", "completed b") })
  assert(code == 0 and output == "run=42\n", output .. said)
  assert(lookups(calls) == 3, calls)
  assert(calls:find("api repos/o/r/actions/runs/42/jobs?per_page=100 --jq " .. JOBS_FILTER, 1, true), calls)
  -- One that never keeps them, or an API that keeps failing, is given
  -- up on when the time given has passed, and fails nothing.
  for _, stuck in ipairs({ running, "FAIL" }) do
    output, calls, code, said = ahead(tmp, SHA, { stuck }, {}, { ["42"] = jobs("in_progress a") },
      { WITHIN_SECONDS = "2" })
    assert(code == 0 and output == "run=\n" and lookups(calls) >= 2 and lookups(calls) <= 4, output .. calls)
    assert(said:find("left no verdicts-a in time", 1, true), said)
  end
end

--- A run ahead that completed, or whose job completed, without the
--- job's verdicts -- its suite failed, or never ran -- is none at once,
--- with no wait; so is one whose artifact expired.
local function test_a_run_ahead_done_without_its_verdicts_is_none_at_once(tmp: string)
  if not has_jq() then return end
  local cases: {{string: string}} = {
    { runs = listed(run("42", "completed", "failure", SHA, QUEUE)), why = "a completed run" },
    { runs = listed(run("43", "in_progress", nil, SHA, QUEUE)), why = "a completed job" },
    { runs = listed(run("44", "completed", "success", SHA, QUEUE)), why = "an expired artifact" },
  }
  for _, case in ipairs(cases) do
    local output, calls, code, said = ahead(tmp, SHA, { case.runs },
      { ["43"] = artifacts({ "verdicts-b" }, {}), ["44"] = artifacts({ "verdicts-a" }, { ["verdicts-a"] = true }) },
      { ["43"] = jobs("in_progress b", "completed a") })
    assert(code == 0 and output == "run=\n", case.why .. ": " .. output .. said)
    assert(lookups(calls) == 1, case.why .. ": " .. calls)
    assert(said:find("completed without verdicts-a", 1, true), case.why .. ": " .. said)
  end
end

--- Where the job ahead is taken to keep its verdicts some time after it
--- starts (READY_SECONDS, the checked job's), one that will not have
--- kept them before the wait ends, or has not started, is not waited
--- for; one that will is.
local function test_a_job_ahead_that_cannot_keep_them_in_time_is_not_waited_for(tmp: string)
  if not has_jq() then return end
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  local ready: {string: string} = { READY_SECONDS = "420", WITHIN_SECONDS = "90" }
  for _, case in ipairs({ { job = "in_progress a 60", why = "only after the wait" },
      { job = "queued a", why = "has not started" }, { job = "queued b", why = "has not started" } }) do
    local output, calls, code, said = ahead(tmp, SHA, { running }, {}, { ["42"] = jobs(case.job) }, ready)
    assert(code == 0 and output == "run=\n" and lookups(calls) == 1, case.job .. ": " .. output .. calls)
    assert(said:find(case.why, 1, true), case.job .. ": " .. said)
  end
  local output, calls, code, said = ahead(tmp, SHA, { running },
    { ["42-1"] = artifacts({}, {}), ["42"] = KEPT }, { ["42"] = jobs("in_progress a 400") }, ready)
  assert(code == 0 and output == "run=42\n" and lookups(calls) == 2, output .. calls .. said)
end

--- A base no queue run has for its head -- main's already, whose
--- verdicts the restore took -- is none at once, as is another
--- commit's, another queue's, and a push's run; with no base at all
--- nothing is asked.
local function test_a_base_that_heads_no_queue_run_is_none(tmp: string)
  if not has_jq() then return end
  for _, runs_listed in ipairs({ listed(), listed(run("42", "in_progress", nil, "f" .. SHA:sub(2), QUEUE)),
      listed(run("42", "in_progress", nil, SHA, "gh-readonly-queue/other/pr-7-x")),
      listed(run("42", "in_progress", nil, SHA, "main")),
      listed(run("42", "in_progress", nil, SHA, QUEUE, "push")) }) do
    local output, calls, code, said = ahead(tmp, SHA, { runs_listed }, { ["42"] = KEPT })
    assert(code == 0 and output == "run=\n" and lookups(calls) == 1, output .. calls .. said)
    assert(not calls:find("/artifacts", 1, true), calls)
    assert(said:find("is no merge queue run's head", 1, true), said)
  end
  for _, base in ipairs({ "", "main", SHA:sub(2) }) do
    local output, calls, code = ahead(tmp, base, { listed(run("42", "in_progress", nil, SHA, QUEUE)) },
      { ["42"] = KEPT })
    assert(code == 0 and output == "run=\n" and calls == "", base .. ": " .. output .. calls)
  end
end

--- A checkout whose change moves build/harness_epoch.tl from the base's
--- runs every test (--all), standing on no verdict: nothing is asked.
--- One that leaves it, or whose base it lacks, asks as ever.
local function test_a_change_that_moves_the_harness_takes_nothing(tmp: string)
  local has_git = Child.run({ "/bin/sh", "-c", "command -v git" }, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })
  if not has_jq() or has_git == nil or has_git.code ~= 0 then return end
  local repo = tmp .. "/repo"
  assert(Fs.mkdirs(repo .. "/build"))
  local function git(...: string): string
    local result = assert(Child.run({ "/usr/bin/env", "git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", repo, ... },
      { stdout = "capture", stderr = "capture", timeout_ms = 30000,
        env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = tmp, GIT_CONFIG_NOSYSTEM = "1" } }))
    assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
    return ((result.stdout or ""):gsub("%s+$", ""))
  end
  git("init", "-q")
  assert(Fs.write(repo .. "/build/harness_epoch.tl", "epoch 1\n"))
  assert(Fs.write(repo .. "/other.tl", "a\n"))
  git("add", "-A")
  git("commit", "-q", "-m", "base")
  local base = git("rev-parse", "HEAD")
  assert(Fs.write(repo .. "/other.tl", "b\n"))
  git("commit", "-q", "-am", "change")
  local running = listed(run("42", "in_progress", nil, base, QUEUE))
  local output, calls, code, said = ahead(tmp, base, { running }, { ["42"] = KEPT }, nil, nil, repo)
  assert(code == 0 and output == "run=42\n", output .. calls .. said)
  assert(Fs.write(repo .. "/build/harness_epoch.tl", "epoch 2\n"))
  git("commit", "-q", "-am", "harness")
  output, calls, code, said = ahead(tmp, base, { running }, { ["42"] = KEPT }, nil, nil, repo)
  assert(code == 0 and output == "run=\n" and calls == "", output .. calls)
  assert(said:find("every test runs (--all)", 1, true), said)
end
