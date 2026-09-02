#!/usr/bin/env cosmic
-- The dispatcher's id resolution: every id-taking argument position —
-- not only the first — accepts a rendered handle, and a handle that
-- names nothing is refused the same way a bad prefix is. The verbs
-- themselves are exercised with resolved ids elsewhere
-- (`_work/gitcompare_test.tl`, `_work/gitgraph_test.tl`); this is the
-- dispatch layer in `_work/gitboard.tl` that resolves what a session
-- typed before a verb ever sees it.

local check = require("cosmic.check")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local gitboard = require("_work.gitboard")
local store = require("_work.store")
local tail = require("_work.tail")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item

--- Run gitboard.main(...) and capture exactly what it prints via
--- print() -- the same swap-and-restore pattern _eval/score_test.tl
--- uses to pin a CLI's exact console output, without a real subprocess.
--- @param ... string Arguments to pass to gitboard.main, as on argv
--- @return integer gitboard.main's exit code
--- @return string Every print()'d line, newline-joined, no trailing newline
local function gitboard_and_capture(...: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(gitboard.main, ...)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

-- `attach`'s PARENT slot: a handle-form second argument resolves the
-- same as a prefix would, so a session pasting a handle from `show`
-- output can attach with it directly.
local function test_attach_resolves_a_handle_form_parent()
  local s = init_state_repo("attach-handle")
  local root = file_item(s, "an outcome", "")
  local leaf = file_item(s, "a workable slice", "")
  assert(gitboard.main("attach", leaf, tail.handle(root), "--dir", s.root) == 0,
    "a handle-form parent should resolve")
  local it = check.must(store.load(s, leaf))
  assert(it.parent == root, "and the attach actually landed")
end

-- `compare`'s OTHER slot: same handle form, same resolution.
local function test_compare_resolves_a_handle_form_other()
  local s = init_state_repo("compare-handle")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(gitboard.main("compare", high, tail.handle(low), "--dir", s.root) == 0,
    "a handle-form OTHER should resolve")
  local winner = check.must(store.load(s, high))
  assert(#winner.beats == 1 and winner.beats[1] == low,
    "and the comparison actually landed")
end

-- A handle naming nothing is refused cleanly in a secondary slot too
-- — no crash, just the same "no item matches" store gives arg 1.
local function test_secondary_slot_refuses_a_handle_that_matches_nothing()
  local s = init_state_repo("compare-handle-miss")
  local low = file_item(s, "the lesser outcome", "")
  local high = file_item(s, "the greater outcome", "")
  assert(gitboard.main("compare", high, "«ZZZZ_ZZZZ»", "--dir", s.root) ~= 0,
    "a handle matching nothing is refused")
  local winner = check.must(store.load(s, high))
  assert(#winner.beats == 0, "and nothing was recorded")
  local loser = check.must(store.load(s, low))
  assert(#loser.beats == 0, "the unrelated item is untouched")
  assert(cmp.cmd_compare(s, high, low) == 0,
    "the store is still writable after the refusal")
end

-- `gitboard help` names the two id forms a session actually meets:
-- the handle every render leads with, and the branch prefix that is a
-- DIFFERENT string from it -- the confusion this item exists to close.
local function test_help_documents_the_id_forms()
  local code, printed = gitboard_and_capture("help")
  assert(code == 0, "help should exit 0, got " .. code)
  assert(printed:find("KSUIDs", 1, true),
    "help should say ids are KSUIDs\ngot: " .. printed)
  assert(printed:find("last 8", 1, true),
    "help should name the handle as the id's last 8 characters\ngot: " .. printed)
  assert(printed:find("«d0x1_37YJ»", 1, true),
    "help should carry the worked handle example\ngot: " .. printed)
  assert(printed:find("bare or wrapped", 1, true),
    "help should say a handle is accepted bare or wrapped\ngot: " .. printed)
  assert(printed:find("unambiguous prefix", 1, true),
    "help should say an unambiguous prefix also works\ngot: " .. printed)
  assert(printed:find("branches are named", 1, true),
    "help should describe how branches are named\ngot: " .. printed)
  assert(printed:find("first 8", 1, true),
    "help should name the branch as the id's first 8 characters\ngot: " .. printed)
  assert(printed:find("different string", 1, true),
    "help should call out that the branch differs from the handle\ngot: " .. printed)
end
