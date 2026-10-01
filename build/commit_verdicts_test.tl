--- The verdicts main saves under each commit, for a branch based on it:
--- .github/scripts/merge-base.sh, which finds the main commit a run's
--- tree grew from, and .github/scripts/prune-commit-verdicts.sh, which
--- deletes those entries a day on. Each runs against a fake `gh` holding
--- the API's JSON, which it answers through the script's own `--jq`
--- filter with the system's jq; where the system has no jq (CI's
--- images), those cases return unchecked, and the filters are held to
--- their text alone.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The scripts, and the system's `sh`, jq and tools, which run them.
Test.needs{
  reads = { ".github/scripts/merge-base.sh", ".github/scripts/prune-commit-verdicts.sh" },
  system = true,
}

-- By their whole paths: a process the test starts elsewhere finds them.
local MERGE_BASE <const> = assert(Fs.absolute(".github/scripts/merge-base.sh"))
local PRUNE <const> = assert(Fs.absolute(".github/scripts/prune-commit-verdicts.sh"))

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local BASE <const> = "fedcba9876543210fedcba9876543210fedcba98"

--- The filters the scripts hand `gh api --jq`, as they write them.
local BASE_FILTER <const> = ".merge_base_commit.sha"
local PRUNE_FILTER <const> = [[.actions_caches[] | select(.key | test(\"-sha-[0-9a-f]{40}\$\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id]]
local COMPILES_FILTER <const> = [[.actions_caches[] | select(.key | startswith(\"compiles-branch-\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id]]

--- A fake `gh`: `api [--paginate] URL --jq FILTER` answers the file
--- `answer` through FILTER, or fails where it holds FAIL; `api -X DELETE
--- URL` succeeds but for a URL ending in an id listed in `refuse`. Each
--- call's arguments are logged to `calls`.
local FAKE <const> = [[#!/bin/sh
echo "$*" >> "$FAKE/calls"
[ "$1" = api ] || { echo "fake gh: $*" >&2; exit 2; }
shift
if [ "$1" = -X ]; then
  [ "$2" = DELETE ] || exit 2
  ! grep -qx "${3##*/}" "$FAKE/refuse" 2>/dev/null
  exit
fi
[ "$1" != --paginate ] || shift
[ "$2" = --jq ] && [ $# -eq 3 ] || { echo "fake gh: $*" >&2; exit 2; }
[ "$(cat "$FAKE/answer")" != FAIL ] || exit 1
jq -r "$3" "$FAKE/answer"
]]

--- Whether the system has a jq to answer the filters through. Where it
--- has none (CI's images), the cases that need one return unchecked and
--- only test_the_filters_are_the_scripts holds the filters; live, gh's
--- own jq (gojq) runs them, which this system jq only stands in for.
local function has_jq(): boolean
  local result = Child.run({ "/bin/sh", "-c", "command -v jq" }, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })
  return result ~= nil and result.code == 0
end

local runs = 0

--- Runs `script` with `env` against a fake `gh` answering `answer`,
--- refusing to delete the ids of `refuse`; answers what it wrote to
--- $GITHUB_OUTPUT, the calls it made to `gh`, and what it said.
local function run(tmp: string, script: string, env: {string: string}, answer: string, refuse?: {string}):
    string, string, string
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/gh", FAKE))
  assert(Fs.chmod(dir .. "/bin/gh", 493))
  assert(Fs.write(dir .. "/answer", answer))
  assert(Fs.write(dir .. "/refuse", table.concat(refuse or {}, "\n") .. "\n"))
  local full: {string: string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"), FAKE = dir,
    GITHUB_OUTPUT = dir .. "/output", REPOSITORY = "o/r",
  }
  for name, value in pairs(env) do full[name] = value end
  local result = assert(Child.run({ "/bin/sh", script }, { env = full, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  local said = (result.stdout or "") .. (result.stderr or "")
  assert(result.code == 0, "the script failed the job: " .. said)
  return Fs.read(dir .. "/output") or "", Fs.read(dir .. "/calls") or "", said
end

local function test_the_filters_are_the_scripts()
  local text = assert(Fs.read(MERGE_BASE))
  assert(text:find("--jq '" .. BASE_FILTER .. "'", 1, true), "merge-base.sh's filter moved")
  text = assert(Fs.read(PRUNE))
  assert(text:find('prune verdicts- "' .. PRUNE_FILTER .. '"', 1, true), "prune-commit-verdicts.sh's filter moved")
  assert(text:find('prune compiles-branch- "' .. COMPILES_FILTER .. '"', 1, true),
    "prune-commit-verdicts.sh's filter of the branches' compiles moved")
end

--- A branch's push asks the API for its merge base with main, by the
--- commit, and names it.
local function test_a_branch_push_names_its_merge_base(tmp: string)
  if not has_jq() then return end
  local output, calls, said = run(tmp, MERGE_BASE, { EVENT = "push", REF = "refs/heads/topic", SHA = SHA },
    '{"merge_base_commit":{"sha":"' .. BASE .. '"},"commits":[]}')
  assert(output == "sha=" .. BASE .. "\n", output .. said)
  assert(calls == "api repos/o/r/compare/main..." .. SHA .. "?per_page=1 --jq " .. BASE_FILTER .. "\n", calls)
end

--- The merge queue's run takes its base with no call; main's push, and
--- any other event, names none, and asks nothing.
local function test_the_queue_names_its_base_and_main_none(tmp: string)
  local output, calls = run(tmp, MERGE_BASE, { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x",
    SHA = SHA, QUEUE_BASE = BASE }, "FAIL")
  assert(output == "sha=" .. BASE .. "\n" and calls == "", output .. calls)
  for _, env in ipairs({
    { EVENT = "push", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "schedule", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "workflow_dispatch", REF = "refs/heads/topic", SHA = SHA },
    { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x", SHA = SHA, QUEUE_BASE = "" },
  }) do
    output, calls = run(tmp, MERGE_BASE, env, "FAIL")
    assert(output == "" and calls == "", env.EVENT .. " " .. env.REF .. ": " .. output .. calls)
  end
end

--- A lookup that fails, or answers no whole commit, names nothing, and
--- the job goes on: the restore takes main's newest.
local function test_a_failed_lookup_names_nothing(tmp: string)
  local env <const> = { EVENT = "push", REF = "refs/heads/topic", SHA = SHA }
  local output, calls, said = run(tmp, MERGE_BASE, env, "FAIL")
  assert(output == "" and calls ~= "", output .. calls)
  assert(said:find("main's newest", 1, true), said)
  if not has_jq() then return end
  for _, answer in ipairs({ '{"message":"Not Found"}', '{"merge_base_commit":{"sha":"abc"}}',
      '{"merge_base_commit":{"sha":"' .. BASE:upper() .. '"}}', "not json" }) do
    output = run(tmp, MERGE_BASE, env, answer)
    assert(output == "", answer .. ": " .. output)
  end
end

--- An entry as the API lists the cache's: `hours` old.
local function entry(id: integer, key: string, hours: number): string
  -- With milliseconds, as the API writes them.
  local created = Time.format_rfc3339(Time.now_ns() - math.floor(hours * 3600) * 1000000000, { digits = 3 })
  return '{"id":' .. id .. ',"key":"' .. key .. '","created_at":"' .. created .. '","ref":"refs/heads/main"}'
end

local function listing(...: string): string
  return '{"total_count":' .. select("#", ...) .. ',"actions_caches":[' .. table.concat({ ... }, ",") .. "]}"
end

--- The ids `calls` deleted, in order.
local function deleted(calls: string): string
  local ids: {string} = {}
  for id in calls:gmatch("api %-X DELETE repos/o/r/actions/caches/(%d+)\n") do ids[#ids + 1] = id end
  return table.concat(ids, " ")
end

--- Only the verdicts under a commit, a day old, are deleted: not those
--- under their content, nor a newer commit's, nor another cache's.
local function test_the_prune_deletes_only_old_verdicts_under_a_commit(tmp: string)
  if not has_jq() then return end
  local _, calls, said = run(tmp, PRUNE, {}, listing(
    entry(1, "verdicts-leg-0123456789abcdef-f-sha-" .. SHA, 30),
    entry(2, "verdicts-leg-0123456789abcdef-f-sha-" .. BASE, 2),
    entry(3, "verdicts-leg-0123456789abcdef-f-d0d0d0", 50),
    entry(4, "verdicts-leg-checked-0123456789abcdef-f-sha-" .. BASE, 25),
    entry(5, "verdicts-leg-0123456789abcdef-f-sha-abc", 50)))
  assert(calls:find("api --paginate repos/o/r/actions/caches?key=verdicts-&per_page=100 --jq ", 1, true), calls)
  assert(deleted(calls) == "1 4", calls)
  assert(said:find("pruned 2 ", 1, true), said)
  -- HOURS moves the cutoff.
  _, calls = run(tmp, PRUNE, { HOURS = "1" }, listing(entry(2, "verdicts-leg-h-f-sha-" .. BASE, 2)))
  assert(deleted(calls) == "2", calls)
end

--- The compiles a branch's push saved for its later pushes go a day
--- on too, and nothing else of the compiles: main's own, keyed by their
--- content, stay, whatever their age.
local function test_the_prune_deletes_old_branch_compiles(tmp: string)
  if not has_jq() then return end
  local _, calls, said = run(tmp, PRUNE, {}, listing(
    entry(1, "compiles-branch-leg-0123abcd-d0d0d0", 30),
    entry(2, "compiles-branch-leg-0123abcd-d1d1d1", 2),
    entry(3, "compiles-leg-d0d0d0", 50),
    entry(4, "verdicts-leg-0123456789abcdef-f-d0d0d0", 50)))
  assert(calls:find("api --paginate repos/o/r/actions/caches?key=compiles-branch-&per_page=100 --jq ", 1, true), calls)
  assert(deleted(calls) == "1", calls)
  assert(said:find("pruned 1 branch compiles entries", 1, true), said)
end

--- A listing or a delete that fails fails nothing: the rest go on.
local function test_a_failed_prune_fails_nothing(tmp: string)
  local _, calls, said = run(tmp, PRUNE, {}, "FAIL")
  assert(deleted(calls) == "" and said:find("none pruned", 1, true), calls .. said)
  if not has_jq() then return end
  _, calls, said = run(tmp, PRUNE, {}, listing(entry(1, "verdicts-leg-h-f-sha-" .. SHA, 30),
    entry(2, "verdicts-leg-h-f-sha-" .. BASE, 30)), { "1" })
  assert(deleted(calls) == "1 2" and said:find("pruned 1 ", 1, true) and said:find("(1 failed)", 1, true),
    calls .. said)
end
