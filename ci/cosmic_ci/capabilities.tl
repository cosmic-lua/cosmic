--- The host requirements (`requires` names of build/host_names.tl) each
--- CI leg promises, named as ci.yml's COSMIC_WORKER names it, read from
--- capabilities.json beside this module. The driver
--- gives every suite its leg's list as COSMIC_TEST_PROMISES and the name
--- as COSMIC_TEST_LEG (cosmic_ci.orchestration's `promise`), and a held
--- run fails a module whose promised requirement is absent. A name no leg
--- promises, `program:make` as much as `nest`, may not be required
--- (build/tree_checks.tl's `promises`): that module would run nowhere. Add
--- it to a leg whose image has it in the change that first requires it.
---
--- Data alone, in a file of its own: the tree's build/tree_checks.tl,
--- which cannot require a module of ci/, reads capabilities.json too.
---
--- - Every leg's image or runner has the shell at /bin/sh. The Linux
---   legs' images, busybox's on alpine's, have cat at /bin/cat, which
---   the macOS leg has too but never asks for: its tests that run it
---   need a sandbox.
--- - `path:/usr/bin/env` and `path:/etc/passwd` are files every leg's
---   system has, which tests that read or start the system's own paths
---   require: /usr/bin/env stands for /usr, a directory being no file a
---   policy grants.
--- - Every Linux leg's kernel (an Ubuntu 24.04 runner's) lists a
---   process's children in /proc, CONFIG_PROC_CHILDREN.
--- - Every leg boots every core (`-Dboot-cores=all`,
---   cosmic_ci.orchestration), so the modules that need a tool of the
---   portable programs run on all of them (`all_cores`).
--- - The ubuntu runner has curl, which cosmic/child_relay_curl_test.tl
---   runs in a sandbox as a client that honours the proxy variables.
--- - The checked leg's core is the checked build, whose instruments the
---   tests that require `checked` use: a held run fails them if they
---   skip.
--- - No macOS run is held (it has no sandbox), so a name it lacks is
---   skipped there rather than failed: the names its list holds say what
---   it gives.
--
-- TODO: promise `portable` once the driver gives its portable suite a
-- list of its own: it runs `cosmic test` on a portable artifact, which
-- the native suite on the same leg is not, so a leg's one list cannot
-- promise it (cosmic_ci.orchestration's `suite_run` takes `extra`).
-- TODO: promise `landlock:N` for the N the runners' kernels give (ubuntu-24.04's
-- and its arm image's), once a run's summary says the ABI they hold:
-- only the bare `landlock` (version 1 or later) is known to hold.
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")

--- What capabilities.json holds.
local record Data
  legs: {string:{string}}
end
local DATA <const> = Shape.record_of("Data")

--- Where the data is, below the project's root: the driver and its tests run there.
local path <const> = "cosmic_ci/capabilities.json"

local record Capabilities
  --- The requirements each leg promises, by the leg's name. Raises where the data cannot be read.
  legs: function(): {string:{string}}
end

--- What has been read of the file: the data once it is.
local record Read
  data?: Data
end

local read: Read = {}

function Capabilities.legs(): {string:{string}}
  local held = read.data
  if held ~= nil then return held.legs end
  local text, why = Fs.read(path)
  assert(text ~= nil, why)
  local decoded, trouble = DATA:decode_into(text)
  assert(decoded ~= nil, path .. ": " .. trouble)
  read.data = decoded
  return decoded.legs
end

return Capabilities
