--- The cosmic-owned runtime `.tl` package searcher, replacing tl.loader().
---
--- Public, and the caller set is what settled it: the generated
--- embed wrapper runs `require("cosmic.searcher").install()` before the
--- entry of EVERY artifact anyone builds, which makes this the module
--- with the widest reach in the tree. It sat under `_cli/` — marked
--- internal — for as long as that was true. Same rule as the pure lint checks (now `_tool.lint`)
--- in 3c: who requires a module decides whether it is internal, and a
--- manifest can hold that contradiction where position cannot.
---
--- Three guarantees tl's own loader did not make:
---
--- 1. Modules resolve through cosmic.teal's include dirs, so required
---    .d.tl markers always resolve and `is` narrowing never silently
---    degrades to a table test against a real userdata handle.
--- 2. One compile configuration: the same cosmic.teal env as
---    --compile, instead of tl's own env defaults.
--- 3. Loud failures: a module that fails to compile fails the
---    require() with the formatted issues. tl's loader ran tl.check
---    and generated code without ever looking at the type errors.
---
--- Compiled output is cached content-hashed, so a script's .tl require
--- tree compiles once per content+build, not once per run — through
--- `cosmic.teal.compile_cached`, which is the same call the script
--- runner makes, so the two paths cannot drift. install()'s runtime
--- searcher compiles lax — the same gradual-typing on-ramp as running
--- a script directly; --check types remains the strict gate — while
--- in-project tree resolution (install_manifest, layer 3) compiles
--- strict, so tree-first is never a downgrade from the binary's
--- already-checked bytes.
---
--- The ENTRY script stays lax either way, and that is decided, not
--- inherited (#840): a searcher only sees modules that pass through
--- require(), so `cosmic foo.tl` compiles foo.tl lax even inside a
--- project. The alternative — strict inside a project, lax outside —
--- is a second rule keyed on "which project am I in", precisely the
--- ambiguity _make/root.tl refuses to guess about, and it would
--- silently revoke the on-ramp for anyone running a script from a
--- directory that happens to be a project.
---
--- install() appends the searcher at the END of package.searchers so
--- the default Lua file searcher finds pre-compiled .lua modules
--- first; without this, setting TL_PATH costs ~330ms per run
--- recompiling cosmic's own modules. Everything here loads
--- lazily on the first require() the default searchers cannot
--- resolve, so runs that never touch a .tl file never load the
--- ~15k-line Teal compiler.
---
--- And in a STRIPPED artifact there is no compiler to load at all --
--- the floor keeps `cosmic/**` (this module included) and drops
--- `tl.lua`. Acquiring it is therefore fallible, and a failure is a
--- MISS, not an error: see `acquire_teal`.

--- The two entry points this searcher needs from cosmic.teal.
---
--- Named here because the compiler is acquired through pcall (see
--- `acquire_teal`), which erases the module's own type.
local record TealSearch
  search_module: function(module_name: string): string | nil
  compile_cached: function(input_path: string, opts?: {string: boolean}): string | nil, string
end

--- cosmic.teal, or nil in an artifact that carries no Teal compiler.
---
--- A stripped artifact carries this searcher (the floor keeps
--- `cosmic/**`) but not `tl.lua`, and `cosmic.teal` requires `tl` at
--- its top level -- so a plain require here THREW in every stripped
--- artifact, turning each ordinary miss into "module 'tl' not found",
--- an error about a compiler the artifact omits on purpose.
--- @return TealSearch|nil The compiler surface, or nil when absent
local function acquire_teal(): TealSearch | nil
  local ok, mod = pcall(require, "cosmic.teal")
  if not ok then
    return nil
  end
  return mod as TealSearch -- cast: from any (pcall erases the module type)
end

--- Resolve, compile (or hit the cache), load -- with a compiler in hand.
--- @param teal TealSearch The acquired cosmic.teal surface
--- @param module_name string Module name as passed to require()
--- @return any A loader function, or a string describing the miss
--- @return any The found filename (loader data)
local function search_with(teal: TealSearch, module_name: string): any, any
  local found = teal.search_module(module_name)
  if not found then
    return "no .tl source found for module '" .. module_name .. "'"
  end
  local code, cerr = teal.compile_cached(found)
  if not code then
    error("error loading module '" .. module_name .. "' from '"
      .. found .. "':\n" .. cerr, 0)
  end
  -- compile() preserves shebangs for CLI output, but load() on a
  -- string does not skip them (only luaL_loadfile does); blank the
  -- shebang line, keeping line numbers intact.
  local lua_code = code as string -- cast: nil ruled out by the guard above
  if lua_code:sub(1, 2) == "#!" then
    lua_code = "--" .. lua_code:sub(3)
  end
  local chunk, lerr = load(lua_code, "@" .. found)
  if not chunk then
    error("error loading module '" .. module_name .. "': " .. tostring(lerr), 0)
  end
  return chunk, found
end

--- The searcher installed into package.searchers.
---
--- A searcher that cannot help is contractually supposed to RETURN a
--- string, so require can aggregate every searcher's message into one
--- report; throwing aborts that aggregate and names the wrong missing
--- thing. Without a compiler this returns its miss like any other.
--- @param module_name string Module name as passed to require()
--- @return any A loader function, or a string describing the miss
--- @return any The found filename (loader data)
local function cosmic_tl_searcher(module_name: string): any, any
  local teal = acquire_teal()
  if teal is TealSearch then
    return search_with(teal, module_name)
  end
  return "no .tl searcher in this artifact (it carries no Teal compiler)"
end

local installed = false

--- Append the searcher to package.searchers. Idempotent (the embed
--- wrapper installs it before the app entry, which may itself be the
--- dispatcher that installs it too); no-op without package.searchers.
local function install()
  if installed or not package.searchers then
    return
  end
  installed = true
  table.insert(package.searchers, cosmic_tl_searcher)
end

--- ## In-project resolution
---
--- Everything above answers "the tree has a `.tl` and nothing else
--- does". What follows answers a different question, and it is the one
--- `docs/design/make/resolution.md` is about: **in a project, the tree
--- answers; outside one, the binary does.**
---
--- The searcher above is APPENDED, so `/zip/**` — the running binary's
--- own payload — wins every import the artifact happens to embed. For
--- an artifact running as itself that is exactly right. For a child the
--- build spawned inside a project it is not: a test then tests the
--- binary's modules rather than the tree's, and a generator runs its own
--- helpers from the previous generation. The one installed here is
--- INSERTED ahead of the default file searcher instead, so the tree
--- outranks the zip.
---
--- It activates only when the engine hands it a manifest, and the
--- manifest travels in argv (`--modules`), never the environment: ten
--- of this repo's own tests spawn a cosmic against a different project
--- root, and an inherited path would answer their imports out of THIS
--- tree while they build something else. That is the ambient-export
--- bug class, and it is why there is no env var.

--- Absolute project root, or nil when no manifest was installed.
local tree_root: string | nil = nil

--- import path -> built file, from the manifest's closure.
local tree_map: {string: string} = {}

--- The project's build directory, relative to the root.
local tree_build: string = "o"

--- Whether the tree searcher has already been inserted into
--- package.searchers -- guards install_manifest the same way `installed`
--- guards install(): a repeat call still refreshes tree_root/tree_map
--- from its manifest, but must not insert a second copy of the
--- searcher into the chain.
local tree_installed = false

--- Re-entrancy guard for the compile path below.
---
--- Resolving a module the closure does not name means compiling it, and
--- compiling means `require("cosmic.teal")`. If THAT require came back
--- through here it would recurse forever. While the guard is up this
--- searcher misses, so the compiler is loaded from the closure or from
--- `/zip` — never through itself.
local compiling = false

--- Load a file the graph already built.
--- @param path string The built `.lua` path
--- @param name string The module name, for the error
--- @return any A loader function
--- @return any The filename (loader data)
local function load_built(path: string, name: string): any, any
  local chunk, lerr = loadfile(path)
  if not chunk then
    error("error loading module '" .. name .. "' from '" .. path
      .. "': " .. tostring(lerr), 0)
  end
  return chunk, path
end

--- Compile a source in the project tree and load it.
---
--- STRICT, and the two halves of what that means are both deliberate.
--- Type errors fail the require: a module that does not type-check is
--- not one to run, and this is the layer that keeps a tree-first
--- resolution from being a downgrade from the binary's checked bytes.
--- Warnings do NOT fail it: werror is `--check types`'s contract, and
--- inheriting it here turns a shadowed local into a runtime failure of
--- whatever happened to require the file first. The gate stays the gate.
--- @param path string The source path
--- @param name string The module name, for the error
--- @return any A loader function
--- @return any The filename (loader data)
local function compile_tree(path: string, name: string): any, any
  compiling = true
  local teal = acquire_teal()
  if not (teal is TealSearch) then
    compiling = false
    return "no Teal compiler in this artifact for '" .. name .. "'"
  end
  -- pcall'd so a compile_cached throw still clears `compiling`: left up,
  -- it would fail every later tree resolution with "compiler bootstrap
  -- in progress" instead of just this one require.
  local ok, code, cerr = pcall(teal.compile_cached, path, {strict = true})
  compiling = false
  if not ok then
    error("error loading module '" .. name .. "' from '" .. path
      .. "': " .. tostring(code), 0)
  end
  if not code then
    error("error loading module '" .. name .. "' from '" .. path
      .. "':\n" .. tostring(cerr), 0)
  end
  local lua_code = code as string -- cast: nil ruled out by the guard above
  if lua_code:sub(1, 2) == "#!" then
    lua_code = "--" .. lua_code:sub(3)
  end
  local chunk, lerr = load(lua_code, "@" .. path)
  if not chunk then
    error("error loading module '" .. name .. "': " .. tostring(lerr), 0)
  end
  return chunk, path
end

--- Does this path name a readable file? `io.open` rather than
--- `cosmic.fs`, because this runs before the tree can answer for
--- `cosmic.fs` itself.
--- @param path string The path to test
--- @return boolean
local function readable(path: string): boolean
  local f = io.open(path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

--- The in-project searcher: closure, then the build directory, then
--- source.
---
--- All three are the same answer at different costs, which is what lets
--- the rule stay one sentence.
---
--- 1. **The closure** the manifest names. Exactly what this target
---    depends on, and make made those files before this process
---    started, so it is both a cache and a freshness guarantee.
--- 2. **The build directory.** Every verb that runs the project's own
---    code compiles the whole tree first (`prepare_stage`), so
---    `o/<path>.lua` is there and current for imports outside this
---    target's closure — the dispatcher's own modules, in a child the
---    build spawned. Without this step they were strict-compiled per
---    child instead: measured at 2.3 s for one probe test against 5 ms.
---    The freshness this leans on is the same the closure leans on;
---    a manifest pointed by hand at a `o/` nobody built is outside it.
--- 3. **Source**, strict-compiled. What covers a COMPUTED require:
---    `require(name)` with a runtime string is invisible to the import
---    scanner, so no closure names it and the graph may not have built
---    it. `_perf`'s scenario modules load exactly that way.
--- @param module_name string Module name as passed to require()
--- @return any A loader function, or a string describing the miss
--- @return any The found filename (loader data)
local function tree_searcher(module_name: string): any, any
  local built = tree_map[module_name]
  if built ~= nil then
    return load_built(built, module_name)
  end
  if tree_root == nil then
    return "no project manifest for '" .. module_name .. "'"
  end
  local rel = (module_name:gsub("%.", "/"))
  for _, suffix in ipairs({".lua", "/init.lua"}) do
    local path = tree_root .. "/" .. tree_build .. "/" .. rel .. suffix
    if readable(path) then
      return load_built(path, module_name)
    end
  end
  if compiling then
    return "compiler bootstrap in progress: '" .. module_name .. "'"
  end
  for _, suffix in ipairs({".tl", "/init.tl"}) do
    local path = tree_root .. "/" .. rel .. suffix
    if readable(path) then
      return compile_tree(path, module_name)
    end
  end
  return "no source in the project tree for '" .. module_name .. "'"
end

--- Read a manifest and install the in-project searcher.
---
--- The manifest is written by the engine into its own output directory
--- and named on the child's command line. Two line kinds, so a reader
--- never has to infer one from the other:
---
---     root <absolute project root>
---     build <build directory, relative to the root>
---     mod <import.path> <built file>
---
--- Inserted at index 2 — after `package.preload`, ahead of the default
--- file searcher — because beating `/zip` is the entire point. A
--- failure says why (#1001: the bare boolean was deliberately silent,
--- and the caller could not tell "no manifest" from "unreadable
--- manifest"); the CALLER decides whether that matters — a child with
--- no manifest is an ordinary cosmic, which is what a hand-run script
--- is.
--- @param path string Path to the manifest file
--- @return boolean Whether a manifest was read and installed
--- @return string? Why not, when it was not
local function install_manifest(path: string): boolean, string
  if not package.searchers then
    return false, "package.searchers is unavailable"
  end
  local f = io.open(path, "r")
  if not f then
    return false, "cannot read manifest: " .. path
  end
  local root: string | nil = nil
  local build: string | nil = nil
  local map: {string: string} = {}
  for line in f:lines() do
    local kind, rest = line:match("^(%S+)%s+(.*)$")
    if kind == "root" then
      root = rest
    elseif kind == "build" then
      build = rest
    elseif kind == "mod" then
      local name, file = rest:match("^(%S+)%s+(%S+)$")
      if name then
        map[name] = file
      end
    end
  end
  f:close()
  if root == nil then
    return false, "manifest has no root line: " .. path
  end
  tree_root = root
  tree_build = build or tree_build
  tree_map = map
  if not tree_installed then
    tree_installed = true
    table.insert(package.searchers, 2, tree_searcher)
  end
  return true
end

--- Find `--modules <manifest>` on an argv and install it.
---
--- The scan STOPS at the first argument that is not a flag, which is
--- where getopt stops parsing too: past that point a `--modules` is the
--- SCRIPT's own, and acting on it would let `cosmic s.tl --modules x`
--- redirect the dispatcher's requires. The engine always attaches its
--- own ahead of everything, so the two never disagree about whose it is.
---
--- Here rather than in the dispatcher because it is the channel's own
--- rule, and the channel is this module's.
--- @param argv {string} The process argv, 1-based
--- @return boolean Whether a manifest was read and installed
--- @return string? Why not, when a named manifest could not be (an
--- argv with no --modules at all returns false with NO message — that
--- is the ordinary case, not a failure)
local function install_argv_manifest(argv: {string}): boolean, string
  for i = 1, #argv do
    if argv[i] == "--modules" then
      return install_manifest(argv[i + 1] or "")
    elseif argv[i]:sub(1, 1) ~= "-" then
      return false
    end
  end
  return false
end

local record SearcherModule
  install: function()
  install_argv_manifest: function(argv: {string}): boolean, string
  install_manifest: function(path: string): boolean, string
end

local M: SearcherModule = {
  install = install,
  install_argv_manifest = install_argv_manifest,
  install_manifest = install_manifest,
}

return M
