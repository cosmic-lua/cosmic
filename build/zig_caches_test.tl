--- build/zig.tl cannot require [`build.zig_caches`] (it runs standalone),
--- so the two spell where zig's caches are apart: they must agree, or a
--- sandboxed worker would be given a cache where zig does not put it.

local Zig = require("build.zig")
local zig_caches = require("build.zig_caches")

local function test_the_caches_are_where_zig_puts_them(tmp: string)
  for _, env in ipairs({
      { XDG_CACHE_HOME = tmp .. "/xdg" },
      { HOME = tmp .. "/home" },
      { XDG_CACHE_HOME = tmp .. "/xdg", COSMIC_ZIG_GLOBAL_CACHE = "/g", COSMIC_ZIG_CACHE = "/p" },
      {},
  } as {{string:string}}) do
    local paths = zig_caches.paths("/repo", env)
    local shared, project = Zig.global_cache("/repo", env), Zig.project_cache("/repo", env)
    assert(paths[1] == shared and paths[2] == project,
      table.concat(paths, " ") .. " but zig puts them at " .. shared .. " " .. project)
  end
end
