--- The shape of a cosmic database, in one place.
---
--- Every table is WITHOUT ROWID on a natural key, so insertion order
--- cannot reach the bytes and two builds of one tree produce one file.

local record schema
  tables: {string}
  settings: {string}
end

--- The statements that create an empty database, in order.
schema.tables = {
  "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",

  [[CREATE TABLE modules (path TEXT PRIMARY KEY,
                          file TEXT NOT NULL,
                          kind TEXT NOT NULL,
                          source_hash BLOB NOT NULL,
                          key BLOB NOT NULL,
                          source TEXT NOT NULL,
                          lua TEXT NOT NULL,
                          bytecode BLOB NOT NULL,
                          decl TEXT) WITHOUT ROWID]],

  [[CREATE TABLE imports (path TEXT NOT NULL,
                          requires TEXT NOT NULL,
                          PRIMARY KEY (path, requires)) WITHOUT ROWID]],

  [[CREATE TABLE images (target TEXT PRIMARY KEY,
                         sha256 BLOB NOT NULL,
                         size INTEGER NOT NULL,
                         encoding TEXT NOT NULL,
                         data BLOB NOT NULL) WITHOUT ROWID]],

  [[CREATE TABLE payload (path TEXT PRIMARY KEY,
                          data BLOB NOT NULL) WITHOUT ROWID]],
}

--- The settings a reproducible file depends on. They are stated rather
--- than left to the defaults, which could move with a SQLite bump.
schema.settings = {
  "PRAGMA page_size = 4096",
  "PRAGMA auto_vacuum = 0",
  "PRAGMA encoding = 'UTF-8'",
}

return schema
