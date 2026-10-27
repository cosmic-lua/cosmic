--- Tests of [`build.ceilings_base`]: the ceilings file is held to the file at the merge base, from the base CI names or
--- that git finds, and a run that cannot name one fails in CI and is skipped (saying why) only where none can exist. The
--- git is a stand-in that answers each call from a table.
local CeilingsBase = require("build.ceilings_base")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{}

local BASE <const> = "0123456789abcdef0123456789abcdef01234567"

local BASE_TEXT <const> = "[checked]\nbuild/a.tl nil_not_allowed 3\n\nbuild/b.tl view_written 2\n"

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

local BLOB <const> = "cat-file -p " .. BASE .. ":build/ceilings.txt"

--- A git that has the base commit, an ancestor of HEAD, whose ceilings file holds `text`.
local function holding(text: string): Answers
  return {
    status = {
      ["cat-file -e " .. BASE .. "^{commit}"] = 0,
      ["merge-base --is-ancestor " .. BASE .. " HEAD"] = 0,
      [BLOB] = 0,
    },
    printed = { [BLOB] = text },
  }
end

--- The tree at `tmp` with `text` as its ceilings file.
local function tree_with(tmp: string, text: string): string
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/ceilings.txt", text))
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

local function test_a_raised_count_in_ci_is_refused_naming_the_line(tmp: string)
  local root = tree_with(tmp, "[checked]\nbuild/a.tl nil_not_allowed 4\n\nbuild/b.tl view_written 2\n")
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(holding(BASE_TEXT), { calls = {} }))
  assert(#verdict.lines == 1, table.concat(verdict.lines, "\n"))
  assert(verdict.lines[1] == "build/ceilings.txt:2: [checked] build/a.tl nil_not_allowed rose from 3 to 4; " ..
      "a ceiling only falls: fix the code instead", verdict.lines[1])
end

local function test_a_new_key_in_the_merge_queue_is_refused(tmp: string)
  local root = tree_with(tmp, BASE_TEXT .. "\nbuild/c.tl arity 1\n")
  local env = ci({ COSMIC_CI_EVENT = "merge_group", COSMIC_CI_BASE_SHA = BASE })
  local verdict = CeilingsBase.check(root, env, git_of(holding(BASE_TEXT), { calls = {} }))
  assert(#verdict.lines == 1 and has(verdict.lines[1], "build/c.tl arity is a row the merge base lacks"),
    table.concat(verdict.lines, "\n"))
end

local function test_a_lowered_count_and_a_removed_row_are_accepted(tmp: string)
  local root = tree_with(tmp, "[checked]\nbuild/a.tl nil_not_allowed 2\n")
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(holding(BASE_TEXT), { calls = {} }))
  assert(#verdict.lines == 0, table.concat(verdict.lines, "\n"))
  assert(has(verdict.note, "held to the ceilings of 0123456789ab"), verdict.note)
end

local function test_a_base_without_the_file_makes_every_row_new(tmp: string)
  local root = tree_with(tmp, BASE_TEXT)
  local answers = holding(BASE_TEXT)
  answers.status[BLOB] = 128
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(answers, { calls = {} }))
  assert(#verdict.lines == 2, table.concat(verdict.lines, "\n"))
end

local function test_a_base_the_checkout_lacks_is_fetched_once_and_a_fetch_that_fails_fails_the_check(tmp: string)
  local root = tree_with(tmp, BASE_TEXT)
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
  local root = tree_with(tmp, BASE_TEXT)
  local answers = holding(BASE_TEXT)
  answers.status["merge-base --is-ancestor " .. BASE .. " HEAD"] = 1
  local verdict = CeilingsBase.check(root, ci({ COSMIC_CEILINGS_BASE = BASE }), git_of(answers, { calls = {} }))
  assert(#verdict.lines == 1 and has(verdict.lines[1], "is not an ancestor of HEAD"), table.concat(verdict.lines, "\n"))
end

local function test_a_run_of_ci_that_holds_a_change_and_names_no_base_fails(tmp: string)
  local root = tree_with(tmp, BASE_TEXT)
  for _, env in ipairs({
      ci({}),
      ci({ COSMIC_CI_EVENT = "merge_group" }),
      ci({ COSMIC_CI_BASE_SHA = "unknown" }),
  }) do
    local verdict = CeilingsBase.check(root, env, git_of(nothing(), { calls = {} }))
    assert(#verdict.lines == 1 and has(verdict.lines[1], "so they are refused"), table.concat(verdict.lines, "\n"))
  end
end

local function test_the_runs_of_main_itself_are_skipped_saying_so(tmp: string)
  local root = tree_with(tmp, BASE_TEXT)
  for _, env in ipairs({
      ci({ COSMIC_CI_EVENT = "schedule" }),
      ci({ COSMIC_CI_EVENT = "workflow_dispatch" }),
      ci({ GITHUB_REF = "refs/heads/main" }),
  }) do
    local verdict = CeilingsBase.check(root, env, git_of(nothing(), { calls = {} }))
    assert(#verdict.lines == 0 and has(verdict.note, "run of main itself"), verdict.note)
  end
end

local function test_a_checkout_without_git_or_origin_main_is_skipped_saying_so_and_one_with_both_is_held(tmp: string)
  local root = tree_with(tmp, "[checked]\nbuild/a.tl nil_not_allowed 9\n")
  local outside = CeilingsBase.check(root, {}, git_of(nothing(), { calls = {} }))
  assert(#outside.lines == 0 and has(outside.note, "no git checkout"), outside.note)
  local answers = holding(BASE_TEXT)
  answers.status["rev-parse --git-dir"] = 0
  local lonely = CeilingsBase.check(root, {}, git_of(answers, { calls = {} }))
  assert(#lonely.lines == 0 and has(lonely.note, "no merge base with origin/main"), lonely.note)
  answers.status["merge-base HEAD origin/main"] = 0
  answers.printed["merge-base HEAD origin/main"] = BASE .. "\n"
  local held = CeilingsBase.check(root, {}, git_of(answers, { calls = {} }))
  assert(#held.lines == 1 and has(held.lines[1], "rose from 3 to 9"), table.concat(held.lines, "\n"))
end
