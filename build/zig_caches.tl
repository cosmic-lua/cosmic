--- Where zig's global and project caches are, as build/zig.tl puts
--- them. [`build.caches`] uses it to bind them into a sandboxed worker
--- that declares the `zig` cache. It is part of the test harness
--- ([`build.test`]'s `harness_own`), so it requires nothing but
--- cosmic.fs. build/zig.tl runs standalone on the bootstrap's own
--- standard library and cannot require this module; it spells the same
--- rule in its [`Zig.global_cache`] and [`Zig.project_cache`], which
--- build/zig_caches_test.tl holds this to.

local Fs = require("cosmic.fs")

local record zig_caches
end

--- Where one of zig's caches would be: `variable` from `environment`
--- when set, else `tool` in this user's cosmic cache directory as
--- [`Fs.cache_path`] names it -- nothing made -- else `fallback`.
local function located(variable: string, tool: string, fallback: string,
                       environment: {string:string}): string
  local given = environment[variable]
  if given ~= nil and given ~= "" then return given end
  local named, _ = Fs.cache_path(tool, environment)
  if named ~= nil then return named end
  return fallback
end

--- Where zig's global cache and then its project cache are for a tree
--- at `root`, as `environment` names them, with nothing made or
--- checked: COSMIC_ZIG_GLOBAL_CACHE and COSMIC_ZIG_CACHE when set, else
--- `zig-global` and `zig-project` in the user's cosmic cache
--- directory, else `root`/o's `zig-global` and `zig-cache`.
function zig_caches.paths(root: string, environment: {string:string}): {string}
  return {
    located("COSMIC_ZIG_GLOBAL_CACHE", "zig-global", root .. "/o/zig-global", environment),
    located("COSMIC_ZIG_CACHE", "zig-project", root .. "/o/zig-cache", environment),
  }
end

return zig_caches
