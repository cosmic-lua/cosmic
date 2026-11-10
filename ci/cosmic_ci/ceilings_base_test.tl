--- [`CeilingsBase.ceilings_base`], which names the merge base of a run's
--- commit with main for the format check, against a git that answers as
--- a checkout's and origin's would, each call scripted; no test runs the
--- host's git, and the step asks the API nothing, which a fake API that
--- answers every call with a 500 holds it to.
local CeilingsBase = require("cosmic_ci.ceilings_base")
local ChangedPaths = require("cosmic_ci.changed_paths")
local GithubFake = require("cosmic_ci.github_fake")

local SHA <const> = "0123456789abcdef0123456789abcdef01234567"
local BASE <const> = "fedcba9876543210fedcba9876543210fedcba98"
local OLDER <const> = "1111111111111111111111111111111111111111"
local TIP <const> = "2222222222222222222222222222222222222222"
local HEAD <const> = "3333333333333333333333333333333333333333"
local ENTRY <const> = "4444444444444444444444444444444444444444"

local QUEUE_REF <const> = "refs/heads/gh-readonly-queue/main/pr-1-" .. SHA

--- The fetch of `want`'s history down to the ref `exclude`, as the step runs it.
local function fetch(exclude: string, want: string): string
  return "fetch --quiet --no-tags --shallow-exclude=" .. exclude .. " origin " .. want
end

--- A commit as `git cat-file commit` writes it, with `parents`; its message holds a line no parent is read from.
local function commit(parents: {string}): string
  local lines: mut {string} = { "tree " .. string.rep("9", 40) }
  for _, parent in ipairs(parents) do lines[#lines + 1] = "parent " .. parent end
  lines[#lines + 1] = "author t <t@example.com> 1767225600 +0000"
  return table.concat(lines, "\n") .. "\n\nsubject\n\nparent " .. string.rep("8", 40) .. "\n"
end

--- What a run of the step came to.
local record Step
  --- Its exit status.
  code: integer
  --- What it wrote to $GITHUB_OUTPUT, and what it said.
  output: string
  said: string
  --- The git calls it made, the API calls, and its waits in seconds.
  git: {string}
  calls: {string}
  sleeps: {integer}
end

--- [`CeilingsBase.ceilings_base`] in `env`, against a git that answers each call, by its arguments, with the next of
--- `answers` for it (the last one again once they run out; false for a call that fails) and fails the test on a call
--- they do not name, and an API that answers 500.
local function step(env: {string: string}, answers: {string: {string | boolean}}): Step
  local fake = GithubFake.new(function(_path: string, _nth: integer): string? return nil end)
  local made: mut {string} = {}
  local asked: mut {string: integer} = {}
  local function git(argv: {string}, _seconds: integer): ChangedPaths.Ran
    local call = table.concat(argv, " ")
    made[#made + 1] = call
    local scripted = assert(answers[call], "unexpected git call: " .. call)
    local nth = math.min((asked[call] or 0) + 1, #scripted)
    asked[call] = nth
    local answer = scripted[nth]
    if answer is string then return { ok = true, output = answer } end
    return { ok = false, output = "" }
  end
  local code = CeilingsBase.ceilings_base(env, fake.host, git)
  return { code = code, output = GithubFake.text(fake.outputs), said = GithubFake.text(fake.printed), git = made,
    calls = fake.calls, sleeps = fake.sleeps }
end

local QUEUE <const>: {string: string} = { EVENT = "merge_group", REF = QUEUE_REF, SHA = SHA, REPOSITORY = "o/r",
  BASE_REF = "refs/heads/main", QUEUE_BASE = ENTRY }

local PULL <const>: {string: string} = { EVENT = "pull_request", REF = "refs/pull/1/merge", SHA = SHA, REPOSITORY = "o/r",
  PR_BASE_REF = "main" }

local MANUAL <const>: {string: string} = { EVENT = "workflow_dispatch", REF = "refs/heads/topic", SHA = SHA, REPOSITORY = "o/r" }

--- A history of [`SHA`] that the fetch cut off at one commit, [`ENTRY`], whose parent is [`BASE`].
local function grown_from_one(): mut {string: {string | boolean}}
  return {
    [fetch("refs/heads/main", SHA)] = { "" },
    ["rev-list --parents " .. SHA] = { SHA .. " " .. ENTRY .. "\n" .. ENTRY .. "\n" },
    ["cat-file commit " .. ENTRY] = { commit({ BASE }) },
  }
end

--- A pull request for main names the main its merge commit was merged into, read from the checkout as it is: it
--- fetches nothing and asks the API nothing, so an API that answers 500 ("this diff is temporarily unavailable due to
--- heavy server load") cannot fail it.
local function test_a_pull_request_for_main_reads_its_base_from_the_checkout_and_asks_the_api_nothing()
  local ran = step(PULL, { ["rev-list --parents -n 1 " .. SHA] = { SHA .. " " .. TIP .. " " .. HEAD .. "\n" } })
  assert(ran.code == 0 and ran.output == "sha=" .. TIP .. "\n", tostring(ran.code) .. ran.output .. ran.said)
  assert(#ran.calls == 0 and #ran.git == 1 and #ran.sleeps == 0, table.concat(ran.git, "\n"))
  assert(ran.said:find("first parent", 1, true) ~= nil, ran.said)
end

--- The merge queue's run fetches its commit's history down to main and holds the markers to the one commit of main
--- it is cut off at: not to its own base (`merge_group.base_sha`), the entry ahead, which already holds that entry's
--- markers, and with no call of the API.
local function test_the_queue_holds_the_markers_to_the_commit_of_main_its_history_grew_from_not_to_its_own_base()
  local ran = step(QUEUE, grown_from_one())
  assert(ran.code == 0 and ran.output == "sha=" .. BASE .. "\n", ran.output .. ran.said)
  assert(#ran.calls == 0 and #ran.git == 3 and ran.git[1] == fetch("refs/heads/main", SHA), table.concat(ran.git, "\n"))
  assert(not ran.output:find(ENTRY, 1, true), "the queue's own base was named")
end

--- A pull request the checkout cannot answer for (too shallow, one parent, three, another commit's line) and one for
--- another branch than main fetch as the queue does.
local function test_a_pull_request_the_checkout_cannot_answer_fetches_its_history()
  local lines: {string | boolean} = { false, "", SHA .. "\n", SHA .. " " .. TIP .. "\n",
    SHA .. " " .. TIP .. " " .. HEAD .. " " .. OLDER .. "\n", HEAD .. " " .. TIP .. " " .. OLDER .. "\n", SHA .. " " .. TIP .. " abc\n" }
  for _, line in ipairs(lines) do
    local answers = grown_from_one()
    answers["rev-list --parents -n 1 " .. SHA] = { line }
    local ran = step(PULL, answers)
    assert(ran.code == 0 and ran.output == "sha=" .. BASE .. "\n" and #ran.git == 4, tostring(line) .. ": " .. ran.output .. ran.said)
  end
  for _, branch in ipairs({ "topic", "" }) do
    local other = step({ EVENT = "pull_request", REF = "refs/pull/1/merge", SHA = SHA, REPOSITORY = "o/r", PR_BASE_REF = branch },
      grown_from_one())
    assert(other.code == 0 and other.output == "sha=" .. BASE .. "\n" and #other.git == 3, branch .. other.output .. other.said)
  end
end

--- A branch that merged main is cut off at several commits. Where main's tip is among their parents it is the base;
--- otherwise the base is the parent main's own history, fetched down to the branch, is cut off at, which must be one
--- of them, with the branch still naming the run's commit.
local function test_a_history_cut_off_at_several_commits_is_held_to_mains_tip_or_to_where_main_meets_it()
  local function merged(): mut {string: {string | boolean}}
    return {
      [fetch("refs/heads/main", SHA)] = { "" },
      ["rev-list --parents " .. SHA] = { SHA .. " " .. ENTRY .. " " .. HEAD .. "\n" .. ENTRY .. "\n" .. HEAD .. "\n" },
      ["cat-file commit " .. ENTRY] = { commit({ OLDER }) },
      ["cat-file commit " .. HEAD] = { commit({ BASE }) },
    }
  end
  local names <const> = "ls-remote origin refs/heads/main refs/heads/topic"
  local at_tip = merged()
  at_tip[names] = { BASE .. "\trefs/heads/main\n" .. SHA .. "\trefs/heads/topic\n" }
  local ran = step(MANUAL, at_tip)
  assert(ran.code == 0 and ran.output == "sha=" .. BASE .. "\n" and #ran.calls == 0, ran.output .. ran.said)

  local function behind(cut_at: string, topic: string): Step
    local answers = merged()
    answers[names] = { TIP .. "\trefs/heads/main\n" .. SHA .. "\trefs/heads/topic\n" }
    answers[fetch("refs/heads/topic", "refs/heads/main")] = { "" }
    answers["rev-parse --verify --quiet FETCH_HEAD^{commit}"] = { TIP .. "\n" }
    answers["rev-list --parents " .. TIP] = { TIP .. "\n" }
    answers["cat-file commit " .. TIP] = { commit({ cut_at }) }
    answers["ls-remote origin refs/heads/topic"] = { topic .. "\trefs/heads/topic\n" }
    return step(MANUAL, answers)
  end
  local met = behind(BASE, SHA)
  assert(met.code == 0 and met.output == "sha=" .. BASE .. "\n" and #met.calls == 0, met.output .. met.said)
  -- a commit of main the run's history does not hold as a parent is no base of it
  local stranger = behind(string.rep("5", 40), SHA)
  assert(stranger.code == 1 and stranger.output == "", stranger.output .. stranger.said)
  -- a branch that moved names another commit, of which main's history says nothing
  local moved = behind(BASE, HEAD)
  assert(moved.code == 1 and moved.output == "" and moved.said:find("no longer names", 1, true) ~= nil, moved.output .. moved.said)
end

--- A commit that is on main already is its own base: main's tip, or the commit main's history down to its branch is
--- cut off at.
local function test_a_commit_on_main_is_its_own_base()
  local at_tip = step(MANUAL, {
    [fetch("refs/heads/main", SHA)] = { false },
    ["ls-remote origin refs/heads/main refs/heads/topic"] = { SHA .. "\trefs/heads/main\n" .. SHA .. "\trefs/heads/topic\n" },
  })
  assert(at_tip.code == 0 and at_tip.output == "sha=" .. SHA .. "\n", at_tip.output .. at_tip.said)
  local behind = step(MANUAL, {
    [fetch("refs/heads/main", SHA)] = { false },
    ["ls-remote origin refs/heads/main refs/heads/topic"] = { TIP .. "\trefs/heads/main\n" .. SHA .. "\trefs/heads/topic\n" },
    [fetch("refs/heads/topic", "refs/heads/main")] = { "" },
    ["rev-parse --verify --quiet FETCH_HEAD^{commit}"] = { TIP .. "\n" },
    ["rev-list --parents " .. TIP] = { TIP .. "\n" },
    ["cat-file commit " .. TIP] = { commit({ SHA }) },
    ["ls-remote origin refs/heads/topic"] = { SHA .. "\trefs/heads/topic\n" },
  })
  assert(behind.code == 0 and behind.output == "sha=" .. SHA .. "\n", behind.output .. behind.said)
end

--- A fetch that fails is made again after 2 and 4 seconds, three in all: one that then succeeds names the base, and a
--- run no fetch answers fails the step, naming none.
local function test_a_fetch_that_fails_is_made_again_and_fails_the_step_when_none_succeeds()
  local answers = grown_from_one()
  answers[fetch("refs/heads/main", SHA)] = { false, false, "" }
  local ran = step(QUEUE, answers)
  assert(ran.code == 0 and ran.output == "sha=" .. BASE .. "\n", tostring(ran.code) .. ran.output .. ran.said)
  assert(#ran.sleeps == 2 and ran.sleeps[1] == 2 and ran.sleeps[2] == 4, ran.said)
  local down: {string: {string | boolean}} = {
    [fetch("refs/heads/main", SHA)] = { false },
    ["ls-remote origin refs/heads/main " .. QUEUE_REF] = { false },
    [fetch(QUEUE_REF, "refs/heads/main")] = { false },
  }
  local never = step(QUEUE, down)
  assert(never.code == 1 and never.output == "" and #never.calls == 0, tostring(never.code) .. never.output)
  assert(#never.sleeps == 4 and never.said:find("the job fails here", 1, true) ~= nil, never.said)
  local once = step({ EVENT = "merge_group", REF = QUEUE_REF, SHA = SHA, BASE_REF = "refs/heads/main", TRIES = "1" }, down)
  assert(once.code == 1 and #once.sleeps == 0 and #once.git == 3, once.said)
end

--- Main's own runs hold no base, run no git and succeed; a run that must hold one and cannot name it (a queue with
--- no branch, no commit, a history cut off nowhere) fails.
local function test_main_asks_nothing_and_a_run_that_names_no_base_fails()
  local mains: {{string: string}} = {
    { EVENT = "push", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "workflow_dispatch", REF = "refs/heads/main", SHA = SHA },
    { EVENT = "schedule", REF = "refs/heads/main", SHA = SHA },
    {},
  }
  for _, env in ipairs(mains) do
    local ran = step(env, {})
    assert(ran.code == 0 and ran.output == "" and #ran.git == 0, tostring(env["EVENT"]) .. ": " .. ran.output .. ran.said)
  end
  local unnamed: {{string: string}} = {
    { EVENT = "merge_group", REF = QUEUE_REF, SHA = SHA },
    { EVENT = "merge_group", REF = QUEUE_REF, SHA = SHA, BASE_REF = "main..x" },
    { EVENT = "workflow_dispatch", REF = "refs/heads/topic", SHA = "abc" },
  }
  for _, env in ipairs(unnamed) do
    local ran = step(env, {})
    assert(ran.code == 1 and ran.output == "" and #ran.git == 0, tostring(env["BASE_REF"]) .. ": " .. ran.output .. ran.said)
  end
  -- a history with no commit of main under it (another repository's, or main rewritten) has no base
  local apart = step(MANUAL, {
    [fetch("refs/heads/main", SHA)] = { "" },
    ["rev-list --parents " .. SHA] = { SHA .. "\n" },
    ["cat-file commit " .. SHA] = { commit({}) },
    ["ls-remote origin refs/heads/main refs/heads/topic"] = { TIP .. "\trefs/heads/main\n" .. SHA .. "\trefs/heads/topic\n" },
    [fetch("refs/heads/topic", "refs/heads/main")] = { "" },
    ["rev-parse --verify --quiet FETCH_HEAD^{commit}"] = { TIP .. "\n" },
    ["rev-list --parents " .. TIP] = { TIP .. "\n" },
    ["cat-file commit " .. TIP] = { commit({}) },
  })
  assert(apart.code == 1 and apart.output == "" and apart.said:find("the job fails here", 1, true) ~= nil, apart.output .. apart.said)
end

--- A step that cannot be read refuses, running nothing.
local function test_an_unreadable_environment_is_refused()
  local unreadable: {{string: string}} = { { FETCH_SECONDS = "soon" }, { TRIES = "-1" } }
  for _, env in ipairs(unreadable) do
    local ran = step(env, {})
    assert(ran.code == 2 and #ran.git == 0 and #ran.calls == 0)
  end
end
