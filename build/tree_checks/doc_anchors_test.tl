--- [`build.tree_checks.docs`]' `anchors` on fixture trees: which records are
--- doc anchors, and when two of them share a name. The tree's own are
--- held to it by `cosmic fix --check .`, not here.

local fixture = require("build.docs_fixture")
local tree_docs = require("build.tree_checks.docs")

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- An anchor module of one documented string field, `field`.
local function anchor(name: string, field: string): string
  return source(
    "--- Doc anchors.",
    "local record " .. name,
    "  --- what " .. field .. " means here",
    "  " .. field .. ": string",
    "end",
    "local value: " .. name .. " = { " .. field .. " = \"" .. field .. "\" }",
    "return value")
end

local function test_two_anchors_sharing_a_name_are_flagged(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "test"),
  })
  local found = tree_docs.anchors(db, { "cosmic.verbs Verbs", "cosmic.shapes Shapes" })
  assert(#found == 1 and found[1]:find(
    "cosmic.shapes Shapes.test and cosmic.verbs Verbs.test: `cosmic docs test` answers both",
    1, true) ~= nil, table.concat(found, "\n"))
end

--- An anchor may share its name with a real member -- a function, or
--- a field of a record a function hands out -- and anchors with names
--- of their own do not collide.
local function test_an_anchor_beside_a_real_member_is_allowed(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "tests"),
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "  record Miss",
      "    --- where it went wrong",
      "    test: string",
      "  end",
      "end",
      "--- Tests it.",
      "function Thing.test(): Thing.Miss return { test = \"x\" } end",
      "return Thing"),
  })
  local found = tree_docs.anchors(db, { "cosmic.verbs Verbs", "cosmic.shapes Shapes" })
  assert(#found == 0, table.concat(found, "\n"))
end

--- A record of documented strings that a field of another record holds (`examples?: {Example}`) is handed out with
--- that record, so it is no anchor and may share a field's name with one.
local function test_a_record_a_field_holds_is_no_anchor(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "about"),
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "  record Example",
      "    --- what it shows",
      "    about: string",
      "  end",
      "  record Command",
      "    --- its examples",
      "    examples?: {Example}",
      "  end",
      "end",
      "return Thing"),
  })
  local found = tree_docs.anchors(db, { "cosmic.verbs Verbs" })
  assert(#found == 0, table.concat(found, "\n"))
end
