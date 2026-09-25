--- The shape of a cosmic database, in one place.
---
--- Every ordinary table is WITHOUT ROWID on a natural key, so insertion
--- order cannot reach the bytes and two builds of one tree produce one
--- file. `docs`, `catalog` and `examples` are the exceptions: FTS5's
--- external-content mode needs a real rowid to join against, so each
--- is keyed on one instead -- ordinary INSERTs still run in one
--- deterministic order (see `build/writer.tl`), which is what keeps the
--- file byte-identical, not the rowid's absence. `ca_roots` and
--- `zoneinfo` are ones too, for their size: a WITHOUT ROWID row lives in
--- an index page, where a blob past about a kilobyte spills into
--- overflow pages of its own; see below. Each is written in key order.

local record schema
end

--- Each table's name and its column list, in creation order.
local tables: {{string}} = {
  { "meta", "(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID" },

  -- bytecode comes before source: every require reads it, and SQLite
  -- reaches a column by walking the row's overflow-page chain past
  -- every earlier one, so putting it first keeps a require from paging
  -- through the much larger source text to get there. The Lua tl
  -- generated is not here: nothing that reads this file loads it, and
  -- the working database's `compiled` keeps it for the build. `source`
  -- is stored raw-deflated (`deflate(X)`, `build.writer`), as is a
  -- declaration's: only an uncaught error's line and `Store.source`
  -- read it, and it is most of what a module's row weighs.
  { "modules", [[(path TEXT PRIMARY KEY,
                  file TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  source_hash BLOB NOT NULL,
                  key BLOB NOT NULL,
                  bytecode BLOB NOT NULL,
                  tests TEXT NOT NULL,
                  source BLOB NOT NULL) WITHOUT ROWID]] },

  { "imports", [[(path TEXT NOT NULL,
                  requires TEXT NOT NULL,
                  PRIMARY KEY (path, requires)) WITHOUT ROWID]] },

  { "decls", [[(path TEXT PRIMARY KEY,
                source BLOB NOT NULL) WITHOUT ROWID]] },

  -- TODO: nothing writes payload, which doc/design.md says holds an
  -- embed-built executable's own files: have build/embed.tl carry a
  -- project's files here, or drop the table and the doc's line.
  { "payload", [[(path TEXT PRIMARY KEY,
                  data BLOB NOT NULL) WITHOUT ROWID]] },

  -- The IANA time zone database, one TZif file per zone name, which
  -- `cosmic.time` reads where the host has no zone files of its own.
  { "zoneinfo", [[(name TEXT PRIMARY KEY,
                   data BLOB NOT NULL)]] },

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

  -- The bill of materials (`build.bom`): filled in cosmic's own
  -- projection, carried by the tool and copied into every executable
  -- `cosmic build` writes; empty in a project's projection.
  { "components", [[(name TEXT PRIMARY KEY,
                     kind TEXT NOT NULL,
                     version TEXT NOT NULL,
                     license TEXT NOT NULL,
                     url TEXT NOT NULL,
                     sha256 TEXT NOT NULL,
                     patches TEXT NOT NULL) WITHOUT ROWID]] },

  { "notices", [[(component TEXT NOT NULL,
                  ordinal INTEGER NOT NULL,
                  file TEXT NOT NULL,
                  text TEXT NOT NULL,
                  PRIMARY KEY (component, ordinal)) WITHOUT ROWID]] },

  -- The CA roots the binary trusts (`build.roots`), one DER
  -- certificate a row: filled and carried as the bill of materials is.
  -- A rowid table, unlike the rest: a row of a WITHOUT ROWID table
  -- past about a thousand bytes spills onto an overflow page of its
  -- own, which more than doubled this one's size. Rows go in in
  -- `sha256` order, which keeps the file the same on every build, and
  -- `build.roots` never writes one certificate twice.
  { "ca_roots", [[(sha256 BLOB NOT NULL,
                   label TEXT NOT NULL,
                   der BLOB NOT NULL)]] },

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

--- The query answering one digest of the data tables a binary carries
--- that `cosmic refresh` replaces without moving its runtime identity
--- (core/store.c, `runtime`): every zone by name and bytes, every CA
--- root by digest, label and bytes, in key order, under the schema
--- `qualifier` names. `cosmic test` keys each verdict on it, computed
--- from the running binary's own rows (`build.test`), so a test that
--- read a zone or a root runs again on a binary that carries others.
function schema.tables_digest(qualifier: string): string
  return "SELECT lower(hex(sha256('zoneinfo' || char(10) || " ..
    "coalesce((SELECT group_concat(name || ' ' || lower(hex(sha256(data))), " ..
    "char(10) ORDER BY name) FROM " .. qualifier .. "zoneinfo), '') || char(10) || " ..
    "'ca_roots' || char(10) || coalesce((SELECT group_concat(lower(hex(sha256)) || " ..
    "' ' || lower(hex(label)) || ' ' || lower(hex(sha256(der))), char(10) " ..
    "ORDER BY sha256, label, der) FROM " .. qualifier .. "ca_roots), ''))))"
end

return schema
