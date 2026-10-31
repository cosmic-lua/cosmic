--- build/zig.tl cannot require [`build.zig_caches`] (it runs standalone),
--- so the two spell where zig's caches are apart: they must agree, or a
--- sandboxed worker would be given a cache where zig does not put it.

local Fs = require("cosmic.fs")
local Zig = require("build.zig")
local zig_caches = require("build.zig_caches")
local build_paths = require("build.paths")

local function test_the_caches_are_where_zig_puts_them(tmp: string)
  local root = tmp .. "/repo"
  assert(Fs.mkdirs(root))
  for _, env in ipairs({
      { XDG_CACHE_HOME = tmp .. "/xdg" },
      { HOME = tmp .. "/home" },
      { XDG_CACHE_HOME = tmp .. "/xdg", COSMIC_ZIG_GLOBAL_CACHE = "/g", COSMIC_ZIG_CACHE = "/p" },
      { COSMIC_BUILD_HOME = tmp .. "/builds" },
  } as {{string:string}}) do
    local paths = zig_caches.paths(root, env)
    local output = build_paths.required(root, env)
    local shared, project = Zig.global_cache(output, env), Zig.project_cache(output, env)
    assert(paths[1] == shared and paths[2] == project,
      table.concat(paths, " ") .. " but zig puts them at " .. shared .. " " .. project)
  end
  assert(#zig_caches.paths(root, {}) == 0, "a tree with no cache and no build directory has caches")
end
