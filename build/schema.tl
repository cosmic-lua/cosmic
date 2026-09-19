--- The shape of a cosmic database, in one place.
---
--- Every table is WITHOUT ROWID on a natural key, so insertion order
--- cannot reach the bytes and two builds of one tree produce one file.

local record schema
end

--- Each table's name and its column list, in creation order.
local tables: {{string}} = {
  { "meta", "(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID" },

  { "modules", [[(path TEXT PRIMARY KEY,
                  file TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  source_hash BLOB NOT NULL,
                  key BLOB NOT NULL,
                  source TEXT NOT NULL,
                  lua TEXT NOT NULL,
                  bytecode BLOB NOT NULL,
                  tests TEXT NOT NULL) WITHOUT ROWID]] },

  { "imports", [[(path TEXT NOT NULL,
                  requires TEXT NOT NULL,
                  PRIMARY KEY (path, requires)) WITHOUT ROWID]] },

  { "images", [[(target TEXT PRIMARY KEY,
                 sha256 BLOB NOT NULL,
                 size INTEGER NOT NULL,
                 encoding TEXT NOT NULL,
                 data BLOB NOT NULL) WITHOUT ROWID]] },

  { "decls", [[(path TEXT PRIMARY KEY,
                source TEXT NOT NULL) WITHOUT ROWID]] },

  { "payload", [[(path TEXT PRIMARY KEY,
                  data BLOB NOT NULL) WITHOUT ROWID]] },
}

--- The settings a reproducible file depends on. They are stated rather
--- than left to the defaults, which could move with a SQLite bump.
local settings: {string} = {
  "page_size = 4096",
  "auto_vacuum = 0",
  "encoding = 'UTF-8'",
}

--- The statements that create an empty database, in order, every table
--- under `qualifier`: `"out."` for a schema attached under that name,
--- `""` for a connection's own.
function schema.create(qualifier: string): {string}
  local out: {string} = {}
  for _, pair in ipairs(tables) do
    out[#out + 1] = "CREATE TABLE " .. qualifier .. pair[1] .. " " .. pair[2]
  end
  return out
end

--- The pragmas that set a database up to be reproducible, for the
--- schema `qualifier` names; they must run before its first table.
function schema.settings(qualifier: string): {string}
  local out: {string} = {}
  for _, setting in ipairs(settings) do
    out[#out + 1] = "PRAGMA " .. qualifier .. setting
  end
  return out
end

return schema
