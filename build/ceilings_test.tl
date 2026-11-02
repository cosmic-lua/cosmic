--- Tests of [`build.ceilings`]: what a marker holds, what it does not (a marker of another stage, of a closed code, a stale
--- one), and the words a finding is refused in, which a compile and the check of the tree share.
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{}

local function finding(code: string, y: integer): Ceilings.Finding
  return { code = code, y = y, x = 3, msg = "message " .. tostring(y), fix = "fix " .. tostring(y) }
end

--- Whether `text`, which may be absent, holds `needle`.
local function has(text: string?, needle: string): boolean
  return text ~= nil and text:find(needle, 1, true) ~= nil
end

--- No file configures the stages: they are these four, in the order a comment writes them, and each is held by markers.
local function test_the_stages_markers_hold_are_the_four_of_the_checker()
  local stages: mut {string} = {}
  for _, stage in ipairs(Ceilings.markable()) do stages[#stages + 1] = tostring(stage) end
  assert(table.concat(stages, " ") == "scoped declared untyped checked", table.concat(stages, " "))
end

--- A project holds no marker: its findings are all refused, and the lines say the count alone, not what a marker holds.
local function test_a_markerless_text_lists_every_finding_without_a_marker_to_add()
  local errors = { finding("nil_not_allowed", 4), finding("nil_not_allowed", 9), finding("view_written", 2) }
  local text = "a()\nb()\n"
  local judged = Ceilings.marked("checked", "a.tl", text, errors, { "nil_not_allowed", "view_written" }, "bodies", true)
  assert(#judged.lines == 6, table.concat(judged.lines, "\n"))
  assert(judged.lines[2] == "a.tl: 1 error of view_written in its bodies on line 2; follow the fix above", judged.lines[2])
  assert(judged.lines[4] == "a.tl: 1 error of nil_not_allowed in its bodies on line 4; follow the fix above", judged.lines[4])
  assert(not has(table.concat(judged.lines, "\n"), "marker"), table.concat(judged.lines, "\n"))
  -- the same errors under a text with markers are told with what is marked
  local marked = Ceilings.marked("checked", "a.tl", text, errors, { "nil_not_allowed", "view_written" }, "bodies")
  assert(has(marked.lines[2], ", marked 0; follow the fix above rather than add a marker"), marked.lines[2])
end

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

-- The markers: a stage has its findings held at the lines they occur on. A marker in a fixture is written
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
