#!/usr/bin/env cosmic
--- Regression tests for owned compiled patterns. The compatibility matcher
--- intentionally still exposes its Node API; these tests exercise the
--- metadata-owning wrapper used by newer analysis consumers.
local check = require("cosmic.check")
local node_mod = require("cosmic.ast.node")
local pattern = require("cosmic.ast.pattern")

local type Node = node_mod.Node

local function parse_ok(source: string): Node
  return check.must(node_mod.parse(source, "pattern_test.tl")).node[1]
end

local function test_owned_predicate_snapshot_survives_later_compilation()
  local first = check.must(pattern.compile("$F:^test_()"))
  local _second = check.must(pattern.compile("$F:^run_()"))
  assert(pattern.match(first, parse_ok("test_one()")) ~= nil,
    "first owned predicate must still match after another compile")
  assert(pattern.match(first, parse_ok("run_one()")) == nil,
    "first owned predicate must reject the later pattern's name")
end

local function test_owned_pattern_captures_are_compatible_with_match_results()
  local compiled = check.must(pattern.compile("print($X)"))
  local captures = check.must(pattern.match(compiled, parse_ok("print(value)")),
    "expected owned pattern match")
  assert(captures["_X"] ~= nil and captures["_X"].tk == "value",
    "owned pattern capture did not bind the candidate expression")
end
