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
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The script, and the system's `sh`, jq and tools, which run it; and
--- ci.yml, whose keys `stage` is run with and whose `seed` job reads.
Test.needs{ reads = { ".github/scripts/queue-seed.sh", ".github/workflows/ci.yml" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/queue-seed.sh"))

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local QUEUE <const> = "gh-readonly-queue/main/pr-7-fedcba"

--- The filters the script hands `gh api --jq`, as it writes them.
local RUNS_FILTER <const> = [[.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"]]
local ARTIFACTS_FILTER <const> = ".artifacts[] | select(.expired | not) | .name"
local AHEAD_RUNS_FILTER <const> = [[.workflow_runs[] | select(.event == "merge_group") | "\(.id) \(.status) \(.head_sha) \(.head_branch)"]]
local JOBS_FILTER <const> = [[.jobs[] | "\(.status) \(.started_at // "" | if . == "" then "none" else fromdateiso8601 end) \(if (env.SUITE_STEP // "") == "" then "-" elif any(.steps[]?; .name == env.SUITE_STEP and (.status == "in_progress" or .status == "completed")) then "reached" else "before" end) \(.name)"]]

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
    timeout_ns = Time.seconds(30) })
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
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
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
--- `marker`, a passing driver check's marker (holding `marker_key`, or
--- a key of no shape), and its seed.keys. The zig build outputs hold a
--- program, whose mode their seed keeps.
local function stage(tmp: string, env: {string: string}, marker: boolean, marker_key?: string): string, string
  runs = runs + 1
  local temp = tmp .. "/stage-" .. runs
  assert(Fs.mkdirs(temp .. "/zig-build/zig-project/o/abc"))
  assert(Fs.write(temp .. "/zig-build/zig-project/o/abc/build", "z"))
  assert(Fs.chmod(temp .. "/zig-build/zig-project/o/abc/build", 493))
  assert(Fs.mkdirs(temp .. "/verdicts"))
  assert(Fs.write(temp .. "/verdicts/verdicts.db", "v"))
  assert(Fs.mkdirs(temp .. "/build-cache"))
  assert(Fs.write(temp .. "/build-cache/cache.db", "c"))
  if marker then
    assert(Fs.mkdirs(temp .. "/driver-checked"))
    assert(Fs.write(temp .. "/driver-checked/key", (marker_key or "driver-checked-v2-leg-x") .. "\n"))
  end
  local full: {string: string} = { PATH = Env.get("PATH") or "/usr/bin:/bin", RUNNER_TEMP = temp }
  for name, value in pairs(env) do full[name] = value end
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "stage" }, { env = full, cwd = temp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
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

local ZIG <const> = "zig-build-leg-v1-"
local CORE <const> = ZIG .. "full-c1-"

--- The tar `stage` kept the zig build outputs in, beside the seed in an
--- artifact of their own.
local function zig_tar(seed: string): string
  return seed .. "-zig/zig-build.tar"
end

--- The program the tar `stage` kept the zig build outputs in lays out,
--- under `dir`.
local function unpacked(seed: string, dir: string): string
  assert(Fs.mkdirs(dir))
  local result = assert(Child.run({ "/bin/sh", "-c", 'tar -xf "$1" -C "$2"', "sh", zig_tar(seed), dir },
    { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return dir .. "/zig-build/zig-project/o/abc/build"
end

--- The zig build outputs are kept, with their modes, under the key the
--- run's restore named, where it restored no entry of this core and
--- vendor part: another core's, another vendor part's, or none. The
--- prefix of such an entry goes with them, for main's lookup.
local function test_stage_keeps_the_zig_build_outputs_of_a_new_core(tmp: string)
  for i, restored in ipairs({ ZIG .. "full-c0-8-1", ZIG .. "light-c1-8-1", "zig-build-leg-v0-full-c1-8-1", "" }) do
    local seed, keys = stage(tmp, { ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE,
      ZIG_BUILD_RESTORED = restored }, false)
    assert(keys == "zig-build=" .. CORE .. "9-1\nzig-build-exact=" .. CORE .. "\n", restored .. ": " .. keys)
    assert(not Fs.exists(seed .. "/zig-build.tar"), "the zig build outputs are kept in the seed itself")
    local program = unpacked(seed, tmp .. "/unpacked-" .. i)
    assert(Fs.read(program) == "z" and assert(Fs.stat(program)).mode & 0x1ff == 493,
      restored .. ": the zig build outputs lost a file or its mode")
  end
end

--- An entry of this core and vendor part restored answers already, so
--- nothing of zig's is kept; nor where the job names no key (the
--- checked job).
local function test_stage_keeps_no_zig_build_outputs_an_entry_holds(tmp: string)
  local seed, keys = stage(tmp, { ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE,
    ZIG_BUILD_RESTORED = CORE .. "8-1" }, false)
  assert(keys == "" and not Fs.exists(zig_tar(seed)), keys)
  seed, keys = stage(tmp, { VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d2" }, false)
  assert(keys == "verdicts=verdicts-leg-h-f-d2\n" and not Fs.exists(zig_tar(seed)), keys)
end

--- A tar that fails keeps none of zig's and names no key for it, and
--- the stage goes on to keep the rest: the outputs save only time.
local function test_a_failing_zig_tar_keeps_the_rest(tmp: string)
  local bin = tmp .. "/failing-tar"
  assert(Fs.mkdirs(bin))
  assert(Fs.write(bin .. "/tar", "#!/bin/sh\necho partial > \"$2\"\nexit 1\n"))
  assert(Fs.chmod(bin .. "/tar", 493))
  local seed, keys = stage(tmp, {
    PATH = bin .. ":" .. (Env.get("PATH") or "/usr/bin:/bin"),
    VERDICTS_PREFIX = "verdicts-leg-h-f-", VERDICTS_DIGEST = "d1", VERDICTS_RESTORED = "",
    ZIG_BUILD_KEY = CORE .. "9-1", ZIG_BUILD_EXACT = CORE, ZIG_BUILD_RESTORED = "",
  }, true)
  assert(keys == "verdicts=verdicts-leg-h-f-d1\ndriver-checked=driver-checked-v2-leg-x\n", keys)
  assert(not Fs.exists(zig_tar(seed)), "a failed tar is kept")
  assert(Fs.read(seed .. "/verdicts/verdicts.db") == "v")
end

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
    local started = ago ~= "" and ('"' .. Time.format_rfc3339(Time.now_ns() - math.tointeger(tonumber(ago)) * 1000000000,
      nil, { digits = 0 }) .. '"') or
      "null"
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
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
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
  -- The third round finds them, a wait between each: a window well
  -- past that, which costs nothing once they are found, so that a slow
  -- host's rounds still reach it.
  local started = Time.monotonic_ns()
  local output, calls, code, said = ahead(tmp, SHA, { running, "FAIL", running },
    { ["42-1"] = artifacts({ "ci-driver-a" }, {}), ["42"] = KEPT },
    { ["42"] = jobs("in_progress a", "completed b") }, { WITHIN_SECONDS = "15" })
  assert(code == 0 and output == "run=42\n", output .. said)
  assert(lookups(calls) == 3, calls)
  assert(Time.monotonic_ns() - started >= Time.seconds(2), "the rounds did not wait between them")
  assert(calls:find("api repos/o/r/actions/runs/42/jobs?per_page=100 --jq " .. JOBS_FILTER, 1, true), calls)
  -- One that never keeps them, or an API that keeps failing, is asked
  -- after again, then given up on when the time given has passed, and
  -- fails nothing. With no wait between rounds, they run for a second or
  -- more, however long one takes on a slow host.
  for _, stuck in ipairs({ running, "FAIL" }) do
    output, calls, code, said = ahead(tmp, SHA, { stuck }, {}, { ["42"] = jobs("in_progress a") },
      { WITHIN_SECONDS = "1", WAIT_SECONDS = "0" })
    assert(code == 0 and output == "run=\n" and lookups(calls) >= 2, output .. calls)
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

--- Where the job ahead names the step after which it keeps its
--- verdicts (SUITE_STEP, a leg's), one that has not begun it -- not
--- started, still building, or itself waiting on the run ahead of it
--- -- is not waited for; one in its suite, or past it, is. Verdicts
--- the run ahead holds already are taken whatever its job is doing.
local function test_a_job_ahead_before_its_suite_is_not_waited_for(tmp: string)
  if not has_jq() then return end
  local running = listed(run("42", "in_progress", nil, SHA, QUEUE))
  -- The helper's own five seconds: a job ahead waited for that should
  -- not be fails by the assertions below, not by a long wait.
  local suite: {string: string} = { SUITE_STEP = SUITE }
  for _, job in ipairs({ "in_progress a 60 queued", "in_progress a 60", "queued a", "queued b",
      "in_progress a 60 pending" }) do
    local output, calls, code, said = ahead(tmp, SHA, { running }, {}, { ["42"] = jobs(job) }, suite)
    assert(code == 0 and output == "run=\n" and lookups(calls) == 1, job .. ": " .. output .. calls)
    assert(said:find("has not begun '" .. SUITE .. "'", 1, true), job .. ": " .. said)
  end
  for _, job in ipairs({ "in_progress a 60 in_progress", "in_progress a 60 completed" }) do
    local output, calls, code, said = ahead(tmp, SHA, { running },
      { ["42-1"] = artifacts({}, {}), ["42"] = KEPT }, { ["42"] = jobs(job) }, suite)
    assert(code == 0 and output == "run=42\n" and lookups(calls) == 2, job .. ": " .. output .. calls .. said)
  end
  local output, calls, code, said = ahead(tmp, SHA, { running }, { ["42"] = KEPT },
    { ["42"] = jobs("in_progress a 60 queued") }, suite)
  assert(code == 0 and output == "run=42\n" and lookups(calls) == 1 and not calls:find("/jobs", 1, true),
    output .. calls .. said)
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
    timeout_ns = Time.seconds(30) })
  if not has_jq() or has_git == nil or has_git.code ~= 0 then return end
  local repo = tmp .. "/repo"
  assert(Fs.mkdirs(repo .. "/build"))
  local function git(...: string): string
    local result = assert(Child.run({ "/usr/bin/env", "git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", repo, ... },
      { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30),
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

--- ci.yml, decoded.
local function workflow(): {string: {string: any}}
  local text = assert(Fs.read(".github/workflows/ci.yml"))
  return (assert(Json.decode_object(text, { json5 = true, hash_comments = true }))) as {string: {string: any}}
end

--- The step of `steps` whose `id` is `id`, or whose `run` holds `text`.
local function step_of(steps: {{string: any}}, id?: string, text?: string): {string: any}
  for _, step in ipairs(steps) do
    local script = step.run
    if (id ~= nil and step.id == id) or
        (text ~= nil and script is string and script:find(text, 1, true) ~= nil) then
      return step
    end
  end
  error("no step " .. tostring(id or text))
end

local HEX64 <const> = "95301174f75ffeb84a42bb8a48da9110e55de69d2379ca686f538663fe25529d"

--- Whether leg `leg` runs in a container (its matrix `image`), in ci.yml's
--- platform matrix: an entry of its name, else the entry that names
--- none (alpine-x86_64's, which adds to every leg).
local function in_container(leg: string): boolean
  local platform = (workflow().jobs as {string: {string: any}}).platform
  local image: string
  for _, entry in ipairs(((platform.strategy as {string: any}).matrix as {string: any}).include as {{string: any}}) do
    if entry.name == leg then return (entry.image as string) ~= "" end
    if entry.name == nil then image = entry.image as string end
  end
  assert(image ~= nil, "no platform leg " .. leg)
  return image ~= ""
end

--- Each runner image a leg's run names, `<ImageOS>-<ImageVersion>` as
--- ci.yml's "name the zig build cache" step writes it: linux-aarch64's
--- as run 36730873187 named it (ImageOS ubuntu24-arm64, whose `-` the
--- seed's key read once refused), the others in the runners' shapes.
local IMAGES <const>: {string: string} = {
  ["linux-x86_64"] = "ubuntu24-20260920.130.1",
  ["linux-aarch64"] = "ubuntu24-arm64-20260920.129.1",
  ["macos-aarch64"] = "macos15-20260915.0138",
  ["alpine-x86_64"] = "ubuntu24-20260920.130.1",
}

--- `template` with each `${{ ... }}` in it the value a run of leg `leg`
--- gives it, in the shape the step that writes it writes: hashFiles
--- a sha256, a digest one too, a restore's matched key none (nothing
--- restored, so everything is kept). An expression it does not know
--- fails, so a key built of something new is read here first.
local function expand(template: string, leg: string, steps: {{string: any}}): string
  local host = "verdicts-" .. leg .. "-3a9f8d7b94f5492e-"
  local values: {string: string} = {
    ["matrix.name"] = leg,
    ["github.sha"] = SHA,
    ["github.run_id"] = "36730873187",
    ["github.run_attempt"] = "1",
    ["steps.host-id.outputs.prefix"] = host,
    ["steps.host-id.outputs.verdicts"] = host .. "bfd3e88dc72aaf8f-",
    ["steps.names.outputs.image"] = IMAGES[leg],
    ["steps.names.outputs.vendor"] = "zig-build-" .. leg .. "-" .. HEX64 .. "-",
    ["steps.names.outputs.core"] = HEX64,
    ["steps.verdicts-trim.outputs.digest"] = HEX64,
    ["steps.compiles-trim.outputs.digest"] = HEX64,
    ["steps.verdicts-restore.outputs.cache-matched-key"] = "",
    ["steps.compiles-restore.outputs.cache-matched-key"] = "",
    ["steps.zig-cache-restore.outputs.cache-matched-key"] = "",
  }
  return (template:gsub("%${{ (.-) }}", function(expression: string): string
    if expression:match("^hashFiles%(") then return HEX64 end
    if expression == "matrix.image && 'container' || steps.names.outputs.image" then
      return in_container(leg) and "container" or IMAGES[leg]
    end
    if expression == "steps.zig-cache-restore.outputs.cache-primary-key" then
      return expand((step_of(steps, "zig-cache-restore").with as {string: string}).key, leg, steps)
    end
    local value = values[expression]
    assert(value ~= nil, "a key holds an expression the test gives no value: " .. expression)
    return value
  end))
end

--- Runs the `seed` job (of `ci`, ci.yml's jobs)'s key read for leg `leg`
--- over `keys` (a seed.keys), and answers what it wrote to
--- $GITHUB_OUTPUT.
local function read_keys(tmp: string, ci: {string: {string: any}}, leg: string, keys: string): string
  runs = runs + 1
  local dir = tmp .. "/read-" .. runs
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/seed.keys", keys))
  assert(Fs.write(dir .. "/output", ""))
  local seed = ci.seed
  local script = step_of(seed.steps as {{string: any}}, "keys").run as string
  script = script:gsub("%${{ matrix%.name }}", leg):gsub("%${{ github%.sha }}", SHA)
  assert(not script:find("${{", 1, true), "the key read holds an expression the test gives no value: " .. script)
  local result = assert(Child.run({ "/bin/sh", "-e", "-c", script }, {
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", RUNNER_TEMP = dir, GITHUB_OUTPUT = dir .. "/output" },
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return Fs.read(dir .. "/output") or ""
end

--- Every key a leg's `stage` names, run as ci.yml runs it on that leg
--- (its env, and the driver check's marker under the key ci.yml builds
--- for it), `seed` reads back on that leg's own runner, and no other
--- leg's: linux-aarch64's driver marker, whose image holds a third
--- `-`-joined part, was once dropped, so each of its queue legs ran the
--- driver check again.
local function test_seed_reads_every_key_each_leg_stages(tmp: string)
  local ci = workflow().jobs as {string: {string: any}}
  local platform, checked = ci.platform, ci.checked
  local platform_steps = platform.steps as {{string: any}}
  local checked_steps = checked.steps as {{string: any}}
  local legs = ((ci.seed.strategy as {string: any}).matrix as {string: any}).include as {{string: any}}
  local staged: {string: string} = {}
  for _, leg in ipairs(legs) do
    local name = leg.name as string
    local steps = leg.checked and checked_steps or platform_steps
    local env: {string: string} = {}
    for key, template in pairs(step_of(steps, nil, "queue-seed.sh stage").env as {string: string}) do
      env[key] = expand(template, name, steps)
    end
    local marker: string
    if not leg.checked then
      marker = expand((step_of(steps, "driver-check-restore").with as {string: string}).key, name, steps)
      -- A container leg's marker names its container (in the host's
      -- prefix), not the runner's image, which a mixed fleet varies;
      -- macOS's, on the runner's own userland, names the image.
      if in_container(name) then
        assert(marker:find("-container-verdicts-" .. name .. "-", 1, true) and
            not marker:find(IMAGES[name], 1, true), marker)
      else
        assert(marker:find("-" .. IMAGES[name] .. "-verdicts-" .. name .. "-", 1, true), marker)
      end
    end
    local _, keys = stage(tmp, env, marker ~= nil, marker)
    -- Each cache the leg saves is named: the verdicts twice, and where
    -- the leg is a platform one its compiles, zig outputs and marker.
    local _, count = keys:gsub("\n", "")
    assert(count == (leg.checked and 2 or 6), name .. ": " .. keys)
    local read = read_keys(tmp, ci, name, keys)
    assert(read == keys, name .. " reads back only some of its keys:\n" .. keys .. "read:\n" .. read)
    staged[name] = keys
  end
  -- A leg reads none of another's, nor of one whose name begins its own.
  for name, keys in pairs(staged) do
    for other in pairs(staged) do
      if other ~= name then
        local read = read_keys(tmp, ci, other, keys)
        assert(read == "", other .. " reads " .. name .. "'s keys: " .. read)
      end
    end
  end
end
