#!/usr/bin/env cosmic
--- reads: docs/guides
-- Ratchets over the shipped guides: `docs/guides/make.md` teaches the
-- project model, and it SHIPS inside the binary — a wrong sentence
-- there is wrong advice delivered by the tool itself. Nothing else
-- checks it against `_make/`.
--
-- The drift is real. When D15 made shipping opt-in, `_make/artifact.tl`
-- dropped `asset` from its `ships` table — and the guide kept teaching
-- the deleted "everything else ships" row in four places, one of which
-- contradicted a correct row two lines above it. Four instances, three
-- review rounds, two commits, for a claim that is one grep. These are
-- the greps.
--
-- Every one of them asks the CODE, by requiring it. The first version
-- of this file recovered the kind vocabulary by regexing
-- `_make/types.tl`, because a Teal enum is a type and types are erased
-- — so there was nothing to require. `_make.types` now carries
-- `kinds`, and the one assertion that still reads source lives beside
-- the enum in `_make/types_test.tl`, where a broken parse fails by
-- name instead of quietly shrinking what this file covers.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local make = require("_make")
local project = require("_make.project")
local ratchet = require("_build.ratchet")
local types = require("_make.types")

local GUIDE < const > = "docs/guides/make.md"
local GUIDES_DIR < const > = "docs/guides"

--- How one row of a guide table teaches one thing.
local record Taught
  --- Text that must appear in the first cell of some row.
  marker: string
  --- A path the model must classify as this kind, so the row is held
  --- against what `--make` DOES and not merely against a vocabulary.
  --- Without it a row can carry the right marker and teach the wrong
  --- thing — `` `*_test.tl` `` declaring payload passes a check that
  --- only looks for the marker.
  path: string
end

-- How each model kind is taught. This map IS the pairing the ratchet
-- enforces — a kind added to the model fails here until the guide
-- teaches it and this map says how; a kind removed fails until both
-- drop it. Three copies would drift; two copies plus this test cannot
-- drift silently.
local TAUGHT < const >: {string: {Taught}} = {
  ["module"] = {{marker = "`<dir>/*.tl`", path = "db/query.tl"}},
  ["entry"] = {
    {marker = "`main.tl` at the root", path = "main.tl"},
    -- The entry kind's second position, and a row of its own because
    -- one binary per subdirectory is the thing most projects need.
    {marker = "`cmd/<name>/main.tl`", path = "cmd/app/main.tl"},
  },
  ["test"] = {{marker = "`*_test.tl`", path = "db/query_test.tl"}},
  ["example"] = {{marker = "`*_example.tl`", path = "db/query_example.tl"}},
  ["benchmark"] = {
    {marker = "`*_benchmark.tl`", path = "db/query_benchmark.tl"},
  },
  ["types"] = {{marker = "`*.d.tl`", path = "db/query.d.tl"}},
  ["pin"] = {{marker = "`*_pin.tl`", path = "3p/lpeg/lpeg_pin.tl"}},
  ["gen"] = {{marker = "`*_gen.tl`", path = "db/schema_gen.tl"}},
  ["payload-gen"] = {
    {marker = "embed_gen.tl", path = "cmd/app/embed_gen.tl"},
  },
  ["payload"] = {{marker = "`embed/**`", path = "embed/schema.sql"}},
  ["testdata"] = {
    {marker = "`testdata/`", path = "db/testdata/fixture.json"},
  },
  ["asset"] = {{marker = "everything else", path = "README.md"}},
}

-- Rows of the model table that teach no kind, each with the reason it
-- belongs there anyway. A row in neither table is a row nobody decided.
local EXTRA_ROWS < const >: {string: string} = {
  ["`_<dir>/`"] = "a visibility marker, not a kind",
}

-- Verbs the guide teaches that the registry does not carry, and why.
local EXTRA_VERBS < const >: {string: string} = {
  -- `_make/init.tl` answers `help` before it looks the verb up, so it
  -- is a real verb with no row. Teaching it is right; the registry
  -- having no row for it is also right.
  ["help"] = "dispatched ahead of the registry, so it has no row",
}

--- The rows of one of the guide's tables.
--- @param heading string The `## ` heading the table sits under
--- @param header string The header row's first cell
--- @return {ratchet.Row} In file order
local function guide_rows(heading: string, header: string): {ratchet.Row}
  local rows = check.must(ratchet.rows(GUIDE, heading, header))
  assert(#rows > 0, GUIDE .. ": no table under '## " .. heading .. "'")
  return rows
end

--- Every guide file, in path order.
--- @return {string} Paths relative to the repo root
local function guide_files(): {string}
  local found = check.must(fs.find(GUIDES_DIR, {glob = "*.md"}))
  table.sort(found)
  assert(#found > 0, "no guide files found under " .. GUIDES_DIR)
  return found
end

-- The guide's marker table and the model's kind vocabulary are the
-- same list. Both directions: a kind the model has and the table does
-- not teach is advice with a hole in it, and a row teaching a kind the
-- model no longer has is the D15 failure again — the tool delivering a
-- claim the model retired.
local function test_the_guide_teaches_exactly_the_models_kinds()
  for _, kind in ipairs(types.kinds) do
    assert(TAUGHT[kind], "kind '" .. kind .. "' is in the model's " ..
      "vocabulary but has no teaching row: add the row to " .. GUIDE ..
      "'s model table and its marker to TAUGHT in this test")
  end
  local known: {string: boolean} = {}
  for _, kind in ipairs(types.kinds) do
    known[kind] = true
  end
  for kind in pairs(TAUGHT) do
    assert(known[kind], "TAUGHT pairs '" .. kind .. "' with a marker " ..
      "but `_make.types` no longer lists it: delete the row from " ..
      GUIDE .. "'s model table and this entry")
  end

  local rows = guide_rows("The project model", "marker")
  for kind, taught in pairs(TAUGHT) do
    for _, one in ipairs(taught) do
      assert(ratchet.bearing(rows, one.marker), GUIDE .. ": the model " ..
        "table has no row whose marker cell contains '" .. one.marker ..
        "', so the guide no longer teaches the '" .. kind .. "' kind")
    end
  end

  for _, row in ipairs(rows) do
    local claimed = EXTRA_ROWS[row.cell] ~= nil
    for _, taught in pairs(TAUGHT) do
      for _, one in ipairs(taught) do
        claimed = claimed or (row.cell:find(one.marker, 1, true) ~= nil)
      end
    end
    assert(claimed, row.where .. ": the model table row '" .. row.cell ..
      "' teaches no model kind and is not recorded in EXTRA_ROWS — " ..
      "a row nobody paired with the model is how the retired " ..
      "vocabulary survived review")
  end
end
test_the_guide_teaches_exactly_the_models_kinds()

-- And each marker means what the walk means by it. The pairing above
-- only proves a row EXISTS; this runs the model's own classifier over
-- a path the row describes, so a marker taught as the wrong kind
-- fails. That is the half of the D15 drift a presence check cannot
-- see: the deleted row had the right marker in it.
local function test_each_taught_marker_classifies_as_its_kind()
  for _, kind in ipairs(types.kinds) do
    for _, one in ipairs(TAUGHT[kind]) do
      local got = project.classify(one.path)
      assert(got == kind, GUIDE .. ": the table teaches '" .. one.marker ..
        "' as " .. kind .. ", but the model classifies " .. one.path ..
        " as " .. got .. " — the row and the walk disagree")
    end
  end
end
test_each_taught_marker_classifies_as_its_kind()

-- The verb table is the registry, restated for a reader. The guide
-- says so itself — "`cosmic --make help` prints this list ... it is
-- the one that cannot go stale" — which is exactly the sentence a
-- table drifts behind: `run` shipped and the row still said planned.
-- `_make` exports both halves already, so this needs no parsing at
-- all; it is the shape every ratchet here should have.
local function test_the_verb_table_is_the_registry()
  local shipped: {string: boolean} = {}
  for _, name in ipairs(make.IMPLEMENTED) do
    shipped[name] = true
  end
  local planned: {string: boolean} = {}
  for _, name in ipairs(make.PLANNED) do
    planned[name] = true
  end

  local taught: {string: boolean} = {}
  for _, row in ipairs(guide_rows("Verbs", "verb")) do
    local named = ratchet.names(row.cell)
    assert(#named > 0, row.where .. ": a verb row names no verb")
    for _, name in ipairs(named) do
      taught[name] = true
      assert(shipped[name] or planned[name] or EXTRA_VERBS[name] ~= nil,
        row.where .. ": the table teaches a verb '" .. name ..
        "' that `--make` has no row for, planned or otherwise")
      -- The `today` column is the claim that goes stale. A shipped
      -- verb marked planned tells a reader not to reach for something
      -- that is right there.
      local says_planned = row.line:find("planned", 1, true) ~= nil
      if shipped[name] then
        assert(not says_planned, row.where .. ": '" .. name ..
          "' is in the registry and shipped, but its row still says " ..
          "planned")
      elseif planned[name] then
        assert(says_planned, row.where .. ": '" .. name .. "' is a " ..
          "planned verb, but its row does not say so")
      end
    end
  end

  for _, name in ipairs(make.IMPLEMENTED) do
    assert(taught[name], "`--make " .. name .. "` ships but " .. GUIDE ..
      "'s verb table does not list it — the guide is the tool's own " ..
      "answer to what it can do")
  end
  for _, name in ipairs(make.PLANNED) do
    assert(taught[name], "'" .. name .. "' is a planned verb with no " ..
      "row in " .. GUIDE .. "'s verb table")
  end
  for name in pairs(EXTRA_VERBS) do
    assert(taught[name], "EXTRA_VERBS excuses '" .. name .. "' from " ..
      "the registry, but the table no longer teaches it")
  end
end
test_the_verb_table_is_the_registry()

-- Retired vocabulary stays retired. D15's `ships` table dropped
-- `asset`: an unlisted repo file is part of the project, never of its
-- artifacts. The row that said otherwise — "an asset, embedded at its
-- relative path" — survived one review in four places. So: in a
-- teaching position (a table row), `asset` may appear only in the
-- pin's legitimate sense ("a pinned external asset"), which does not
-- embed anything. Prose about pins ("the fetched asset lands under
-- `o/`") is not a teaching row and stays free.
local function test_no_table_row_teaches_asset_outside_pins()
  for _, path in ipairs(guide_files()) do
    for _, row in ipairs((check.must(ratchet.rows(path)))) do
      local lower = row.line:lower()
      if lower:find("asset", 1, true) then
        assert(lower:find("pin", 1, true), row.where .. ": a table row " ..
          "may say 'asset' only about pins (\"a pinned external " ..
          "asset\"); anywhere else it is the row D15 deleted — " ..
          "shipping is opt-in, and nothing ships for being in the repo")
      end
    end
  end
end
test_no_table_row_teaches_asset_outside_pins()

-- And the row that replaced it keeps saying the true thing. Wherever a
-- guide table describes "everything else", it must say the file is
-- never embedded — that row is the one place the opt-in rule is
-- taught, and it is the exact cell the D15 drift corrupted.
local function test_everything_else_teaches_never_embedded()
  local seen = 0
  for _, path in ipairs(guide_files()) do
    for _, row in ipairs((check.must(ratchet.rows(path)))) do
      if row.cell == "everything else" then
        seen = seen + 1
        assert(row.line:find("never embedded", 1, true), row.where ..
          ": the 'everything else' row must teach that an unlisted " ..
          "file is never embedded; shipping is opt-in (D15): " ..
          row.line)
      end
    end
  end
  assert(seen > 0, "no 'everything else' row found in any guide " ..
    "table — the opt-in rule is no longer taught where the model " ..
    "table is")
end
test_everything_else_teaches_never_embedded()

print("all guide ratchet tests passed")
