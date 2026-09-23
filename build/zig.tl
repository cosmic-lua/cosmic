--- Fetches, verifies and runs the one pinned zig -- the cosmic
--- replacement for `bin/zig`'s shell fallback, run by `bin/zig` itself
--- once `$COSMIC_BOOTSTRAP` names a cosmic that carries `cosmic.http`
--- and `cosmic.archive`.
---
---     cosmic build/zig.tl [args...]
---
--- The pin is `bin/zig.pin`: a `version` line, then one line per host
--- naming that host's release tarball's sha256. `COSMIC_ZIG` names an
--- already-installed zig binary and skips all of this, exactly as
--- `bin/zig` does.
---
--- Otherwise the release is cached at
--- `$XDG_CACHE_HOME/cosmic/zig/<version>-<host>` (default
--- `$HOME/.cache/cosmic/zig/...`): if `<install>/zig` is already
--- there, it is used as is; otherwise the tarball named by
--- `https://ziglang.org/download/<version>/zig-<host>-<version>.tar.xz`
--- is downloaded with `Http.download`'s own `sha256` check straight
--- into a scratch directory under the cache, extracted with
--- `cosmic.archive`, and moved into place -- tolerating a concurrent
--- winner the same way `bin/zig`'s `mv ... || true` did.
---
--- `build` gets the same cache-directory, global-cache-directory and
--- prefix flags `bin/zig` always added, relative to the repository
--- root (found from this script's own path); every other subcommand
--- passes its arguments through unchanged.
---
--- This script only uses stdlib modules -- it runs on the pinned
--- bootstrap cosmic, not on a core the tree just built, so nothing
--- here may depend on `o/` existing. The logic lives in
--- `build/zig_lib.tl`, unit tested (without a network) in
--- `build/zig_test.tl`; this file is the thin entry point the
--- `cosmic build/zig.tl` command line reaches.

local Zig = require("build.zig_lib")

return function(argv: {integer:string}): integer
  return Zig.main(argv)
end
