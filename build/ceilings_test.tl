--- Tests of [`build.ceilings`]: the data file's shape, what it refuses, and the words a ceiling is enforced in, which a
--- compile and the check of the tree share.
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "build/ceilings.txt", letters = "r" },
  },
}

local function parsed(text: string): Ceilings.Table
  local table_, why = Ceilings.parse(text)
  return (assert(table_, why))
end

local function refused(text: string): string
  local table_, why = Ceilings.parse(text)
  assert(table_ == nil, "accepted:\n" .. text)
  return why
end

local function finding(code: string, y: integer): Ceilings.Finding
  return { code = code, y = y, x = 3, msg = "message " .. tostring(y), fix = "fix " .. tostring(y) }
end

local function test_errors_over_their_ceiling_are_listed_with_the_count_and_what_it_is_pinned_at()
  local errors = { finding("nil_not_allowed", 4), finding("nil_not_allowed", 9), finding("view_written", 2) }
  local held = Ceilings.over("build/a.tl", errors, { "nil_not_allowed", "view_written" }, { ["build/a.tl nil_not_allowed"] = 1 }, "bodies")
  assert(#held.lines == 5, table.concat(held.lines, "\n"))
  assert(held.lines[1] == "build/a.tl:4:3: message 4 (nil_not_allowed): fix 4", held.lines[1])
  assert(held.lines[2]:find(":9:3:", 1, true), held.lines[2])
  assert(held.lines[3] == "build/a.tl: 2 errors of nil_not_allowed in its bodies, pinned 1; follow the fix above rather than raise the pin",
    held.lines[3])
  assert(held.lines[5] == "build/a.tl: 1 error of view_written in its bodies, pinned 0; follow the fix above rather than raise the pin",
    held.lines[5])
  assert(held.found["build/a.tl nil_not_allowed"] == 2 and held.found["build/a.tl view_written"] == 1)
end

local function test_a_tree_without_ceilings_lists_its_errors_without_a_pin_to_raise()
  local errors = { finding("nil_not_allowed", 4), finding("nil_not_allowed", 9), finding("view_written", 2) }
  local held = Ceilings.over("a.tl", errors, { "nil_not_allowed", "view_written" }, {}, "bodies", true)
  assert(#held.lines == 5, table.concat(held.lines, "\n"))
  assert(held.lines[3] == "a.tl: 2 errors of nil_not_allowed in its bodies; follow the fix above", held.lines[3])
  assert(held.lines[5] == "a.tl: 1 error of view_written in its bodies; follow the fix above", held.lines[5])
  -- the same errors under a table that has ceilings are told with them
  local pinned = Ceilings.over("a.tl", errors, { "nil_not_allowed", "view_written" }, {}, "bodies", false)
  assert(pinned.lines[3] == "a.tl: 2 errors of nil_not_allowed in its bodies, pinned 0; follow the fix above rather than raise the pin",
    pinned.lines[3])
end

local function test_errors_at_or_under_their_ceiling_and_codes_nobody_asked_for_are_not_listed()
  local errors = { finding("nil_not_allowed", 4), finding("view_written", 2), finding("other_code", 1) }
  local held = Ceilings.over("build/a.tl", errors, { "nil_not_allowed", "view_written" },
    { ["build/a.tl nil_not_allowed"] = 1, ["build/a.tl view_written"] = 5 }, "bodies")
  assert(#held.lines == 0, table.concat(held.lines, "\n"))
  assert(held.found["build/a.tl other_code"] == nil)
end

local function test_a_ceiling_above_what_is_found_is_told_to_fall_in_the_order_of_the_keys()
  local lines = Ceilings.fallen({ ["b.tl x"] = 2, ["a.tl x"] = 1 }, { ["b.tl x"] = 3, ["a.tl x"] = 1, ["c.tl y"] = 2 }, "the file")
  assert(#lines == 2 and lines[1] == "b.tl x: pinned 3 but 2 found; lower the pin in the file" and
      lines[2] == "c.tl y: pinned 2 but 0 found; lower the pin in the file", table.concat(lines, "\n"))
end

--- Whether `text`, which may be absent, holds `needle`.
local function has(text: string?, needle: string): boolean
  return text ~= nil and text:find(needle, 1, true) ~= nil
end

local MARKED <const> = "[marked]\nscoped declared untyped checked\n"

--- The file lists exactly the stages markers hold, and holds no row: the one text the parse accepts.
local function test_the_file_of_the_tree_lists_every_stage_as_marked_and_holds_no_row()
  local ceilings = assert(Ceilings.read("."))
  for _, stage in ipairs(Ceilings.markable()) do
    assert(Ceilings.by_marks(ceilings, stage), tostring(stage) .. " is not held by markers")
    assert(next(Ceilings.of(ceilings, stage)) == nil, tostring(stage) .. " has a row")
  end
  local parsed_text = parsed("# why\n" .. MARKED .. "\n")
  assert(Ceilings.by_marks(parsed_text, "declared"))
end

--- A stage taken out of `[marked]` and given rows is how a count held a finding no marker holds: no stage may have rows.
local function test_a_section_of_rows_is_refused_for_every_stage()
  for _, stage in ipairs({ "scoped", "declared", "untyped", "checked", "testdata", "examples" }) do
    local why = refused(MARKED .. "\n[" .. stage .. "]\nbuild/a.tl view_written 1\n")
    assert(has(why, "build/ceilings.txt:4: [" .. stage .. "] is no section of this file"), why)
  end
  -- the demotion itself: `declared` out of the list, with rows at its counts
  local demoted = refused("[marked]\nscoped untyped checked\n\n[declared]\nbuild/a.tl float_key 1\n")
  assert(has(demoted, "[declared] is no section of this file"), demoted)
  -- a row with no section, or among the stages
  assert(has(refused("build/a.tl nil_not_allowed 3\n"), "this file has no row"))
  assert(has(refused(MARKED .. "build/a.tl 3\n"), "[marked] lists stages by name, not `build/a.tl 3`"))
end

--- `[marked]` must name exactly the stages markers hold, so that no stage is left to hold its findings by counts.
local function test_a_marked_list_that_misses_a_stage_is_refused()
  for _, missing in ipairs({ "scoped", "declared", "untyped", "checked" }) do
    local names: mut {string} = {}
    for _, stage in ipairs(Ceilings.markable()) do
      if tostring(stage) ~= missing then names[#names + 1] = tostring(stage) end
    end
    local why = refused("[marked]\n" .. table.concat(names, " ") .. "\n")
    assert(has(why, "`" .. missing .. "` is missing"), why)
  end
  assert(has(refused(""), "[marked] must list every stage"))
  assert(has(refused("[marked]\nscoped declared untyped checked testdata\n"), "`testdata` is no stage that markers hold"))
  assert(has(refused(MARKED .. "\n[marked]\nscoped\n"), "[marked] is listed twice"))
end

--- Whether a code is held by a marker or a row, and so whether it may be closed, is a check of the whole tree
--- ([`tree_checks.closure`], which `cosmic fix --check .` runs); this holds the list alone.
local function test_every_closed_code_is_a_code_of_a_stage_once()
  local codes: mut {string: boolean} = {}
  for _, code in ipairs(Scopes.codes) do codes[code] = true end
  for _, code in ipairs(Declarations.codes) do codes[code] = true end
  for _, code in ipairs(Check.codes) do codes[code] = true end
  local closed: mut {string: boolean} = {}
  for _, code in ipairs(Ceilings.closed()) do
    assert(codes[code] == true, code .. " is listed in Ceilings.closed and is no code of a stage")
    assert(closed[code] == nil, code .. " is listed twice in Ceilings.closed")
    closed[code] = true
  end
end

-- The markers: a stage listed under `[marked]` has its findings held at the lines they occur on. A marker in a fixture is written
-- as `KEY .. " ..."` so that this file holds none.

local KEY <const> = "-- checked:"

local function first(list: {Ceilings.Spot}, at: integer): Ceilings.Spot
  return assert(list[at])
end

local function test_a_code_two_stages_report_is_held_by_the_marker_of_its_own_stage()
  -- `float_key` is a code of `declared` and of `checked`: each stage's finding needs its own marker
  local both = "local x = f() -- declared: float_key\n"
  local judged = Ceilings.marked("checked", "a.tl", both, { finding("float_key", 1) }, { "float_key" }, "bodies")
  assert(#judged.unmarked == 1, "the declared marker does not hold the checked finding")
  local own = Ceilings.marked("declared", "a.tl", both, { finding("float_key", 1) }, { "float_key" }, "declarations")
  assert(#own.lines == 0 and #own.stale == 0 and #own.unmarked == 0)
  assert(first(judged.unmarked, 1).stage == "checked")
end

local function test_a_finding_on_a_line_without_a_marker_for_its_code_is_listed_and_one_with_it_is_not()
  local source = "local a = 1\nlocal b = t[k] " .. KEY .. " nil_not_allowed\nlocal c = t[k]\n"
  local judged = Ceilings.marked("checked", "build/a.tl", source, { finding("nil_not_allowed", 2), finding("nil_not_allowed", 3) },
    { "nil_not_allowed" }, "bodies")
  assert(#judged.lines == 2, table.concat(judged.lines, "\n"))
  assert(judged.lines[1] == "build/a.tl:3:3: message 3 (nil_not_allowed): fix 3", judged.lines[1])
  assert(judged.lines[2] == "build/a.tl: 1 error of nil_not_allowed in its bodies on line 3, marked 0; " ..
      "follow the fix above rather than add a marker", judged.lines[2])
  assert(#judged.unmarked == 1 and first(judged.unmarked, 1).line == 3 and first(judged.unmarked, 1).count == 1)
  assert(#judged.stale == 0)
  local tree = Ceilings.marked("checked", "a.tl", source, { finding("nil_not_allowed", 3) }, { "nil_not_allowed" }, "bodies", true)
  assert(tree.lines[2] == "a.tl: 1 error of nil_not_allowed in its bodies on line 3; follow the fix above", tree.lines[2])
end

local function test_a_marker_whose_finding_is_gone_is_stale_with_the_count_it_holds_too_many()
  local source = "local b = t[k] " .. KEY .. " nil_not_allowed*3, view_written\nlocal c = 1\n"
  local judged = Ceilings.marked("checked", "build/a.tl", source, { finding("nil_not_allowed", 1) }, { "nil_not_allowed", "view_written" },
    "bodies")
  assert(#judged.lines == 0, table.concat(judged.lines, "\n"))
  assert(#judged.stale == 2, tostring(#judged.stale))
  assert(first(judged.stale, 1).code == "nil_not_allowed" and first(judged.stale, 1).count == 2 and first(judged.stale, 1).line == 1)
  assert(first(judged.stale, 2).code == "view_written" and first(judged.stale, 2).count == 1)
end

local function test_several_codes_on_one_line_and_a_marker_of_another_stage_are_judged_apart()
  local source = "local b = t[k] " .. KEY .. " nil_not_allowed, view_written, float_key\n"
  local errors = { finding("nil_not_allowed", 1), finding("view_written", 1) }
  local judged = Ceilings.marked("checked", "a.tl", source, errors, { "nil_not_allowed", "view_written" }, "bodies")
  assert(#judged.lines == 0 and #judged.stale == 0, table.concat(judged.lines, "\n"))
  -- `float_key` is no code of this stage's list, so its marker is none of this check's business
  local two = Ceilings.marked("checked", "a.tl", source, { finding("nil_not_allowed", 1), finding("nil_not_allowed", 1) },
    { "nil_not_allowed", "view_written" }, "bodies")
  assert(#two.unmarked == 1 and first(two.unmarked, 1).count == 1 and #two.stale == 1 and first(two.stale, 1).code == "view_written")
end

local function test_a_marker_above_a_line_holds_that_line_and_moved_code_keeps_its_marker()
  local source = "local a = 1\n" .. KEY .. " nil_not_allowed\nlocal b = t[k]\n"
  assert(#Ceilings.marked("checked", "a.tl", source, { finding("nil_not_allowed", 3) }, { "nil_not_allowed" }, "bodies").lines == 0)
  -- the same finding, the code moved down a line with its marker
  local moved = "local z = 0\nlocal a = 1\n" .. KEY .. " nil_not_allowed\nlocal b = t[k]\n"
  local judged = Ceilings.marked("checked", "a.tl", moved, { finding("nil_not_allowed", 4) }, { "nil_not_allowed" }, "bodies")
  assert(#judged.lines == 0 and #judged.stale == 0)
  -- the finding left behind at its old line is unmarked and the marker is stale
  local left = Ceilings.marked("checked", "a.tl", moved, { finding("nil_not_allowed", 3) }, { "nil_not_allowed" }, "bodies")
  assert(#left.unmarked == 0 and #left.stale == 1 or #left.lines > 0, "a marker holds the line it is on or above")
end

local function test_a_closed_code_is_held_by_no_marker()
  local closed = "arity"
  local source = "local b = t[k] " .. KEY .. " " .. closed .. "\n"
  local judged = Ceilings.marked("checked", "a.tl", source, { finding(closed, 1) }, { closed }, "bodies")
  assert(#judged.unmarked == 1, "a marker for a closed code holds nothing")
  assert(table.concat(judged.lines, "\n"):find("on line 1, marked 0", 1, true) ~= nil, table.concat(judged.lines, "\n"))
end
