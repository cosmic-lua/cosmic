--- Fall-through hints sourced from `docs/guides/gotchas.md`'s symptom blocks.
---
--- Split from `cosmic._teal_hints` for room: that module's 13 hand
--- patterns carry fixes, and this module is the closing net behind
--- them — a checker message none of those patterns recognizes still
--- earns a hint when some gotcha section documents its exact shape.
---
--- Each `## <slug>` section in the guide may open with a fenced
--- ```` ```text ```` block listing the message shape(s) it explains,
--- one per line, positions and variable names elided as `...`. This
--- module loads that guide once per process, turns each line into a
--- Lua pattern (`...` becomes the lazy wildcard `.-`, everything else
--- escaped literally), and matches an issue's message against them in
--- the order the sections appear. A malformed block — an unterminated
--- fence, a heading with no fence — is skipped rather than thrown:
--- `_build/gotchas_test.tl` is where a guide's own shape mismatches
--- are gated, not this runtime path.

local GUIDE_PATH < const > = "/zip/docs/guides/gotchas.md"

--- One message shape, already a Lua pattern, paired with the section
--- that explains it.
local record Shape
  slug: string
  pattern: string
end

--- Lua's magic pattern characters, escaped so a literal line matches
--- itself before `...` is turned into a wildcard.
local function escape_literal(s: string): string
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

--- Turn one symptom line into a Lua pattern: every `...` run becomes
--- `.-` (matches any run, lazily), everything else is escaped literal.
--- @param shape string A symptom line from a guide's ```text block
--- @return string A `string.find` pattern
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

--- Parse every section's symptom block out of the guide's text, in the
--- order the sections appear. A section with no fenced block right
--- after its heading (or one whose fence never closes) contributes
--- nothing — never a throw, this is library code reading a file it
--- does not control the shape of.
--- @param text string The guide's full markdown
--- @return {Shape}
local function parse_shapes(text: string): {Shape}
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local out: {Shape} = {}
  local i = 1
  while i <= #lines do
    local slug = lines[i]:match("^## ([%w%-]+)%s*$")
    if slug then
      local j = i + 1
      while j <= #lines and lines[j] == "" do
        j = j + 1
      end
      if lines[j] and lines[j]:match("^```text%s*$") then
        local k = j + 1
        local closed = false
        -- A fence that runs into the next heading before closing is
        -- unterminated: stop there rather than swallowing whatever
        -- that next section's own fence eventually closes with.
        while k <= #lines and not lines[k]:match("^## ") do
          if lines[k] == "```" then
            closed = true
            break
          end
          local shape = lines[k]:match("^%s*(.-)%s*$")
          if shape ~= "" then
            out[#out + 1] = {slug = slug, pattern = shape_to_pattern(shape)}
          end
          k = k + 1
        end
        if not closed then
          -- An unterminated fence taught nothing real; drop what this
          -- heading contributed rather than trust a partial read.
          while #out > 0 and out[#out].slug == slug do
            out[#out] = nil
          end
        end
      end
    end
    i = i + 1
  end
  return out
end

-- Loaded once per process: the guide is fixed for the life of the
-- artifact, and re-reading it on every issue would cost a syscall and
-- a re-parse per error line.
local cache_loaded = false
local cache_shapes: {Shape} | nil = nil

--- The parsed shape table, loading and caching it on first use. `nil`
--- (never re-tried) when the guide is not embedded — a stripped
--- artifact, or one built without docs.
local function shapes(): {Shape} | nil
  if not cache_loaded then
    cache_loaded = true
    local text = require("cosmic.fs").read(GUIDE_PATH)
    if text then
      cache_shapes = parse_shapes(text)
    end
  end
  return cache_shapes
end

--- A fix-hint naming the gotcha section whose symptom block matches
--- this message, or nil when no section claims it.
--- @param msg string The error message to match
--- @return string|nil A hint naming the section, or nil
local function hint_for_message(msg: string): string | nil
  local table_ = shapes()
  if not table_ then
    return nil
  end
  for _, shape in ipairs(table_) do
    if msg:find(shape.pattern, 1, false) then
      return "  hint: see cosmic --docs guide.gotchas — section " .. shape.slug
    end
  end
  return nil
end

local record TealSymptomsModule
  hint_for_message: function(msg: string): string | nil
  -- Internal: exported only so `_teal_symptoms_test.tl` can feed
  -- `parse_shapes` a malformed block directly, without a fixture guide
  -- to make malformed on disk. Pure (no I/O), per D19's helper exemption.
  type Shape = Shape
  parse_shapes: function(text: string): {Shape}
end

local M: TealSymptomsModule = {
  hint_for_message = hint_for_message,
  parse_shapes = parse_shapes,
}

return M
