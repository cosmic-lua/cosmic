--- Tests of [`build.markers`]: what a text's markers are, and the edits that remove and write them. A marker in a fixture
--- is written as `KEY .. " ..."` so that this file holds none of its own (it would be one for the ratchet to count).
local Markers = require("build.markers")
local Test = require("cosmic.test")

Test.policy{}

local KEY <const> = "-- checked:"

--- Lines as one text.
local function text(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

local function spot(line: integer, code: string, count?: integer): Markers.Spot
  return { file = "a.tl", line = line, stage = "checked", code = code, count = count or 1 }
end

local function test_a_trailing_comment_holds_the_line_it_ends()
  local read = Markers.read(text("local x = 1", "local y = t[k] " .. KEY .. " map_field, nil_not_allowed*2", "return y"), "a.tl")
  assert(#read.marks == 1, tostring(#read.marks))
  local mark = assert(read.marks[1])
  assert(mark.line == 2 and mark.at == 2 and not mark.alone and mark.prefix == "")
  local segment = assert(mark.segments[1])
  assert(#mark.segments == 1 and segment.stage == "checked")
  assert(#segment.codes == 2 and segment.codes[1] == "map_field" and segment.codes[2] == "nil_not_allowed")
  assert(segment.counts["map_field"] == 1 and segment.counts["nil_not_allowed"] == 2)
end

local function test_a_comment_of_a_line_of_its_own_holds_the_line_below()
  local read = Markers.read(text("local x = 1", KEY .. " any_use", "local y = x"), "a.tl")
  local mark = assert(read.marks[1])
  assert(#read.marks == 1 and mark.alone and mark.line == 3 and mark.at == 2)
  -- three dashes are a doc comment, and prose after the words is no list of codes
  assert(#Markers.read(text("--- " .. KEY .. " any_use", "local y = 1"), "a.tl").marks == 0)
  assert(#Markers.read(text("local y = 1 " .. KEY .. " this is why"), "a.tl").marks == 0)
  assert(#Markers.read(text("local y = 1 " .. KEY .. ""), "a.tl").marks == 0)
  assert(#Markers.read(text("local y = 1 " .. KEY .. " a, a"), "a.tl").marks == 0, "a code twice is no list")
end

local function test_the_words_inside_a_string_are_no_marker()
  local read = Markers.read(text("local s = \"x " .. KEY .. " map_field\"", "local t = [[", "y " .. KEY .. " any_use", "]]"), "a.tl")
  assert(#read.marks == 0)
  assert(Markers.counts(text("local s = \"x " .. KEY .. " map_field\""), "a.tl")["checked map_field"] == nil)
end

local function test_a_marker_follows_the_words_of_a_comment_the_line_already_ends_in()
  local read = Markers.read(text("local y = 1 -- why not " .. KEY .. " any_use"), "a.tl")
  local mark = assert(read.marks[1])
  assert(#read.marks == 1 and mark.prefix == "-- why not" and assert(mark.segments[1]).counts["any_use"] == 1)
end

local function test_counts_sum_the_codes_of_all_markers()
  local counts = Markers.counts(text("a() " .. KEY .. " any_use*2, map_field", "b() " .. KEY .. " any_use"), "a.tl")
  assert(counts["checked any_use"] == 3 and counts["checked map_field"] == 1)
end

local function test_removing_a_finding_lowers_a_count_and_drops_a_marker_that_reaches_none()
  local source = text("a() " .. KEY .. " any_use*2, map_field", "b() " .. KEY .. " any_use", "c()")
  local lowered = Markers.without(source, "a.tl", { spot(1, "any_use") })
  assert(lowered == text("a() " .. KEY .. " any_use, map_field", "b() " .. KEY .. " any_use", "c()"), lowered)
  local dropped = Markers.without(source, "a.tl", { spot(1, "any_use", 2), spot(1, "map_field"), spot(2, "any_use") })
  assert(dropped == text("a()", "b()", "c()"), dropped)
end

local function test_removing_a_marker_keeps_the_comment_it_follows_and_deletes_a_line_of_its_own()
  local kept = Markers.without(text("a() -- why " .. KEY .. " any_use"), "a.tl", { spot(1, "any_use") })
  assert(kept == text("a() -- why"), kept)
  local alone = Markers.without(text("a()", "  " .. KEY .. " any_use", "  b()"), "a.tl", { spot(3, "any_use") })
  assert(alone == text("a()", "  b()"), alone)
end

local function test_writing_a_marker_appends_it_and_merges_with_the_one_the_line_has()
  local source = text("a()", "b() " .. KEY .. " map_field", "c() -- why")
  local marked = Markers.with(source, "a.tl", { spot(1, "any_use"), spot(2, "any_use", 2), spot(2, "map_field"),
    spot(3, "view_written") })
  assert(marked == text("a() " .. KEY .. " any_use", "b() " .. KEY .. " map_field*2, any_use*2",
    "c() -- why " .. KEY .. " view_written"), marked)
  -- the text reads back as the markers written
  local counts = Markers.counts(marked, "a.tl")
  assert(counts["checked any_use"] == 3 and counts["checked map_field"] == 2 and counts["checked view_written"] == 1)
end

local function test_a_line_that_ends_inside_a_string_gets_its_marker_on_the_line_above()
  local source = text("local function f()", "  local s = g([[", "text", "]])", "end")
  local marked = Markers.with(source, "a.tl", { spot(2, "any_use") })
  assert(marked == text("local function f()", "  " .. KEY .. " any_use", "  local s = g([[", "text", "]])", "end"), marked)
  local read = Markers.read(marked, "a.tl")
  local mark = assert(read.marks[1])
  assert(#read.marks == 1 and mark.alone and mark.line == 3, "the marker holds the line below it")
end

local function test_moving_code_moves_its_marker_with_the_line()
  local before = text("a()", "b() " .. KEY .. " any_use")
  local after = text("b() " .. KEY .. " any_use", "a()")
  assert(assert(Markers.read(before, "a.tl").marks[1]).line == 2)
  assert(assert(Markers.read(after, "a.tl").marks[1]).line == 1)
  assert(Markers.counts(before, "a.tl")["checked any_use"] == Markers.counts(after, "a.tl")["checked any_use"])
end

local function test_one_comment_holds_the_markers_of_several_stages_and_each_is_judged_by_its_own()
  local source = text("local x = f() -- declared: float_key -- checked: map_field*2, any_use", "g()")
  local read = Markers.read(source, "a.tl")
  local mark = assert(read.marks[1])
  assert(#read.marks == 1 and #mark.segments == 2 and assert(mark.segments[1]).stage == "declared" and
      assert(mark.segments[2]).stage == "checked")
  local counts = Markers.counts(source, "a.tl")
  assert(counts["declared float_key"] == 1 and counts["checked map_field"] == 2 and counts["checked float_key"] == nil)
  -- one stage's finding going leaves the other's marker
  local without: Markers.Spot = { file = "a.tl", line = 1, stage = "declared", code = "float_key", count = 1 }
  assert(Markers.without(source, "a.tl", { without }) == text("local x = f() -- checked: map_field*2, any_use", "g()"))
  -- and the stages are written in their order whichever was added first
  local both = Markers.with(text("g()"), "a.tl", { spot(1, "map_field"), { file = "a.tl", line = 1, stage = "declared",
    code = "float_key", count = 1 } })
  assert(both == text("g() -- declared: float_key -- checked: map_field"), both)
end

local function test_a_comment_with_the_words_and_a_sentence_is_left_alone()
  local source = text("local x = f() -- checked: it is fine, as written", "g() -- declared: float_key -- checked: because of this", "h() " .. KEY .. " done")
  assert(#Markers.read(source, "a.tl").marks == 0)
  assert(Markers.without(source, "a.tl", { spot(1, "it"), spot(3, "done") }) == source)
  -- a single word that is no code of the stage is prose too, and a code of another stage is none of this one's
  assert(Markers.bare("h() " .. KEY .. " done") == "h() " .. KEY .. " done")
  assert(#Markers.read(text("h() -- untyped: float_key", "h() -- scoped: map_field"), "a.tl").marks == 0)
end

local function test_the_markers_are_written_in_the_order_of_the_stages_and_after_the_words_of_the_comment()
  local marked = Markers.with(text("g() -- why"), "a.tl", { spot(1, "map_field", 2), spot(1, "any_use"),
    { file = "a.tl", line = 1, stage = "scoped", code = "shadows", count = 1 } })
  assert(marked == text("g() -- why -- scoped: shadows -- checked: any_use, map_field*2"), marked)
  assert(Markers.without(marked, "a.tl", { spot(1, "map_field", 2), spot(1, "any_use"),
    { file = "a.tl", line = 1, stage = "scoped", code = "shadows", count = 1 } }) == text("g() -- why"))
end

local function test_a_line_is_shown_without_the_markers_that_end_it()
  assert(Markers.bare("mut skip?: function(Response): boolean " .. KEY .. " any_use") == "mut skip?: function(Response): boolean")
  assert(Markers.bare("n: integer -- declared: key_type -- checked: any_use, map_field*2") == "n: integer")
  -- a comment of the author's, or a sentence after the words, stays
  assert(Markers.bare("n: integer -- the count") == "n: integer -- the count")
  assert(Markers.bare("n: integer -- the count " .. KEY .. " any_use") == "n: integer -- the count")
  assert(Markers.bare("n: integer " .. KEY .. " it is why") == "n: integer " .. KEY .. " it is why")
  assert(Markers.bare("n: integer") == "n: integer")
end

local function test_a_line_of_its_own_holds_the_markers_of_several_stages()
  local source = text("-- declared: key_type -- checked: any_use", "n: {any: any}")
  local mark = assert(Markers.read(source, "a.tl").marks[1])
  assert(mark.alone and mark.line == 2 and #mark.segments == 2)
  local written = Markers.with(text("local s = g([[", "x", "]])"), "a.tl", { spot(1, "any_use"),
    { file = "a.tl", line = 1, stage = "declared", code = "key_type", count = 1 } })
  assert(written == text("-- declared: key_type -- checked: any_use", "local s = g([[", "x", "]])"), written)
  assert(Markers.counts(written, "a.tl")["declared key_type"] == 1)
end

local function test_a_marker_a_line_holds_twice_loses_only_what_is_stale()
  -- one count held by a comment above and one at the end of the line
  local source = text("-- checked: any_use", "f() -- checked: any_use")
  local once = Markers.without(source, "a.tl", { spot(2, "any_use") })
  assert(once == text("f() -- checked: any_use") or once == text("-- checked: any_use", "f()"), once)
  assert(Markers.counts(once, "a.tl")["checked any_use"] == 1)
end

local function test_a_line_whose_line_above_ends_inside_a_string_is_refused_a_marker()
  local source = text("local s = [[", "text", "]] .. g([[", "more", "]])")
  local refused = Markers.unwritable(source, "a.tl", { spot(3, "any_use"), spot(1, "any_use") })
  assert(#refused == 1 and assert(refused[1]).line == 3)
  assert(Markers.with(source, "a.tl", { spot(3, "any_use") }) == source)
end
