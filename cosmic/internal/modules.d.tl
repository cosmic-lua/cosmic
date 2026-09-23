-- Every raw module core C opens on its own, keyed by its name under
-- `cosmic.internal.`: what build/entry_points.tl is handed, so it can
-- name every function they hold. See core/store.c.

local type compress = require("cosmic.internal.compress")
local type hash = require("cosmic.internal.hash")
local type http = require("cosmic.internal.http")
local type sqlite = require("cosmic.internal.sqlite")

local record modules
  compress: compress
  hash: hash
  http: http
  sqlite: sqlite
end

return modules
