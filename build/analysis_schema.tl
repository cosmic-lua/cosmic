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

--- The doc block that opens `text`: its first lines up to the first one that does not begin with `--`, a blank line
--- among them, each ended by a line feed, whatever line ends the file has. A tag outside it (in a string, a function's
--- doc, the code) says nothing. [`tag_in_block`] is the same cut in SQL.
local function leading_block(text: string): string
  local out: mut {string} = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    if line:sub(1, 2) ~= "--" then break end
    out[#out + 1] = line
  end
  return table.concat(out, "\n") .. "\n"
end

--- Whether the doc block that opens `text` holds `tag` as a line of its own, a file saved with CR LF line ends as well
--- as one with LF.
local function holds_line(text: string, tag: string): boolean
  return ("\n" .. leading_block(text)):find("\n" .. tag .. "\n", 1, true) ~= nil
end

--- The SQL expression that is true where the doc block that opens the text `source` holds `tag` as a line of its own:
--- the cut [`leading_block`] makes, found by a recursive walk over the lines, which `GLOB` and `instr` cannot do.
local function tag_in_block(source: string, tag: string): string
  local text = "(replace(" .. source .. ", char(13) || char(10), char(10)) || char(10))"
  local walk = "(WITH RECURSIVE r(p) AS (SELECT 1 UNION ALL SELECT p + instr(substr(" .. text .. ", p), char(10)) " ..
    "FROM r WHERE substr(" .. text .. ", p, 2) = '--') SELECT max(p) FROM r)"
  return "instr(char(10) || substr(" .. text .. ", 1, " .. walk .. " - 1), char(10) || '" .. tag .. "' || char(10)) > 0"
end

--- Whether the text of a declaration file holds [`analysis_schema.binding_tag`] as a line of its own, a file saved with
--- CR LF line ends as well as one with LF.
function analysis_schema.declares_binding(text: string): boolean
  return holds_line(text, binding_tag)
end

local public_tag <const> = "--- @public"

--- The line a module of a closed directory holds to open itself to every importer, as a module of a namespace is
--- ([`build.positions`]). Like [`analysis_schema.binding_tag`], a line of the module's doc block that the docs leave out.
function analysis_schema.public_tag(): string
  return public_tag
end

--- Whether the source of a module holds [`analysis_schema.public_tag`] as a line of its own.
function analysis_schema.declares_public(text: string): boolean
  return holds_line(text, public_tag)
end

--- Whether `path`, below the root, is test support: a file of the top-level `test/` directory, which no module that is
--- no test may require, as it may no test, since the tool carries neither ([`build.positions`]). It is a layout contract
--- like `*_test.tl`, the same in every project.
function analysis_schema.is_support(path: string): boolean
  return globbed("test/*", path)
end

--- The SQL expression for the kind of the file whose path is in `column`: `binding`, `decl`, `test`, `example`, `main` or
--- `module` ([`kinds`]). With `source`, the SQL expression for its text, a declaration file that declares itself a
--- binding is one.
local function kind_case(column: string, source?: string): string
  local out: mut {string} = { "CASE" }
  if source ~= nil then
    out[#out + 1] = " WHEN " .. column .. " GLOB '*.d.tl' AND " .. tag_in_block(source, binding_tag) .. " THEN 'binding'"
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
