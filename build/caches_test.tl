--- Where each host cache a test may declare is ([`build.caches`]): where
--- the code that uses it puts it, overrides included, never under the
--- tree.

local Fs = require("cosmic.fs")
local zig_caches = require("build.zig_caches")
local caches = require("build.caches")

--- `zig` is zig's installs, global and project caches, and `bootstrap`
--- the bootstrap cosmic and the launcher's cores, each under the cache
--- directory XDG_CACHE_HOME or HOME names, as build/zig.tl and
--- [`Fs.cache_dir`] put them. COSMIC_ZIG_GLOBAL_CACHE and
--- COSMIC_PORTABLE_CACHE move theirs, and ZIG_LOCAL_CACHE_DIR adds the
--- directory a zig command other than `build` uses.
local function test_a_cache_is_where_its_tool_puts_it()
  local env = { XDG_CACHE_HOME = "/c" }
  local zig = caches.all({ "zig" }, "/repo", env)
  assert(table.concat(zig, " ") == "/c/cosmic/zig /c/cosmic/zig-global /c/cosmic/zig-project",
    table.concat(zig, " "))
  assert(zig[2] == zig_caches.paths("/repo", env)[1] and zig[1] == Fs.cache_dir("zig", { environment = env, make = false }))
  local moved = caches.all({ "zig", "bootstrap" }, "/repo", { HOME = "/h",
    COSMIC_ZIG_GLOBAL_CACHE = "/g", ZIG_LOCAL_CACHE_DIR = "/l", COSMIC_PORTABLE_CACHE = "/p" })
  assert(table.concat(moved, " ") == "/h/.cache/cosmic/zig /g /h/.cache/cosmic/zig-project " ..
      "/l /h/.cache/cosmic/bootstrap /p", table.concat(moved, " "))
  -- With no cache directory there is no build directory either, unless
  -- COSMIC_BUILD_HOME names one, and so no zig cache.
  assert(#caches.all({ "zig" }, "/repo", {}) == 0)
  assert(#caches.all({ "nothing" }, "/repo", env) == 0)
end
