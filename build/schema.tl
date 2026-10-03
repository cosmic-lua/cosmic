--- The shape of a cosmic database, in one place.
---
--- Tables use natural keys, with WITHOUT ROWID for narrow rows. The
--- producers insert every table in a deterministic order, including the
--- rowid tables: `docs`, `catalog` and `examples`, which FTS5 joins by
--- rowid; `ca_roots` and `zoneinfo`, whose blobs fit table pages better;
--- and `modules`, whose separate path index keeps name lookups from
--- reading other modules' overflow pages. A rowid is never an identity
--- a reader may keep across builds.

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
  -- is stored raw-deflated (`deflate(X)`, [`build.writer`]), as is a
  -- declaration's: only an uncaught error's line and [`Store.source`]
  -- read it, and it is most of what a module's row weighs.
  -- A WITHOUT ROWID lookup compares wide records and can read their
  -- overflow chains even when only the path is needed. A separate
  -- narrow primary-key index keeps unrelated bytecode out of a require.
  { "modules", [[(path TEXT PRIMARY KEY NOT NULL,
                  file TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  source_hash BLOB NOT NULL,
                  key BLOB NOT NULL,
                  bytecode BLOB NOT NULL,
                  tests TEXT NOT NULL,
                  source BLOB NOT NULL)]] },

  { "imports", [[(path TEXT NOT NULL,
                  requires TEXT NOT NULL,
                  PRIMARY KEY (path, requires)) WITHOUT ROWID]] },

  -- Each name a module's own block binds to another module, once and to
  -- nothing else ([`build.analyzer.Bound`]): what a type the module
  -- declares means by `name.Member` (`record Entry is
  -- Stream.ArchiveEntry`), which [`build.alias_members`] follows. Unlike
  -- `imports`, `requires` need not be a module the projection holds.
  { "bound", [[(path TEXT NOT NULL,
                name TEXT NOT NULL,
                requires TEXT NOT NULL,
                PRIMARY KEY (path, name)) WITHOUT ROWID]] },

  { "decls", [[(path TEXT PRIMARY KEY,
                source BLOB NOT NULL) WITHOUT ROWID]] },

  -- TODO: nothing writes payload, which doc/design.md says holds an
  -- embed-built executable's own files: have build/embed.tl carry a
  -- project's files here, or drop the table and the doc's line.
  { "payload", [[(path TEXT PRIMARY KEY,
                  data BLOB NOT NULL) WITHOUT ROWID]] },

  -- The IANA time zone database, one TZif file per zone name, which
  -- [`cosmic.time`] reads where the host has no zone files of its own.
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

  -- Each link that resolves of a module's comments, or of a Markdown,
  -- C or Zig file's text, which names no `from_module` ("")
  -- ([`build.link_index`]): where it is, its form ("shortcut", "inline"
  -- or "reference"), its source ("comment", "doc", a doc comment, or
  -- "text", a Markdown file's), its text, and what it
  -- names by `kind`: a "symbol" of `module` (`symbol` as `docs` holds
  -- it, "" for the module's own row), a "file" or directory at `path`
  -- from the root, or an "anchor" of the file at `path`. A column that
  -- does not apply is "". Keyed by target first, as `uses` is, since a
  -- reader asks what links to a target.
  { "links", [[(module TEXT NOT NULL,
                symbol TEXT NOT NULL,
                path TEXT NOT NULL,
                anchor TEXT NOT NULL,
                from_file TEXT NOT NULL,
                line INTEGER NOT NULL,
                column INTEGER NOT NULL,
                from_module TEXT NOT NULL,
                kind TEXT NOT NULL,
                form TEXT NOT NULL,
                source TEXT NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY (module, symbol, path, anchor, from_file, line, column))
                WITHOUT ROWID]] },

  { "examples", [[(id INTEGER PRIMARY KEY,
                   module TEXT NOT NULL,
                   name TEXT NOT NULL,
                   text TEXT NOT NULL,
                   file TEXT NOT NULL,
                   line INTEGER NOT NULL,
                   source TEXT NOT NULL,
                   UNIQUE (file, name))]] },

  -- The bill of materials ([`build.bom`]): filled in cosmic's own
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

  -- The CA roots the binary trusts ([`build.roots`]), one DER
  -- certificate a row: filled and carried as the bill of materials is.
  -- A rowid table: a row of a WITHOUT ROWID table
  -- past about a thousand bytes spills onto an overflow page of its
  -- own, which would more than double this one's size. Rows go in in
  -- `sha256` order, which keeps the file the same on every build, and
  -- [`build.roots`] never writes one certificate twice.
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
--- (`content=`) keeps the searchable text in the content table itself
--- rather than duplicating it into the index's own shadow storage.
--- The documentation and example indexes stem their words (`porter`), so
--- a search for "reading files" finds a comment that says "reads a
--- file". `catalog_fts` keeps the plain tokenizer: an error message is
--- matched as it is spelled, not as a query in words.
local virtual_tables: {{string}} = {
  { "docs_fts",
    "USING fts5(symbol, signature, text, content=docs, content_rowid=id, " ..
    "tokenize='porter unicode61')" },
  { "catalog_fts",
    "USING fts5(message, text, content=catalog, content_rowid=id)" },
  { "examples_fts",
    "USING fts5(name, text, source, content=examples, content_rowid=id, " ..
    "tokenize='porter unicode61')" },
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

--- The statements that rebuild each FTS5 index from its content table's
--- current rows, under `qualifier` as `create` names them. Run them
--- once the tables are filled: it is the documented way to bulk-load an
--- external-content FTS5 table, and needs none of the triggers that
--- would keep the two in sync, which a write-once database has no use
--- for.
function schema.rebuild(qualifier: string): {string}
  local out: {string} = {}
  for _, pair in ipairs(virtual_tables) do
    out[#out + 1] = "INSERT INTO " .. qualifier .. pair[1] .. "(" .. pair[1] ..
      ") VALUES ('rebuild')"
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
--- from the running binary's own rows ([`build.test`]), so a test that
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
