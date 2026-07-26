--- The generation phase: run every unit's payload generator, once each.
---
--- Split from `_make.artifact` on the seam the code already had. The
--- two halves run at different rates and over different things:
--- generation is a phase over the PROJECT, running once before any
--- binary stages, while staging and embedding run once per BINARY.
--- `init.run_graph` already invoked them separately; only the file
--- boundary was missing, and `artifact.tl` was 36 lines under a hard
--- cap with six jobs in it. A split drawn under cap pressure lands
--- wherever the line count falls; this one is drawn where the runtime
--- boundary already is.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

--- Run one unit's generator, if it has one.
--- @param proj Project The scanned project
--- @param unit string The unit's directory, ROOT for the project itself
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function generate_unit(proj: Project, unit: string,
    cosmic: string): boolean, string
  local gen = unit == project.ROOT and project.PAYLOAD_GEN
  or fs.join(unit, project.PAYLOAD_GEN)
  if not fs.isfile(fs.join(proj.root, gen)) then
    return true
  end
  local dest = project.out_dir(unit)
  local mok, merr = fs.makedirs(fs.join(proj.root, dest))
  if not mok then
    return false, "make: cannot create " .. dest .. ": " ..
    (merr or "unknown error")
  end
  io.write("generate " .. gen .. "\n")
  local r, rerr = child.run({cosmic, gen, dest},
    {stdout = "inherit", stderr = "inherit"})
  if not (r is child.Result) then
    return false, "make: " .. gen .. ": " .. (rerr or "unknown error")
  end
  -- cast: narrowing does not survive the early-exit guard above
  if not (r as child.Result).ok then
    return false, "make: " .. gen .. " failed"
  end
  return true
end

--- Run every generator in the project, once each.
---
--- A phase over the project rather than a step inside `build`, and the
--- distinction is load-bearing: the ROOT payload is staged into every
--- binary (root `embed/` is shared the way a root package is), so the
--- root generator has to run before any binary stages — once, not once
--- per binary. Hung off `build`, it ran only while the root binary was
--- being built, so a project with only `cmd/` binaries never ran it at
--- all, and a project with both staged whatever the previous run had
--- left depending on which binary name sorted first.
---
--- Generation stays inside the build verb rather than becoming a verb
--- of its own, because a generator whose output a binary embeds is in
--- that binary's build closure: building without running it embeds the
--- last run's payload, the stale-output failure the model exists to
--- prevent. It runs in the artifact phase rather than as a make rule
--- because the artifact does: the graph compiles, then staging and
--- embedding happen here.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function generate(proj: Project, cosmic: string): boolean, string
  local ok, err = generate_unit(proj, project.ROOT, cosmic)
  if not ok then
    return false, err
  end
  for _, b in ipairs(proj.binaries) do
    if b.dir ~= project.ROOT then
      local bok, berr = generate_unit(proj, b.dir, cosmic)
      if not bok then
        return false, berr
      end
    end
  end
  return true
end

local record GenerateModule
  generate: function(proj: Project, cosmic: string): boolean, string
end

local M: GenerateModule = {
  generate = generate,
}

return M
