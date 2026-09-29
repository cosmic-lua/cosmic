--- The host caches a test may declare it writes (`cosmic.test`'s
--- `Needs.caches`), by name, to what each covers. `build.caches` says
--- where each is on this host.
---
--- The two are apart, and this module requires nothing, because the
--- analyzer checks a declaration's names against these as it parses
--- (`build.analyzer`). That puts this module in the analyzer's identity
--- and the compiler's (`build.work`'s `compiler_identity`). `build.caches`
--- reaches build/zig.tl to find the zig cache, so it is in neither.

local record cache_names
  --- Each name a declaration may give, to what it covers.
  names: {string:string}
end

--- The variables that say where each cache is, which a process that
--- writes one reads to find it: a sandboxed worker is given them
--- (`build.test_inputs`). Here rather than in `build.caches`, whose
--- lazy require of build/zig.tl would put build/zig.tl and all it
--- requires in the harness's digest (`build.test`'s `key_code`), which
--- `build.test_inputs` is part of.
local locating: {string:{string}} = {
  zig = { "HOME", "XDG_CACHE_HOME", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE",
    "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR" },
  bootstrap = { "HOME", "XDG_CACHE_HOME", "COSMIC_PORTABLE_CACHE" },
}

--- The variables `name` is located by (`locating`), none for a name
--- that is no cache.
function cache_names.variables(name: string): {string}
  return locating[name] or {}
end

cache_names.names = {
  zig = "the pinned zig, and zig's global and project caches",
  bootstrap = "the bootstrap cosmic, and the cores a portable cosmic extracts",
}

return cache_names
