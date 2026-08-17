--- The ready bar's section grammar: the headings a spec sidecar must
--- carry, and which of them a given body leaves missing or empty.
---
--- Its own module because it is the one piece of the board's rules
--- that outlived the label board it was written for. The sections
--- mean the same thing over a markdown sidecar that they meant over
--- an issue body, so the grammar moved across unchanged; what each
--- section is FOR is skills/work/decompose.md.
--- The headings a spec must carry.
local READY_SECTIONS < const >: {string} = {
  "Goal", "Change", "Non-goals", "Acceptance", "Enablement",
}

--- Ready-bar lint: the required sections a body is missing or has
--- left empty. A heading counts at any level ("## Goal", "# goal"),
--- matched on the heading text alone, case-insensitively — and only
--- when at least one non-blank line follows it before the next
--- heading, so a pasted template with hollow sections still fails.
--- A thematic break (---) ends the current section: trailing footers
--- appended below one are nobody's content.
--- @param body string The spec sidecar's markdown
--- @return {string} Missing/empty section names, in READY_SECTIONS order
local function ready_gaps(body: string): {string}
  local filled: {string: boolean} = {}
  local current: string = nil
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^#+%s+(.-)%s*$")
    if text then
      current = text:lower()
      if filled[current] == nil then
        filled[current] = false
      end
    elseif line:match("^%s*%-%-%-+%s*$") then
      current = nil
    elseif current and line:match("%S") then
      filled[current] = true
    end
  end
  local missing: {string} = {}
  for _, name in ipairs(READY_SECTIONS) do
    if not filled[name:lower()] then
      missing[#missing + 1] = name
    end
  end
  return missing
end

local record spec
  READY_SECTIONS: {string}
  ready_gaps: function(body: string): {string}
end

local M: spec = {
  READY_SECTIONS = READY_SECTIONS,
  ready_gaps = ready_gaps,
}

return M
