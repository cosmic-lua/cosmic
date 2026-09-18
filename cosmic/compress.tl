--- Deflate, the compression the store uses for the images it carries.

local sys = require("cosmic.syscalls")

local record Compress
end

--- Compresses bytes.
function Compress.deflate(data: string): string | nil, string
  local packed, trouble = sys.deflate(data)
  if packed == nil then
    return nil, trouble
  end
  return packed
end

--- Expands bytes that `deflate` compressed. The expanded size is what
--- the caller recorded when it compressed them.
function Compress.inflate(data: string, size: integer): string | nil, string
  local out, trouble = sys.inflate(data, size)
  if out == nil then
    return nil, trouble
  end
  return out
end

return Compress
