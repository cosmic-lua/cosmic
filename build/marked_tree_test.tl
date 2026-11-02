--- The checks of the tree over a stage that markers hold ([`build.ceilings`]'s `[marked]`), on fixture trees: a finding with no
--- marker on its line fails, a marker whose finding has gone is stale and is mended, several codes may share a line, and
--- code that moves keeps its markers. A marker in a fixture is written as `KEY .. " ..."` so that this file holds none.
local Ceilings = require("build.ceilings")
local Fs = require("cosmic.fs")
local Markers = require("build.markers")
local Test = require("cosmic.test")
local tree_checks = require("build.tree_checks")

Test.policy{
  grants = {
    { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" },
    { path = "core/socket.h", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" },
    { path = "lang/prelude.d.tl", letters = "r" },
  },
}

local KEY <const> = "-- checked:"

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- A tree whose only module is `build/bad.tl` with `body`, and whose ceilings file is `ceilings`.
local function tree(dir: string, name: string, ceilings: string, body: string): string
  local root = dir .. "/" .. name
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/ceilings.txt", ceilings))
  assert(Fs.write(root .. "/build/bad.tl", body))
  return root
end

local MARKED <const> = "[marked]\nchecked declared untyped\n"

local function joined(lines: {string}): string
  return table.concat(lines, "\n")
end

local function test_a_finding_with_no_marker_on_its_line_fails_and_a_marker_holds_it(dir: string)
  local bare = tree(dir, "bare", MARKED, source("local t: integer = 3.5"))
  local found = joined(tree_checks.checked(bare))
  assert(found:find("build/bad.tl:1:20:", 1, true) and found:find("(not_assignable)", 1, true) and
      found:find("build/bad.tl: 1 error of not_assignable in its bodies on line 1, marked 0; " ..
          "follow the fix above rather than add a marker", 1, true), found)
  local held = tree(dir, "held", MARKED, source("local t: integer = 3.5 " .. KEY .. " not_assignable"))
  assert(#tree_checks.checked(held) == 0, joined(tree_checks.checked(held)))
  -- a marker on another line does not hold it
  local other = tree(dir, "other", MARKED, source(KEY .. " not_assignable", "", "local t: integer = 3.5"))
  assert(joined(tree_checks.checked(other)):find("build/bad.tl:3:", 1, true) ~= nil)
  -- a tree whose ceilings file does not list the stage is held by its rows, whatever its text says
  local rows = tree(dir, "rows", "[checked]\n", source("local t: integer = 3.5 " .. KEY .. " not_assignable"))
  assert(joined(tree_checks.checked(rows)):find("pinned 0; follow the fix above", 1, true) ~= nil)
end

local function test_code_that_moves_keeps_its_marker_because_the_marker_is_on_its_line(dir: string)
  local before = source("local t: integer = 3.5 " .. KEY .. " not_assignable")
  local after = source("-- a comment", "", "local u = 1", "local t: integer = 3.5 " .. KEY .. " not_assignable",
    "print(u)")
  assert(#tree_checks.checked(tree(dir, "before", MARKED, before)) == 0)
  local moved = tree_checks.checked(tree(dir, "after", MARKED, after))
  assert(#moved == 0, joined(moved))
end

local function test_a_finding_that_moved_off_its_marker_fails_and_leaves_the_marker_stale(dir: string)
  local root = tree(dir, "left", MARKED, source("local t: integer = 3.5 " .. KEY .. " not_assignable"))
  assert(#tree_checks.checked(root) == 0)
  -- the code gains a line above the marker's line and the finding follows the code, not the marker
  assert(Fs.write(root .. "/build/bad.tl", source("local t: integer = 3.5", "local u = 1 " .. KEY .. " not_assignable")))
  local found = joined(tree_checks.checked(root))
  assert(found:find("build/bad.tl: 1 error of not_assignable in its bodies on line 1", 1, true) and
      found:find("build/bad.tl:2: its marker holds 1 finding of not_assignable that the line no longer has", 1, true), found)
end

local function test_a_stale_marker_is_told_and_the_fix_removes_it(dir: string)
  local root = tree(dir, "stale", MARKED, source("local t: integer = 3 " .. KEY .. " not_assignable"))
  local found = joined(tree_checks.checked(root))
  assert(found == "build/bad.tl:1: its marker holds 1 finding of not_assignable that the line no longer has; " ..
      "`cosmic fix` removes the marker", found)
  -- a run that mends them collects the places and tells nothing
  local sink: Ceilings.Sink = { unmarked = {}, stale = {}, mend = true }
  assert(#tree_checks.checked(root, nil, nil, nil, { sink = sink }) == 0)
  assert(#sink.stale == 1 and #sink.unmarked == 0)
  local spot = assert(sink.stale[1])
  assert(spot.file == "build/bad.tl" and spot.line == 1 and spot.stage == "checked" and spot.code == "not_assignable" and
      spot.count == 1)
  local text = assert(Fs.read(root .. "/build/bad.tl"))
  assert(Fs.write(root .. "/build/bad.tl", Markers.without(text, "build/bad.tl", sink.stale)))
  assert(assert(Fs.read(root .. "/build/bad.tl")) == source("local t: integer = 3"))
  assert(#tree_checks.checked(root) == 0)
end

local function test_several_findings_on_one_line_are_held_by_a_count_and_by_several_codes(dir: string)
  local line = "local a: {integer} = { 3.5, 4.5 }"
  local two = tree(dir, "two", MARKED, source(line))
  assert(joined(tree_checks.checked(two)):find("2 errors of not_assignable in its bodies on line 1", 1, true) ~= nil)
  assert(Fs.write(two .. "/build/bad.tl", source(line .. " " .. KEY .. " not_assignable")))
  local short = joined(tree_checks.checked(two))
  assert(short:find("2 errors of not_assignable in its bodies on line 1", 1, true) and short:find("on line 1, marked 1", 1, true), short)
  assert(Fs.write(two .. "/build/bad.tl", source(line .. " " .. KEY .. " not_assignable*2")))
  assert(#tree_checks.checked(two) == 0, joined(tree_checks.checked(two)))
  -- one more than the line has is stale by the difference
  assert(Fs.write(two .. "/build/bad.tl", source(line .. " " .. KEY .. " not_assignable*3")))
  assert(joined(tree_checks.checked(two)):find("its marker holds 1 finding of not_assignable", 1, true) ~= nil)
  -- two codes on one line, held by one marker; each code is held apart
  local codes = tree(dir, "codes", MARKED, source("local d: integer? = nil", "local f: {integer} = { 3.5, d + 1 }"))
  local both = joined(tree_checks.checked(codes))
  assert(both:find("(not_assignable)", 1, true) and both:find("(nil_not_allowed)", 1, true), both)
  assert(Fs.write(codes .. "/build/bad.tl", source("local d: integer? = nil",
    "local f: {integer} = { 3.5, d + 1 } " .. KEY .. " nil_not_allowed, not_assignable")))
  assert(#tree_checks.checked(codes) == 0, joined(tree_checks.checked(codes)))
  assert(Fs.write(codes .. "/build/bad.tl", source("local d: integer? = nil",
    "local f: {integer} = { 3.5, d + 1 } " .. KEY .. " not_assignable")))
  local rest = joined(tree_checks.checked(codes))
  assert(rest:find("(nil_not_allowed)", 1, true) and not rest:find("(not_assignable)", 1, true), rest)
end

local function test_a_stage_listed_nowhere_is_found_by_forcing_it_and_the_markers_written_hold_it(dir: string)
  local body = source("local t: integer = 3.5", "local u: integer = 3.5")
  local root = tree(dir, "forced", "[checked]\nbuild/bad.tl not_assignable 2\n", body)
  local sink: Ceilings.Sink = { unmarked = {}, stale = {} }
  tree_checks.checked(root, nil, nil, nil, { sink = sink, force = true })
  assert(#sink.unmarked == 2 and #sink.stale == 0, tostring(#sink.unmarked))
  local text = assert(Fs.read(root .. "/build/bad.tl"))
  local marked = Markers.with(text, "build/bad.tl", sink.unmarked)
  assert(marked == source("local t: integer = 3.5 " .. KEY .. " not_assignable",
    "local u: integer = 3.5 " .. KEY .. " not_assignable"), marked)
  assert(Fs.write(root .. "/build/bad.tl", marked))
  assert(Fs.write(root .. "/build/ceilings.txt", Ceilings.migrated(assert(Fs.read(root .. "/build/ceilings.txt")), { "checked" })))
  assert(#tree_checks.checked(root) == 0, joined(tree_checks.checked(root)))
  -- and the markers are the tree's count now, for the ratchet
  local counted = tree_checks.markers(root)
  local file = assert(counted.counts["build/bad.tl"])
  assert(file["checked not_assignable"] == 2 and #counted.lines == 0, joined(counted.lines))
end

local function test_a_comment_that_is_no_marker_is_left_alone_and_a_closed_code_is_never_held(dir: string)
  local root = tree(dir, "prose", MARKED, source("local t = 1 " .. KEY .. " done"))
  local told = tree_checks.markers(root)
  assert(#told.lines == 0 and next(told.counts) == nil, "a word that is no code is prose")
  -- `shadows` is closed: the tree keeps its rule with no exceptions, so a marker does not hold it
  local closed = tree(dir, "closed", "[marked]\nscoped\n", source("local x = 1", "local x = 2 -- scoped: shadows", "return x"))
  local found = joined(tree_checks.scoped(closed))
  assert(found:find("(shadows)", 1, true) and found:find("shadows is closed", 1, true), found)
end

local function test_the_calls_the_checker_gave_no_function_are_held_by_untyped_markers_at_their_lines(dir: string)
  local root = tree(dir, "untyped", MARKED, source("local x = missing(2)", "local y = x.field(1)", "return y"))
  assert(Fs.mkdirs(root .. "/cosmic"))
  assert(Fs.write(root .. "/cosmic/m.tl", source(
    "local record M",
    "  record Item",
    "    n: integer",
    "  end",
    "  make: function(): Item",
    "end",
    "function M.make(): M.Item",
    "  return { n = 1 }",
    "end",
    "return M")))
  local bare = joined(tree_checks.untyped(root))
  assert(bare:find("build/bad.tl:1:", 1, true) and bare:find("in its calls on line 1", 1, true), bare)
  assert(Fs.write(root .. "/build/bad.tl", source("local x = missing(2) -- untyped: call",
    "local y = x.field(1) -- untyped: call", "return y")))
  assert(#tree_checks.untyped(root) == 0, joined(tree_checks.untyped(root)))
  assert(Fs.write(root .. "/build/bad.tl", source("local x = missing(2) -- untyped: call*2",
    "local y = x.field(1) -- untyped: call", "return y")))
  assert(joined(tree_checks.untyped(root)):find("its marker holds 1 finding of call", 1, true) ~= nil)
end

local function test_a_file_that_does_not_parse_keeps_its_markers_through_the_check_and_the_fix(dir: string)
  local body = source("local t: integer = 3.5 " .. KEY .. " not_assignable", "local = = 1")
  local root = tree(dir, "broken", MARKED, body)
  local sink: Ceilings.Sink = { unmarked = {}, stale = {}, mend = true }
  for _, found in ipairs({ tree_checks.checked(root, nil, nil, nil, { sink = sink }),
      tree_checks.declared(root, nil, nil, { sink = sink }) }) do
    assert(not joined(found):find("no longer has", 1, true), joined(found))
  end
  assert(#sink.stale == 0, "a file no stage could judge has no stale marker")
  -- the same markers over a file that parses and has no finding are stale
  assert(Fs.write(root .. "/build/bad.tl", source("local t: integer = 3 " .. KEY .. " not_assignable")))
  tree_checks.checked(root, nil, nil, nil, { sink = sink })
  assert(#sink.stale == 1)
end
