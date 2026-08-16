#!/usr/bin/env cosmic
local implementer = require("_work.implementer")

local function test_is_accept_exact_match()
  assert(implementer.is_accept("work-verdict: accept"),
    "exact single-line body accepts")
end
test_is_accept_exact_match()

local function test_is_accept_reads_the_older_spelling()
  assert(implementer.is_accept("plan-verdict: accept"),
    "the older spelling open PRs carry still accepts")
  assert(implementer.is_accept("plan-verdict: accept\n\nlgtm"),
    "the older spelling accepts on the first line too")
end
test_is_accept_reads_the_older_spelling()

local function test_is_accept_multiline_first_line()
  assert(implementer.is_accept("work-verdict: accept\n\nlgtm"),
    "exact first line accepts even with trailing lines")
end
test_is_accept_multiline_first_line()

local function test_is_accept_rejects_prose_prefix()
  assert(not implementer.is_accept("looks good, work-verdict: accept"),
    "a prose-prefixed first line is not exact")
end
test_is_accept_rejects_prose_prefix()

local function test_is_accept_rejects_marker_on_later_line()
  assert(not implementer.is_accept("lgtm\nwork-verdict: accept"),
    "the marker only counts on the first line")
end
test_is_accept_rejects_marker_on_later_line()

local function test_is_accept_tolerates_crlf()
  assert(implementer.is_accept("work-verdict: accept\r\nmore"),
    "a \\r\\n body still matches on the first line")
end
test_is_accept_tolerates_crlf()

local function test_is_accept_rejects_empty()
  assert(not implementer.is_accept(""), "an empty body is not an accept")
end
test_is_accept_rejects_empty()

local function test_in_landing_queue()
  assert(implementer.in_landing_queue({"work:land", "work:enable"}),
    "a work:land issue is in the landing queue")
  assert(not implementer.in_landing_queue({"work:do"}),
    "an issue still in do was never accepted")
  assert(not implementer.in_landing_queue({"work:check"}),
    "an issue awaiting a verdict is not landable")
  assert(not implementer.in_landing_queue({"perf"}),
    "an issue on no phase is not landable")
end
test_in_landing_queue()

local function test_closes_matches_capitalized()
  assert(implementer.closes("Closes #7", 7), "Closes #7 matches issue 7")
end
test_closes_matches_capitalized()

local function test_closes_matches_lowercase()
  assert(implementer.closes("fixes bugs\n\ncloses #7\n", 7),
    "lowercase closes #7 matches issue 7")
end
test_closes_matches_lowercase()

local function test_closes_anchors_the_digit_run()
  assert(not implementer.closes("Closes #70", 7),
    "#70 must not match a search for #7")
end
test_closes_anchors_the_digit_run()

local function test_closes_rejects_absent_reference()
  assert(not implementer.closes("no reference here", 7),
    "a body with no closes reference does not match")
end
test_closes_rejects_absent_reference()
