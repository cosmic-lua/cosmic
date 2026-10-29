--- Tests of [`build.ceilings`]: the data file's shape, what it refuses, and the words a ceiling is enforced in, which a
--- compile and the check of the tree share.
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Fs = require("cosmic.fs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{
  grants = { { path = "build/ceilings.txt", letters = "r" } },
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

local function test_a_section_holds_a_line_for_each_ceiling_and_a_comment_says_why()
  local ceilings = parsed("# the first stage\n[checked]\n# a comment before its lines\nbuild/a.tl nil_not_allowed 3\n" ..
      "build/b.tl view_written 12\n\n[untyped]\nbuild/c.tl 4\n")
  local checked = Ceilings.of(ceilings, "checked")
  assert(checked["build/a.tl nil_not_allowed"] == 3 and checked["build/b.tl view_written"] == 12)
  assert(Ceilings.of(ceilings, "untyped")["build/c.tl"] == 4)
  assert(next(Ceilings.of(ceilings, "declared")) == nil, "a stage the file lacks has no ceilings")
end

local function test_a_line_outside_a_section_or_of_the_wrong_shape_is_refused_with_its_place()
  assert(refused("build/a.tl nil_not_allowed 3\n"):find("a ceiling before any [stage] line", 1, true))
  local zero = refused("[checked]\nbuild/a.tl nil_not_allowed 0\n")
  assert(zero:find("build/ceilings.txt:2: expected `<file> <code> <count>` with a count of 1 or more", 1, true), zero)
  assert(refused("[checked]\nbuild/a.tl nil_not_allowed\n"):find(":2: expected", 1, true))
  assert(refused("[checked]\nbuild/a.tl nil_not_allowed three\n"):find(":2: expected", 1, true))
  assert(refused("[checked]\nbuild/a.tl nil_not_allowed -1\n"):find(":2: expected", 1, true))
end

local function test_a_stage_no_check_has_and_a_ceiling_given_twice_are_refused()
  assert(refused("[checks]\n"):find("no stage checks in a check of the tree", 1, true))
  local twice = refused("[checked]\nbuild/a.tl nil_not_allowed 3\nbuild/a.tl nil_not_allowed 4\n")
  assert(twice:find(":3: `build/a.tl nil_not_allowed` has a ceiling twice in [checked]", 1, true), twice)
  -- the same key in two stages is two ceilings
  local both = parsed("[checked]\nbuild/a.tl nil_not_allowed 3\n[declared]\nbuild/a.tl float_key 4\n")
  assert(Ceilings.of(both, "checked")["build/a.tl nil_not_allowed"] == 3 and
      Ceilings.of(both, "declared")["build/a.tl float_key"] == 4)
end

local function test_the_file_of_the_tree_parses_and_names_only_the_stages_the_checks_hold()
  local ceilings = assert(Ceilings.read("."))
  local counted = 0
  local stages: {Ceilings.Stage} = { "scoped", "declared", "untyped", "checked", "examples", "testdata" }
  for _, stage in ipairs(stages) do
    local held = Ceilings.of(ceilings, stage)
    for key, n in pairs(held) do
      assert(n >= 1, key)
      counted = counted + 1
    end
  end
  assert(counted > 3000, "the ceilings of the tree are thousands: " .. tostring(counted))
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

local function test_a_key_that_can_never_be_met_is_refused_at_the_parse()
  assert(refused("[checked]\nbuild/a.tl nil_not_alowed 3\n"):find(":2: `nil_not_alowed` is no code of [checked]", 1, true))
  assert(refused("[declared]\nbuild/a.tl nil_not_allowed 3\n"):find("is no code of [declared]", 1, true))
  assert(refused("[checked]\nbuild/a.tl 3\n"):find(":2: a ceiling of [checked] is a file and a code, not `build/a.tl`", 1, true))
  assert(refused("[checked]\nbuild/a.tl  nil_not_allowed 3\n"):find("is a file and a code", 1, true))
  assert(refused("[checked]\nbuild/a.tl nil_not_allowed extra 3\n"):find("is a file and a code", 1, true))
  assert(refused("[untyped]\nbuild/a.tl lines 3\n"):find("a ceiling of [untyped] is one word", 1, true))
  -- a code of the stage is met: each stage has its own list
  local ceilings = parsed("[examples]\nbuild/a.tl view_written 1\n[declared]\nbuild/a.tl float_key 1\n" ..
      "[checked]\nbuild/a.tl nil_not_allowed 1\n[untyped]\nbuild/a.tl 2\n")
  assert(Ceilings.of(ceilings, "untyped")["build/a.tl"] == 2)
end

local function test_a_ceiling_for_a_file_the_tree_lacks_is_dead(dir: string)
  assert(Fs.mkdirs(dir .. "/build"))
  assert(Fs.write(dir .. "/build/ceilings.tl", "-- here\n"))
  local ceilings = parsed("[checked]\nbuild/ceilings.tl nil_not_allowed 3\nbuild/gone.tl nil_not_allowed 1\n" ..
      "[examples]\nbuild/nothing.tl view_written 2\n")
  local dead = Ceilings.dead(dir, ceilings)
  assert(#dead == 2, table.concat(dead, "\n"))
  assert(dead[1] == "build/gone.tl nil_not_allowed: pinned in [checked], and the tree has no file build/gone.tl", dead[1])
  assert(dead[2]:find("build/nothing.tl view_written: pinned in [examples]", 1, true), dead[2])
end

--- Whether `text` holds `needle`.
local function says(text: string, needle: string): boolean
  return text:find(needle, 1, true) ~= nil
end

--- How many lines `text` has.
local function lines_of(text: string): integer
  local _, count = text:gsub("\n", "\n")
  return count
end

local function test_a_ceiling_with_a_neighbour_is_named_with_its_place()
  -- Alone between blank lines, under a comment or a stage line, and last in the file: all fine.
  assert(Ceilings.crowded("[checked]\n# why\nbuild/a.tl nil_not_allowed 3\n\nbuild/b.tl view_written 12\n") == "")
  assert(Ceilings.crowded("[checked]\nbuild/a.tl nil_not_allowed 3\n\n[generated]\n\nbuild/c.tl 4") == "")
  assert(Ceilings.crowded("") == "")
  -- Another ceiling directly after, or a comment, or a stage line, is not.
  local pair = Ceilings.crowded("[checked]\nbuild/a.tl nil_not_allowed 3\nbuild/b.tl view_written 12\n")
  assert(lines_of(pair) == 1 and says(pair, "build/ceilings.txt:2: `build/a.tl nil_not_allowed 3` is followed directly by another line"),
    pair)
  local commented = Ceilings.crowded("[checked]\nbuild/a.tl nil_not_allowed 3\n# why\nbuild/b.tl view_written 12\n")
  assert(lines_of(commented) == 1 and says(commented, ":2:"), commented)
  local staged = Ceilings.crowded("[checked]\nbuild/a.tl nil_not_allowed 3\n[generated]\nbuild/c.tl 4\nbuild/d.tl 5\n")
  assert(lines_of(staged) == 2 and says(staged, ":2:") and says(staged, ":4:"), staged)
  -- Every crowded line is named, not the first alone.
  assert(lines_of(Ceilings.crowded("[checked]\nbuild/a.tl x 1\nbuild/b.tl x 1\nbuild/c.tl x 1\n\nbuild/d.tl x 1\n")) == 2)
end

local function test_the_file_of_the_tree_keeps_each_ceiling_alone_between_blank_lines()
  local text, why = Fs.read("build/ceilings.txt")
  assert(text ~= nil, why)
  local crowded = Ceilings.crowded(text)
  assert(crowded == "", tostring(lines_of(crowded)) .. " ceilings have a neighbour, so a change to a neighbouring pin " ..
      "conflicts with a change to them; put a blank line after each ceiling:\n" .. crowded:sub(1, 600))
end

--- Whether `text`, which may be absent, holds `needle`.
local function has(text: string?, needle: string): boolean
  return text ~= nil and text:find(needle, 1, true) ~= nil
end

local function test_a_raised_count_is_refused_with_its_line_and_the_two_counts()
  local base = "[checked]\n# why\nbuild/a.tl nil_not_allowed 3\n\nbuild/b.tl view_written 2\n"
  local now = "[checked]\n# why\nbuild/a.tl nil_not_allowed 4\n\nbuild/b.tl view_written 2\n"
  local raised = Ceilings.rises(base, now)
  assert(#raised == 1, table.concat(raised, "\n"))
  assert(raised[1] == "build/ceilings.txt:3: [checked] build/a.tl nil_not_allowed rose from 3 to 4; a ceiling only falls: fix the code instead",
    raised[1])
end

local function test_a_row_the_base_lacks_is_refused_whether_it_is_a_new_file_a_new_code_a_stage_moved_to_or_a_rename()
  local base = "[checked]\nbuild/a.tl nil_not_allowed 3\n\n[declared]\nbuild/c.tl key_type 1\n"
  local now = "[checked]\nbuild/a.tl nil_not_allowed 3\n\nbuild/new.tl nil_not_allowed 1\n\nbuild/a.tl view_written 1\n\n" ..
    "[declared]\nbuild/c.tl key_type 1\n\nbuild/a.tl nil_not_allowed 3\n\nbuild/renamed.tl key_type 1\n"
  local raised = Ceilings.rises(base, now)
  assert(#raised == 4, table.concat(raised, "\n"))
  assert(raised[1] == "build/ceilings.txt:4: [checked] build/new.tl nil_not_allowed is a row the merge base lacks, pinned 1; " ..
      "a ceiling only falls and a row is never added: fix the code instead", raised[1])
  assert(has(raised[2], ":6: [checked] build/a.tl view_written is a row the merge base lacks"), raised[2])
  assert(has(raised[3], ":11: [declared] build/a.tl nil_not_allowed is a row the merge base lacks"), raised[3])
  assert(has(raised[4], ":13: [declared] build/renamed.tl key_type is a row the merge base lacks"), raised[4])
end

local function test_a_count_lowered_a_row_removed_and_a_file_unchanged_are_accepted()
  local base = "[checked]\nbuild/a.tl nil_not_allowed 3\n\nbuild/b.tl view_written 2\n\nbuild/c.tl arity 1\n\n[untyped]\nbuild/u.tl 5\n"
  local now = "[checked]\nbuild/a.tl nil_not_allowed 2\n\nbuild/c.tl arity 1\n\n[untyped]\nbuild/u.tl 5\n"
  assert(#Ceilings.rises(base, now) == 0, table.concat(Ceilings.rises(base, now), "\n"))
  assert(#Ceilings.rises(base, base) == 0)
  assert(#Ceilings.rises(base, "") == 0, "every row removed")
end

local function test_the_untyped_stage_rises_by_file_like_the_others()
  local raised = Ceilings.rises("[untyped]\nbuild/u.tl 5\n", "[untyped]\nbuild/u.tl 6\n\nbuild/v.tl 1\n")
  assert(#raised == 2, table.concat(raised, "\n"))
  assert(has(raised[1], "[untyped] build/u.tl rose from 5 to 6"), raised[1])
end

local function test_a_base_that_holds_a_row_of_a_code_closed_since_is_still_a_base()
  -- `arity` is closed now, and the merge base of a branch cut before it was closed can still hold a row of it
  local base = "[checked]\nbuild/a.tl arity 3\n"
  assert(#Ceilings.rises(base, "") == 0)
  assert(#Ceilings.rises(base, "[checked]\nbuild/a.tl arity 2\n") == 0, "rises judges counts; parse refuses the row")
end

local function test_a_line_keyed_by_a_closed_code_is_refused_in_every_stage_that_counts_by_code()
  -- a closed code of the stage (`examples` and `testdata` count the findings of any stage's codes)
  local closed_of: {string: string} = {
    scoped = "shadows", declared = "repeated_field", checked = "arity", examples = "arity", testdata = "shadows",
  }
  for stage, code in pairs(closed_of) do
    local why = refused("[" .. stage .. "]\nbuild/a.tl " .. code .. " 1\n")
    assert(has(why, "build/ceilings.txt:2: " .. code .. " is closed: the tree keeps this rule with no exceptions; " ..
        "fix the code instead"), why)
  end
  -- a code that has a row is not closed
  assert(Ceilings.of(parsed("[checked]\nbuild/a.tl view_written 1\n"), "checked")["build/a.tl view_written"] == 1)
end

local function test_every_code_of_a_stage_with_no_row_is_closed_and_every_closed_code_is_a_code()
  local codes: mut {string: boolean} = {}
  for _, code in ipairs(Scopes.codes) do codes[code] = true end
  for _, code in ipairs(Declarations.codes) do codes[code] = true end
  for _, code in ipairs(Check.codes) do codes[code] = true end
  local text = assert(Fs.read("build/ceilings.txt"))
  local pinned: mut {string: boolean} = {}
  local stage = ""
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%[([a-z]+)%]$")
    if name ~= nil then
      stage = name
    elseif line ~= "" and line:sub(1, 1) ~= "#" and stage ~= "untyped" then
      local code = line:match("^%S+ (%S+) %d+$")
      if code ~= nil then pinned[code] = true end
    end
  end
  local closed: mut {string: boolean} = {}
  for _, code in ipairs(Ceilings.closed()) do
    assert(codes[code] == true, code .. " is listed in Ceilings.closed and is no code of a stage")
    assert(closed[code] == nil, code .. " is listed twice in Ceilings.closed")
    assert(pinned[code] == nil, code .. " is closed and build/ceilings.txt still pins it")
    closed[code] = true
  end
  for code in pairs(codes) do
    assert(pinned[code] == true or closed[code] == true, code .. " has no row left in build/ceilings.txt: add it to " ..
        "Ceilings.closed in build/ceilings.tl, so that no pin of it comes back")
  end
end
