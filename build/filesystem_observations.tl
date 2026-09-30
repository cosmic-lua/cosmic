--- What is left of the observation log in Teal until its C goes
--- (core/observed.c, the observed SQLite VFS): the log's C resolution of
--- a path, which build/confine_test.tl holds build.confine's
--- `resolution` to. No run keys, audits or judges anything by the log.
---
--- The module is also the name core/store.c hands the raw tables of the
--- log and of SQLite's record to (`open_observations`), which
--- core/allocation_test.tl reaches through its loader to walk that C
--- under every refused allocation.
-- TODO: drop this module, and build/filesystem_observations_test.tl,
-- with core/observed.c, the observed VFS and core/store.c's
-- `open_observations` (removing the observation log, step 5 -- plan
-- 4.2's PR 5).

--- SQLite's table and the syscall table's log, of which only `resolve`
--- is read here (core/store.c's `open_observations`). Boot mode falls
--- back to requiring them by name, which only boot's own preload
--- answers.
local type Raw = require("cosmic.internal.observations")

local extra: any = select(2, ...)
local raws: Raw
if type(extra) == "table" then
  raws = extra as Raw
else
  raws = require("cosmic.internal.observations")
end
local syscalls = raws.syscalls

local record observations
end

--- What an absolute path resolves to, links and all, when it is read:
--- `realpath` of the path, or, when it is not there, of its nearest
--- existing ancestor with the missing names after it as written, "."
--- and ".." included. "" for a relative path.
function observations.resolution(path: string): string
  return syscalls.resolve(path)
end

return observations
