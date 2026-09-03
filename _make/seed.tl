--- The `o/_types/types_gen` seed pass: fill it from the fetched pins
--- BEFORE any generator's import closure compiles.
---
--- `_teal_engine.default_include_dirs` hardcodes `o/_types/types_gen`
--- first on every project's compile include path, generator or not.
--- On a cold tree that directory does not exist yet, so
--- `generate.closure_argv` -- which strict-compiles a generator's own
--- import closure before running it -- resolves `cosmo.*`/`tl` types
--- through the fallback instead: the RUNNING binary's bundled
--- `/zip/.types`, from whatever release built this tree. A closure
--- member adapted to a NEW `cosmo.*` shape (the one `3p/cosmos` pin
--- this tree just fetched actually carries) fails against that old
--- shape before the real generated types exist to check it against.
---
--- This pass closes the gap the only way available before the graph
--- exists: run the types generator itself, UNCLOSED, straight against
--- the running binary's own helpers -- exactly the fallback
--- `closure_argv`'s doc already describes, taken once, deliberately,
--- so the real closure compile that follows never has to.
local child = require("cosmic.child")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local types = require("_make.types")

local type Project = types.Project

--- The one generator this repo owns whose output every project's
--- compile include path hardcodes. Only a project that owns this exact
--- file (this repo) ever seeds; a downstream project or `--make`
--- fixture that owns no such file is untouched.
local TYPES_GEN < const > = "_types/types_gen.tl"

--- Where the seed pass writes, relative to the project root. Separate
--- from `TYPES_GEN`'s own owned directory (`o/_types/types_gen`, which
--- `run_generator` clears and rewrites on the real run) so a seed
--- failure can never corrupt or partially populate the directory the
--- graph, the stamp digest, and `cmd/cosmic/embed_gen.tl` all read.
local SEED_DIR < const > = "o/_types/types_seed"

--- Whether `proj` needs a seed pass before its generators' closures
--- compile.
---
--- Asks the MODEL, never the disk, for the first half: a project that
--- does not declare `_types/types_gen.tl` as a `gen` file -- every
--- downstream project, every `_make/testdata` fixture -- has no such
--- generator to run and never seeds. The second half reads disk on
--- purpose: once the real generator has produced `o/_types/types_gen`,
--- that IS the seed for every later closure compile this invocation
--- makes, so seeding again would only pay the cost for nothing.
--- @param proj Project The scanned project
--- @return boolean
local function should_seed(proj: Project): boolean
  local has_gen = false
  for _, f in ipairs(proj.files) do
    if f.path == TYPES_GEN and f.kind == "gen" then
      has_gen = true
      break
    end
  end
  if not has_gen then
    return false
  end
  return not fs.is_present(fs.join(proj.root, "o/_types/types_gen"))
end

--- Run the seed pass.
---
--- Clears `SEED_DIR` first, the way `run_generator` clears the
--- directory it owns -- a stale file left behind by an earlier failed
--- run is not a seed, and would be trusted as one. Runs `TYPES_GEN`
--- with no `--modules` manifest and `LUA_PATH` unset for the child, so
--- its own requires resolve out of the RUNNING BINARY exactly as they
--- would with no closure computed at all -- the fallback `closure_argv`
--- already takes when `o/_types/types_gen` is absent, here taken on
--- purpose before that closure compile runs at all.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function run(proj: Project, cosmic: string): boolean, string
  local at = fs.join(proj.root, SEED_DIR)
  if fs.is_present(at) then
    local rok, rerr = fs.remove_all(at)
    if not rok then
      return false, "make: seed failed: cannot clear " .. SEED_DIR .. ": " ..
      (rerr or "unknown error")
    end
  end
  local saved = cenv.get("LUA_PATH")
  local function restore()
    if saved == nil then
      local _ok, _err = cenv.unset("LUA_PATH")
    else
      local _ok, _err = cenv.set("LUA_PATH", saved)
    end
  end
  local _ok, _uerr = cenv.unset("LUA_PATH")
  local r, rerr = child.run({cosmic, TYPES_GEN, SEED_DIR},
    {stdout = "inherit", stderr = "inherit"})
  restore()
  if r == nil then
    return false, "make: seed failed: " .. tostring(rerr or "start failed")
  end
  if not r.ok then
    return false, "make: seed failed: " .. TYPES_GEN .. " failed"
  end
  return true
end

--- Remove `SEED_DIR` once the real generator output exists. Relative,
--- like `run`'s own path use -- both rely on the cwd-is-project-root
--- invariant `_make.init` already holds for the whole `sources` call.
--- @return boolean, string Success, or false plus the reason
local function cleanup(): boolean, string
  if not fs.is_present(SEED_DIR) then
    return true
  end
  local ok, err = fs.remove_all(SEED_DIR)
  if not ok then
    return false, "make: cannot clear " .. SEED_DIR .. ": " .. (err or "unknown error")
  end
  return true
end

local record SeedModule
  SEED_DIR: string
  should_seed: function(proj: Project): boolean
  run: function(proj: Project, cosmic: string): boolean, string
  cleanup: function(): boolean, string
end

local M: SeedModule = {
  SEED_DIR = SEED_DIR,
  should_seed = should_seed,
  run = run,
  cleanup = cleanup,
}

return M
