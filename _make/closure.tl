--- The mini-graph: compile a generator's import closure before it runs,
--- and build the argv that hands it the manifest.

local build = require("_cli.build")
local cenv = require("cosmic.env")
local deps = require("_make.deps")
local fs = require("cosmic.fs")
local modules = require("_cli.build.modules")
local project = require("_make.project")
local seed = require("_make.seed")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- The source a built path came from, and how the graph makes it: the
--- layout rule read backwards, the same inversion `_cli.build.modules`
--- does for imports.
---
--- BOTH spellings, because `.lua` sources are first-class. `deps` lists
--- one as `o/<path>.lua` exactly like a compiled module, so assuming
--- `.tl` here would skip it: the mini-graph would never produce it
--- while the manifest still named it, and on a cold tree the
--- generator's `require` would hit the closure layer, find nothing at
--- that path, and fail loudly -- a valid project broken on its FIRST
--- build and only its first, the worst shape a bug can take.
--- @param proj Project The scanned project
--- @param built string A built path (`o/x/y.lua`)
--- @return string|nil The source path, or nil when there is no source
--- @return string The verb that makes it: "compile" or "copy"
local function source_of(proj: Project, built: string): string | nil, string
  local rel = built:sub(#project.BUILD_DIR + 2)
  local tl = (rel:gsub("%.lua$", ".tl"))
  if fs.is_file(fs.join(proj.root, tl)) then
    return tl, "compile"
  end
  if fs.is_file(fs.join(proj.root, rel)) then
    return rel, "copy"
  end
  return nil, ""
end

--- Is `built` at least as new as `src`? Mtime schedules, and this is
--- the scheduling half the graph gets for free from make and a phase
--- before the graph has to do for itself. Without it every verb paid
--- one subprocess compile per closure member per invocation, on a
--- no-op build too.
--- @param proj Project The scanned project
--- @param src string The source path, relative to the root
--- @param built string The built path, relative to the root
--- @return boolean True when the output is up to date
local function fresh(proj: Project, src: string, built: string): boolean
  local out = fs.stat(fs.join(proj.root, built))
  if not out then
    return false
  end
  local into = fs.stat(fs.join(proj.root, src))
  if not into then
    return false
  end
  local ot = out:modify_time()
  local it = (into as fs.Stat):modify_time() -- cast: same
  if ot.secs ~= it.secs then
    return ot.secs > it.secs
  end
  return ot.nsecs >= it.nsecs
end

--- Run one generator, handing it the output directory it owns.
---
--- CLEARED first, not merged into, and the engine does it rather than
--- the generator. A generator's output is a function of its inputs, so
--- an input that goes away has to take its output with it: a renamed
--- module leaving the old name behind means the artifact ships a file
--- no source produces, and the next `--make build` embeds it again.
--- Cosmic's own generator clears its directory itself, which makes
--- the whole class LOOK handled; a project whose generator does not
--- would ship stale payload with no way to notice short of
--- `--make clean`, so the engine clears for everyone.
---
--- Safe only because the directory is the GENERATOR's -- `o/<its path
--- minus extension>/` -- and holds nothing else. Handing a generator
--- `o/<unit>/` and clearing that would delete the build.
--- The mini-graph: compile a generator's import closure before running
--- it, and hand it a manifest naming what it just built.
---
--- A generator runs BEFORE the graph, so it has nothing built to
--- resolve through -- so without this closure compile it would
--- resolve its own helpers out of the RUNNING BINARY instead.
--- `_types/types_gen.tl` is not embedded so it comes from the tree,
--- while `_types/gentype_render.tl` is, so it would come from `/zip`:
--- one generator, two generations of code, where a one-line edit to a
--- helper would take two full builds to take effect, with the first
--- reporting PASS.
---
--- A graph before the graph, and small: `_types/types_gen.tl`'s closure
--- is 20 files of this repo's 375. It also does not deadlock on itself
--- -- strict-compiling a generator that produces the `cosmo.*`
--- declarations succeeds with `o/_types/types_gen/` absent, because
--- `_make.seed` has already run it once into `o/_types/types_seed`,
--- which this compile checks first; the bundled `/zip/.types` is the
--- fallback only for a project with no `_types/types_gen.tl` of its own.
--- @param proj Project The scanned project
--- @param gen string The generator's path, relative to the root
--- @param out string The generator's own output base for the manifest
--- @param cosmic string Absolute path to the cosmic binary
--- @return {string} The `--modules` argv fragment (empty when unavailable)
local function argv(proj: Project, gen: string, out: string,
    cosmic: string): {string}, string
  local self: File | nil = nil
  for _, f in ipairs(proj.files) do
    if f.path == gen then
      self = f
    end
  end
  if not (self is File) then
    -- LOUD, not a fall-through: a generator the model does not know
    -- about (excluded by `.cosmicignore`, or a path that never existed)
    -- has no closure to compile and no manifest to hand it, so running
    -- it anyway would be the stale-generation fall-through this whole
    -- mechanism exists to close -- silently, since nothing else here
    -- would explain why the manifest is missing.
    return {}, "make: " .. gen .. ": not a project file"
  end
  local files = deps.closure(proj, self, deps.index(proj))
  local built = deps.built_paths(files)
  if #built == 0 then
    return {}
  end
  -- `compile` sets LUA_PATH for the child it spawns. In a recipe step
  -- that child IS the process, so the mutation dies with it; called in
  -- process it would outlive the call and be inherited by every later
  -- child, which is a side effect nothing here asks for.
  -- Restoring has to tell an UNSET LUA_PATH from an empty one: to Lua
  -- they are the default path and no path, which is why this branches
  -- on nil rather than on "". `cenv.get`'s type distinguishes the two.
  local saved = cenv.get("LUA_PATH")
  local function restore()
    if saved == nil then
      local _ok, _err = cenv.unset("LUA_PATH")
    else
      local _ok, _err = cenv.set("LUA_PATH", saved)
    end
  end
  -- Ahead of "." below, so it wins over the fallback (see _make.seed).
  local seeded = fs.is_present(seed.SEED_DIR)
  for _, path in ipairs(built) do
    local src, verb = source_of(proj, path)
    if src ~= nil and not fresh(proj, src, path) then
      -- The graph's own steps, called directly rather than
      -- reimplemented: one strict compile (or one copy, for a `.lua`
      -- source) with the write-only-when-changed contract. Going
      -- through `--compile-strict --output` instead would be a SECOND
      -- spelling of the same step, and that one writes to stdout unless
      -- both flags are given -- a difference nothing would have caught.
      local args: {string} = verb ~= "compile" and {src, path}
      or seeded and {cosmic, src, path, "--include-dir", seed.SEED_DIR, "--include-dir", "."}
      or {cosmic, src, path, "--include-dir", "."}
      if build.dispatch(verb, args) ~= 0 then
        restore()
        -- LOUD, not a fall-through. Returning no manifest here would
        -- run the generator against the RUNNING BINARY's copy of its
        -- own helpers -- the stale-generation failure this whole
        -- mechanism exists to close -- and it would do it after
        -- printing a compile error, so the output looks explained.
        return {}, "make: " .. gen .. ": cannot build " .. path
      end
    end
  end
  restore()
  local manifest = modules.write(out, proj.root, built)
  if manifest == nil then
    return {}
  end
  return {"--modules", manifest}
end

local record ClosureModule
  argv: function(proj: Project, gen: string, out: string,
  cosmic: string): {string}, string
end

local M: ClosureModule = {
  argv = argv,
}

return M
