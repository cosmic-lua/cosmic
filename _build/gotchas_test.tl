#!/usr/bin/env cosmic
--- reads: docs/guides/gotchas.md _build/testdata/gotchas
-- Every gotcha section's symptom block names a real, refused message:
-- `docs/guides/gotchas.md`'s `## <slug>` sections may open with a
-- fenced ```text``` block of checker-message shapes (`cosmic._teal_symptoms`
-- reads it to build the fall-through hint), and this ratchets that the
-- block never drifts from what the checker actually says. A symptom
-- the checker no longer emits, or a fixture that no longer fails,
-- catches here instead of shipping a hint that names the wrong thing.
--
-- The parse below is its own copy of `cosmic._teal_symptoms`'s, not a
-- call into it: that module is a `cosmic._*` internal shard, off
-- limits to a file outside `cosmic/` (the `visibility` lint), and
-- reading independently is also the point -- this test proves the
-- DOCUMENT is honest, which a shared parser could not catch if the
-- parser itself had the bug.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local GUIDE < const > = "docs/guides/gotchas.md"
local FIXTURE_DIR < const > = "_build/testdata/gotchas"

--- One section's symptom lines, in file order.
local record Section
  slug: string
  shapes: {string}
end

--- Lua's magic pattern characters, escaped so a literal fragment
--- matches itself before `...` is turned into a wildcard.
local function escape_literal(s: string): string
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

--- A symptom line as a `string.find` pattern: `...` becomes the lazy
--- wildcard `.-`, everything else is escaped literal.
local function shape_to_pattern(shape: string): string
  local parts: {string} = {}
  local pos = 1
  while true do
    local dots_start, dots_end = shape:find("...", pos, true)
    if not dots_start then
      parts[#parts + 1] = escape_literal(shape:sub(pos))
      break
    end
    parts[#parts + 1] = escape_literal(shape:sub(pos, dots_start - 1))
    pos = dots_end + 1
  end
  return table.concat(parts, ".-")
end

--- Every section that opens with a fenced ```text``` symptom block,
--- in the order the sections appear in the guide.
--- @param text string The guide's full markdown
--- @return {Section}
local function sections_with_symptoms(text: string): {Section}
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local out: {Section} = {}
  local i = 1
  while i <= #lines do
    local slug = lines[i]:match("^## ([%w%-]+)%s*$")
    if slug then
      local j = i + 1
      while j <= #lines and lines[j] == "" do
        j = j + 1
      end
      if lines[j] and lines[j]:match("^```text%s*$") then
        local shapes: {string} = {}
        local k = j + 1
        local closed = false
        -- A fence that runs into the next heading before closing is
        -- unterminated: stop there rather than reading into whatever
        -- that next section's own fence eventually closes with.
        while k <= #lines and not lines[k]:match("^## ") do
          if lines[k] == "```" then
            closed = true
            break
          end
          local shape = lines[k]:match("^%s*(.-)%s*$")
          if shape ~= "" then
            shapes[#shapes + 1] = shape
          end
          k = k + 1
        end
        assert(closed, GUIDE .. ": section '" .. slug ..
          "' opens a ```text block that never closes")
        assert(#shapes > 0, GUIDE .. ": section '" .. slug ..
          "' has an empty ```text block")
        out[#out + 1] = {slug = slug, shapes = shapes}
      end
    end
    i = i + 1
  end
  return out
end

--- Every rendered issue line ("severity: message") a check produced.
--- @param result teal.CheckResult The result of a strict check
--- @return {string}
local function issue_lines(result: teal.CheckResult): {string}
  local out: {string} = {}
  for _, issue in ipairs(result.errors) do
    out[#out + 1] = issue.severity .. ": " .. issue.message
  end
  for _, issue in ipairs(result.warnings) do
    out[#out + 1] = issue.severity .. ": " .. issue.message
  end
  return out
end

local function test_every_symptom_is_real_and_gated()
  local text = check.must(fs.read(GUIDE))
  local sections = sections_with_symptoms(text)
  assert(#sections > 0, GUIDE .. ": no symptom blocks found; the " ..
    "harness is broken")

  for _, section in ipairs(sections) do
    local fixture = FIXTURE_DIR .. "/" .. section.slug .. ".tl"
    assert(fs.is_file(fixture), GUIDE .. ": section '" .. section.slug ..
      "' carries a symptom block but has no fixture at " .. fixture)

    local result = teal.check_file(fixture)
    assert(not result.ok, fixture .. ": --check types must refuse this " ..
      "fixture — a fixture the checker accepts documents a symptom " ..
      "that is not actually an error")

    local lines = issue_lines(result)
    for _, shape in ipairs(section.shapes) do
      local pattern = shape_to_pattern(shape)
      local found = false
      for _, line in ipairs(lines) do
        if line:find(pattern, 1, false) then
          found = true
          break
        end
      end
      assert(found, fixture .. ": no refusal contains the '" ..
        section.slug .. "' symptom '" .. shape .. "' -- got:\n  " ..
        table.concat(lines, "\n  "))
    end
  end
end

-- The other direction: a fixture with no claiming section is a
-- fixture nobody is proving anything with.
local function test_every_fixture_has_a_symptom_section()
  local text = check.must(fs.read(GUIDE))
  local claimed: {string: boolean} = {}
  for _, section in ipairs(sections_with_symptoms(text)) do
    claimed[section.slug] = true
  end

  local found = check.must(fs.find(FIXTURE_DIR, {glob = "*.tl"}))
  assert(#found > 0, "no fixtures found under " .. FIXTURE_DIR)
  for _, path in ipairs(found) do
    local slug = fs.basename(path):match("^(.*)%.tl$")
    assert(claimed[slug], path .. ": no section '" .. tostring(slug) ..
      "' in " .. GUIDE .. " carries a symptom block for this fixture")
  end
end

print("all gotchas ratchet tests passed")
