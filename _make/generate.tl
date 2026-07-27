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

--- Run one generator, handing it the output directory it owns.
--- @param proj Project The scanned project
--- @param gen string The generator's path, relative to the root
--- @param dest string The output directory it owns, relative to the root
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function run_generator(proj: Project, gen: string, dest: string,
    cosmic: string): boolean, string
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

--- Run every `*_gen.tl` in the project: the SOURCE generators.
---
--- These run before the graph does, not after it, and that is the whole
--- difference between the two generator kinds. A payload generator
--- produces what an artifact CARRIES, so it runs once the tree is
--- compiled. A `*_gen.tl` produces INPUTS — `_types/*.d.tl` is the
--- case in hand — which the compiler, the checker, the formatter and
--- the linter all read. Running it after the graph would type-check
--- against whatever the last run left, which is the stale-output
--- failure the model exists to prevent.
---
--- Each owns `o/<its own path minus .tl>/` -- `_types/types_gen.tl`
--- fills `o/_types/types_gen/` -- so the output is reachable from the
--- generator's own position, and the directory holds NOTHING else.
---
--- Not `o/<its directory>`: that is where the graph's own per-file
--- bookkeeping for the generator's siblings lands (`o/_types/gentl.lua`,
--- `o/_types/gentl.tl.fmt.got`), so anything reading the generated set
--- by walking the directory would pick up build droppings. The artifact
--- ships this directory verbatim; it has to contain only what the
--- generator wrote.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function sources(proj: Project, cosmic: string): boolean, string
  for _, f in ipairs(proj.files) do
    if f.kind == "gen" then
      local dest = project.out_dir(f.path:sub(1, -#".tl" - 1))
      local ok, err = run_generator(proj, f.path, dest, cosmic)
      if not ok then
        return false, err
      end
    end
  end
  return true
end

--- Run one unit's generator, if it has one.
--- @param proj Project The scanned project
--- @param unit string The unit's directory, ROOT for the project itself
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function generate_unit(proj: Project, unit: string,
    cosmic: string): boolean, string
  -- Both spellings, because a marker is a name and `.lua` sources are
  -- first-class. The validator refuses a unit that carries both.
  for _, ext in ipairs({".tl", ".lua"}) do
    local name = project.PAYLOAD_GEN .. ext
    local gen = unit == project.ROOT and name or fs.join(unit, name)
    if fs.isfile(fs.join(proj.root, gen)) then
      return run_generator(proj, gen, project.out_dir(unit), cosmic)
    end
  end
  return true
end

--- Run every payload generator in the project, once each.
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
  sources: function(proj: Project, cosmic: string): boolean, string
end

local M: GenerateModule = {
  generate = generate,
  sources = sources,
}

return M
