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

--- Whether a spec's Enablement section states a blocker. The section
--- either records that none is needed or names the items that must
--- land first, and the second form has to be mirrored in the item's
--- `blocked_by` — prose is not something `next` can read, so a
--- dependency left only here sequences nothing.
---
--- Deliberately about the CLAIM, not the id: "Blocked by: #1252" and
--- "blocked on <ksuid>" both count, because the question is whether
--- the planner said a dependency exists, not which one they meant.
--- @param body string The spec sidecar's markdown
--- @return boolean True when the Enablement section claims a blocker
local function claims_blocker(body: string): boolean
  local inside = false
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^#+%s+(.-)%s*$")
    if text then
      inside = text:lower() == "enablement"
    elseif inside then
      local lower = line:lower()
      if lower:match("blocked%s+by") or lower:match("blocked%s+on") then
        return true
      end
    end
  end
  return false
end

local record spec
  READY_SECTIONS: {string}
  claims_blocker: function(body: string): boolean
  ready_gaps: function(body: string): {string}
end

local M: spec = {
  READY_SECTIONS = READY_SECTIONS,
  ready_gaps = ready_gaps,
  claims_blocker = claims_blocker,
}

return M
