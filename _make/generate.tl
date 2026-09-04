--- The generation phase: run every unit's payload generator, once each.
---
--- Generation and staging run at different rates over different
--- things: generation is a phase over the PROJECT, running once
--- before any binary stages, while staging and embedding
--- (`_make.artifact`) run once per BINARY. `init.run_graph` invokes
--- the two separately, which is the boundary this file follows.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local closure = require("_make.closure")
local fetch = require("_make.fetch")
local project = require("_make.project")
local seed = require("_make.seed")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- Generators already run this INVOCATION, keyed by the absolute output
--- directory each one owns.
---
--- `graph_stage` runs `sources` before every graph verb, and `test`,
--- `example`, `coverage` (and `run`) each stage the binaries before
--- their own graph verb runs -- so one `--make ci` reaches
--- `run_generator` for the same generator many times over, and every
--- one of those calls clears and re-runs it. The tree does not move
--- between them: a graph verb's own stages never edit sources, so
--- the second call is paying full generator cost to reproduce what
--- the first already wrote. Memoized for the life of this process
--- only -- a fresh invocation (and `converge`'s re-exec into a freshly
--- built binary is exactly that, a new process) starts with this
--- table empty, which is required: the tree it runs against may not be
--- the one the last process saw.
local ran: {string: boolean} = {}

--- A path with its extension removed.
---
--- Handles both spellings: a `.lua` generator is as real as a `.tl`
--- one, and stripping only three characters would turn `foo_gen.lua`
--- into the output directory `o/foo_gen.` -- a trailing dot, which
--- `fs.make_dirs` refuses with EILSEQ and which is an invalid filename
--- on Windows, a platform cosmic targets.
--- @param path string A path with a `.tl` or `.lua` extension
--- @return string The path without it
local function stem_of(path: string): string
  return (path:gsub("%.tl$", ""):gsub("%.lua$", ""))
end

--- @param proj Project The scanned project
--- @param gen string The generator's path, relative to the root
--- @param dest string The output directory it owns, relative to the root
--- @param cosmic string Absolute path to the cosmic binary
--- @return boolean, string Success, or false plus the reason
local function run_generator(proj: Project, gen: string, dest: string,
    cosmic: string): boolean, string
  local at = fs.join(proj.root, dest)
  if ran[at] then
    return true
  end
  if fs.is_present(at) then
    local rok, rerr = fs.remove_all(at)
    if not rok then
      return false, "make: cannot clear " .. dest .. ": " ..
      (rerr or "unknown error")
    end
  end
  local mok, merr = fs.make_dirs(at)
  if not mok then
    return false, "make: cannot create " .. dest .. ": " ..
    (merr or "unknown error")
  end
  io.write("generate " .. gen .. "\n")
  local flag, cerr = closure.argv(proj, gen, at, cosmic)
  if cerr ~= nil then
    return false, cerr
  end
  local argv: {string} = {cosmic}
  for _, a in ipairs(flag) do
    argv[#argv + 1] = a
  end
  argv[#argv + 1] = gen
  argv[#argv + 1] = dest
  local r, rerr = child.run(argv,
    {stdout = "inherit", stderr = "inherit"})
  if r == nil then
    return false, "make: " .. gen .. ": " .. tostring(rerr or "start failed")
  end
  if not r.ok then
    return false, "make: " .. gen .. " failed"
  end
  ran[at] = true
  return true
end

--- Where the `cosmo.*`/`tl` declarations land: HARDCODED, not derived,
--- because `cosmic.teal`'s default_include_dirs() hardcodes this
--- same path first on every project's compile include path -- generator
--- or not, there is nothing per-project to carry as a variable.
--- teal_config_test.tl guards the tlconfig.lua mirror of that list;
--- nothing guards this one, so a rename of either has to touch both by
--- hand.
local TYPES_GEN_DIR < const > = "o/_types/types_gen"

--- Where its content-addressed stamp lands: BESIDE the directory, not
--- inside it. `run_generator` clears and rewrites `TYPES_GEN_DIR` on
--- every call (see its own doc above), so a file placed inside it gets
--- a fresh mtime on every run whether or not its bytes changed. A
--- sibling stamp, written only when the digest moves, is what lets a
--- compile rule depend on "did the generated types change" rather than
--- "did the generator run" -- the first is what a cosmos pin bump
--- actually changes, and the second is true on every single build.
local TYPES_STAMP < const > = TYPES_GEN_DIR .. ".stamp"

--- A deterministic digest of every file under `dir`: sorted relative
--- path and content, concatenated. Sorted so directory-walk order can
--- never move the hash, and content-based rather than mtime-based so
--- the digest is exactly as stable as the generator's OUTPUT bytes,
--- never as stable as its last run.
--- @param dir string Absolute path to the directory to digest
--- @return string Hex digest; a fixed sentinel when the directory has
--- nothing (absent, or a project with no generator at all)
local function digest_of(dir: string): string
  local found = fs.find_info(dir)
  if not found then
    return "empty"
  end
  if not next(found.files) then
    return "empty"
  end
  -- find_info keys are full paths; the digest wants names relative to
  -- dir so the hash never moves with the tree's location.
  local names: {string} = {}
  for full in pairs(found.files) do
    names[#names + 1] = full:sub(#dir + 2)
  end
  table.sort(names)
  local parts: {string} = {}
  for _, rel in ipairs(names) do
    parts[#parts + 1] = rel
    parts[#parts + 1] = fs.read(fs.join(dir, rel)) or ""
  end
  return hash.sha256_hex(table.concat(parts, "\x00"))
end

--- Refresh the generated-types stamp.
---
--- Runs for every project, generator or not: `TYPES_GEN_DIR` sits on
--- every compile's include path regardless (see above), so a compile
--- rule that depends on the stamp needs it to always resolve to a real
--- file -- even a project with no `_types/types_gen.tl` gets one, whose
--- digest is the "empty" sentinel. Written only when the bytes differ
--- (graph.tl's own `write_if_changed` contract, kept local here rather
--- than imported: pulling in `_make.graph` for one four-line helper
--- would not fit under its own 500-line cap), so a no-op run leaves the
--- stamp's mtime alone.
--- @param proj Project The scanned project
--- @return boolean, string Success, or false plus the reason
local function stamp_types(proj: Project): boolean, string
  local path = fs.join(proj.root, TYPES_STAMP)
  local content = digest_of(fs.join(proj.root, TYPES_GEN_DIR)) .. "\n"
  if fs.read(path) == content then
    return true
  end
  if not fs.make_dirs(fs.dirname(path)) then
    return false, "make: cannot create " .. fs.dirname(TYPES_STAMP)
  end
  local wok, werr = fs.write(path, content)
  if not wok then
    return false, "make: cannot write " .. TYPES_STAMP .. ": " ..
    (werr or "unknown error")
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
  -- Carried patches repair first: a cold tree's fetch may have run
  -- under a pinned release that predates a patch, and the repair is
  -- local — the digest-verified archive is already on disk (see
  -- _make.patch). Before the generators, because they read the pinned
  -- trees this repairs; `fetch` (which applies patches itself) and
  -- `clean` never reach this phase, so neither pays for it.
  local rok, rerr = fetch.repair(proj)
  if not rok then
    return false, rerr
  end
  -- Before any closure compiles below -- see _make.seed.
  if seed.should_seed(proj) then
    local seedok, seederr = seed.run(proj, cosmic)
    if not seedok then
      return false, seederr
    end
  end
  -- UNCONDITIONAL: skipping `cleanup` on a failure below leaves
  -- `SEED_DIR` for `should_seed` to trust next time (_make.seed).
  local ok, err = true, ""
  for _, f in ipairs(proj.files) do
    if ok and f.kind == "gen" then
      local dest = project.out_dir(stem_of(f.path))
      ok, err = run_generator(proj, f.path, dest, cosmic)
    end
  end
  if ok then
    ok, err = stamp_types(proj)
  end
  local cok, cerr = seed.cleanup()
  if not ok then
    return false, err
  end
  if not cok then
    return false, cerr
  end
  -- Its one job done: `o/_types/types_gen` is the only declaration set left.
  return true
end

--- Is `f` the payload generator `unit` owns, spelled `name`?
--- @param unit string The unit's directory, ROOT for the project itself
--- @param name string The generator's basename (`embed_gen.tl` or `.lua`)
--- @param f File A candidate file
--- @return boolean
local function owns(unit: string, name: string, f: File): boolean
  if f.kind ~= "payload-gen" or fs.basename(f.path) ~= name then
    return false
  end
  local dir = f.path == name and project.ROOT or fs.dirname(f.path)
  return dir == unit
end

--- Run one unit's generator, if it has one.
---
--- Asks the MODEL, not the disk: `proj.files` is what `.cosmicignore`
--- and every other scan rule already filtered, so a payload generator
--- excluded there stays excluded here too. Probing `fs.is_file` directly
--- would run a generator the model does not know about -- silently, on
--- output the engine can't attribute to any project file.
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
    for _, f in ipairs(proj.files) do
      if owns(unit, name, f) then
        -- `o/<unit>/embed_gen`, which is `o/<gen path minus extension>`:
        -- the same rule the source generators get, so every generator
        -- owns one directory and the engine may clear it. NOT
        -- `o/<unit>/`, which is the build's.
        return run_generator(proj, f.path, project.out_dir(stem_of(f.path)),
          cosmic)
      end
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
--- per binary. Hung off `build` instead, it would run only while the
--- root binary was being built, so a project with only `cmd/` binaries
--- would never run it at all, and a project with both would stage
--- whatever the previous run had left, depending on which binary name
--- sorted first.
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
