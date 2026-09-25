--- What core/store.c's `open_observations` hands only
--- `build.filesystem_observations` when it loads from the binary's own
--- tree: the raw tables whose calls it stands in for or drains.

local type process = require("cosmic.internal.process")
local type sqlite = require("cosmic.internal.sqlite")

local record observations
  --- The process table, whose `spawn` it stands in for to note each
  --- child a test starts.
  process: process
  --- SQLite's table, whose record of the files SQLite opens it drains.
  sqlite: sqlite
end

return observations
