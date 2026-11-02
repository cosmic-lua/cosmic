--- Tests of [`build.ceilings_base`]: the markers of the tree are held to those of the files at the merge base, from the base CI
--- names or that git finds, and a run that cannot name one fails in CI and is skipped (saying why) only where none can exist.
--- The git is a stand-in that answers each call from a table.
local CeilingsBase = require("build.ceilings_base")
local Fs = require("cosmic.fs")
local Markers = require("build.markers")
local Test = require("cosmic.test")

Test.policy{}

local BASE <const> = "0123456789abcdef0123456789abcdef01234567"

--- The calls a git was asked, joined with spaces.
local record Asked
  calls: mut {string}
end

--- What the stand-in git answers: the exit status of each call (joined with spaces) and what it printed. A call it lacks
--- fails with status 128.
local record Answers
  status: mut {string: integer}
  printed: mut {string: string}
end

local function git_of(answers: Answers, asked: Asked): CeilingsBase.Git
  return function(_root: string, args: {string}): integer, string
    local call = table.concat(args, " ")
    asked.calls[#asked.calls + 1] = call
    local status = answers.status[call]
    if status == nil then return 128, "" end
    return status, answers.printed[call] or ""
  end
end

local function nothing(): Answers
  return { status = {}, printed = {} }
end

--- A git that has the base commit, an ancestor of HEAD.
local function holding(): Answers
  return {
    status = {
      ["cat-file -e " .. BASE .. "^{commit}"] = 0,
      ["merge-base --is-ancestor " .. BASE .. " HEAD"] = 0,
      ["rev-parse --is-shallow-repository"] = 0,
    },
    printed = { ["rev-parse --is-shallow-repository"] = "true\n" },
  }
end

--- The tree at `tmp`.
local function tree_with(tmp: string): string
  assert(Fs.mkdirs(tmp .. "/build"))
  return tmp
end

--- A branch push's environment in CI, with `extra` set.
local function ci(extra: {string:string}): {string:string}
  local env: mut {string:string} = { GITHUB_ACTIONS = "true", COSMIC_CI_EVENT = "push", GITHUB_REF = "refs/heads/feature" }
  for name, value in pairs(extra) do env[name] = value end
  return env
end

--- Whether `text`, which may be absent, holds `needle`.
local function has(text: string?, needle: string): boolean
  return text ~= nil and text:find(needle, 1, true) ~= nil
end

local KEY <const> = "-- checked:"

local GREP <const> = "grep -l -F -e -- scoped: -e -- declared: -e -- checked: -e -- untyped: " .. BASE ..
  " -- *.tl :(exclude)vendor :(exclude)ci"

--- A `git cat-file --batch` stream of `files`: a header and the bytes of each, in order.
local function stream(files: {string}): string
  local out: mut {string} = {}
  for _, content in ipairs(files) do
    out[#out + 1] = string.rep("a", 40) .. " blob " .. tostring(#content) .. "\n" .. content .. "\n"
  end
  return table.concat(out)
end

--- A git that has the base, whose markers are in `files` (path to text).
local function marked_base(files: {string: string}): Answers
  local answers = holding()
  local paths: mut {string} = {}
  for path in pairs(files) do paths[#paths + 1] = path end
  table.sort(paths)
  local listed: mut {string} = {}
  local contents: mut {string} = {}
  for _, path in ipairs(paths) do
    listed[#listed + 1] = BASE .. ":" .. path
    contents[#contents + 1] = assert(files[path])
  end
  if #paths == 0 then
    answers.status[GREP] = 1
  else
    answers.status[GREP] = 0
  end
  answers.printed[GREP] = table.concat(listed, "\n") .. "\n"
  answers.status["cat-file --batch"] = 0
  answers.printed["cat-file --batch"] = stream(contents)
  return answers
end

local function test_a_base_the_checkout_lacks_is_fetched_once_and_a_fetch_that_fails_fails_the_check(tmp: string)
  local root = tree_with(tmp)
  local asked: Asked = { calls = {} }
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(nothing(), asked))
  assert(#verdict.lines == 1 and has(verdict.lines[1], "is not in this checkout"), table.concat(verdict.lines, "\n"))
  local fetched = 0
  for _, call in ipairs(asked.calls) do
    if call == "fetch --quiet --no-tags --depth=1 origin " .. BASE then fetched = fetched + 1 end
  end
  assert(fetched == 1, "fetched " .. tostring(fetched))
end

local function test_a_base_that_is_not_an_ancestor_of_head_is_refused(tmp: string)
  local root = tree_with(tmp)
  local answers = holding()
  answers.printed["rev-parse --is-shallow-repository"] = "false\n"
  for _, status in ipairs({ 1, 128, -1 }) do
    answers.status["merge-base --is-ancestor " .. BASE .. " HEAD"] = status
    local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(answers, { calls = {} }))
    assert(#verdict.lines == 1 and has(verdict.lines[1], "is not an ancestor of HEAD"), table.concat(verdict.lines, "\n"))
  end
  -- a shallow checkout cannot tell, as a branch push's cannot, and is not refused for it
  answers.printed["rev-parse --is-shallow-repository"] = "true\n"
  local shallow = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(answers, { calls = {} }))
  assert(#shallow.lines == 0, table.concat(shallow.lines, "\n"))
end

local function test_a_base_that_is_not_a_full_hash_fails(tmp: string)
  local root = tree_with(tmp)
  local short = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = "0" }), git_of(holding(), { calls = {} }))
  assert(#short.lines == 1 and has(short.lines[1], "no full commit hash"), table.concat(short.lines, "\n"))
end

local function test_the_base_a_workflow_names_for_the_markers_wins_over_the_queues(tmp: string)
  local root = tree_with(tmp)
  local other = "1111111111111111111111111111111111111111"
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE, COSMIC_CI_BASE_SHA = other }),
    git_of(holding(), { calls = {} }))
  assert(#verdict.lines == 0 and has(verdict.note, "0123456789ab"), table.concat(verdict.lines, "\n") .. verdict.note)
end

local function test_a_run_of_ci_that_holds_a_change_and_names_no_base_fails(tmp: string)
  local root = tree_with(tmp)
  for _, env in ipairs({
      ci({}),
      ci({ COSMIC_CI_EVENT = "merge_group" }),
      ci({ COSMIC_CI_BASE_SHA = "unknown" }),
      ci({ COSMIC_CI_EVENT = "workflow_dispatch" }),
  }) do
    local verdict = CeilingsBase.check(root, env, git_of(nothing(), { calls = {} }))
    assert(#verdict.lines == 1 and has(verdict.lines[1], "so they are refused"), table.concat(verdict.lines, "\n"))
  end
end

local function test_the_runs_of_main_itself_are_skipped_saying_so(tmp: string)
  local root = tree_with(tmp)
  for _, env in ipairs({
      ci({ COSMIC_CI_EVENT = "schedule" }),
      ci({ COSMIC_CI_EVENT = "workflow_dispatch", GITHUB_REF = "refs/heads/main" }),
      ci({ GITHUB_REF = "refs/heads/main" }),
  }) do
    local verdict = CeilingsBase.check(root, env, git_of(nothing(), { calls = {} }))
    assert(#verdict.lines == 0 and has(verdict.note, "run of main itself"), verdict.note)
  end
end

local function test_a_checkout_without_git_or_origin_main_is_skipped_saying_so_and_one_with_both_is_held(tmp: string)
  local root = tree_with(tmp)
  local held: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 1 } }
  local outside = CeilingsBase.check(root, {}, git_of(nothing(), { calls = {} }), held)
  assert(#outside.lines == 0 and has(outside.note, "no git checkout"), outside.note)
  local answers = marked_base({})
  answers.status["rev-parse --git-dir"] = 0
  local lonely = CeilingsBase.check(root, {}, git_of(answers, { calls = {} }), held)
  assert(#lonely.lines == 0 and has(lonely.note, "no merge base with origin/main"), lonely.note)
  answers.status["merge-base HEAD origin/main"] = 0
  answers.printed["merge-base HEAD origin/main"] = BASE .. "\n"
  local verdict = CeilingsBase.check(root, {}, git_of(answers, { calls = {} }), held)
  assert(#verdict.lines == 1 and has(verdict.lines[1], "1 of its markers hold checked map_field and the merge base held 0"),
    table.concat(verdict.lines, "\n"))
end

-- The markers: a file may hold no more of a stage's code than it did at the merge base. A marker in a fixture is written as
-- `KEY .. " ..."` so that this file holds none.

local function test_a_file_with_more_markers_of_a_code_than_the_base_is_refused(tmp: string)
  local root = tree_with(tmp)
  local base = marked_base({ ["build/a.tl"] = "f() " .. KEY .. " map_field\ng()\n" })
  local held: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 2, ["checked any_use"] = 1 } }
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), held)
  assert(#verdict.lines == 2, table.concat(verdict.lines, "\n"))
  assert(has(verdict.lines[1], "build/a.tl: 1 of its markers hold checked any_use and the merge base held 0"),
    verdict.lines[1])
  assert(has(verdict.lines[2], "2 of its markers hold checked map_field and the merge base held 1"), verdict.lines[2])
end

local function test_a_new_file_of_markers_is_refused_and_a_file_at_or_under_its_base_is_not(tmp: string)
  local root = tree_with(tmp)
  local base = marked_base({ ["build/a.tl"] = "f() " .. KEY .. " map_field*3\n" })
  local fine: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 3 } }
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), fine)
  assert(#verdict.lines == 0, table.concat(verdict.lines, "\n"))
  local lower: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 1 } }
  assert(#CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), lower).lines == 0)
  local added: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 3 }, ["build/new.tl"] = { ["checked map_field"] = 1 } }
  local refused = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), added)
  assert(#refused.lines == 1 and has(refused.lines[1], "build/new.tl: 1 of its markers hold checked map_field and the " ..
      "merge base held 0"), table.concat(refused.lines, "\n"))
end

local function test_a_base_without_markers_makes_every_marker_new_and_a_tree_without_asks_git_nothing(tmp: string)
  local root = tree_with(tmp)
  local held: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 1 } }
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(marked_base({}), { calls = {} }), held)
  assert(#verdict.lines == 1, table.concat(verdict.lines, "\n"))
  local asked: Asked = { calls = {} }
  local none = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(marked_base({}), asked), {})
  assert(#none.lines == 0)
  for _, call in ipairs(asked.calls) do
    assert(call:find("^grep") == nil and call:find("^cat%-file %-%-batch") == nil, call)
  end
end

local function test_a_base_whose_markers_git_cannot_read_fails_the_check(tmp: string)
  local root = tree_with(tmp)
  local base = marked_base({ ["build/a.tl"] = "f()\n" })
  base.status[GREP] = 128
  local held: CeilingsBase.Held = { ["build/a.tl"] = { ["checked map_field"] = 1 } }
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), held)
  assert(#verdict.lines == 1 and has(verdict.lines[1], "git grep of the markers"), table.concat(verdict.lines, "\n"))
end

local function test_code_that_moved_keeps_its_count_of_markers_and_passes(tmp: string)
  local root = tree_with(tmp)
  local before = "a()\nb() " .. KEY .. " map_field\nc() " .. KEY .. " map_field, any_use\n"
  -- the same findings three lines lower, after code added above them
  local after = "x()\ny()\nz()\na()\nb() " .. KEY .. " map_field\nc() " .. KEY .. " map_field, any_use\n"
  local base = marked_base({ ["build/a.tl"] = before })
  local held: CeilingsBase.Held = { ["build/a.tl"] = Markers.counts(after, "build/a.tl") }
  assert(held["build/a.tl"] ~= nil and (held["build/a.tl"] or {})["checked map_field"] == 2)
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), held)
  assert(#verdict.lines == 0, table.concat(verdict.lines, "\n"))
  -- a marker added on one of the new lines is one more than the base held
  local more = after .. "d() " .. KEY .. " map_field\n"
  held = { ["build/a.tl"] = Markers.counts(more, "build/a.tl") }
  local refused = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(base, { calls = {} }), held)
  assert(#refused.lines == 1 and has(refused.lines[1], "3 of its markers hold checked map_field and the merge base " ..
      "held 2"), table.concat(refused.lines, "\n"))
end
