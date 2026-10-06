--- The verdicts main saves under each commit, for a branch based on it:
--- .github/scripts/merge-base.sh, which finds the main commit a run's
--- tree grew from, and .github/scripts/prune-commit-verdicts.sh, which
--- deletes those entries a day on. Each runs against a fake `gh` holding
--- the API's JSON, which it answers through the script's own `--jq`
--- filter with the system's jq (build/commit_verdicts_jq_test.tl, which a
--- host with no jq skips); the filters are held to their text here, where
--- jq is not needed.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The scripts, and the system's `sh` and tools, which run them.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = ".github/scripts/merge-base.sh", letters = "r" },
    { path = ".github/scripts/prune-commit-verdicts.sh", letters = "r" },
  },
}

local fixture = require("build.commit_verdicts_fixture")

local MERGE_BASE <const> = fixture.MERGE_BASE
local PRUNE <const> = fixture.PRUNE
local SHA <const> = fixture.SHA
local BASE <const> = fixture.BASE
local BASE_FILTER <const> = fixture.BASE_FILTER
local PRUNE_FILTER <const> = fixture.PRUNE_FILTER
local COMPILES_FILTER <const> = fixture.COMPILES_FILTER

--- Runs `script` with `env` against a fake `gh` answering `answer`,
--- refusing to delete the ids of `refuse`; answers what it wrote to
--- $GITHUB_OUTPUT, the calls it made to `gh`, and what it said.
local function run(tmp: string, script: string, env: {string: string}, answer: string, refuse?: {string}):
    string, string, string
  local ran = fixture.run(tmp, script, env, answer, refuse)
  return ran.output, ran.calls, ran.said
end
local deleted = fixture.deleted

local function test_the_filters_are_the_scripts()
  local text = assert(Fs.read(MERGE_BASE))
  assert(text:find("--jq '" .. BASE_FILTER .. "'", 1, true), "merge-base.sh's filter moved")
  text = assert(Fs.read(PRUNE))
  assert(text:find('prune verdicts- "' .. PRUNE_FILTER .. '"', 1, true), "prune-commit-verdicts.sh's filter moved")
  assert(text:find('prune compiles-branch- "' .. COMPILES_FILTER .. '"', 1, true),
    "prune-commit-verdicts.sh's filter of the branches' compiles moved")
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

--- A lookup that fails names nothing, and the job goes on: the restore
--- takes main's newest.
local function test_a_failed_lookup_names_nothing(tmp: string)
  local env <const> = { EVENT = "push", REF = "refs/heads/topic", SHA = SHA }
  local output, calls, said = run(tmp, MERGE_BASE, env, "FAIL")
  assert(output == "" and calls ~= "", output .. calls)
  assert(said:find("main's newest", 1, true), said)
end

--- A listing or a delete that fails fails nothing: the rest go on.
local function test_a_failed_prune_fails_nothing(tmp: string)
  local _, calls, said = run(tmp, PRUNE, {}, "FAIL")
  assert(deleted(calls) == "" and said:find("none pruned", 1, true), calls .. said)
end
