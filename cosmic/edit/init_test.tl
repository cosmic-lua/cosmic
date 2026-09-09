#!/usr/bin/env cosmic
local check = require("cosmic.check")
local edit = require("cosmic.edit")
local source_mod = require("cosmic.ast.source")
local walk = require("cosmic.ast.walk")

local type Edit = edit.Edit
local type Node = source_mod.Node
local type Snapshot = source_mod.Snapshot

local function parsed(text: string, name?: string): Snapshot
  return check.must(source_mod.parse(text, name or "edit.tl"))
end

local function named(snapshot: Snapshot, name: string): Node
  local found: Node
  walk.walk(snapshot.node, function(node: Node)
      if node.tk == name then
        local range = snapshot.ranges[node]
        local prior = found and snapshot.ranges[found] or nil
        if range and (not prior
          or range.end_byte - range.start_byte < prior.end_byte - prior.start_byte) then
          found = node
        end
      end
    end)
  assert(found, "missing node " .. name)
  return found
end

local function rename(snapshot: Snapshot, from: string, to: string): Edit
  local range = check.must(source_mod.range(snapshot, named(snapshot, from)))
  return check.must(edit.replace(snapshot, range, to))
end

local function test_apply_assembles_disjoint_edits_once_in_source_order()
  local snapshot = parsed("local alpha = 1\nlocal beta = 2\n")
  local result, err = edit.apply(snapshot, {
      edit.fix("beta", "safe", {rename(snapshot, "beta", "second")}),
      edit.fix("alpha", "safe", {rename(snapshot, "alpha", "first")}),
    })
  assert(result, err)
  check.equal(result.code, "local first = 1\nlocal second = 2\n")
  check.equal(result.applied_edits, 2)
  check.equal(result.changed, true)
end

local function test_apply_deduplicates_identical_edits_and_reports_one()
  local snapshot = parsed("local value = 1\n")
  local replacement = rename(snapshot, "value", "answer")
  local result, err = edit.apply(snapshot, {
      edit.fix("one", "safe", {replacement}),
      edit.fix("same", "safe", {replacement}),
    })
  assert(result, err)
  check.equal(result.code, "local answer = 1\n")
  check.equal(result.applied_edits, 1)
end

local function test_apply_drops_noops_from_the_applied_count()
  local snapshot = parsed("local value = 1\n")
  local result = check.must(edit.apply(snapshot, {edit.fix("noop", "safe", {
            rename(snapshot, "value", "value"),
          })}))
  check.equal(result.code, snapshot.source)
  check.equal(result.changed, false)
  check.equal(result.applied_edits, 0)
end

local function test_apply_refuses_conflicting_edits_atomically()
  local snapshot = parsed("local value = 1\n")
  local range = check.must(source_mod.range(snapshot, named(snapshot, "value")))
  local one = check.must(edit.replace(snapshot, range, "first"))
  local two = check.must(edit.replace(snapshot, range, "second"))
  local result, err = edit.apply(snapshot, {edit.fix("conflict", "safe", {one, two})})
  check.equal(result, nil)
  check.equal(err, "edit ranges overlap or conflict")
end

local function test_apply_refuses_nested_ranges_atomically()
  local snapshot = parsed("return value\n")
  local whole = check.must(edit.replace(snapshot,
      check.must(source_mod.range(snapshot, snapshot.node)), "return other\n"))
  local inner = rename(snapshot, "value", "answer")
  local result, err = edit.apply(snapshot, {edit.fix("nested", "safe", {whole, inner})})
  check.equal(result, nil)
  check.equal(err, "edit ranges overlap or conflict")
end

local function test_replace_refuses_a_constructed_unowned_range()
  local snapshot = parsed("return value\n")
  local result, err = edit.replace(snapshot, {start_byte = 1, end_byte = 7}, "")
  check.equal(result, nil)
  check.equal(err, "edit range is not owned by its source revision")
end

local function test_range_bytes_supports_gap_edits_and_insertions()
  local snapshot = parsed("return value\n")
  local gap = check.must(source_mod.range_bytes(snapshot, 7, 8))
  local insertion = check.must(source_mod.range_bytes(snapshot, 1, 1))
  local result = check.must(edit.apply(snapshot, {edit.fix("spacing", "safe", {
            check.must(edit.replace(snapshot, insertion, "-- inserted\n")),
            check.must(edit.replace(snapshot, gap, "  ")),
          })}))
  check.equal(result.code, "-- inserted\nreturn  value\n")
  check.equal(result.applied_edits, 2)
end

local function test_large_disjoint_batch_reports_every_unique_edit()
  local count = 256
  local snapshot = parsed('return "' .. string.rep("a", count) .. '"\n')
  local edits: {Edit} = {}
  for i = 1, count do
    local range = check.must(source_mod.range_bytes(snapshot, 8 + i, 9 + i))
    edits[#edits + 1] = check.must(edit.replace(snapshot, range, "b"))
  end
  local result = check.must(edit.apply(snapshot, {edit.fix("large", "safe", edits)}))
  check.equal(result.code, 'return "' .. string.rep("b", count) .. '"\n')
  check.equal(result.applied_edits, count)
end

local function test_apply_refuses_stale_current_contents()
  local snapshot = parsed("return value\n")
  local result, err = edit.apply(snapshot,
    {edit.fix("rename", "safe", {rename(snapshot, "value", "answer")})},
    "return changed\n")
  check.equal(result, nil)
  check.equal(err, "source changed since this edit plan was created")
end

local function test_one_foreign_edit_refuses_the_whole_batch()
  local snapshot = parsed("local first = 1\nlocal second = 2\n", "one.tl")
  local foreign = parsed("local second = 2\n", "two.tl")
  local result, err = edit.apply(snapshot, {edit.fix("mixed", "safe", {
          rename(snapshot, "first", "one"), rename(foreign, "second", "two"),
        })})
  check.equal(result, nil)
  check.equal(err, "edit belongs to a different source revision")
end

local function test_validation_reports_parse_failure_without_formatting_apply()
  local snapshot = parsed("local value=1\n")
  local invalid = rename(snapshot, "value", "(")
  local raw = check.must(edit.apply(snapshot, {edit.fix("invalid", "suggested", {invalid})}))
  check.equal(raw.code, "local (=1\n")
  local validation = check.must(edit.validate(snapshot,
      {edit.fix("invalid", "suggested", {invalid})}))
  check.equal(validation.application.code, raw.code)
  check.equal(validation.parse.snapshot, nil)
  assert(#validation.parse.issues > 0, "invalid candidate must carry parse issues")
end
