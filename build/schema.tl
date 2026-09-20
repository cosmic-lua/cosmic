--- The shape of a cosmic database, in one place.
---
--- Every ordinary table is WITHOUT ROWID on a natural key, so insertion
--- order cannot reach the bytes and two builds of one tree produce one
--- file. `docs`, `catalog` and `examples` are the exceptions: FTS5's
--- external-content mode needs a real rowid to join against, so each
--- is keyed on one instead -- ordinary INSERTs still run in one
--- deterministic order (see `build/writer.tl`), which is what keeps the
--- file byte-identical, not the rowid's absence.

local record schema
end

--- Each table's name and its column list, in creation order.
local tables: {{string}} = {
  { "meta", "(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID" },

  -- bytecode comes before source and lua: every require reads it, and
  -- SQLite reaches a column by walking the row's overflow-page chain
  -- past every earlier one, so putting it first keeps a require from
  -- paging through the much larger source text to get there.
  { "modules", [[(path TEXT PRIMARY KEY,
                  file TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  source_hash BLOB NOT NULL,
                  key BLOB NOT NULL,
                  bytecode BLOB NOT NULL,
                  tests TEXT NOT NULL,
                  source TEXT NOT NULL,
                  lua TEXT NOT NULL) WITHOUT ROWID]] },

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

  { "docs", [[(id INTEGER PRIMARY KEY,
               module TEXT NOT NULL,
               symbol TEXT NOT NULL,
               source_symbol TEXT NOT NULL,
               exported INTEGER NOT NULL,
               kind TEXT NOT NULL,
               signature TEXT NOT NULL,
               text TEXT NOT NULL,
               file TEXT NOT NULL,
               line INTEGER NOT NULL)]] },

  { "uses", [[(module TEXT NOT NULL,
                     symbol TEXT NOT NULL,
                     from_module TEXT NOT NULL,
                     from_file TEXT NOT NULL,
                     line INTEGER NOT NULL,
                     PRIMARY KEY (module, symbol, from_module, line)) WITHOUT ROWID]] },

  { "examples", [[(id INTEGER PRIMARY KEY,
                   module TEXT NOT NULL,
                   name TEXT NOT NULL,
                   text TEXT NOT NULL,
                   file TEXT NOT NULL,
                   line INTEGER NOT NULL,
                   source TEXT NOT NULL,
                   UNIQUE (module, name))]] },

  { "catalog", [[(id INTEGER PRIMARY KEY,
                  kind TEXT NOT NULL,
                  module TEXT NOT NULL,
                  symbol TEXT,
                  message TEXT,
                  text TEXT,
                  file TEXT NOT NULL,
                  line INTEGER NOT NULL)]] },
}

--- Each FTS5 virtual table's name and its `USING fts5(...)` clause, in
--- creation order, after every ordinary table. External-content mode
--- (`content=`) keeps the searchable text in `catalog` itself rather
--- than duplicating it into the index's own shadow storage.
local virtual_tables: {{string}} = {
  { "docs_fts",
    "USING fts5(symbol, signature, text, content=docs, content_rowid=id)" },
  { "catalog_fts",
    "USING fts5(message, text, content=catalog, content_rowid=id)" },
  { "examples_fts",
    "USING fts5(name, text, source, content=examples, content_rowid=id)" },
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
  for _, pair in ipairs(virtual_tables) do
    out[#out + 1] =
      "CREATE VIRTUAL TABLE " .. qualifier .. pair[1] .. " " .. pair[2]
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
