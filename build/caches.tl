--- The host caches a test may declare it writes (`cosmic.test`'s
--- `Needs.caches`), by name, and where each is on this host.
---
--- A cache here is content-addressed: what a tool finds in it is what it
--- would have made again, so it only saves time and never changes a
--- result. That is why none enters a verdict's key, and why a test's
--- read or write of one is no input the audit asks a declaration of,
--- beyond the name.
---
--- - `zig`: the pinned zig `bin/zig` runs and the caches it builds in --
---   its installs (`Fs.cache_path("zig")`, build/zig.tl's `locate`), its
---   global cache and the project cache (`Zig.cache_paths`, where
---   `Zig.global_cache` and `Zig.project_cache` put them), overrides
---   (COSMIC_ZIG_GLOBAL_CACHE, COSMIC_ZIG_CACHE, and ZIG_GLOBAL_CACHE_DIR
---   and ZIG_LOCAL_CACHE_DIR for a command other than `build`) included.
--- - `bootstrap`: the bootstrap cosmic `bin/cosmic-bootstrap` fetches,
---   cached by digest, and the cores a portable cosmic's launcher
---   extracts (build/launcher.tl), COSMIC_PORTABLE_CACHE included.

local Fs = require("cosmic.fs")

--- The names a declaration may give are `build.cache_names`', which the
--- analyzer checks a declaration against, and so are the variables that
--- locate each (`cache_names.variables`).
local record caches
end

--- Where the cache `name` is for a tree at `root`, with `environment`
--- the variables that locate it: each directory, absolute, whether it
--- is there yet or not -- nothing is made or looked at. None for a name that is no cache, or where
--- neither XDG_CACHE_HOME nor HOME names a cache directory (build/zig.tl
--- then keeps zig's caches under `root`/o, the tree's own).
-- TODO: take the bootstrap cosmic's and the launcher's cores directory
-- from the code that decides them, once either is Teal: today
-- bin/cosmic-bootstrap and build/launcher.tl's shell each spell
-- `Fs.cache_path`'s rule again, which this follows.
local function paths(name: string, root: string, environment: {string:string}): {string}
  local out: {string} = {}
  local function add(path: string | nil)
    if path == nil or path:sub(1, 1) ~= "/" or Fs.within(path, root) then return end
    for _, have in ipairs(out) do
      if have == path then return end
    end
    out[#out + 1] = path
  end
  if name == "zig" then
    -- Required here, not above: only the zig cache's paths need
    -- build/zig.tl, and what it reaches of the standard library.
    local Zig = require("build.zig")
    local installs, _ = Fs.cache_path("zig", environment)
    add(installs)
    for _, path in ipairs(Zig.cache_paths(root, environment)) do add(path) end
    -- Where a zig command other than `build` keeps them, when the
    -- caller names its own (`Zig.passthrough_environment`).
    add(environment.ZIG_GLOBAL_CACHE_DIR)
    add(environment.ZIG_LOCAL_CACHE_DIR)
  elseif name == "bootstrap" then
    local bootstrap, _ = Fs.cache_path("bootstrap", environment)
    add(bootstrap)
    local portable = environment.COSMIC_PORTABLE_CACHE
    if portable ~= nil then
      add(portable)
    else
      local cores, _ = Fs.cache_path("cores", environment)
      add(cores)
    end
  end
  return out
end

--- Every directory the caches `names` are, as `paths` finds each.
function caches.all(names: {string}, root: string, environment: {string:string}): {string}
  local out: {string} = {}
  for _, name in ipairs(names) do
    for _, path in ipairs(paths(name, root, environment)) do out[#out + 1] = path end
  end
  return out
end

--- Makes each of `directories` that is not there, with its parents. False and
--- why for the first that could not be made.
function caches.make(directories: {string}): boolean, string
  for _, path in ipairs(directories) do
    local made, trouble = Fs.mkdirs(path)
    if not made then return false, path .. ": " .. trouble end
  end
  return true, ""
end

return caches
