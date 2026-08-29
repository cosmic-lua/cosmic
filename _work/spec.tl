--- The spec bar's section grammar: the headings a spec sidecar must
--- carry, and which of them a given body leaves missing or empty.
---
--- Its own module because it is the one piece of the board's rules
--- that outlived the label board it was written for. The sections
--- mean the same thing over a markdown sidecar that they meant over
--- an issue body, so the grammar moved across unchanged; what each
--- section is FOR is skills/work/SKILL.md. Goal context is the parent
--- chain and dependencies are `blocked_by` edges, so neither is a
--- section.
--- The headings a spec must carry.
local READY_SECTIONS < const >: {string} = {
  "Change", "Non-goals", "Acceptance",
}

--- Spec-bar lint: the required sections a body is missing or has
--- left empty. A heading counts at any level ("## Change", "# change"),
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

--- The one section `name` names, its heading line included, "" when
--- the body does not carry it.
---
--- Headings match exactly as `ready_gaps` matches them — any level,
--- case-insensitively on the heading text — so one grammar serves the
--- spec bar and a narrowed read alike, and `--section acceptance`
--- and `--section Acceptance` name the same thing. The section ends
--- at the next heading or at a thematic break, for the same reason
--- `ready_gaps` stops there: a footer appended below a break is
--- nobody's content.
--- @param body string The spec sidecar's markdown
--- @param name string The section's heading text
--- @return string The section including its heading, "" when absent
local function section_of(body: string, name: string): string
  local want = name:lower()
  local out: {string} = {}
  local inside = false
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^#+%s+(.-)%s*$")
    if text then
      if inside then
        break
      end
      inside = text:lower() == want
      if inside then
        out[#out + 1] = line
      end
    elseif inside then
      if line:match("^%s*%-%-%-+%s*$") then
        break
      end
      out[#out + 1] = line
    end
  end
  if #out == 0 then
    return ""
  end
  return table.concat(out, "\n") .. "\n"
end

local record spec
  READY_SECTIONS: {string}
  ready_gaps: function(body: string): {string}
  section_of: function(body: string, name: string): string
end

local M: spec = {
  READY_SECTIONS = READY_SECTIONS,
  ready_gaps = ready_gaps,
  section_of = section_of,
}

return M
