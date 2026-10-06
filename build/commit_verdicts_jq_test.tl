--- The cases of .github/scripts/merge-base.sh and
--- .github/scripts/prune-commit-verdicts.sh that run their `--jq` filters
--- through the system's jq, as a fake `gh` answers them (see
--- build/commit_verdicts_fixture.tl). A host with no jq skips them
--- (`requires`); the filters' text is held in build/commit_verdicts_test.tl,
--- which runs everywhere. Live, gh's own jq (gojq) runs the filters, which
--- this system jq only stands in for.
-- Only the macOS leg is promised a jq (ci/cosmic_ci/capabilities.tl, whose
-- TODO names what the Linux legs wait on), so the Linux legs skip these.
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local fixture = require("build.commit_verdicts_fixture")

--- The scripts, and the system's `sh`, jq and tools, which run them.
Test.policy{
  profiles = { "system" },
  env = { "PATH" },
  grants = {
    { path = ".github/scripts/merge-base.sh", letters = "r" },
    { path = ".github/scripts/prune-commit-verdicts.sh", letters = "r" },
  },
  requires = { "program:jq" },
}

local MERGE_BASE <const> = fixture.MERGE_BASE
local PRUNE <const> = fixture.PRUNE
local SHA <const> = fixture.SHA
local BASE <const> = fixture.BASE
local BASE_FILTER <const> = fixture.BASE_FILTER

--- Runs `script` with `env` against a fake `gh` answering `answer`,
--- refusing to delete the ids of `refuse`; answers what it wrote to
--- $GITHUB_OUTPUT, the calls it made to `gh`, and what it said.
local function run(tmp: string, script: string, env: {string: string}, answer: string, refuse?: {string}):
    string, string, string
  local ran = fixture.run(tmp, script, env, answer, refuse)
  return ran.output, ran.calls, ran.said
end
local deleted = fixture.deleted

--- A branch's push asks the API for its merge base with main, by the
--- commit, and names it.
local function test_a_branch_push_names_its_merge_base(tmp: string)
  local output, calls, said = run(tmp, MERGE_BASE, { EVENT = "push", REF = "refs/heads/topic", SHA = SHA },
    '{"merge_base_commit":{"sha":"' .. BASE .. '"},"commits":[]}')
  assert(output == "sha=" .. BASE .. "\n", output .. said)
  assert(calls == "api repos/o/r/compare/main..." .. SHA .. "?per_page=1 --jq " .. BASE_FILTER .. "\n", calls)
end

--- A lookup that answers no whole commit names nothing either.
local function test_an_answer_that_is_no_commit_names_nothing(tmp: string)
  local env <const> = { EVENT = "push", REF = "refs/heads/topic", SHA = SHA }
  for _, answer in ipairs({ '{"message":"Not Found"}', '{"merge_base_commit":{"sha":"abc"}}',
      '{"merge_base_commit":{"sha":"' .. BASE:upper() .. '"}}', "not json" }) do
    local output = run(tmp, MERGE_BASE, env, answer)
    assert(output == "", answer .. ": " .. output)
  end
end

--- An entry as the API lists the cache's: `hours` old.
local function entry(id: integer, key: string, hours: number): string
  -- With milliseconds, as the API writes them.
  local created = Time.format_rfc3339(Time.now_ns() - math.floor(hours * 3600) * 1000000000, nil, { digits = 3 })
  return '{"id":' .. id .. ',"key":"' .. key .. '","created_at":"' .. created .. '","ref":"refs/heads/main"}'
end

local function listing(...: string): string
  return '{"total_count":' .. select("#", ...) .. ',"actions_caches":[' .. table.concat({ ... }, ",") .. "]}"
end

--- Only the verdicts under a commit, a day old, are deleted: not those
--- under their content, nor a newer commit's, nor another cache's.
local function test_the_prune_deletes_only_old_verdicts_under_a_commit(tmp: string)
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
  local _, calls, said = run(tmp, PRUNE, {}, listing(
    entry(1, "compiles-branch-leg-0123abcd-d0d0d0", 30),
    entry(2, "compiles-branch-leg-0123abcd-d1d1d1", 2),
    entry(3, "compiles-leg-d0d0d0", 50),
    entry(4, "verdicts-leg-0123456789abcdef-f-d0d0d0", 50)))
  assert(calls:find("api --paginate repos/o/r/actions/caches?key=compiles-branch-&per_page=100 --jq ", 1, true), calls)
  assert(deleted(calls) == "1", calls)
  assert(said:find("pruned 1 branch compiles entries", 1, true), said)
end

--- A prune whose delete fails goes on with the rest and counts the failure.
local function test_a_failed_delete_leaves_the_rest_deleted(tmp: string)
  local _, calls, said = run(tmp, PRUNE, {}, listing(entry(1, "verdicts-leg-h-f-sha-" .. SHA, 30),
    entry(2, "verdicts-leg-h-f-sha-" .. BASE, 30)), { "1" })
  assert(deleted(calls) == "1 2" and said:find("pruned 1 ", 1, true) and said:find("(1 failed)", 1, true),
    calls .. said)
end
