#!/usr/bin/env cosmic
-- test _tool.friction: a transcript's indicators, read off a fixture

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local friction = require("_tool.friction")

local tmpdir = os.getenv("TEST_TMPDIR")

-- One model response arrives as several events sharing a requestId and
-- a usage record (the second and third lines here); a blank line is
-- not an event; an error result may carry a list, not a string.
local FIXTURE < const > = table.concat({
    '{"timestamp":"2026-09-03T18:00:00.500Z","type":"user",'
    .. '"message":{"role":"user","content":"go"}}',
    '{"timestamp":"2026-09-03T18:00:10Z","type":"assistant","requestId":"r1",'
    .. '"message":{"usage":{"input_tokens":10,"output_tokens":20,'
    .. '"cache_read_input_tokens":100,"cache_creation_input_tokens":5},'
    .. '"content":[{"type":"text","text":"listing"}]}}',
    '{"timestamp":"2026-09-03T18:00:10Z","type":"assistant","requestId":"r1",'
    .. '"message":{"usage":{"input_tokens":10,"output_tokens":20,'
    .. '"cache_read_input_tokens":100,"cache_creation_input_tokens":5},'
    .. '"content":[{"type":"tool_use","id":"t1","name":"Bash",'
    .. '"input":{"command":"ls -la\\nsecond line"}}]}}',
    '{"timestamp":"2026-09-03T18:00:11Z","type":"user","message":{"content":'
    .. '[{"type":"tool_result","tool_use_id":"t1","is_error":false,'
    .. '"content":"fine"}]}}',
    '{"timestamp":"2026-09-03T18:00:20Z","type":"assistant","requestId":"r2",'
    .. '"message":{"usage":{"input_tokens":1,"output_tokens":2},"content":'
    .. '[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"a/b.tl"}}]}}',
    '{"timestamp":"2026-09-03T18:00:21Z","type":"user","message":{"content":'
    .. '[{"type":"tool_result","tool_use_id":"t2","is_error":true,'
    .. '"content":[{"type":"text","text":"Refusing"}]}]}}',
    '{"timestamp":"2026-09-03T18:00:30Z","type":"assistant","requestId":"r3",'
    .. '"message":{"usage":{"input_tokens":1,"output_tokens":3},"content":'
    .. '[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"ls -la"}}]}}',
    "",
    '{"timestamp":"2026-09-03T18:01:00Z","type":"user","message":{"content":'
    .. '[{"type":"tool_result","tool_use_id":"t3","is_error":false,'
    .. '"content":"fine"}]}}',
  }, "\n")

local function write_fixture(name: string): string
  local path = fs.join(tmpdir, name)
  check.must(fs.write(path, FIXTURE))
  return path
end

local function test_counts_calls_errors_repeats_and_first_edit()
  local s = check.must(friction.summarize(write_fixture("t.jsonl")))
  check.equal(s.events, 8, "blank lines are not events")
  check.equal(#s.calls, 3, "three tool_use blocks")
  check.equal(s.by_name["Bash"], 2, "two Bash calls")
  check.equal(s.by_name["Edit"], 1, "one Edit call")
  check.equal(s.first_edit, 2, "the Edit is the second call")
  check.equal(s.errors, 1, "one error result")
  check.equal(s.calls[2].is_error, true, "the error joins its call by id")
  check.truthy(s.calls[2].error_text:find("Refusing", 1, true),
    "a list result is rendered as text: " .. s.calls[2].error_text)
  check.equal(s.repeats["ls -la"], 2, "keyed on the command's first line")
  check.equal(s.repeats["a/b.tl"], nil, "a single call is not a repeat")
end

local function test_wall_and_usage_once_per_request()
  local s = check.must(friction.summarize(write_fixture("u.jsonl")))
  check.equal(s.wall_seconds, 60, "milliseconds are dropped before parsing")
  check.equal(s.usage.input_tokens, 12, "r1 counted once, then r2 and r3")
  check.equal(s.usage.output_tokens, 25, "output tokens summed once per request")
  check.equal(s.usage.cache_read_input_tokens, 100, "a missing count is zero")
  check.equal(s.usage.cache_creation_input_tokens, 5, "cache creation summed")
end

local function test_render_carries_every_indicator()
  local s = check.must(friction.summarize(write_fixture("r.jsonl")))
  local text = friction.render(s)
  for _, needle in ipairs({
      "events=8 tool_calls=3 wall=60s",
      "tokens: in=12 out=25 cache_read=100 cache_create=5",
      "by tool: Bash=2 Edit=1",
      "first edit: call 2",
      "errors (1):",
      "- 2 Edit: a/b.tl -> ",
      "repeated commands (1):",
      "- x2 ls -la",
    }) do
    check.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n" .. text)
  end
end

local function test_missing_file_is_a_fallible_return()
  local s, err = friction.summarize(fs.join(tmpdir, "absent.jsonl"))
  check.equal(s, nil, "no summary for a missing file")
  check.truthy(err ~= nil and err ~= "", "and a reason")
end

local function test_main_exit_status()
  check.equal(friction.main(), 1, "no arguments is a usage error")
  check.equal(friction.main(write_fixture("m.jsonl")), 0, "a readable transcript is 0")
  check.equal(friction.main(fs.join(tmpdir, "nope.jsonl")), 1, "an unreadable one is 1")
end
