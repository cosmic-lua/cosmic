#!/usr/bin/env cosmic
-- The builder brief's own text carries the practices a builder must
-- follow before `brief` ever fills a placeholder — pin each one by a
-- literal find, the way `_work.review_test` pins the `Board:` line.
-- The template hand-wraps its prose across lines, so a pinned sentence
-- is matched against a whitespace-flattened copy rather than raw text
-- — a rewrap must not itself break these tests.

local brieftext = require("_work.brieftext")

--- `s` with every run of whitespace (including the template's own
--- line wraps) collapsed to one space, so a sentence pinned here reads
--- the same whether the template wraps it across one line or several.
--- @param s string The text to flatten
--- @return string The flattened text
local function flat(s: string): string
  return (s:gsub("%s+", " "))
end

local BUILDER < const > = flat(brieftext.BUILDER)

local function test_step_one_measures_headroom_before_the_first_edit()
  assert(BUILDER:find(
      "Before the first edit, `wc -l` every file the Change names; if "
      .. "the Change's additions cannot fit under the 500-line cap, "
      .. "STOP now (report the count) rather than after implementing.",
      1, true) ~= nil,
    "step 1 must tell a builder to measure headroom before editing "
    .. "and stop before implementing, not after")
end

local function test_step_three_prefers_a_per_file_check_between_edits()
  assert(BUILDER:find(
      "Between edits, `bin/cosmic --check types <file>` on the files "
      .. "you touched; run the full gate once, before the push.",
      1, true) ~= nil,
    "step 3 must prefer a per-file check between edits and reserve "
    .. "the full gate for once, before the push")
end

local function test_the_stop_rule_keeps_the_diff_on_a_bounce()
  assert(BUILDER:find(
      "Leave your diff committed on the item branch (unpushed), never "
      .. "reverted: the respec starts from it.", 1, true) ~= nil,
    "the STOP rule must say to keep the diff on the item branch, "
    .. "unpushed, never reverted")
end

local function test_step_seven_reports_a_base_conflict_rather_than_rebasing()
  assert(BUILDER:find(
      "If the push or the PR shows a conflict with the base branch, "
      .. "stop and report it with the conflicting files; merging the "
      .. "base into the item branch is the orchestrator's, never a "
      .. "builder's rebase.", 1, true) ~= nil,
    "step 7 must tell a builder to stop and report a base conflict, "
    .. "never rebase it themselves")
end
