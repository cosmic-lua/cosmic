#!/usr/bin/env cosmic
--- Parser tests for _work/facts.tl: parse() over hand-written bodies.
--- The running half (fact_failures, problems) spawns commands and is
--- exercised end to end by the board's own `check` verb.
local facts = require("_work.facts")

--- A body with no facts block at all: the ready bar's own skeleton.
local PLAIN_BODY < const > = [[
## Goal
G4 — via epic #12

## Acceptance
`--make ci` ends `ci: PASS`.
]]

local function test_facts_none()
  local got = assert(facts.parse(PLAIN_BODY))
  assert(#got == 0, "expected no facts, got " .. tostring(#got))
end
test_facts_none()

local function test_facts_two_in_one_block()
  local body = "## Acceptance\n"
  .. "```facts\n"
  .. "$ echo hi\n"
  .. "hi\n"
  .. "there\n"
  .. "$ true\n"
  .. "```\n"
  local got = assert(facts.parse(body))
  assert(#got == 2, "expected 2 facts, got " .. tostring(#got))
  assert(got[1].command == "echo hi", "got: " .. got[1].command)
  assert(got[1].expected == "hi\nthere", "got: " .. got[1].expected)
  assert(got[2].command == "true", "got: " .. got[2].command)
  assert(got[2].expected == "", "expected empty, got: " .. got[2].expected)
end
test_facts_two_in_one_block()

local function test_facts_two_blocks()
  local body = "```facts\n$ a\nA\n```\n\nprose\n\n```facts\n$ b\nB\n```\n"
  local got = assert(facts.parse(body))
  assert(#got == 2, "expected 2 facts, got " .. tostring(#got))
  assert(got[1].command == "a" and got[1].expected == "A", "got: " .. got[1].command)
  assert(got[2].command == "b" and got[2].expected == "B", "got: " .. got[2].command)
end
test_facts_two_blocks()

local function test_facts_crlf_body()
  local body = "```facts\r\n$ echo hi\r\nhi\r\nthere\r\n```\r\n"
  local got = assert(facts.parse(body))
  assert(#got == 1, "expected 1 fact, got " .. tostring(#got))
  assert(got[1].command == "echo hi", "got: " .. got[1].command)
  assert(got[1].expected == "hi\nthere", "got: " .. got[1].expected)
end
test_facts_crlf_body()

local function test_facts_malformed_content_before_command()
  local body = "```facts\nstray content\n$ echo hi\nhi\n```\n"
  local got, err = facts.parse(body)
  assert(got == nil, "expected nil for malformed block")
  assert(err ~= nil and err:find("line 2", 1, true) ~= nil,
    "err should name line 2: " .. tostring(err))
end
test_facts_malformed_content_before_command()

local function test_facts_unclosed_block()
  local body = "```facts\n$ echo hi\nhi\n"
  local got, err = facts.parse(body)
  assert(got == nil, "expected nil for unclosed block")
  assert(err ~= nil and err:find("line 1", 1, true) ~= nil,
    "err should name the opening line 1: " .. tostring(err))
end
test_facts_unclosed_block()

local function test_facts_other_fence_not_parsed()
  local body = "```text\n$ echo hi\nhi\n```\n"
  local got = assert(facts.parse(body))
  assert(#got == 0, "content in a non-facts fence must not be parsed")
end
test_facts_other_fence_not_parsed()

local function test_problems_reports_a_parse_error()
  local got = facts.problems("```facts\nstray content\n$ echo hi\n```\n")
  assert(#got == 1, "a parse error is one problem, got " .. tostring(#got))
  assert(got[1]:find("line 2", 1, true) ~= nil, "got: " .. got[1])
end
test_problems_reports_a_parse_error()
