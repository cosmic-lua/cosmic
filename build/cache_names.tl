--- The host caches a test may declare it writes (`cosmic.test`'s
--- `Needs.caches`), by name, to what each covers: `build.caches` says
--- what each is and where it is on this host. Apart from it, and
--- requiring nothing, because the analyzer checks a declaration's names
--- against these as it parses (`build.analyzer`), so this module is in
--- the analyzer's identity and the compiler's (`build.work`'s
--- `compiler_identity`), where `build.caches`, which reaches build/zig.tl
--- to find the zig cache, is in neither.

local record cache_names
  --- Each name a declaration may give, to what it covers.
  names: {string:string}
end

cache_names.names = {
  zig = "the pinned zig, and zig's global and project caches",
  bootstrap = "the bootstrap cosmic, and the cores a portable cosmic extracts",
}

return cache_names
