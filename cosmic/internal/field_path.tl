--- How a message names a place in a value, from the root `$`: `$.rows[1].id`
--- for a list element's field, `$["a b"]` for a key that is not an
--- identifier. [`cosmic.shape`] names a failing value so, and
--- [`cosmic.sandbox`] a policy field that is wrong. It holds no JSON
--- reader, so a program that only checks a policy does not load one.
---
---     local FieldPath = require("cosmic.internal.field_path")
---     local rows = FieldPath.field(FieldPath.root, "rows")
---     print(FieldPath.field(FieldPath.index(rows, 2), "id")) -- $.rows[1].id

local record FieldPath
  --- The path of the value itself.
  mut root: string
end

FieldPath.root = "$"

--- `s` as a JSON string literal, for a message: `"` and `\\` escaped and
--- every control character a `\u` escape. It writes what [`Json.quote`]
--- writes, which this module cannot call without loading the JSON reader.
--- @param s string The text to quote
--- @return string The literal
function FieldPath.quote(s: string): string
  return '"' .. s:gsub('[%c"\\]', function(c: string): string
    if c == '"' or c == "\\" then return "\\" .. c end
    return ("\\u%04x"):format(assert(c:byte()))
  end) .. '"'
end

--- The path `path` extended by the member `name`: `.name` for an
--- identifier, else `["name"]` quoted as JSON quotes a string.
--- @param path string The path of the containing value
--- @param name string The member's key
--- @return string The member's path
function FieldPath.field(path: string, name: string): string
  if name:find("^[%a_][%w_]*$") then return path .. "." .. name end
  return path .. "[" .. FieldPath.quote(name) .. "]"
end

--- The path `path` extended by the list element at `index`, counted from
--- 1 as Lua counts it and from 0 as the JSON document does.
--- @param path string The path of the containing list
--- @param index integer The element's Lua index
--- @return string The element's path
function FieldPath.index(path: string, index: integer): string
  return path .. "[" .. tostring(index - 1) .. "]"
end

return FieldPath
