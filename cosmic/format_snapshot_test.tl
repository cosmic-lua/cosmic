#!/usr/bin/env cosmic
-- public parsed-snapshot formatter tests

local source = require("cosmic.ast.source")
local snapshot_format = require("cosmic.format_snapshot")

local function test_public_snapshot_formatter_returns_typed_result_and_snapshot()
  local input = "local function id<T>(x:T):T\nreturn x\nend\n"
  local snapshot, err = source.parse(input, "public_snapshot.tl")
  assert(snapshot, err)
  local result, final = snapshot_format.format_snapshot(snapshot)
  assert(result is snapshot_format.FormatResult, "result keeps its public nominal type")
  assert(result.ok, "snapshot formatting must succeed")
  assert(result.code == "local function id<T>(x: T): T\n  return x\nend\n",
    "snapshot formatter must retain house style")
  assert(final and final.source == result.code,
    "slot 2 must carry the validated output snapshot")
end

local function test_snapshot_formatter_needs_no_type_check()
  local input = "local missing = require(\"does.not.exist\")\n"
    .. "local value: number = \"wrong\"\nreturn missing, value\n"
  local snapshot, err = source.parse(input, "type_errors.tl")
  assert(snapshot, err)
  local result, final = snapshot_format.format_snapshot(snapshot)
  assert(result.ok and final, "syntax-only formatting must ignore semantic errors")
end
