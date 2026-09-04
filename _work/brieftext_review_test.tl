#!/usr/bin/env cosmic
-- The review-role templates' own text carries the practices a reviewer
-- must follow before `brief` ever fills a placeholder — pin each one by
-- a literal find, the way `_work.brieftext_test` pins the builder
-- template's. The templates hand-wrap their prose across lines, so a
-- pinned sentence is matched against a whitespace-flattened copy rather
-- than raw text — a rewrap must not itself break these tests.

local brieftext_review = require("_work.brieftext_review")

--- `s` with every run of whitespace (including the template's own
--- line wraps) collapsed to one space, so a sentence pinned here reads
--- the same whether the template wraps it across one line or several.
--- @param s string The text to flatten
--- @return string The flattened text
local function flat(s: string): string
  return (s:gsub("%s+", " "))
end

local REVIEW < const > = flat(brieftext_review.REVIEW)
local RESEARCH_REVIEW < const > = flat(brieftext_review.RESEARCH_REVIEW)

local function test_review_warns_against_sleep_n_on_a_backgrounded_build()
  assert(REVIEW:find(
      "Never end the turn assuming something will notify you when it "
      .. "finishes: a subagent has no persistent monitoring between "
      .. "turns, and `sleep N; <command>` is exactly the pattern the "
      .. "harness blocks.", 1, true) ~= nil,
    "the mutation-test step must warn a reviewer to block "
    .. "synchronously on a backgrounded build rather than assume a "
    .. "notification")
end

local function test_research_review_warns_against_sleep_n_on_a_backgrounded_build()
  assert(RESEARCH_REVIEW:find(
      "Never end the turn assuming something will notify you when it "
      .. "finishes: a subagent has no persistent monitoring between "
      .. "turns, and `sleep N; <command>` is exactly the pattern the "
      .. "harness blocks.", 1, true) ~= nil,
    "the probe-rerunning step must warn a research reviewer to block "
    .. "synchronously on a backgrounded build rather than assume a "
    .. "notification")
end
