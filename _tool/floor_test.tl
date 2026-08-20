#!/usr/bin/env cosmic
--- Tests for the shared floor helper.
local check = require("cosmic.check")
local floor = require("_tool.floor")
local fs = require("cosmic.fs")

local function path_for(name: string): string
  local dir = assert(os.getenv("TEST_TMPDIR"), "TEST_TMPDIR must be set")
  return fs.join(dir, name)
end

local function test_write_then_read_round_trips()
  local path = path_for("roundtrip.tl")
  assert(floor.write(path, {["a.tl"] = 3, ["b.tl"] = 1}))
  local got = check.must(floor.read(path))
  assert(got["a.tl"] == 3 and got["b.tl"] == 1, "write then read round-trips")
end
test_write_then_read_round_trips()

local function test_read_refuses_a_duplicate_key_by_default()
  local path = path_for("dup.tl")
  assert(fs.write(path, "return {\n  a = 1,\n  a = 2,\n}\n"))
  local data, err = floor.read(path)
  assert(data == nil, "a duplicate key must be refused")
  assert(err and err:find("repeats the key 'a'", 1, true),
    "the error names the key, got: " .. tostring(err))
end
test_read_refuses_a_duplicate_key_by_default()

local function test_read_forwards_on_duplicate_and_its_return_lands()
  local path = path_for("resolved.tl")
  assert(fs.write(path, "return {\n  a = 1,\n  a = 2,\n}\n"))
  local seen: {any} = {}
  local got = check.must(floor.read(path, {
        on_duplicate = function(_key: string, first: any, second: any): any
          seen[#seen + 1] = first
          seen[#seen + 1] = second
          return "resolved"
        end,
      }))
  assert(got.a == "resolved", "the resolver's return value lands in the read table")
  assert(seen[1] == 1 and seen[2] == 2,
    "the resolver saw the first and second values")
end
test_read_forwards_on_duplicate_and_its_return_lands()

local function test_format_then_parse_round_trips()
  local text = check.must(floor.format({["a.tl"] = 3, ["b.tl"] = 1}))
  local got = check.must(floor.parse(text))
  assert(got["a.tl"] == 3 and got["b.tl"] == 1, "format then parse round-trips")
end
test_format_then_parse_round_trips()

local function test_parse_refuses_a_duplicate_key_by_default()
  local data, err = floor.parse("return {\n  a = 1,\n  a = 2,\n}\n")
  assert(data == nil, "a duplicate key must be refused")
  assert(err and err:find("repeats the key 'a'", 1, true),
    "the error names the key, got: " .. tostring(err))
end
test_parse_refuses_a_duplicate_key_by_default()

local function test_parse_forwards_on_duplicate_and_noun()
  local seen: {any} = {}
  local got = check.must(floor.parse("return {\n  a = 1,\n  a = 2,\n}\n", {
        noun = "coverage baseline",
        on_duplicate = function(_key: string, first: any, second: any): any
          seen[#seen + 1] = first
          seen[#seen + 1] = second
          return "resolved"
        end,
      }))
  assert(got.a == "resolved", "the resolver's return value lands in the parsed table")
  assert(seen[1] == 1 and seen[2] == 2,
    "the resolver saw the first and second values")
  -- The noun reaches literal's error grammar.
  local _data, err = floor.parse("not a literal", {noun = "coverage baseline"})
  assert(err and err:find("coverage baseline", 1, true),
    "the noun names the file kind in errors, got: " .. tostring(err))
end
test_parse_forwards_on_duplicate_and_noun()

local function test_format_refuses_outside_the_domain()
  local text, err = floor.format({[1] = "a number is not a string key"})
  assert(text == nil, "a non-string key is outside the floor domain")
  assert(err and err ~= "", "the refusal carries a message")
end
test_format_refuses_outside_the_domain()

print("all floor tests passed")
