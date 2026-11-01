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
  --- The name of the `docs` index of a module's `local` declarations.
  local_index: string
end

schema.local_index = "docs_by_local"

--- What a statement creates: the `name` of a table or an index and the `body` after it.
local record Definition
  name: string
  body: string
end

--- Each table's name and its column list, in creation order.
local tables: {Definition} = {
  { name = "meta", body = "(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID" },

  -- bytecode comes before source: every require reads it, and SQLite
  -- reaches a column by walking the row's overflow-page chain past
  -- every earlier one, so putting it first keeps a require from paging
  -- through the much larger source text to get there. The Lua tl
  -- generated is not here: nothing that reads this file loads it, and
  -- the working database's `compiled` keeps it for the build, with the
  -- bytecode as `string.dump` wrote it. `bytecode` is stored
  -- raw-deflated (`deflate(X)`, [`build.writer`]): the core inflates it
  -- when it loads a module and in [`Store.bytecode`], and a query that
  -- reads its bytes inflates it first (`inflate(bytecode)`), so no
  -- digest or key moves with the compressor. `source` is stored the
  -- same way, as is a declaration's: only an uncaught error's line and
  -- [`Store.source`] read it, and it is most of what a module's row
  -- weighs.
  -- A WITHOUT ROWID lookup compares wide records and can read their
  -- overflow chains even when only the path is needed. A separate
  -- narrow primary-key index keeps unrelated bytecode out of a require.
  { name = "modules", body = [[(path TEXT PRIMARY KEY NOT NULL,
                  file TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  source_hash BLOB NOT NULL,
                  key BLOB NOT NULL,
                  bytecode BLOB NOT NULL,
                  tests TEXT NOT NULL,
                  source BLOB NOT NULL)]] },

  { name = "imports", body = [[(path TEXT NOT NULL,
                  requires TEXT NOT NULL,
                  PRIMARY KEY (path, requires)) WITHOUT ROWID]] },

  -- Every module the source the checker reads for a path requires by a
  -- literal name, its declaration's where it has one, whether or not
  -- the projection holds the name as a module. The type checker
  -- follows these (a declaration is checked, never loaded), so
  -- [`build.plans`]'s `dependency_keys` reads them instead of
  -- parsing an embedded source again. Nothing that decides what loads
  -- reads this table: a closure over it would make a declaration-only
  -- module loadable. Each module has a row with the empty name beside
  -- its edges, so a module that requires nothing is told from one the
  -- table was written without.
  { name = "decl_imports", body = [[(path TEXT NOT NULL,
                       requires TEXT NOT NULL,
                       PRIMARY KEY (path, requires)) WITHOUT ROWID]] },

  -- Each name a module's own block binds to another module, once and to
  -- nothing else ([`build.syntax_analyzer`]'s `Bound`): what a type the module
  -- declares means by `name.Member` (`record Entry is
  -- Stream.ArchiveEntry`), which [`build.alias_members`] follows. Unlike
  -- `imports`, `requires` need not be a module the projection holds.
  { name = "bound", body = [[(path TEXT NOT NULL,
                name TEXT NOT NULL,
                requires TEXT NOT NULL,
                PRIMARY KEY (path, name)) WITHOUT ROWID]] },

  { name = "decls", body = [[(path TEXT PRIMARY KEY,
                source BLOB NOT NULL) WITHOUT ROWID]] },

  -- The stub of each of the standard library's modules (build.stub),
  -- raw-deflated like a source: what a project's checker is given in
  -- place of the module's source. Only cosmic's own projection
  -- and the tool fill it; a program has no checker to read it.
  { name = "stubs", body = [[(path TEXT PRIMARY KEY,
                source BLOB NOT NULL) WITHOUT ROWID]] },

  -- Where each standard-library module declares its types and their
  -- members ([`build.syntax_places`]), in the module's source as `modules`
  -- holds it: the working database's `places` of that source, by module.
  -- What `cosmic lsp` answers a go to definition of a symbol of the
  -- binary's own `cosmic.*` modules from, in a project, where the working
  -- database holds no such module ([`build.lsp.source`]'s
  -- `places`). `line` and `column` count from 1, `length` in
  -- bytes; `plain` is 1 where the name's line holds only ASCII and the
  -- protocol numbers the lines before it as the lexer does. Only cosmic's own projection and the tool fill it; a program
  -- has no editor to answer.
  { name = "places", body = [[(module TEXT NOT NULL,
                  ordinal INTEGER NOT NULL,
                  symbol TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  line INTEGER NOT NULL,
                  column INTEGER NOT NULL,
                  length INTEGER NOT NULL,
                  plain INTEGER NOT NULL,
                  PRIMARY KEY (module, ordinal)) WITHOUT ROWID]] },

  -- What each standard-library module declares its types to have
  -- ([`build.syntax_members`]): the working database's `members` of the
  -- module's source as `modules` holds it, by module, with `doc` the
  -- text of the doc comment on the same symbol ("" for none), which the
  -- working database holds in `docs`. What `cosmic lsp` completes the
  -- members of a type of the binary's own `cosmic.*` modules from, in a
  -- project, where the working database holds no such module
  -- ([`build.lsp.source`]'s `members`). Only cosmic's own projection and
  -- the tool fill it; a program has no editor to answer.
  { name = "members", body = [[(module TEXT NOT NULL,
                  ordinal INTEGER NOT NULL,
                  owner TEXT NOT NULL,
                  name TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  scope TEXT NOT NULL,
                  type TEXT NOT NULL,
                  doc TEXT NOT NULL,
                  PRIMARY KEY (module, ordinal)) WITHOUT ROWID]] },

  -- The file a standard-library module generated from another file (the
  -- syscall modules, from `core/*.h`) is generated from, raw-deflated like a
  -- source, beside the module's `places`, which hold the lines of that file
  -- ([`build.syntax_derivation`]'s `origin_lines`). `cosmic lsp` writes the
  -- file below the build directory and answers there. `sha256` is the
  -- file's, as hex. Only cosmic's own projection and the tool fill it.
  { name = "origins", body = [[(module TEXT PRIMARY KEY,
                  file TEXT NOT NULL,
                  sha256 TEXT NOT NULL,
                  source BLOB NOT NULL) WITHOUT ROWID]] },

  -- A project's static assets ([`Layout.static`]), one row per
  -- file under `static/`: `path` relative to it ("css/app.css"), the
  -- bytes, their lowercase hex SHA-256, the Content-Type
  -- ([`cosmic.mime`]), the gzip of the bytes when that is worth
  -- sending ([`Mime.gzip`]), else NULL, and their zstd when that is
  -- ([`Mime.zstd`]), else NULL. [`cosmic.web.assets`] reads it from the
  -- program's own database.
  { name = "payload", body = [[(path TEXT PRIMARY KEY,
                  data BLOB NOT NULL,
                  sha256 TEXT NOT NULL,
                  type TEXT NOT NULL,
                  gzip BLOB,
                  zstd BLOB) WITHOUT ROWID]] },

  -- The IANA time zone database, one TZif file per zone name, which
  -- [`cosmic.time`] reads where the host has no zone files of its own.
  { name = "zoneinfo", body = [[(name TEXT PRIMARY KEY,
                   data BLOB NOT NULL)]] },

  -- The browser-side files [`cosmic.web`] serves under `/_web/` (htmx and
  -- its SSE extension), each with its SHA-256 as hex and its SHA-384 as
  -- base64, the value of an `integrity` attribute, computed at boot.
  { name = "web_assets", body = [[(name TEXT PRIMARY KEY,
                     data BLOB NOT NULL,
                     sha256 TEXT NOT NULL,
                     sha384 TEXT NOT NULL,
                     version TEXT NOT NULL) WITHOUT ROWID]] },

  { name = "docs", body = [[(id INTEGER PRIMARY KEY,
               module TEXT NOT NULL,
               symbol TEXT NOT NULL,
               source_symbol TEXT NOT NULL,
               exported INTEGER NOT NULL,
               kind TEXT NOT NULL,
               signature TEXT NOT NULL,
               text TEXT NOT NULL,
               file TEXT NOT NULL,
               line INTEGER NOT NULL)]] },

  { name = "uses", body = [[(module TEXT NOT NULL,
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
  { name = "links", body = [[(module TEXT NOT NULL,
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

  { name = "examples", body = [[(id INTEGER PRIMARY KEY,
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
  { name = "components", body = [[(name TEXT PRIMARY KEY,
                     kind TEXT NOT NULL,
                     version TEXT NOT NULL,
                     license TEXT NOT NULL,
                     url TEXT NOT NULL,
                     sha256 TEXT NOT NULL,
                     sha3_256 TEXT NOT NULL,
                     patches TEXT NOT NULL) WITHOUT ROWID]] },

  { name = "notices", body = [[(component TEXT NOT NULL,
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
  -- `distrust_after` is [`build.roots.Root`]'s.
  { name = "ca_roots", body = [[(sha256 BLOB NOT NULL,
                   label TEXT NOT NULL,
                   der BLOB NOT NULL,
                   distrust_after TEXT NOT NULL)]] },

  -- The certificates OneCRL revokes ([`build.onecrl`]), filled and
  -- carried as `ca_roots` is, in the order of their bytes.
  { name = "ca_revoked", body = [[(kind TEXT NOT NULL,
                     name BLOB NOT NULL,
                     value BLOB NOT NULL)]] },

  { name = "catalog", body = [[(id INTEGER PRIMARY KEY,
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
local virtual_tables: {Definition} = {
  { name = "docs_fts", body =
      "USING fts5(symbol, signature, text, content=docs, content_rowid=id, " ..
      "tokenize='porter unicode61')" },
  { name = "catalog_fts", body =
      "USING fts5(message, text, content=catalog, content_rowid=id)" },
  { name = "examples_fts", body =
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

--- The SQL for the last dotted name of the SQL `symbol`, a method's `:`
--- read as `.` (`Box:grow` and `X.Box.grow` both end in `grow`): what
--- follows `symbol`'s last `.`, by dropping the longest prefix that ends
--- in one. The `docs` index on it ([`schema.create`]) is found by the
--- planner only through this very text, so a query that means to use it
--- builds the expression here.
function schema.last_name(symbol: string): string
  local dotted = "replace(" .. symbol .. ", ':', '.')"
  return "replace(" .. dotted .. ", rtrim(" .. dotted .. ", replace(" .. dotted ..
    ", '.', '')), '')"
end

--- The indexes of the `docs` table, each as its name and what follows
--- `ON docs` in its statement. A lookup by name reads a symbol by its
--- last name, its source spelling or its module rather than scanning
--- every row. A module is found by the end of its name in the index of
--- the modules' own rows. A public source's filter
--- ([`symbols.shown_docs`]) finds a module's `local` declarations in
--- the index of those alone. A query answers the same rows with them or
--- without them, so a database written before they existed is only
--- slower to read.
local docs_indexes: {Definition} = {
  { name = "docs_by_last_name", body = "(" .. schema.last_name("symbol") .. ")" },
  { name = "docs_by_source_symbol", body = "(source_symbol)" },
  { name = "docs_by_module", body = "(module)" },
  { name = "docs_by_module_row", body = "(module) WHERE symbol = ''" },
  { name = schema.local_index, body = "(module, source_symbol) WHERE exported = 0 AND signature LIKE 'local %'" },
}

--- The statements that create an empty database, in order, every table
--- and then every index under `qualifier`: `"out."` for a schema
--- attached under that name, `""` for a connection's own.
function schema.create(qualifier: string): {string}
  local out: mut {string} = {}
  for _, pair in ipairs(tables) do
    out[#out + 1] = "CREATE TABLE " .. qualifier .. pair.name .. " " .. pair.body
  end
  for _, pair in ipairs(docs_indexes) do
    out[#out + 1] = "CREATE INDEX " .. qualifier .. pair.name .. " ON docs " .. pair.body
  end
  for _, pair in ipairs(virtual_tables) do
    out[#out + 1] =
      "CREATE VIRTUAL TABLE " .. qualifier .. pair.name .. " " .. pair.body
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
  local out: mut {string} = {}
  for _, pair in ipairs(virtual_tables) do
    out[#out + 1] = "INSERT INTO " .. qualifier .. pair.name .. "(" .. pair.name ..
      ") VALUES ('rebuild')"
  end
  return out
end

--- The pragmas that set a database up to be reproducible, for the
--- schema `qualifier` names; they must run before its first table.
function schema.settings(qualifier: string): {string}
  local out: mut {string} = {}
  for _, setting in ipairs(settings) do
    out[#out + 1] = "PRAGMA " .. qualifier .. setting
  end
  return out
end

--- The query answering one digest of the data tables a binary carries
--- that `cosmic refresh` replaces without moving its runtime identity
--- (core/store.c, `runtime`): every zone by name and bytes, every CA
--- root by digest, label and bytes, every web asset by name, version and
--- digest, in key order, under the schema
--- `qualifier` names. `cosmic test` keys each verdict on it, computed
--- from the running binary's own rows ([`build.test`]), so a test that
--- read a zone or a root runs again on a binary that carries others.
--- `web` false leaves the web assets out, for a database from before
--- that table, which has none to read.
function schema.tables_digest(qualifier: string, web?: boolean): string
  local assets = ""
  if web ~= false then
    assets = " || char(10) || 'web_assets' || char(10) || coalesce((SELECT group_concat(name || ' ' || " ..
      "version || ' ' || sha256, char(10) ORDER BY name) FROM " .. qualifier .. "web_assets), '')"
  end
  return "SELECT lower(hex(sha256('zoneinfo' || char(10) || " ..
    "coalesce((SELECT group_concat(name || ' ' || lower(hex(sha256(data))), " ..
    "char(10) ORDER BY name) FROM " .. qualifier .. "zoneinfo), '') || char(10) || " ..
    "'ca_roots' || char(10) || coalesce((SELECT group_concat(lower(hex(sha256)) || " ..
    "' ' || lower(hex(label)) || ' ' || lower(hex(sha256(der))) || ' ' || distrust_after, char(10) " ..
    "ORDER BY sha256, label, der) FROM " .. qualifier .. "ca_roots), '') || char(10) || " ..
    "'ca_revoked' || char(10) || coalesce((SELECT group_concat(kind || ' ' || lower(hex(name)) || " ..
    "' ' || lower(hex(value)), char(10) ORDER BY kind, name, value) FROM " .. qualifier ..
    "ca_revoked), '')" .. assets .. ")))"
end

return schema
