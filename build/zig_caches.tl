--- Where zig's global and project caches are, as build/zig.tl puts
--- them. [`build.caches`] uses it to bind them into a sandboxed worker
--- that declares the `zig` cache. It is part of the test harness
--- ([`build.test`]'s `harness_own`), so it requires nothing but
--- cosmic.fs and build.paths. build/zig.tl runs standalone on the bootstrap's own
--- standard library and cannot require this module; it spells the same
--- rule in its [`Zig.global_cache`] and [`Zig.project_cache`], which
--- build/zig_caches_test.tl holds this to.

local Fs = require("cosmic.fs")
local build_paths = require("build.paths")

local record zig_caches
end

--- Where one of zig's caches would be: `variable` from `environment`
--- when set, else `tool` in this user's cosmic cache directory as
--- [`Fs.cache_dir`] names it with `make = false`, so nothing is made, else
--- what `fallback` names, nil where it names nothing.
local function located(variable: string, tool: string, fallback: function(): string | nil,
                       environment: {string:string}): string | nil
  local given = environment[variable]
  if given ~= nil and given ~= "" then return given end
  local named, _ = Fs.cache_dir(tool, { environment = environment, make = false })
  if named ~= nil then return named end
  return fallback()
end

--- Where zig's global cache and then its project cache are for a tree
--- at `root`, as `environment` names them, with nothing made or
--- checked: COSMIC_ZIG_GLOBAL_CACHE and COSMIC_ZIG_CACHE when set, else
--- `zig-global` and `zig-project` in the user's cosmic cache
--- directory, else `zig-global` and `zig-cache` in `root`'s build
--- directory ([`build.paths`]); each is left out where none of these
--- names one, as zig then builds nothing for the tree.
function zig_caches.paths(root: string, environment: {string:string}): {string}
  local function in_build(name: string): function(): string | nil
    return function(): string | nil
      local directory, _ = build_paths.directory(root, environment)
      if directory == nil then return nil end
      return directory .. "/" .. name
    end
  end
  local out: {string} = {}
  for _, path in ipairs({
      located("COSMIC_ZIG_GLOBAL_CACHE", "zig-global", in_build("zig-global"), environment) or "",
      located("COSMIC_ZIG_CACHE", "zig-project", in_build("zig-cache"), environment) or "",
  }) do
    if path ~= "" then out[#out + 1] = path end
  end
  return out
end

return zig_caches
