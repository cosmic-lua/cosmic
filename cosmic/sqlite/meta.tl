--- Internal helper for cosmic.sqlite: schema fingerprinting and a
--- minimal key/value convention for tracking what a database file was
--- built from — the standard "does this file still match what I'd
--- build fresh" check a cache or other derived file needs before
--- trusting what's already on disk. Lives in its own file so
--- cosmic/sqlite/init.tl stays under the 500-line cap.
---
--- meta_get/meta_set assume the caller has already created a table
--- shaped exactly `cosmic_meta(k TEXT PRIMARY KEY, v TEXT NOT NULL)`
--- — this module holds no opinion on the rest of the caller's own
--- schema, only this one convention.
---
--- Every function here takes its connection as `any` rather than
--- `sqlite.Database`: importing that type would require requiring
--- cosmic.sqlite itself, which is this module's own caller
--- (cosmic/sqlite/init.tl) — a cycle. `is Db` narrows it structurally
--- instead, the same technique cosmic.sqlite.extras uses to attach
--- onto a Database under construction.

local column_mod = require("cosmic.sqlite.column")
local hash = require("cosmic.hash")
local row_iter = require("cosmic.sqlite.row_iter")

local type Rows = row_iter.Rows

--- The shape these helpers need from a connection: enough of
--- sqlite.Database to run a query.
local record Db
  query: function(self: Db, sql: string, params?: any): Rows | nil, string
  query_one: function(self: Db, sql: string, params?: any): {string: any} | nil, string
  exec: function(self: Db, sql: string, params?: any): boolean, string
end

--- A connection's actual schema, fingerprinted: every object
--- `sqlite_master` carries a definition for (table, view, index — an
--- FTS5 virtual table's own tokenizer argument included), sorted for
--- a deterministic order, sha256'd. Reads the schema as SQLite itself
--- materialized it rather than concatenating DDL source text, so it
--- never drifts from a connection actually built with a given DDL.
--- @param db_any any An open sqlite.Database
--- @return string | nil The fingerprint, hex-encoded
--- @return string Error message
local function schema_fingerprint(db_any: any): string | nil, string
  if not (db_any is Db) then
    return nil, "schema_fingerprint: not a sqlite.Database"
  end
  local db = db_any
  local rows, err = db:query(
    "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name")
  if rows == nil then
    return nil, err
  end
  local parts: {string} = {}
  for row in rows do
    local text, cerr = column_mod.column_text(row, "sql")
    if text == nil then
      return nil, cerr
    end
    parts[#parts + 1] = text
  end
  local ierr = rows:err()
  if ierr then
    return nil, ierr
  end
  return hash.sha256_hex(table.concat(parts, "\n"))
end

--- Read one value from the caller's `cosmic_meta` table (see the
--- module doc comment). `nil, nil` means the key is absent — an
--- ordinary miss, not a failure; `nil, err` is a real query failure.
--- @param db_any any An open sqlite.Database
--- @param key string The key
--- @return string | nil The value
--- @return string Error message
local function meta_get(db_any: any, key: string): string | nil, string
  if not (db_any is Db) then
    return nil, "meta_get: not a sqlite.Database"
  end
  local db = db_any
  local row, err = db:query_one("SELECT v FROM cosmic_meta WHERE k = ?", {key})
  if row == nil then
    return nil, err
  end
  return column_mod.column_text(row, "v")
end

--- Write one value into the caller's `cosmic_meta` table (see
--- meta_get), replacing whatever was there.
--- @param db_any any An open sqlite.Database
--- @param key string The key
--- @param value string The value
--- @return boolean True on success
--- @return string Error message
local function meta_set(db_any: any, key: string, value: string): boolean, string
  if not (db_any is Db) then
    return false, "meta_set: not a sqlite.Database"
  end
  local db = db_any
  return db:exec([[
    INSERT INTO cosmic_meta(k, v) VALUES (?, ?)
    ON CONFLICT(k) DO UPDATE SET v = excluded.v
  ]], {key, value})
end

--- The connection's own `PRAGMA user_version` — the lightest-weight
--- version stamp SQLite carries natively, needing no table of its own.
--- @param db_any any An open sqlite.Database
--- @return integer | nil The version
--- @return string Error message
local function db_user_version(db_any: any): integer | nil, string
  if not (db_any is Db) then
    return nil, "db_user_version: not a sqlite.Database"
  end
  local db = db_any
  local row, err = db:query_one("PRAGMA user_version")
  if row == nil then
    return nil, err or "PRAGMA user_version returned no row"
  end
  local n, cerr = column_mod.column_number(row, "user_version")
  if n == nil then
    return nil, cerr
  end
  return math.tointeger(n)
end

local record meta
  schema_fingerprint: function(db_any: any): string | nil, string
  meta_get: function(db_any: any, key: string): string | nil, string
  meta_set: function(db_any: any, key: string, value: string): boolean, string
  db_user_version: function(db_any: any): integer | nil, string
end

local M: meta = {
  schema_fingerprint = schema_fingerprint,
  meta_get = meta_get,
  meta_set = meta_set,
  db_user_version = db_user_version,
}

return M
