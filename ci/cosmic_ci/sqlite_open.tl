--- A writable SQLite open for the driver, which runs on the pinned release
--- and is also checked and run against the tree: the release's
--- [`Sqlite.open`] takes a boolean and the tree's an options table.

local Sqlite = require("cosmic.sqlite")

local record SqliteOpen
end

-- The table is truthy to the release's boolean, and the tree's options
-- read it, so one call runs on both; only the cast keeps either from
-- refusing it by type.
local open = Sqlite.open as any as function(string, any): Sqlite.Handle | nil, string

--- The database at `path` opened for reading and writing, as [`Sqlite.open`]
--- answers it.
function SqliteOpen.writable(path: string): Sqlite.Handle | nil, string
  -- TODO: once ci/cosmic-driver.pin names a release whose Sqlite.open
  -- takes `{ writable = true }`, call that at each caller and drop this
  -- module.
  return open(path, { writable = true })
end

return SqliteOpen
