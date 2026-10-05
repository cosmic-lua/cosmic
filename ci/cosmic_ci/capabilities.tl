--- The host requirements each CI leg promises (a `requires` name of
--- build/host_names.tl): the leg is given what spawn's sandbox needs
--- (.github/scripts/leg-container.sh, which turns off the host's
--- restriction of user namespaces, lets one be made, and leaves /proc
--- whole) and runs every worker sandboxed, so a held run
--- (COSMIC_CI_REQUIRE_SANDBOX=1) fails a test module that requires one
--- of these and finds it missing, naming the leg, rather than skip it
--- unrun. The driver hands the leg's list to every suite it runs as
--- COSMIC_TEST_PROMISES, and its name as COSMIC_TEST_LEG
--- (cosmic_ci.orchestration's `environment`). A leg is named as ci.yml's
--- COSMIC_WORKER names it: a light run's second share of linux-x86_64 is
--- linux-x86_64-shard.
---
--- A name no leg promises is one a test module may not require
--- (build/tree_checks.tl's `promises`): a module n/a or skipped on every
--- leg would run nowhere. The macOS leg runs unsandboxed on the runner's
--- own user and has no Landlock, user namespace or procfs, so it
--- promises none.
---
--- Data alone, in text Lua reads as well as Teal: the tree's own
--- build/tree_checks.tl, which cannot require a module of ci/, loads it.
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
