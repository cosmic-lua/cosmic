--- .github/scripts/queue-seed.sh, which finds the merge queue's run a
--- push to main reuses (`find`), and keeps in a queue run's leg what
--- main would have saved, under the keys it would have saved it under
--- (`stage`). `find` runs against a fake `gh` that answers what the
--- script's `--jq` filters would print, one lookup at a time.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The script, and the system's `sh` and tools, which run it.
Test.needs{ reads = { ".github/scripts/queue-seed.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/queue-seed.sh"))

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local QUEUE <const> = "gh-readonly-queue/main/pr-7-fedcba"

--- A fake `gh`: each lookup of the runs answers the next of
--- `lookups` (a lookup "FAIL" fails), the last again once they run out;
--- a lookup of run <id>'s artifacts answers `artifacts[id]`. Each
--- call's arguments are logged to `calls`.
local FAKE <const> = [[#!/bin/sh
echo "$*" >> "$FAKE/calls"
case $2 in
  */artifacts*) id=${2%/artifacts*}; id=${id##*/}; cat "$FAKE/artifacts-$id" 2>/dev/null; exit 0 ;;
esac
n=$(($(cat "$FAKE/n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$FAKE/n"
[ -f "$FAKE/lookup-$n" ] || n=last
[ "$(cat "$FAKE/lookup-$n")" != FAIL ] || exit 1
cat "$FAKE/lookup-$n"
]]

local runs = 0

--- A run's line, as the script's filter prints it.
local function line(id: string, status: string, conclusion: string, sha: string, branch: string): string
  return id .. " " .. status .. " " .. conclusion .. " " .. sha .. " " .. branch ..
    " https://github.com/o/r/actions/runs/" .. id .. "\n"
end

--- What `find` writes to $GITHUB_OUTPUT, the calls it made to `gh`,
--- its status and what it said.
local function find(tmp: string, lookups: {string}, artifacts: {string: string}): string, string, integer, string
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/gh", FAKE))
  assert(Fs.chmod(dir .. "/bin/gh", 493))
  for i, text in ipairs(lookups) do
    assert(Fs.write(dir .. "/lookup-" .. (i == #lookups and "last" or tostring(i)), text))
  end
  for id, names in pairs(artifacts) do assert(Fs.write(dir .. "/artifacts-" .. id, names)) end
  local env: {string: string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"), FAKE = dir,
    GITHUB_OUTPUT = dir .. "/output", GITHUB_STEP_SUMMARY = dir .. "/summary",
    REPOSITORY = "o/r", SHA = SHA, WAIT_SECONDS = "0", TRIES = "3",
  }
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "find" }, { env = env, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  return Fs.read(dir .. "/output") or "", Fs.read(dir .. "/calls") or "", result.code,
    (result.stdout or "") .. (result.stderr or "")
end

local SEEDED <const> = "ci-driver-linux-x86_64\nseed-linux-x86_64\nportable-product-linux-x86_64\n"

local function found(id: string): string
  return "run=" .. id .. "\nurl=https://github.com/o/r/actions/runs/" .. id .. "\n"
end
local NONE <const> = "run=\nurl=\n"

--- The queue's passing run of this commit is found, by the commit and
--- the event, and named in the step summary.
local function test_a_passing_queue_run_is_found(tmp: string)
  local output, calls, code, said = find(tmp, { line("42", "completed", "success", SHA, QUEUE) },
    { ["42"] = SEEDED })
  assert(code == 0, said)
  assert(output == found("42"), output)
  assert(calls:find("repos/o/r/actions/workflows/ci.yml/runs?event=merge_group&head_sha=" .. SHA, 1, true), calls)
  assert(said:find("passed the merge queue in https://github.com/o/r/actions/runs/42", 1, true), said)
  assert((Fs.read(tmp .. "/run-" .. runs .. "/summary") or ""):find("runs/42", 1, true))
end

--- No run of this commit, or none that passed on main's queue with a
--- seed, is none: the push runs the full scope, and the lookup, which
--- gives up only then, never fails it.
local function test_no_passing_seeded_queue_run_is_none(tmp: string)
  local cases: {{string: string}} = {
    { runs = "", why = "no run" },
    { runs = line("42", "completed", "failure", SHA, QUEUE), why = "a failed run" },
    { runs = line("42", "completed", "cancelled", SHA, QUEUE), why = "a cancelled run" },
    { runs = line("42", "completed", "success", "f" .. SHA:sub(2), QUEUE), why = "another commit's run" },
    { runs = line("42", "completed", "success", SHA, "gh-readonly-queue/other/pr-7-x"), why = "another branch's queue" },
    { runs = line("43", "completed", "success", SHA, QUEUE), why = "a run with no seed" },
  }
  for _, case in ipairs(cases) do
    local output, _, code, said = find(tmp, { case.runs }, { ["42"] = SEEDED, ["43"] = "portable-product-x\n" })
    assert(code == 0, case.why .. ": " .. said)
    assert(output == NONE, case.why .. ": " .. output)
    assert(said:find("the full scope runs", 1, true), said)
  end
end

--- A run of this commit still in progress -- the queue lands its merge
--- the moment its check passes -- is asked after again, until it
--- completes; one that never does, or an API that keeps failing, is
--- given up on after TRIES lookups.
local function test_a_run_in_progress_is_waited_for(tmp: string)
  local output, calls, code, said = find(tmp, {
    line("42", "in_progress", "none", SHA, QUEUE), "FAIL",
    line("42", "completed", "success", SHA, QUEUE),
  }, { ["42"] = SEEDED })
  assert(code == 0 and output == found("42"), output .. said)
  local lookups = select(2, calls:gsub("workflows/ci.yml/runs", ""))
  assert(lookups == 3, calls)
  for _, stuck in ipairs({ line("42", "queued", "none", SHA, QUEUE), "FAIL" }) do
    output, calls, code = find(tmp, { stuck }, {})
    lookups = select(2, calls:gsub("workflows/ci.yml/runs", ""))
    assert(code == 0 and output == NONE and lookups == 3, output .. calls)
  end
end

--- One passing run is enough where another of the commit failed.
local function test_a_passing_run_beside_a_failed_one_is_found(tmp: string)
  local output = find(tmp, { line("41", "completed", "failure", SHA, QUEUE) ..
    line("42", "completed", "success", SHA, QUEUE) }, { ["41"] = SEEDED, ["42"] = SEEDED })
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
