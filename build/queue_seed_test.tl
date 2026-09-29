--- .github/scripts/queue-seed.sh, which finds the merge queue's run a
--- push to main reuses (`find`), and keeps in a queue run's leg what
--- main would have saved, under the keys it would have saved it under
--- (`stage`). `find` runs against a fake `gh` holding the API's JSON,
--- which it answers through the script's own `--jq` filters with the
--- system's jq, one lookup at a time; where the system has no jq (CI's
--- images), those cases return unchecked, and the filters are held to
--- their text alone.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The script, and the system's `sh`, jq and tools, which run it.
Test.needs{ reads = { ".github/scripts/queue-seed.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/queue-seed.sh"))

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local QUEUE <const> = "gh-readonly-queue/main/pr-7-fedcba"

--- The filters the script hands `gh api --jq`, as it writes them.
local RUNS_FILTER <const> = [[.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"]]
local ARTIFACTS_FILTER <const> = ".artifacts[] | select(.expired | not) | .name"

--- A fake `gh api URL --jq FILTER`: each lookup of the runs answers the
--- next of the lookups written (one "FAIL" fails), the last again once
--- they run out; one of run <id>'s artifacts answers artifacts-<id>
--- (none where there is no such file), and fails once where
--- artifacts-<id>.fail is there. Each call's arguments are logged to
--- `calls`.
local FAKE <const> = [[#!/bin/sh
echo "$*" >> "$FAKE/calls"
[ "$1" = api ] && [ "$3" = --jq ] && [ $# -eq 4 ] || { echo "fake gh: $*" >&2; exit 2; }
case $2 in
  */artifacts*)
    id=${2%/artifacts*}; id=${id##*/}; file=$FAKE/artifacts-$id
    if [ -f "$file.fail" ]; then rm "$file.fail"; exit 1; fi
    [ -f "$file" ] || file=$FAKE/no-artifacts ;;
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

--- A run, as the API lists it.
local function run(id: string, status: string, conclusion: string | nil, sha: string, branch: string): string
  return '{"id":' .. id .. ',"status":"' .. status .. '","conclusion":' ..
    (conclusion and ('"' .. conclusion .. '"') or "null") .. ',"head_sha":"' .. sha ..
    '","head_branch":"' .. branch .. '","html_url":"https://github.com/o/r/actions/runs/' .. id .. '"}'
end

--- The API's list of `runs`.
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

--- What `stage` keeps under $RUNNER_TEMP/seed, run with `env`, and
--- its seed.keys.
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
end
