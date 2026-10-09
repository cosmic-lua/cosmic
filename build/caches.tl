--- The host caches a test may declare it writes ([`cosmic.test`]'s
--- [`Needs.caches`]), by name, and where each is on this host.
---
--- A cache here is content-addressed: what a tool finds in it is what it
--- would have made again, so it only saves time and never changes a
--- result. That is why none enters a verdict's key, and why a test
--- declares one by its name alone.
---
--- - `zig`: the pinned zig [`bin/zig`] runs and the caches it builds in --
---   its installs (`Fs.cache_dir("zig", { make = false })`, build/zig.tl's `locate`), its
---   global cache and the project cache ([`build.zig_caches`], where
---   [`Zig.global_cache`] and [`Zig.project_cache`] put them), overrides
---   (COSMIC_ZIG_GLOBAL_CACHE, COSMIC_ZIG_CACHE, and ZIG_GLOBAL_CACHE_DIR
---   and ZIG_LOCAL_CACHE_DIR for a command other than `build`) included.
--- - `bootstrap`: the bootstrap cosmic [`bin/cosmic-bootstrap`] fetches,
---   cached by digest, and the cores a portable cosmic's launcher
---   extracts (build/launcher.tl), COSMIC_PORTABLE_CACHE included.

local Fs = require("cosmic.fs")
local zig_caches = require("build.zig_caches")

--- The names a declaration may give are [`build.cache_names`]', which the
--- analyzer checks a declaration against, and so are the variables that
--- locate each ([`cache_names.variables`]).
local record caches
  cores: function(environment: {string:string}): string | nil
end

--- Where the cache `name` is for a tree at `root`, with `environment`
--- the variables that locate it: each directory, absolute, whether it is
--- there yet or not; nothing is made or looked at. None for a name that
--- is no cache, or where neither XDG_CACHE_HOME nor HOME names a cache
--- directory (build/zig.tl then keeps zig's caches in the tree's build
--- directory, which COSMIC_BUILD_HOME alone can name then).
-- TODO: take the bootstrap cosmic's and the launcher's cores directory
-- from the code that decides them, once either is Teal: today
-- bin/cosmic-bootstrap and build/launcher.tl's shell each spell
-- [`Fs.cache_dir`]'s rule again, which this follows.
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
    local installs, _ = Fs.cache_dir("zig", { environment = environment, make = false })
    add(installs)
    for _, path in ipairs(zig_caches.paths(root, environment)) do add(path) end
    -- Where a zig command other than `build` keeps them, when the
    -- caller names its own ([`Zig.passthrough_environment`]).
    add(environment.ZIG_GLOBAL_CACHE_DIR)
    add(environment.ZIG_LOCAL_CACHE_DIR)
  elseif name == "bootstrap" then
    local bootstrap, _ = Fs.cache_dir("bootstrap", { environment = environment, make = false })
    add(bootstrap)
    add(caches.cores(environment))
  end
  return out
end

--- Where a portable cosmic's launcher extracts its cores, with
--- `environment` the variables that locate it: COSMIC_PORTABLE_CACHE,
--- or the `cores` cache ([`Fs.cache_dir`]). Nil where neither names a
--- directory. This program's own core is there, where it is a portable
--- artifact, so a sandboxed worker that declares the `bootstrap` cache
--- is given cores of its own to write instead ([`build.test_sandbox`]).
function caches.cores(environment: {string:string}): string | nil
  local portable = environment.COSMIC_PORTABLE_CACHE
  if portable ~= nil then return portable end
  local cores, _ = Fs.cache_dir("cores", { environment = environment, make = false })
  return cores
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
