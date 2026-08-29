--- The spec bar's grammar: the one heading a spec sidecar must
--- carry — what to build — and whether a given body carries it.
---
--- There is no Acceptance section, because acceptance is not
--- per-item: the CI gate passing is the one definition of done every
--- item shares, and proof specific to a change rides the DIFF as a
--- test or ratchet the gate runs — a gate outlives the sidecar that
--- asked for it. The bar checks only what a machine can check
--- honestly: whether the Change decides enough is the puller's
--- judgment (a wrong call comes back as a drop with the gap named),
--- and optional prose sections ride along untouched.
---
--- It also names a spec's REVISION, because the sidecar is half of
--- what a review judges: the diff is the other half, and a rework
--- that answers a bounce by rewriting the spec moves this half alone.
local hash = require("cosmic.hash")

--- The headings a spec must carry.
local READY_SECTIONS < const >: {string} = {
  "Change",
}

--- The one section `name` names, its heading line included, "" when
--- the body does not carry it.
---
--- Headings match at any level, case-insensitively on the heading
--- text, so `--section acceptance` and `--section Acceptance` name
--- the same thing. The section ends at the next heading or at a
--- thematic break (---): a footer appended below a break is nobody's
--- content.
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

--- Spec-bar lint: the gaps that keep a body from being buildable,
--- each as one readable line. A heading counts at any level
--- ("## Change", "# change"), matched case-insensitively — and only
--- when at least one non-blank line follows it before the next
--- heading, so a pasted template with hollow sections still fails.
--- The same break rule as `section_of` applies.
--- @param body string The spec sidecar's markdown
--- @return {string} Gap descriptions, possibly empty
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
  local gaps: {string} = {}
  for _, name in ipairs(READY_SECTIONS) do
    if not filled[name:lower()] then
      gaps[#gaps + 1] = ("%s is missing or empty"):format(name)
    end
  end
  return gaps
end

--- The revision of a spec sidecar: a content digest of its body, so
--- two readings of the same text are the same revision and any edit is
--- a different one. A body of "" — an item with no sidecar — hashes to
--- a stable constant, which is the right answer rather than a case to
--- special-case: an item that has never had a spec has not changed one.
--- @param body string The spec sidecar's markdown, "" when it has none
--- @return string The revision, 64 lowercase hex characters
local function revision(body: string): string
  return hash.sha256_hex(body)
end

local record spec
  READY_SECTIONS: {string}
  ready_gaps: function(body: string): {string}
  section_of: function(body: string, name: string): string
  revision: function(body: string): string
end

local M: spec = {
  READY_SECTIONS = READY_SECTIONS,
  ready_gaps = ready_gaps,
  section_of = section_of,
  revision = revision,
}

return M
