--- The verdicts main saves under each commit, for a branch based on it:
--- [`merge_base`], which finds the main commit a run's tree grew from, and
--- `prune`, which deletes those entries a day on, against the API's JSON
--- as `gh api` prints it (cosmic_ci/github_fake.tl).
local CommitVerdicts = require("cosmic_ci.commit_verdicts")
local GithubFake = require("cosmic_ci.github_fake")
local Time = require("cosmic.time")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local BASE <const> = "fedcba9876543210fedcba9876543210fedcba98"
local TOPIC <const>: {string: string} = { EVENT = "push", REF = "refs/heads/topic", SHA = SHA, REPOSITORY = "o/r" }

--- What [`merge_base`] writes to $GITHUB_OUTPUT, said, and its status, in
--- `env` against the lookup's answer `answer` (nil fails it); the calls
--- it made.
local function merge_base(env: {string: string}, answer?: string): string, string, integer, {string}
  local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return answer end)
  local code = CommitVerdicts.merge_base(env, fake.host)
  return GithubFake.text(fake.outputs), GithubFake.text(fake.printed), code, fake.calls
end

--- A branch's push asks the API for its merge base with main, by the
--- commit, and names it.
local function test_a_branch_push_names_its_merge_base()
  local output, said, code, calls = merge_base(TOPIC,
    '{"merge_base_commit":{"sha":"' .. BASE .. '"},"commits":[]}')
  assert(code == 0 and output == "sha=" .. BASE .. "\n", output .. said)
  assert(#calls == 1 and calls[1] == "api repos/o/r/compare/main..." .. SHA .. "?per_page=1", table.concat(calls, "\n"))
  assert(said:find(BASE, 1, true), said)
end

--- A lookup that answers no whole commit names nothing either.
local function test_an_answer_that_is_no_commit_names_nothing()
  for _, answer in ipairs({ '{"message":"Not Found"}', '{"merge_base_commit":{"sha":"abc"}}',
      '{"merge_base_commit":{"sha":"' .. BASE:upper() .. '"}}', '{"merge_base_commit":{"sha":7}}',
      '{"merge_base_commit":null}', "not json" }) do
    local output, said, code = merge_base(TOPIC, answer)
    assert(code == 0 and output == "", answer .. ": " .. output)
    assert(said:find("main's newest", 1, true), said)
  end
end

--- The merge queue's run takes its base with no call; main's push, and
--- any other event, names none, and asks nothing.
local function test_the_queue_names_its_base_and_main_none()
  local output, _, _, calls = merge_base({ EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x",
    SHA = SHA, QUEUE_BASE = BASE, REPOSITORY = "o/r" })
  assert(output == "sha=" .. BASE .. "\n" and #calls == 0, output .. table.concat(calls, "\n"))
  for _, env in ipairs({
      { EVENT = "push", REF = "refs/heads/main", SHA = SHA },
      { EVENT = "schedule", REF = "refs/heads/main", SHA = SHA },
      { EVENT = "workflow_dispatch", REF = "refs/heads/topic", SHA = SHA },
      { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x", SHA = SHA, QUEUE_BASE = "" },
      { EVENT = "merge_group", REF = "refs/heads/gh-readonly-queue/main/x", SHA = SHA, QUEUE_BASE = "main" },
      {},
  }) do
    local none, _, _, asked = merge_base(env, nil)
    assert(none == "" and #asked == 0, tostring(env.EVENT) .. " " .. tostring(env.REF) .. ": " .. none ..
        table.concat(asked, "\n"))
  end
end

--- A lookup that fails names nothing, and the job goes on: the restore
--- takes main's newest.
local function test_a_failed_lookup_names_nothing()
  local output, said, code, calls = merge_base(TOPIC, nil)
  assert(code == 0 and output == "" and #calls == 1, output .. table.concat(calls, "\n"))
  assert(said:find("main's newest", 1, true), said)
  assert(said:find("lookup failed: failed", 1, true), said)
end

--- An entry as the API lists the cache's: `hours` old.
local function entry(id: integer, key: string, hours: number): string
  -- With milliseconds, as the API writes them.
  local created = Time.format_rfc3339((GithubFake.START - math.floor(hours * 3600)) * 1000000000, nil, { digits = 3 })
  return '{"id":' .. id .. ',"key":"' .. key .. '","created_at":"' .. created .. '","ref":"refs/heads/main"}'
end

--- The API's list of the entries given, a page.
local function listing(...: string): string
  return '{"total_count":' .. select("#", ...) .. ',"actions_caches":[' .. table.concat({ ... }, ",") .. "]}"
end

--- A whole `--paginate --slurp` answer: each of `pages` a page.
local function pages(...: string): string
  return "[" .. table.concat({ ... }, ",") .. "]"
end

--- The ids `fake` deleted, in order.
local function deleted(fake: GithubFake.Fake): string
  local ids: {string} = {}
  for _, call in ipairs(fake.calls) do
    local id = call:match("^api %-X DELETE repos/o/r/actions/caches/(%d+)$")
    if id then ids[#ids + 1] = id end
  end
  return table.concat(ids, " ")
end

--- `prune` in `env` over `answer`, the listing as `gh --paginate --slurp`
--- prints it (nil fails it), refusing to delete the ids of `refuse`:
--- the fake, what it said and its status.
local function prune(env: {string: string}, answer: string | nil, refuse?: {string}): GithubFake.Fake, string, integer
  local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return answer end, refuse)
  env.REPOSITORY = "o/r"
  local code = CommitVerdicts.prune(env, fake.host)
  return fake, GithubFake.text(fake.printed), code
end

--- Only the verdicts under a commit, a day old, are deleted: not those
--- under their content, nor a newer commit's, nor another cache's.
local function test_the_prune_deletes_only_old_verdicts_under_a_commit()
  local fake, said, code = prune({}, pages(listing(
    entry(1, "verdicts-leg-0123456789abcdef-f-sha-" .. SHA, 30),
    entry(2, "verdicts-leg-0123456789abcdef-f-sha-" .. BASE, 2),
    entry(3, "verdicts-leg-0123456789abcdef-f-d0d0d0", 50),
    entry(4, "verdicts-leg-checked-0123456789abcdef-f-sha-" .. BASE, 25),
    entry(5, "verdicts-leg-0123456789abcdef-f-sha-abc", 50),
    entry(6, "verdicts-leg-0123456789abcdef-f-sha-0" .. SHA, 50))))
  assert(code == 0, said)
  assert(fake.calls[1] == "api --paginate --slurp repos/o/r/actions/caches?key=verdicts-&per_page=100", fake.calls[1])
  assert(deleted(fake) == "1 4", table.concat(fake.calls, "\n"))
  assert(said:find("pruned 2 commit-keyed verdict entries older than 24 h (0 failed)", 1, true), said)
  -- HOURS moves the cutoff.
  fake = prune({ HOURS = "1" }, pages(listing(entry(2, "verdicts-leg-h-f-sha-" .. BASE, 2))))
  assert(deleted(fake) == "2", table.concat(fake.calls, "\n"))
end

--- The compiles a branch's push saved for its later pushes go a day
--- on too, and nothing else of the compiles: main's own, keyed by their
--- content, stay, whatever their age.
local function test_the_prune_deletes_old_branch_compiles()
  local fake, said = prune({}, pages(listing(
    entry(1, "compiles-branch-leg-0123abcd-d0d0d0", 30),
    entry(2, "compiles-branch-leg-0123abcd-d1d1d1", 2),
    entry(3, "compiles-leg-d0d0d0", 50),
    entry(4, "verdicts-leg-0123456789abcdef-f-d0d0d0", 50))))
  assert(fake.calls[2] == "api --paginate --slurp repos/o/r/actions/caches?key=compiles-branch-&per_page=100",
    table.concat(fake.calls, "\n"))
  assert(deleted(fake) == "1", table.concat(fake.calls, "\n"))
  assert(said:find("pruned 1 branch compiles entry older than 24 h", 1, true), said)
end

--- Every page of the listing is read, as `--paginate` reads them.
local function test_the_prune_reads_every_page()
  local fake = prune({}, pages(listing(entry(1, "verdicts-leg-h-f-sha-" .. SHA, 30)),
    listing(entry(2, "verdicts-leg-h-f-sha-" .. BASE, 30)), listing()))
  assert(deleted(fake) == "1 2", table.concat(fake.calls, "\n"))
end

--- A prune whose delete fails goes on with the rest and counts the failure.
local function test_a_failed_delete_leaves_the_rest_deleted()
  local fake, said = prune({}, pages(listing(entry(1, "verdicts-leg-h-f-sha-" .. SHA, 30),
    entry(2, "verdicts-leg-h-f-sha-" .. BASE, 30))), { "1" })
  assert(deleted(fake) == "1 2" and said:find("pruned 1 commit-keyed verdict entry older", 1, true) and
      said:find("(1 failed)", 1, true), table.concat(fake.calls, "\n") .. said)
end

--- A listing or a delete that fails fails nothing: the rest go on.
local function test_a_failed_prune_fails_nothing()
  local fake, said, code = prune({}, nil)
  assert(code == 0 and deleted(fake) == "" and said:find("none pruned", 1, true), table.concat(fake.calls, "\n") .. said)
  -- Both listings are asked, and both said.
  assert(#fake.calls == 2 and #fake.printed == 4, table.concat(fake.printed, "\n"))
  assert(said:find("lookup failed: failed", 1, true), said)
  -- An answer that is no list of entries, or one whose entry holds no
  -- time to read, deletes none: the listing could not be read.
  for _, answer in ipairs({ '{"message":"Bad credentials"}', pages("{}"),
      pages('{"actions_caches":[{"id":1,"key":"verdicts-h-f-sha-' .. SHA .. '"}]}'),
      pages('{"actions_caches":[{"id":1,"key":"verdicts-h-f-sha-' .. SHA .. '","created_at":"yesterday"}]}') }) do
    fake, said, code = prune({}, answer)
    assert(code == 0 and deleted(fake) == "" and said:find("none pruned", 1, true), answer .. said)
  end
end

--- A step that cannot be read refuses, asking nothing.
local function test_an_unreadable_environment_is_refused()
  for _, env in ipairs({ { HOURS = "a day" }, { HOURS = "-1" }, { CALL_SECONDS = "soon" } }) do
    local fake, _, code = prune(env, pages(listing()))
    assert(code == 2 and #fake.calls == 0, tostring(env.HOURS))
  end
  local fake = GithubFake.new(function(): string | nil return nil end)
  assert(CommitVerdicts.merge_base({ CALL_SECONDS = "soon" }, fake.host) == 2 and #fake.calls == 0)
end
