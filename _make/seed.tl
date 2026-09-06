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
---
--- The RUNNING binary here is `bin/cosmic.pin`'s trust root, not the
--- tree's own build -- a fresh load of its Teal engine inside that
--- process resolves to ITS embedded copy, not the tree's source, so a
--- tree-side default-include-dirs change cannot teach the running
--- binary a new path; only what its ALREADY-COMPILED code already
--- reads (an explicit CLI flag, an env var, or a hardcoded default
--- like `o/_types/types_gen` itself) can. That default is also the
--- ONLY path the interpreted searcher's own on-demand compile of an
--- arbitrary module -- `_cli/main_handlers.tl` (main.lua's own
--- unconditional require), or any `cosmic/*.tl` a generator's run
--- happens to reach -- ever consults; those never receive the
--- `--include-dir` flags `closure_argv` attaches to a generator
--- SCRIPT's own compile step. So `run` below promotes the seed
--- straight into `o/_types/types_gen` once it succeeds, atomically,
--- rather than leaving it at a separate directory nothing but the one
--- explicit flag ever finds.
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

--- Where the seed pass stages its output before promoting it into
--- `TYPES_GEN`'s own owned directory (`o/_types/types_gen`, which
--- `run_generator` clears and rewrites on the real run), relative to
--- the project root. Staged here first, separately, so a seed failure
--- can never corrupt or partially populate `o/_types/types_gen` itself
--- -- `run` only promotes a COMPLETE staged directory, atomically.
local SEED_DIR < const > = "o/_types/types_seed"

--- Where `run` promotes a successful seed to -- the same directory
--- `TYPES_GEN`'s real run owns, and the one path every project's
--- compile include list (`_teal_engine.default_include_dirs`)
--- hardcodes. Named apart from `TYPES_GEN` (the generator's source
--- path) for readability at each call site below.
local TYPES_GEN_DIR < const > = "o/_types/types_gen"

--- Whether `proj` needs a seed pass before its generators' closures
--- compile.
---
--- Asks the MODEL, never the disk, for the first half: a project that
--- does not declare `_types/types_gen.tl` as a `gen` file -- every
--- downstream project, every `_make/testdata` fixture -- has no such
--- generator to run and never seeds. The second half reads disk on
--- purpose: once the real generator has produced `o/_types/types_gen`,
--- that IS the seed for every later closure compile this invocation
--- makes, so seeding again would only pay the cost for nothing --
--- UNLESS `SEED_DIR` is also still sitting there. A generator's own
--- output existing is proof that generator ran; it is not proof
--- `cleanup` ever ran, so a `SEED_DIR` that outlived it (an invocation
--- killed before reaching `sources`'s own cleanup call, see
--- `_make.generate`) is a leftover, not a validated seed -- re-run
--- rather than trust it.
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
  if not fs.is_present(fs.join(proj.root, TYPES_GEN_DIR)) then
    return true
  end
  return fs.is_present(fs.join(proj.root, SEED_DIR))
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
---
--- On success, promotes the staged output into `TYPES_GEN_DIR` itself
--- with one `fs.move` -- an atomic same-filesystem rename, not a copy
--- -- so every consumer of the hardcoded default (the interpreted
--- searcher's on-demand compiles included, never just the one
--- generator-script compile `closure_argv` flags explicitly) sees the
--- seed at the one path they all already know. `should_seed` above
--- only ever calls `run` when `TYPES_GEN_DIR` is absent (or a prior
--- run's `SEED_DIR` was left dangling), so there is never a real
--- directory here for the rename to clobber.
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
  local gen_at = fs.join(proj.root, TYPES_GEN_DIR)
  local promoted, perr = fs.move(at, gen_at)
  if not promoted then
    return false, "make: seed failed: cannot promote " .. SEED_DIR .. " to " ..
    TYPES_GEN_DIR .. ": " .. (perr or "unknown error")
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
  TYPES_GEN_DIR: string
  should_seed: function(proj: Project): boolean
  run: function(proj: Project, cosmic: string): boolean, string
  cleanup: function(): boolean, string
end

local M: SeedModule = {
  SEED_DIR = SEED_DIR,
  TYPES_GEN_DIR = TYPES_GEN_DIR,
  should_seed = should_seed,
  run = run,
  cleanup = cleanup,
}

return M
