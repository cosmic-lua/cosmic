#!/usr/bin/env cosmic
-- Tests for _make.groups: directory accumulation, closure unions, and
-- the root-level no-group rule.

local groups = require("_make.groups")

--- Render `name := values` the way graph.tl's assign does, for lines().
local function assign(name: string, values: {string}): string
  return name .. " := " .. table.concat(values, " ")
end

local function test_groups_accumulate_by_directory()
  local acc = groups.new()
  groups.add(acc, "pkg/a.tl", "pkg/a", {"pkg/b.tl"})
  groups.add(acc, "pkg/b.tl", "pkg/b", {})
  groups.add(acc, "pkg/sub/c.tl", "pkg/sub/c", {"pkg/a.tl", "pkg/b.tl"})
  local lines = groups.lines(acc, assign)
  local body = table.concat(lines, "\n")
  assert(body:find("groupsrcs_pkg := pkg/a.tl pkg/b.tl", 1, true),
    "members accumulate in walk order: " .. body)
  assert(body:find("groupsrcs_pkg/sub := pkg/sub/c.tl", 1, true),
    "subdirectories are their own groups")
  assert(body:find("groupdeps_pkg/sub := pkg/a.tl pkg/b.tl", 1, true),
    "group deps are the sorted union of member closures")
  assert(body:find("groupof_pkg/a := pkg", 1, true), "members name their group")
  assert(body:find("groupof_pkg/sub/c := pkg/sub", 1, true),
    "nested members name the nested group")
end
test_groups_accumulate_by_directory()

local function test_group_deps_are_deduplicated()
  local acc = groups.new()
  groups.add(acc, "pkg/a.tl", "pkg/a", {"lib/x.tl", "lib/y.tl"})
  groups.add(acc, "pkg/b.tl", "pkg/b", {"lib/x.tl"})
  local body = table.concat(groups.lines(acc, assign), "\n")
  assert(body:find("groupdeps_pkg := lib/x.tl lib/y.tl", 1, true),
    "a dep shared by two members appears once: " .. body)
end
test_group_deps_are_deduplicated()

local function test_root_level_sources_join_no_group()
  local acc = groups.new()
  groups.add(acc, "solo.tl", "solo", {})
  local lines = groups.lines(acc, assign)
  assert(#lines == 0,
    "a root-level source emits no group facts; the per-file rule is its path")
end
test_root_level_sources_join_no_group()
