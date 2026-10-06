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
-- TODO: promise `program:jq` on the Linux legs once ci/images/alpine and
-- ci/images/ubuntu install jq: only macos-aarch64's runner has it, so
-- build/queue_seed_jq_test.tl and build/commit_verdicts_jq_test.tl are
-- skipped on the Linux legs.
-- TODO: promise `portable` once the driver gives its portable suite a
-- list of its own: it runs `cosmic test` on a portable artifact, which
-- the native suite on the same leg is not, so a leg's one list cannot
-- promise it (cosmic_ci.orchestration's `suite_run` takes `extra`).
-- TODO: promise `landlock:N` for the N the runners' kernels give (ubuntu-24.04's
-- and its arm image's), once a run's summary says the ABI they hold:
-- only the bare `landlock` (version 1 or later) is known to hold.
-- Every leg's image or runner has the shell at /bin/sh.
local shell = "path:/bin/sh"
-- Every leg's image (ci/images) or runner has git on its PATH.
local git = "program:git"
-- Files every leg's system has, which tests that read or start the
-- system's own paths require: /usr/bin/env stands for /usr, a directory
-- being no file a policy grants.
local env, passwd = "path:/usr/bin/env", "path:/etc/passwd"
-- Every Linux leg's kernel (an Ubuntu 24.04 runner's) lists a process's
-- children in /proc, CONFIG_PROC_CHILDREN.
local children = "path:/proc/thread-self/children"
local linux = { "sandbox", "landlock", "userns", "nest", "own_proc", "proc", shell, git, children, env, passwd }

return {
  legs = {
    ["linux-x86_64"] = linux,
    ["linux-x86_64-shard"] = linux,
    ["linux-x86_64-checked"] = linux,
    ["linux-aarch64"] = linux,
    ["alpine-x86_64"] = linux,
    -- GitHub's macOS runner image carries jq; the Linux legs' images do not.
    ["macos-aarch64"] = { shell, git, "program:jq", env, passwd },
  },
}
