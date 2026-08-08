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
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local build = require("_cli.build")
local modules = require("_cli.build.modules")
local deps = require("_make.deps")
local fetch = require("_make.fetch")
local project = require("_make.project")
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

--- The source a built path came from, and how the graph makes it: the
--- layout rule read backwards, the same inversion `_cli.build.modules`
--- does for imports.
---
--- BOTH spellings, because `.lua` sources are first-class. `deps` lists
--- one as `o/<path>.lua` exactly like a compiled module, and assuming
--- `.tl` skipped it here -- so the mini-graph never produced it, while
--- the manifest still named it. On a cold tree the generator's require
--- then hit the closure layer, found nothing at that path, and failed
--- loudly: a valid project broken on its FIRST build and only its
--- first, which is the worst shape a bug can take.
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
  local osec, onsec = out:mtim()
  local isec, insec = (into as fs.Stat):mtim() -- cast: same
  if osec ~= isec then
    return osec > isec
  end
  return onsec >= insec
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
  -- they are the default path and no path, which is why this branches on
  -- nil rather than on "". `cenv.get` says so in its type since #834;
  -- before that it erased the nil into its default and this line had to
  -- reach past it to `os.getenv`.
  local saved = cenv.get("LUA_PATH")
  local function restore()
    if saved == nil then
      local _ok, _err = cenv.unset("LUA_PATH")
    else
      local _ok, _err = cenv.set("LUA_PATH", saved)
    end
  end
  for _, path in ipairs(built) do
    local src, verb = source_of(proj, path)
    if src ~= nil and not fresh(proj, src, path) then
      -- The graph's own steps, called directly rather than
      -- reimplemented: one strict compile (or one copy, for a `.lua`
      -- source) with the write-only-when-changed contract. Going
      -- through `--compile-strict --output` instead would be a SECOND
      -- spelling of the same step, and that one writes to stdout unless
      -- both flags are given -- a difference nothing would have caught.
      local args: {string} = verb == "compile"
      and {cosmic, src, path, "--include-dir", "."}
      or {src, path}
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
  if fs.exists(at) then
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
  local flag, cerr = closure_argv(proj, gen, at, cosmic)
  if cerr ~= nil then
    return false, cerr
  end
  local argv: {string} = {cosmic}
  for _, a in ipairs(flag) do
    argv[#argv + 1] = a
  end
  argv[#argv + 1] = gen
  argv[#argv + 1] = dest
  -- TRANSITIONAL dual-shape dispatch (delete at the next pin advance,
  -- #981-class): the pinned binary's child.run returns a Result with
  -- spawn_error folded in; the tree's returns Result | nil, string.
  -- cast: transitional dual-shape call
  local run_dual = child.run as function({string}, child.Options): (any, any)
  local r_any, rerr = run_dual(argv,
    {stdout = "inherit", stderr = "inherit"})
  -- cast: transitional dual-shape probe
  local spawn_err = r_any ~= nil and (r_any as {string: any}).spawn_error or rerr
  if r_any == nil or spawn_err ~= nil then
    return false, "make: " .. gen .. ": " .. tostring(spawn_err or "start failed")
  end
  local r = r_any as child.Result -- cast: transitional dual-shape result
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
  if not next(found) then
    return "empty"
  end
  -- find_info keys are full paths (#987); the digest wants names
  -- relative to dir so the hash never moves with the tree's location.
  local names: {string} = {}
  for full in pairs(found) do
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
  for _, f in ipairs(proj.files) do
    if f.kind == "gen" then
      local dest = project.out_dir(stem_of(f.path))
      local ok, err = run_generator(proj, f.path, dest, cosmic)
      if not ok then
        return false, err
      end
    end
  end
  local sok, serr = stamp_types(proj)
  if not sok then
    return false, serr
  end
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
