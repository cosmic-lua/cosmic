#!/usr/bin/env cosmic
-- The discarded-error rule, unit-tested through the same strict check
-- that enforces it: each fixture is a self-contained file (a local
-- fallible function, no imports), so what is asserted is the rule, not
-- the stdlib.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local FALLIBLE < const > = [[
local function effect(): boolean, string
  return true
end
local function value(): string | nil, string
  return "v"
end
]]

local counter = 0

--- Check a fixture body appended to the fallible preamble; returns the
--- error messages the strict check produced.
local function check_fixture(body: string): {string}
  counter = counter + 1
  local path = fs.join(tmpdir, "discard_fixture_" .. tostring(counter) .. ".tl")
  assert(fs.write(path, FALLIBLE .. body))
  local result = teal.check_file(path)
  local msgs: {string} = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  return msgs
end

local function has(msgs: {string}, needle: string): boolean
  for _, m in ipairs(msgs) do
    if m:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function test_statement_drop_is_flagged()
  local msgs = check_fixture("effect()\n")
  assert(has(msgs, "discarded error return"),
    "a bare fallible statement should be flagged, got: "
    .. table.concat(msgs, "; "))
  local vmsgs = check_fixture("value()\n")
  assert(has(vmsgs, "discarded error return"),
    "the fallible-value shape should be flagged too")
end
test_statement_drop_is_flagged()

local function test_spill_into_print_is_flagged()
  local msgs = check_fixture("print(value())\n")
  assert(has(msgs, "spills into the enclosing call"),
    "a fallible call as print's last argument should be flagged, got: "
    .. table.concat(msgs, "; "))
end
test_spill_into_print_is_flagged()

local function test_captures_and_consumers_pass()
  for _, body in ipairs({
      "local v, err = value()\nprint(v, err)\n",
      "local _ok, _err = effect()\n",
      "assert(effect())\n",
      "print((value()))\n", -- parenthesized: truncated to one value
      "print(value(), 1)\n", -- not the final argument: nothing spills
    }) do
    local msgs = check_fixture(body)
    assert(#msgs == 0, "should pass: " .. body:gsub("\n", " ")
      .. " got: " .. table.concat(msgs, "; "))
  end
end
test_captures_and_consumers_pass()

local function test_infallible_statements_pass()
  local msgs = check_fixture(
    "local function fire()\nend\nfire()\n")
  assert(#msgs == 0,
    "a statement call with no error position is fine, got: "
    .. table.concat(msgs, "; "))
end
test_infallible_statements_pass()

local function test_fallible_reads_signatures()
  local discard = require("cosmic._teal_discard")
  assert(discard.fallible("function(string): (boolean, string)"),
    "boolean, string is the fallible-effect shape")
  assert(discard.fallible("function(string): (string | nil, string)"),
    "T | nil, string is the fallible-value shape")
  assert(not discard.fallible("function(string): string"),
    "a single bare return has no error position")
  assert(not discard.fallible("function(...: <any type>)"),
    "no returns, no error position")
  assert(not discard.fallible("function(): (integer, integer)"),
    "a non-string final return is not an error position")
end
test_fallible_reads_signatures()
