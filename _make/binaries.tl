--- Which binaries a `build` selection names.
---
--- Split from the verb registry because it is a SELECTION RULE, and
--- selection is the one thing every verb shares: `build`'s targets are
--- binaries where `check`'s are sources, so the rule that turns paths
--- into targets lives beside the model rather than inside the row that
--- happens to use it.

local selection = require("_make.select")
local types = require("_make.types")

local type Binary = types.Binary
local type Project = types.Project

--- The binaries a selection names, or every binary when it names none.
---
--- Selection names targets of the verb's OWN KIND and never changes
--- what a target means -- the same rule `test` states as "selection
--- changes which tests run, never what gets staged". `build`'s targets
--- are binaries, so a path here names one: `cmd/foo`, `foo`, or the
--- entry itself. A path here names a BINARY, never a source: a
--- selection that narrowed the compile instead would make
--- `--make build cmd/foo` type-check a few files, produce no
--- `o/bin/foo`, and report PASS -- and leave the user who wants one
--- binary of a multi-binary project without a spelling for it.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths
--- @return {Binary}|nil The selected binaries, or nil when one names none
--- @return string The complaint
local function select_binaries(proj: Project, paths: {string}): {Binary} | nil, string
  if #paths == 0 then
    return proj.binaries
  end
  local out: {Binary} = {}
  local seen: {string: boolean} = {}
  for _, sel in ipairs(paths) do
    local hit = false
    for _, b in ipairs(proj.binaries) do
      if sel == b.name or selection.covers(sel, b.entry) then
        hit = true
        if not seen[b.name] then
          seen[b.name] = true
          out[#out + 1] = b
        end
      end
    end
    if not hit then
      return nil, "make: no binary named by: " .. sel ..
      "\nmake: build takes binaries; to type-check sources, use `check`"
    end
  end
  return out
end

local record BinariesModule
  select: function(proj: Project, paths: {string}): {Binary} | nil, string
end

local M: BinariesModule = {
  select = select_binaries,
}

return M
