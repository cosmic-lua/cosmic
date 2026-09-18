--- A database's own payload: the core images and the vendored compiler
--- a build wrote into it, not derived from the tree it also holds.
---
--- Re-importing over an existing database must not drop what an
--- earlier write put there and this write does not produce again --
--- `boot`'s three core images and the compiler row an ordinary project
--- build never carries. Reading them back first is how a write carries
--- them forward unchanged instead of writing an empty set.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record payload
end

--- The images and vendored compiler an existing database already
--- carries. Empty/nil when `path` does not exist yet or holds neither
--- -- an ordinary project's first run.
function payload.carried(path: string): {string:string}, string | nil, string
  local images: {string:string} = {}
  if not Fs.exists(path) then
    return images, nil, ""
  end
  local handle, open_trouble = Sqlite.open(path, false)
  if handle == nil then
    return images, nil, open_trouble
  end
  local rows, rows_trouble = Sqlite.rows(handle,
    "SELECT target, size, data FROM images")
  if rows == nil then
    handle:close()
    return images, nil, rows_trouble
  end
  for _, row in ipairs(rows) do
    local target, size_text, packed = row[1], row[2], row[3]
    local size = math.tointeger(tonumber(size_text) or 0) or 0
    local raw, inflate_trouble = Compress.inflate(packed, size)
    if raw == nil then
      handle:close()
      return images, nil, target .. ": " .. inflate_trouble
    end
    images[target] = raw
  end
  local vendor_rows, vendor_trouble = Sqlite.rows(handle,
    "SELECT source FROM modules WHERE kind = 'vendor' AND path = 'vendor.tl'")
  if vendor_rows == nil then
    handle:close()
    return images, nil, vendor_trouble
  end
  local teal_source: string | nil = nil
  if #vendor_rows > 0 then
    teal_source = vendor_rows[1][1]
  end
  handle:close()
  return images, teal_source, ""
end

return payload
