--- The part of the working database's schema ([`build.work`]'s `schema`)
--- a parse's rows are shaped by: the `derived` table, the `inputs`
--- view every module source is read through, and the tables a parse
--- or a generator fills, keyed by the source they came from.
---
--- What a source parses to is recorded in these columns, in this order.
--- [`build.derivation`]'s shared parses read them with `SELECT *` and check
--- only each table's width. The `inputs` view decides what a compile is
--- given beside a source: its import path and kind, the file it is read
--- from, and whether it was generated.
---
--- So this module is one of the roots of the compiler's identity
--- ([`build.identity`]'s `compiler_roots`) and of the analyzer's
--- ([`build.importer`]'s `analyzer_modules`). The rest of [`build.work`],
--- which only stages and keeps records, is in neither.
--- This module requires nothing, since an edit to what it required
--- would move both identities.
---
--- See [`build.work`] for what each table holds.

local record analysis_schema
  --- The statements that create `derived` and `inputs`, then each of
  --- `tables`, in order.
  statements: {string}
  --- The tables a parse or a generator fills, keyed by the source they
  --- came from: rows in them are only ever as right as the code that
  --- derived them.
  tables: {string}
end

analysis_schema.tables = {
  "parsed", "requires", "tests", "catalog", "docs", "refs", "bound", "examples", "test_inputs", "links",
}

analysis_schema.statements = {
  [[CREATE TABLE IF NOT EXISTS derived (file TEXT PRIMARY KEY,
                                        path TEXT NOT NULL,
                                        kind TEXT NOT NULL,
                                        origin TEXT NOT NULL,
                                        from_hash TEXT NOT NULL,
                                        source TEXT NOT NULL,
                                        source_hash TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE VIEW IF NOT EXISTS inputs AS
      SELECT path AS file,
             replace(CASE WHEN path GLOB '*.d.tl' THEN substr(path, 1, length(path) - 5)
                          WHEN path GLOB '*/init.tl' THEN substr(path, 1, length(path) - 8)
                          ELSE substr(path, 1, length(path) - 3) END, '/', '.') AS path,
             CASE WHEN path GLOB '*.d.tl' THEN 'decl'
                  WHEN path GLOB '*_test.tl' THEN 'test'
                  WHEN path GLOB '*_example.tl' THEN 'example'
                  WHEN path GLOB 'cmd/*/main.tl' AND path NOT GLOB 'cmd/*/*/*' THEN 'main'
                  ELSE 'module' END AS kind,
             'tree' AS origin,
             sha256 AS from_hash,
             CAST(data AS TEXT) AS source,
             sha256 AS source_hash
        FROM files WHERE path GLOB '*.tl'
          AND path NOT GLOB 'testdata/*'
          AND path NOT GLOB '*/testdata/*'
      UNION ALL
      SELECT file, path, kind, origin, from_hash, source, source_hash FROM derived]],
  [[CREATE TABLE IF NOT EXISTS parsed (source_hash TEXT PRIMARY KEY,
                                       has_return INTEGER NOT NULL,
                                       export TEXT NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS requires (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS tests (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS catalog (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        symbol TEXT NOT NULL,
                                        message TEXT NOT NULL,
                                        line INTEGER NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS docs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     symbol TEXT NOT NULL,
                                     source_symbol TEXT NOT NULL,
                                     exported INTEGER NOT NULL,
                                     kind TEXT NOT NULL,
                                     signature TEXT NOT NULL,
                                     text TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS refs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     module TEXT NOT NULL,
                                     member TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS bound (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      module TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS examples (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         text TEXT NOT NULL,
                                         source TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS test_inputs (source_hash TEXT NOT NULL,
                                            ordinal INTEGER NOT NULL,
                                            field TEXT NOT NULL,
                                            value TEXT NOT NULL,
                                            PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS links (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      line INTEGER NOT NULL,
                                      column INTEGER NOT NULL,
                                      form TEXT NOT NULL,
                                      doc INTEGER NOT NULL,
                                      text TEXT NOT NULL,
                                      target TEXT NOT NULL,
                                      own INTEGER NOT NULL,
                                      alias TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
}

return analysis_schema
