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
--- Compiled output is cached content-hashed via script_cache, so a
--- script's .tl require tree compiles once per content+build, not once
--- per run. Compilation is lax — the same gradual-typing on-ramp as
--- running a script directly; --check-types remains the strict gate.
---
--- install() appends the searcher at the END of package.searchers so
--- the default Lua file searcher finds pre-compiled .lua modules
--- first; without this, setting TL_PATH costs ~330ms per run
--- recompiling cosmic's own modules (#377). Everything here loads
--- lazily on the first require() the default searchers cannot
--- resolve, so runs that never touch a .tl file never load the
--- ~15k-line Teal compiler.

--- The searcher: resolve, compile (or hit the cache), load.
--- @param module_name string Module name as passed to require()
--- @return any A loader function, or a string describing the miss
--- @return any The found filename (loader data)
local function cosmic_tl_searcher(module_name: string): any, any
  local teal = require("cosmic.teal")
  local found = teal.search_module(module_name)
  if not found then
    return "no .tl source found for module '" .. module_name .. "'"
  end
  local cache = require("cosmic._cli.script_cache")
  local code = cache.load(found)
  if not code then
    local result = teal.compile(found)
    if not result.ok then
      error("error loading module '" .. module_name .. "' from '"
        .. found .. "':\n" .. teal.format_issues(result.errors), 0)
    end
    code = result.code
    cache.store(found, code)
  end
  -- compile() preserves shebangs for CLI output, but load() on a
  -- string does not skip them (only luaL_loadfile does); blank the
  -- shebang line, keeping line numbers intact.
  local lua_code = code as string -- cast: nil ruled out by branches above
  if lua_code:sub(1, 2) == "#!" then
    lua_code = "--" .. lua_code:sub(3)
  end
  local chunk, lerr = load(lua_code, "@" .. found)
  if not chunk then
    error("error loading module '" .. module_name .. "': " .. tostring(lerr), 0)
  end
  return chunk, found
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
