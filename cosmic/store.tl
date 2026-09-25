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
local Sqlite = require("cosmic.sqlite")

local extra: any = select(2, ...)
local store: raw_store
if type(extra) == "table" then
  store = extra as raw_store
else
  store = require("cosmic.internal.store")
end

local record Store
end

--- Opens a projected module database and searches it ahead of every other.
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
  return store.bytecode(name)
end

--- One entry of the meta table, which is where a build records what it
--- decided. Nil when no database holds that key.
function Store.meta(key: string): string | nil
  return store.meta(key)
end

--- One module's Teal source, or a declaration's, from the binary's own
--- database and no other: what a checker building another tree needs
--- to type a `require` of this one's modules. Stored deflated, it is
--- inflated here; nil beside why when there is no such row or it will
--- not inflate.
function Store.source(name: string): string | nil, string
  return store.source(name)
end

--- Every database `require` searches, in search order: a project's
--- own ahead of the binary's, which is always last. Each is a handle
--- `cosmic.sqlite` reads through and never closes -- what a verb that
--- asks about the shipped tables (`docs`, `uses`, `catalog`) queries.
function Store.databases(): {Sqlite.Handle}
  return store.databases()
end

--- One time zone's TZif file (RFC 8536), by IANA name, from the copy
--- of the tz database the binary's own database carries: what
--- `cosmic.time` reads where the host has no zone files of its own. Nil
--- and why when it carries no such zone.
function Store.zoneinfo(name: string): string | nil, string
  local databases = store.databases()
  local binary = databases[#databases]
  if binary == nil then return nil, "the running binary has no database" end
  local rows, trouble = Sqlite.rows(binary, "SELECT data FROM zoneinfo WHERE name = ?1",
    { { text = name } })
  if rows == nil then return nil, "the binary's zones: " .. trouble end
  if #rows == 0 then return nil, "the binary carries no zone " .. name end
  return rows[1][1].blob or rows[1][1].text, ""
end

--- Calls `fn` searching only the binary's own database, as a process
--- that attached none would -- `require`, `meta`, `source` and
--- `databases` included -- then puts every other back where it was,
--- whether `fn` returned or raised. Nothing can be attached meanwhile.
function Store.alone(fn: function())
  store.alone(fn)
end

return Store
