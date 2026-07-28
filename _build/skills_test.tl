#!/usr/bin/env cosmic
-- Ratchets over the make skill: `skills/cosmic/make.md` teaches the
-- project model, and it SHIPS inside the binary — a wrong sentence
-- there is wrong advice delivered by the tool itself. Nothing else
-- checks it against `_make/`.
--
-- The drift is real. When D15 made shipping opt-in, `_make/artifact.tl`
-- dropped `asset` from its `ships` table — and the skill kept teaching
-- the deleted "everything else ships" row in four places, one of which
-- contradicted a correct row two lines above it. Four instances, three
-- review rounds, two commits, for a claim that is one grep. These are
-- the greps.
--
-- Parsed from source text rather than required: `_make` is internal to
-- its own tree, so this test reads `_make/types.tl` the way it reads
-- the markdown — as bytes. The enum is the vocabulary's single
-- declaration either way.

local check = require("cosmic.check")
local fs = require("cosmic.fs")

-- Both subjects are read as bytes, so both are declared: the skill
-- files this greps, and the model source whose enum they must agree
-- with (`_make` is internal to its own tree, so requiring it is not
-- an option either). Without the declarations an edit to a skill --
-- or to the enum -- left this file up to date and the stage reported
-- the previous run's pass.
-- @reads skills/cosmic/*.md
-- @reads _make/types.tl

local SKILL < const > = "skills/cosmic/make.md"
local MODEL < const > = "_make/types.tl"
local SKILLS_DIR < const > = "skills/cosmic"

--- The model's kind vocabulary, parsed from the enum's own source.
--- @return {string: boolean} The set of kinds
local function model_kinds(): {string: boolean}
  local src = check.must(fs.read(MODEL))
  local block = src:match("enum Kind(.-)\n%s*end")
  assert(block, MODEL .. ": no `enum Kind` block found")
  local out: {string: boolean} = {}
  for kind in block:gmatch("\"([%w%-]+)\"") do
    out[kind] = true
  end
  return out
end

--- One row of a markdown table: its first cell, the rest of the line,
--- and where it is.
local record Row
  cell: string
  line: string
  where: string
end

--- Table rows of one markdown file: every `|`-led line that is neither
--- a header separator nor blank cells of dashes.
--- @param path string The file to scan
--- @return {Row} In file order
local function table_rows(path: string): {Row}
  local out: {Row} = {}
  local n = 0
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    n = n + 1
    if line:sub(1, 1) == "|" then
      local cell = line:match("^|%s*(.-)%s*|")
      if cell and not cell:match("^[-: ]*$") then
        out[#out + 1] = {cell = cell, line = line, where = path .. ":" .. n}
      end
    end
  end
  return out
end

--- The rows of the skill's "The project model" table only.
--- @return {Row} In file order
local function model_table_rows(): {Row}
  local out: {Row} = {}
  local in_section = false
  local n = 0
  for line in check.must(fs.read(SKILL)):gmatch("([^\n]*)\n?") do
    n = n + 1
    if line:match("^## ") then
      in_section = line == "## The project model"
    elseif in_section and line:sub(1, 1) == "|" then
      local cell = line:match("^|%s*(.-)%s*|")
      if cell and cell ~= "marker" and not cell:match("^[-: ]*$") then
        out[#out + 1] = {cell = cell, line = line, where = SKILL .. ":" .. n}
      end
    end
  end
  assert(#out > 0, SKILL .. ": no table under '## The project model'")
  return out
end

--- Every skill file, in path order.
--- @return {string} Paths relative to the repo root
local function skill_files(): {string}
  local found = check.must(fs.collect(SKILLS_DIR, "*.md"))
  table.sort(found)
  assert(#found > 0, "no skill files found under " .. SKILLS_DIR)
  return found
end

-- How each model kind is taught: the marker text that must appear in
-- the first cell of some row of the skill's model table. This map IS
-- the pairing the ratchet enforces — a kind added to the enum fails
-- here until the skill teaches it and this map says how; a kind
-- removed fails until both drop it. Three copies would drift; two
-- copies plus this test cannot drift silently.
local TAUGHT < const >: {string: string} = {
  ["module"] = "`<dir>/*.tl`",
  ["entry"] = "`main.tl` at the root",
  ["test"] = "`*_test.tl`",
  ["example"] = "`*_example.tl`",
  ["benchmark"] = "`*_benchmark.tl`",
  ["types"] = "`*.d.tl`",
  ["pin"] = "`*_pin.tl`",
  ["gen"] = "`*_gen.tl`",
  ["payload-gen"] = "embed_gen.tl",
  ["payload"] = "`embed/**`",
  ["testdata"] = "`testdata/`",
  ["asset"] = "everything else",
}

-- Rows of the model table that are not a kind's teaching row, each
-- with the reason it belongs there anyway. A row in neither table is
-- a row nobody decided.
local EXTRA_ROWS < const >: {string: string} = {
  ["`cmd/<name>/main.tl`"] = "the entry kind's second position",
  ["`_<dir>/`"] = "a visibility marker, not a kind",
}

-- The skill's marker table and the model's kind vocabulary are the
-- same list. Both directions: a kind the enum has and the table does
-- not teach is advice with a hole in it, and a row teaching a kind the
-- enum no longer has is the D15 failure again — the tool delivering a
-- claim the model retired.
local function test_the_skill_teaches_exactly_the_models_kinds()
  local kinds = model_kinds()
  local count = 0
  for _ in pairs(kinds) do
    count = count + 1
  end
  assert(count >= 8, MODEL .. ": expected the enum's kinds, found " ..
    count .. " — the parser found the wrong block")

  for kind in pairs(kinds) do
    assert(TAUGHT[kind], "kind '" .. kind .. "' is in " .. MODEL ..
      "'s enum but has no teaching row: add the row to " .. SKILL ..
      "'s model table and its marker to TAUGHT in this test")
  end
  for kind in pairs(TAUGHT) do
    assert(kinds[kind], "TAUGHT pairs '" .. kind .. "' with a marker " ..
      "but " .. MODEL .. "'s enum no longer has it: delete the row " ..
      "from " .. SKILL .. "'s model table and this entry")
  end

  local rows = model_table_rows()
  for kind, marker in pairs(TAUGHT) do
    local found = false
    for _, row in ipairs(rows) do
      if row.cell:find(marker, 1, true) then
        found = true
        break
      end
    end
    assert(found, SKILL .. ": the model table has no row whose marker " ..
      "cell contains '" .. marker .. "', so the skill no longer " ..
      "teaches the '" .. kind .. "' kind")
  end

  for _, row in ipairs(rows) do
    local claimed = EXTRA_ROWS[row.cell] ~= nil
    for _, marker in pairs(TAUGHT) do
      claimed = claimed or (row.cell:find(marker, 1, true) ~= nil)
    end
    assert(claimed, row.where .. ": the model table row '" .. row.cell ..
      "' teaches no model kind and is not recorded in EXTRA_ROWS — " ..
      "a row nobody paired with the model is how the retired " ..
      "vocabulary survived review")
  end
end
test_the_skill_teaches_exactly_the_models_kinds()

-- Retired vocabulary stays retired. D15's `ships` table dropped
-- `asset`: an unlisted repo file is part of the project, never of its
-- artifacts. The row that said otherwise — "an asset, embedded at its
-- relative path" — survived one review in four places. So: in a
-- teaching position (a table row), `asset` may appear only in the
-- pin's legitimate sense ("a pinned external asset"), which does not
-- embed anything. Prose about pins ("the fetched asset lands under
-- `o/`") is not a teaching row and stays free.
local function test_no_table_row_teaches_asset_outside_pins()
  for _, path in ipairs(skill_files()) do
    for _, row in ipairs(table_rows(path)) do
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
-- skill table describes "everything else", it must say the file is
-- never embedded — that row is the one place the opt-in rule is
-- taught, and it is the exact cell the D15 drift corrupted.
local function test_everything_else_teaches_never_embedded()
  local seen = 0
  for _, path in ipairs(skill_files()) do
    for _, row in ipairs(table_rows(path)) do
      if row.cell == "everything else" then
        seen = seen + 1
        assert(row.line:find("never embedded", 1, true), row.where ..
          ": the 'everything else' row must teach that an unlisted " ..
          "file is never embedded; shipping is opt-in (D15): " ..
          row.line)
      end
    end
  end
  assert(seen > 0, "no 'everything else' row found in any skill " ..
    "table — the opt-in rule is no longer taught where the model " ..
    "table is")
end
test_everything_else_teaches_never_embedded()

print("all skill ratchet tests passed")
