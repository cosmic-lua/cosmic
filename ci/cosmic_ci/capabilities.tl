--- The host requirements (`requires` names of build/host_names.tl) each
--- CI leg promises, named as ci.yml's COSMIC_WORKER names it. The driver
--- gives every suite its leg's list as COSMIC_TEST_PROMISES and the name
--- as COSMIC_TEST_LEG (cosmic_ci.orchestration's `promise`), and a held
--- run fails a module whose promised requirement is absent. A name no leg
--- promises, `program:jq` as much as `nest`, may not be required
--- (build/tree_checks.tl's `promises`): that module would run nowhere. Add
--- it to a leg whose image has it in the change that first requires it.
---
--- Data alone, in text Lua reads as well as Teal: build/tree_checks.tl
--- loads it.
-- TODO: promise `portable` once the driver gives its portable suite a
-- list of its own: it runs `cosmic test` on a portable artifact, which
-- the native suite on the same leg is not, so a leg's one list cannot
-- promise it (cosmic_ci.orchestration's `suite_run` takes `extra`).
-- TODO: promise `landlock:N` for the N the runners' kernels give (ubuntu-24.04's
-- and its arm image's), once a run's summary says the ABI they hold:
-- only the bare `landlock` (version 1 or later) is known to hold.
-- Every leg's image or runner has the shell at /bin/sh.
local shell = "path:/bin/sh"
local linux = { "sandbox", "landlock", "userns", "nest", "own_proc", "proc", shell }

return {
  legs = {
    ["linux-x86_64"] = linux,
    ["linux-x86_64-shard"] = linux,
    ["linux-x86_64-checked"] = linux,
    ["linux-aarch64"] = linux,
    ["alpine-x86_64"] = linux,
    ["macos-aarch64"] = { shell },
  },
}
