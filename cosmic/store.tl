--- The module store: the databases `require` reads, and the few ways in
--- that `require` does not cover.
---
--- The raw module behind this one lives under `cosmic.internal.`, a
--- reserved namespace that never satisfies an ordinary `require` for
--- any caller: `require` caches a result under the name it was asked
--- for, and a value that must be checked on every access can never be
--- that cached value, or the first caller's access would answer for
--- every caller after it. The searcher hands it here directly instead,
--- as the second argument `require` always passes a loader -- present
--- only because this module was itself loaded, trusted, from the
--- binary's own tree. Boot mode, before any such check exists, falls
--- back to requiring it by name, which only boot's own preload answers.

local type raw_store = require("cosmic.internal.store")

local extra: any = select(2, ...)
local store: raw_store
if type(extra) == "table" then
  store = extra as raw_store
else
  store = require("cosmic.internal.store")
end

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
