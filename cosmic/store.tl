--- The databases `require` reads its modules from, for test and build
--- tooling: attach a project's database, and read a module's compiled
--- bytes, its source, its imports, or the binary's own tables. An
--- ordinary program has no use for it.

-- The raw module behind this one lives under `cosmic.internal.`, a
-- reserved namespace that never satisfies an ordinary `require` for
-- any caller: `require` caches a result under the name it was asked
-- for, and a value that must be checked on every access can never be
-- that cached value, or the first caller's access would answer for
-- every caller after it. The searcher hands it here directly instead,
-- as the second argument `require` always passes a loader -- present
-- only because this module was itself loaded, trusted, from the
-- binary's own tree. Boot mode, before any such check exists, falls
-- back to requiring it by name, which only boot's own preload answers.

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
--- an environment of its own; nil and why for none, or for a module a
--- test may not read (a test reads only its import closure unless it
--- declares `store`).
function Store.bytecode(name: string): string | nil, string
  return store.bytecode(name)
end

--- One entry of the meta table, which is where a build records what it
--- decided. Nil when no database holds that key. A test that does not
--- declare `store` raises, naming the declaration that would allow it,
--- for a row outside its own key, unless a database the test attached
--- itself holds the row.
function Store.meta(key: string): string | nil
  return store.meta(key)
end

--- One module's Teal source, or a declaration's, from the binary's own
--- database and no other: what a checker building another tree needs
--- to type a `require` of this one's modules. Stored deflated, it is
--- inflated here; nil beside why when there is no such row, the test
--- may not read it, or it will not inflate.
function Store.source(name: string): string | nil, string
  return store.source(name)
end

--- The names the binary's own `imports` table records the module
--- `name` requiring, sorted: none for a name it holds no row of. Nil
--- and why when the test may not read `name`, or the query failed. What walks the binary's module graph without a handle
--- on every module's rows (`databases`).
function Store.requires(name: string): {string} | nil, string
  return store.requires(name)
end

--- Every database `require` searches, in search order: a project's
--- own ahead of the binary's, which is always last. Each is a handle
--- `cosmic.sqlite` reads through and never closes -- what a verb that
--- asks about the shipped tables (`docs`, `uses`, `catalog`) queries.
--- Raises in a test that does not declare `store`.
function Store.databases(): {Sqlite.Handle}
  return store.databases()
end

--- One time zone's TZif file (RFC 8536), by IANA name, from the copy
--- of the tz database the binary's own database carries: the only zone
--- rules `cosmic.time` reads. Nil and why when it carries no such zone
--- or the query failed; `zone_names` tells the two apart.
function Store.zoneinfo(name: string): string | nil, string
  return store.zoneinfo(name)
end

--- Every time zone name the binary's own database carries, as a set,
--- or nil and why when the query failed.
function Store.zone_names(): {string:boolean} | nil, string
  return store.zone_names()
end

--- Calls `fn` searching only the binary's own database, as a process
--- that attached none would -- `require`, `meta`, `source` and
--- `databases` included -- then puts every other back where it was,
--- whether `fn` returned or raised. Nothing can be attached meanwhile.
function Store.alone(fn: function())
  store.alone(fn)
end

return Store
