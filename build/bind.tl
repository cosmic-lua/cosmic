--- What the build's SQL shares: a value to bind, of each kind it binds.

local Sqlite = require("cosmic.sqlite")

local record bind
end

--- `value`, bound as TEXT.
function bind.text(value: string): Sqlite.Value
  return { text = value }
end

--- `value`, bound as BLOB.
function bind.blob(value: string): Sqlite.Value
  return { blob = value }
end

--- `value`, bound as INTEGER.
function bind.integer(value: integer): Sqlite.Value
  return { integer = value }
end

return bind
