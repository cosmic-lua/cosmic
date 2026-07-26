--- cosmic-owned runtime .tl package searcher (#669), replacing
--- tl.loader().
---
--- Public, and the caller set is what settled it (3g): the generated
--- embed wrapper runs `require("cosmic.searcher").install()` before the
--- entry of EVERY artifact anyone builds, which makes this the module
--- with the widest reach in the tree. It sat under `_cli/` — marked
--- internal — for as long as that was true. Same rule as `cosmic.style`
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
--- runner makes, so the two paths cannot drift. Compilation is lax —
--- the same gradual-typing on-ramp as running a script directly;
--- --check-types remains the strict gate.
---
--- install() appends the searcher at the END of package.searchers so
--- the default Lua file searcher finds pre-compiled .lua modules
--- first; without this, setting TL_PATH costs ~330ms per run
--- recompiling cosmic's own modules (#377). Everything here loads
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
  compile_cached: function(input_path: string): string | nil, string
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

local record SearcherModule
  install: function()
  searcher: function(module_name: string): any, any
end

local M: SearcherModule = {
  install = install,
  searcher = cosmic_tl_searcher,
}

return M
