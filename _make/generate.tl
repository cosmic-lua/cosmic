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
local build = require("_cli.build")
local modules = require("_cli.build.modules")
local deps = require("_make.deps")
local project = require("_make.project")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- A path with its extension removed.
---
--- Both spellings, because a marker is a name: stripping a fixed three
--- characters turned `foo_gen.lua` into the output directory
--- `o/foo_gen.` -- a trailing dot, which makedirs refused with EILSEQ
--- and which is an invalid filename on Windows, a platform cosmic
--- targets. The classifier had just been taught that `.lua` generators
--- are real; this is the runner catching up.
--- @param path string A path with a `.tl` or `.lua` extension
--- @return string The path without it
local function stem_of(path: string): string
  return (path:gsub("%.tl$", ""):gsub("%.lua$", ""))
end

--- The source a built path came from: the graph's layout rule read
--- backwards, the same inversion `_cli.build.modules` does for imports.
--- @param built string A built path (`o/x/y.lua`)
--- @return string The source path (`x/y.tl`)
local function source_of(built: string): string
  local rel = built:sub(#project.BUILD_DIR + 2)
  return (rel:gsub("%.lua$", ".tl"))
end

--- Run one generator, handing it the output directory it owns.
---
--- CLEARED first, not merged into, and the engine does it rather than
--- the generator. A generator's output is a function of its inputs, so
--- an input that goes away has to take its output with it: a renamed
--- module leaving the old name behind means the artifact ships a file
--- no source produces, and the next `--make build` embeds it again.
--- Cosmic's own generator happened to clear its directory itself,
--- which made the whole class look handled; a project whose generator
--- does not would have shipped stale payload with no way to notice
--- short of `--make clean`.
---
--- Safe only because the directory is the GENERATOR's -- `o/<its path
--- minus extension>/` -- and holds nothing else. Handing a generator
--- `o/<unit>/` and clearing that would delete the build.
--- The mini-graph: compile a generator's import closure before running
--- it, and hand it a manifest naming what it just built.
---
--- A generator runs BEFORE the graph, so it has nothing built to
--- resolve through -- and until this existed it resolved its own
--- helpers out of the RUNNING BINARY. `_types/types_gen.tl` is not
--- embedded so it came from the tree, while `_types/gentype_render.tl`
--- is, so it came from `/zip`: one generator, two generations of code,
--- and a one-line edit to a helper took two full builds to take effect
--- with the first reporting PASS. See docs/design/make/resolution.md.
---
--- A graph before the graph, and small: `_types/types_gen.tl`'s closure
--- is 20 files of this repo's 375. It also does not deadlock on itself
--- -- strict-compiling a generator that produces the `cosmo.*`
--- declarations succeeds with `o/_types/types_gen/` absent, because the
--- include path falls back to the bundled `/zip/.types`. That fallback
--- is the one place a build reads the running binary's bytes on
--- purpose.
--- @param proj Project The scanned project
--- @param gen string The generator's path, relative to the root
--- @param out string The generator's own output base for the manifest
--- @param cosmic string Absolute path to the cosmic binary
--- @return {string} The `--modules` argv fragment (empty when unavailable)
local function closure_argv(proj: Project, gen: string, out: string,
    cosmic: string): {string}
  local self: File | nil = nil
  for _, f in ipairs(proj.files) do
    if f.path == gen then
      self = f
    end
  end
  if not (self is File) then
    return {}
  end
  -- cast: narrowing does not survive the guard above
  local files = deps.closure(proj, self as File, deps.index(proj))
  local built = deps.built_paths(files)
  if #built == 0 then
    return {}
  end
  for _, path in ipairs(built) do
    local src = source_of(path)
    if fs.isfile(fs.join(proj.root, src)) then
      -- The graph's own compile step, called directly rather than
      -- reimplemented: it is one strict compile with the
      -- write-only-when-changed contract, so a generator whose closure
      -- did not move costs a hash and no work. Going through
      -- `--compile-strict --output` instead would be a SECOND spelling
      -- of the same step, and that one writes to stdout unless both
      -- flags are given -- a difference nothing would have caught.
      if build.dispatch("compile", {cosmic, src, path,
          "--include-dir", "."}) ~= 0 then
        return {}
      end
    end
  end
  local manifest = modules.write(out, proj.root, built)
  if manifest == nil then
    return {}
  end
  return {"--modules", manifest as string} -- cast: nil ruled out above
end

--- @param proj Project The scanned project
--- @param gen string The generator's path, relative to the root
--- @param dest string The output directory it owns, relative to the root
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function run_generator(proj: Project, gen: string, dest: string,
    cosmic: string): boolean, string
  local at = fs.join(proj.root, dest)
  if fs.exists(at) then
    local rok, rerr = fs.rmrf(at)
    if not rok then
      return false, "make: cannot clear " .. dest .. ": " ..
      (rerr or "unknown error")
    end
  end
  local mok, merr = fs.makedirs(at)
  if not mok then
    return false, "make: cannot create " .. dest .. ": " ..
    (merr or "unknown error")
  end
  io.write("generate " .. gen .. "\n")
  local argv: {string} = {cosmic}
  for _, a in ipairs(closure_argv(proj, gen, at, cosmic)) do
    argv[#argv + 1] = a
  end
  argv[#argv + 1] = gen
  argv[#argv + 1] = dest
  local r, rerr = child.run(argv,
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
      local dest = project.out_dir(stem_of(f.path))
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
  -- first-class. `.tl` first, and the validator refuses a unit that
  -- carries both -- so the order is a tiebreak that never happens.
  for _, ext in ipairs({".tl", ".lua"}) do
    local name = project.PAYLOAD_GEN .. ext
    local gen = unit == project.ROOT and name or fs.join(unit, name)
    if fs.isfile(fs.join(proj.root, gen)) then
      -- `o/<unit>/embed_gen`, which is `o/<gen path minus extension>`:
      -- the same rule the source generators get, so every generator
      -- owns one directory and the engine may clear it. NOT
      -- `o/<unit>/`, which is the build's.
      return run_generator(proj, gen, project.out_dir(stem_of(gen)), cosmic)
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
