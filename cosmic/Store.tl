--- The module store: the databases `require` reads, and the few ways in
--- that `require` does not cover.

local store = require("cosmic.store")

local record Store
end

--- Opens a database and searches it ahead of every other, which is what
--- a project's own build database needs.
function Store.attach(path: string): boolean, string
  local ok, trouble = store.attach(path)
  if not ok then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- One module's compiled bytes, for a caller that must load the chunk in
--- an environment of its own.
function Store.bytecode(name: string): string | nil, string
  local bytes, trouble = store.bytecode(name)
  if bytes == nil then
    return nil, trouble
  end
  return bytes
end

--- One entry of the meta table, which is where a build records what it
--- decided. Nil when no database holds that key.
function Store.meta(key: string): string | nil
  return store.meta(key)
end

return Store
