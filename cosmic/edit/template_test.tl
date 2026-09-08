#!/usr/bin/env cosmic
local check = require("cosmic.check")
local ast_match = require("cosmic.ast.match")
local edit = require("cosmic.edit")
local source_mod = require("cosmic.ast.source")
local template = require("cosmic.edit.template")
local walk = require("cosmic.ast.walk")

local type Node = source_mod.Node
local type Snapshot = source_mod.Snapshot

local function parsed(text: string): Snapshot
  return check.must(source_mod.parse(text, "template.tl"))
end

local function match_one(snapshot: Snapshot, pattern_text: string): Node, {string: Node}
  local pattern = check.must(ast_match.compile_pattern(pattern_text))
  local found: Node
  local captures: {string: Node}
  walk.walk(snapshot.node, function(node: Node)
      if not found then
        local got = ast_match.match(pattern, node)
        if got then found, captures = node, got end
      end
    end)
  assert(found, "missing match")
  assert(captures, "missing captures")
  return found, captures
end

local function apply_one(snapshot: Snapshot, replacement: edit.Edit): string
  local result = check.must(edit.apply(snapshot,
      {edit.fix("template", "safe", {replacement})}))
  return result.code
end

local function test_expression_template_preserves_precedence()
  local snapshot = parsed("return f(a + b)\n")
  local target, captures = match_one(snapshot, "f($X)")
  local replacement = check.must(template.replace_expression(
      snapshot, target, "$X * 2", captures))
  check.equal(apply_one(snapshot, replacement), "return (a + b) * 2\n")
end

local function test_expression_template_refuses_effect_duplication_and_dropping()
  local snapshot = parsed("return wrap(effect())\n")
  local target, captures = match_one(snapshot, "wrap($X)")
  local duplicated, duplicate_err = template.replace_expression(
    snapshot, target, "$X or $X", captures)
  check.equal(duplicated, nil)
  check.equal(duplicate_err, "effectful expression capture must be used exactly once")
  local dropped, dropped_err = template.replace_expression(
    snapshot, target, "true", captures)
  check.equal(dropped, nil)
  check.equal(dropped_err, "effectful expression capture must be used exactly once")
end

local function test_expression_template_refuses_comment_loss()
  local snapshot = parsed("return a --[[ keep ]] + b\n")
  local target, captures = match_one(snapshot, "$A + $B")
  local replacement, err = template.replace_expression(
    snapshot, target, "$B + $A", captures)
  check.equal(replacement, nil)
  check.equal(err, "expression replacement would drop comments")
end

local function test_type_template_groups_a_union_capture()
  local snapshot = parsed("local value: A | B = nil\n")
  local typ = assert(snapshot.types[1], "missing declared type syntax")
  local replacement = check.must(template.replace_type(
      snapshot, typ, "Container<$T>", {_T = typ}))
  check.equal(apply_one(snapshot, replacement),
    "local value: Container<(A | B)> = nil\n")
end

local function test_type_template_refuses_foreign_type_capture()
  local snapshot = parsed("local value: A = nil\n")
  local foreign = parsed("local other: B = nil\n")
  local replacement, err = template.replace_type(snapshot,
    assert(snapshot.types[1]), "$T", {_T = assert(foreign.types[1])})
  check.equal(replacement, nil)
  check.equal(err, "foreign type capture")
end
