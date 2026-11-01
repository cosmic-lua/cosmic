--- A name as an SQL identifier, which the verbs that read or write a table by a name a file or a user spelled quote before they
--- put it in a statement.

local record sql_name
end

--- `name` as an SQL identifier, quoted, with each `"` in it doubled.
function sql_name.quoted(name: string): string
  return '"' .. name:gsub('"', '""') .. '"'
end

return sql_name
