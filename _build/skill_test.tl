#!/usr/bin/env cosmic
-- Ratchets over the skill the binary SHIPS.
--
-- `skills/cosmic/**` is staged into the artifact and read by `--docs`,
-- so a wrong sentence in it is wrong advice delivered by the tool
-- itself.
--
-- Most of what it could get wrong is no longer written down: `_make`
-- renders the kind vocabulary, what ships and the verbs into
-- `skills/cosmic/model.md`, and a table nobody writes cannot disagree
-- with the build. What is left to check is the seam around that —
-- whether the rendering is WHOLE, and whether a hand-written copy has
-- crept back in beside it.
--
-- The gate is here rather than in the renderer because a renderer that
-- refuses wedges the build that would fix it: the refusal survives
-- `--make clean`, and only reaching for the pin by hand gets out of it.
-- Measured, during this change. A failing test fails the run instead,
-- which is loud and recoverable.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local model = require("_make.model")

local SKILL_DIR < const > = "skills/cosmic"
local SKILL < const > = SKILL_DIR .. "/make.md"

-- A claim the model no longer makes, in the words it used to make it.
-- D15 made shipping opt-in; this is what its return would look like,
-- and it is what took two commits to remove the first time.
local RETIRED < const >: {string: string} = {
  ["embedded at its relative path"] =
  "shipping is opt-in (D15): nothing ships by falling through to a default",
}

--- Every markdown file the artifact carries.
--- @return {string} Paths relative to the repo root, sorted
local function skill_files(): {string}
  local found = check.must(fs.collect(SKILL_DIR, "*.md"))
  table.sort(found)
  assert(#found > 0, "no skill files under " .. SKILL_DIR)
  return found
end

-- The rendered guide covers the model whole: every kind an example
-- reaches, every kind with a gloss, every verb with a description. Each
-- gap is a row the guide cannot fill, and a kind added to the model is
-- exactly the change that opens one -- which is the drift this whole
-- arrangement is against.
local function test_the_rendered_model_has_no_gaps()
  local gaps = model.gaps()
  assert(#gaps == 0,
    "the generated model guide cannot describe the model whole:\n  " ..
    table.concat(gaps, "\n  ") ..
    "\nThe guide is rendered by _make/model.tl and read with " ..
    "`cosmic --docs guide.model`")
end
test_the_rendered_model_has_no_gaps()

-- And it says so in the guide, not just in the gap list: a row the
-- renderer could not fill carries a visible marker rather than being
-- dropped, so a reader sees the hole too.
local function test_no_row_renders_as_undocumented()
  local text = model.render()
  assert(not text:find(model.MISSING, 1, true),
    "the rendered guide carries a " .. model.MISSING .. " row")
  -- And it is a real guide, not an empty shell that trivially passes.
  assert(text:find("| marker | declares | ships |", 1, true),
    "the rendered guide has no marker table")
  assert(text:find("| verb | what it does | today |", 1, true),
    "the rendered guide has no verb table")
end
test_no_row_renders_as_undocumented()

-- A retired claim stays retired, across every file the artifact
-- carries -- not just the one that owns the subject. D15's row survived
-- in four places precisely because the fix looked at one of them.
local function test_retired_claims_do_not_come_back()
  for _, path in ipairs(skill_files()) do
    local text = check.must(fs.read(path))
    for claim, why in pairs(RETIRED) do
      assert(not text:find(claim, 1, true),
        path .. " teaches a retired claim (\"" .. claim .. "\"): " .. why)
    end
  end
end
test_retired_claims_do_not_come_back()

-- And the vocabulary is not restated by hand beside the generated one.
-- A second copy is exactly what generation removed: it reads as
-- authoritative, nothing compares it to the model, and it drifts on the
-- next change to `classify`.
local function test_the_vocabulary_is_not_written_by_hand()
  local text = check.must(fs.read(SKILL))
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    assert(not trimmed:match("^|%s*marker%s*|"),
      SKILL .. " restates the marker table by hand: " .. trimmed ..
      "\nThe vocabulary is rendered by _make/model.tl; read it with " ..
      "`cosmic --docs guide.model`")
    assert(not trimmed:match("^|%s*verb%s*|"),
      SKILL .. " restates the verb table by hand: " .. trimmed ..
      "\nThe verbs come from the registry the dispatcher is built from")
  end
end
test_the_vocabulary_is_not_written_by_hand()

print("all skill ratchet tests passed")
