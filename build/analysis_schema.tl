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

--- Where a build reads no module from, as `GLOB` patterns of a path
--- below the root: a site's static files, and the programs a `testdata`
--- directory holds for other projects. The `inputs` view leaves the Teal
--- there out, and [`build.derivation`] the templates.
local apart <const>: {string} = { "static/*", "testdata/*", "*/testdata/*" }

--- The SQL that holds the path in `column` outside every pattern of
--- [`apart`], an `AND <column> NOT GLOB '<pattern>'` each.
function analysis_schema.outside_apart(column: string): string
  local out: mut {string} = {}
  for _, pattern in ipairs(apart) do
    out[#out + 1] = "AND " .. column .. " NOT GLOB '" .. pattern .. "'"
  end
  return table.concat(out, " ")
end

--- Whether `path` matches the `GLOB` pattern `glob`, its `*` any run of characters (a `/` too).
local function globbed(glob: string, path: string): boolean
  return path:match("^" .. glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$") ~= nil
end

--- Whether a build reads the file `path`, a path below the root, as a
--- module: Teal or a template, outside [`apart`], each
--- pattern matched as `GLOB` matches it, its `*` any run of characters.
function analysis_schema.is_module_file(path: string): boolean
  if path:match("%.tl$") == nil and path:match("%.tmpl$") == nil then return false end
  for _, pattern in ipairs(apart) do
    if globbed(pattern, path) then return false end
  end
  return true
end

--- What a Teal file is by its path, in the order they are asked: a declaration, a test, an example, a program's main
--- (`except` a main of a directory below `cmd/<name>/`), else a module. The one definition of the kind: the `inputs` view
--- asks it in SQL ([`kind_case`]) and everything else through [`analysis_schema.kind_of`], both of this table.
local kinds <const>: {{string}} = {
  { "*.d.tl", "decl", "" },
  { "*_test.tl", "test", "" },
  { "*_example.tl", "example", "" },
  { "cmd/*/main.tl", "main", "cmd/*/*/*" },
}

--- The line a declaration file holds to say it declares a table of C bindings: the kind `binding`, a declaration the
--- contract of the error slots ([`build.syntax_contracts`]) holds the calls of. The generator of a derived declaration
--- writes it too ([`build.gen_syscalls`]).
local binding_tag <const> = "--- @kind binding"

--- The line, as [`analysis_schema.declares_binding`] reads it.
function analysis_schema.binding_tag(): string
  return binding_tag
end

--- Whether the text of a declaration file holds [`analysis_schema.binding_tag`] as a line of its own.
function analysis_schema.declares_binding(text: string): boolean
  return ("\n" .. text .. "\n"):find("\n" .. binding_tag .. "\n", 1, true) ~= nil
end

--- The SQL expression for the kind of the file whose path is in `column`: `binding`, `decl`, `test`, `example`, `main` or
--- `module` ([`kinds`]). With `source`, the SQL expression for its text, a declaration file that declares itself a
--- binding is one.
local function kind_case(column: string, source?: string): string
  local out: mut {string} = { "CASE" }
  if source ~= nil then
    out[#out + 1] = " WHEN " .. column .. " GLOB '*.d.tl' AND instr(char(10) || " .. source .. " || char(10), char(10) || '" ..
      binding_tag .. "' || char(10)) > 0 THEN 'binding'"
  end
  for _, rule in ipairs(kinds) do
    local glob, kind, except = assert(rule[1]), assert(rule[2]), assert(rule[3])
    local clause = " WHEN " .. column .. " GLOB '" .. glob .. "'"
    if except ~= "" then clause = clause .. " AND " .. column .. " NOT GLOB '" .. except .. "'" end
    out[#out + 1] = clause .. " THEN '" .. kind .. "'"
  end
  out[#out + 1] = " ELSE 'module' END"
  return table.concat(out)
end

local declaration_kind <const> = "decl"

--- The kind a build gives a declaration it writes or derives and says nothing more of ([`build.derivation`],
--- [`build.lsp.plan`]).
function analysis_schema.declaration_kind(): string
  return declaration_kind
end

--- The kinds that are a declaration, a file of types that no program runs, not a module: the one place that says
--- which, asked in SQL ([`analysis_schema.declaration`]) and in Teal ([`analysis_schema.is_declaration`]). A kind a
--- derived declaration is given belongs here before it is written to the `derived` table. A `binding` is a declaration
--- of a table of C.
local declarations <const>: {string} = { declaration_kind, "binding" }

--- The SQL expression that is true of a row whose kind in `column` is a declaration. `column` is an SQL identifier of
--- the query, never data: it is spliced into the statement.
function analysis_schema.declaration(column: string): string
  return column .. " IN ('" .. table.concat(declarations, "', '") .. "')"
end

--- The SQL expression that is true of a row whose kind in `column` is no declaration: a module, a test, an example,
--- a main, or whatever else a build reads that is not a file of types. `column` is an SQL identifier of the query, never
--- data: it is spliced into the statement.
function analysis_schema.not_declaration(column: string): string
  return column .. " NOT IN ('" .. table.concat(declarations, "', '") .. "')"
end

--- Whether `kind`, the kind of a module of a build, is a declaration.
function analysis_schema.is_declaration(kind: string): boolean
  for _, each in ipairs(declarations) do
    if kind == each then return true end
  end
  return false
end

--- The kind of the Teal file `path`, below the root, as the `inputs` view says it: `binding`, `decl`, `test`, `example`,
--- `main` or `module`. A declaration is a `binding` only given its `text`; asked of the path alone it is `decl`, which a
--- caller that wants to know a module from a declaration cannot tell from one.
function analysis_schema.kind_of(path: string, text?: string): string
  if text ~= nil and globbed("*.d.tl", path) and analysis_schema.declares_binding(text) then
    return "binding"
  end
  for _, rule in ipairs(kinds) do
    local glob, kind, except = assert(rule[1]), assert(rule[2]), assert(rule[3])
    if globbed(glob, path) and (except == "" or not globbed(except, path)) then return kind end
  end
  return "module"
end

analysis_schema.tables = {
  "parsed", "requires", "tests", "catalog", "docs", "refs", "bound", "examples", "test_inputs", "links",
  "stubs", "globals",
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
             ]] .. kind_case("path", "CAST(data AS TEXT)") .. [[ AS kind,
             'tree' AS origin,
             sha256 AS from_hash,
             CAST(data AS TEXT) AS source,
             sha256 AS source_hash
        FROM files WHERE path GLOB '*.tl'
          ]] .. analysis_schema.outside_apart("path") .. [[
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
  [[CREATE TABLE IF NOT EXISTS stubs (source_hash TEXT PRIMARY KEY,
                                      text TEXT NOT NULL,
                                      pruned INTEGER NOT NULL) WITHOUT ROWID]],
  [[CREATE TABLE IF NOT EXISTS globals (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        line INTEGER NOT NULL,
                                        column INTEGER NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]],
}

return analysis_schema
