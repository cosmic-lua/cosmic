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
--- ([`build.importer`]'s `analyzer_modules`). [`build.work_schema`], which the
--- modules of both read their handles by, is in both too; the rest of
--- [`build.work`], which only stages and keeps records, is in neither.
--- This module requires nothing, since an edit to what it required
--- would move both identities.
---
--- See [`build.work`] for what each table holds.

-- The SQL of the schema, first: [`Analysis`] is made of these constants, and the record holds it.

--- The patterns of [`apart`].
local TESTDATA <const> = "testdata/*"
local NESTED_TESTDATA <const> = "*/testdata/*"

--- The SQL condition under which the path in the column `path` is a static
--- asset, as [`analysis_schema.static_asset`] says: under `static/`, or
--- under `static/` of a directory directly under `cmd/`. Constant text,
--- so the `inputs` view, and the schema that holds it, is too.
local STATIC_PATHS <const> = "(path GLOB 'static/?*' OR (path GLOB 'cmd/?*/static/?*' AND " ..
  "instr(substr(path, 5), '/') = instr(substr(path, 5), '/static/')))"

--- The SQL that holds the path in the column `path` outside the static
--- assets and outside every pattern of [`apart`].
local OUTSIDE_APART <const> = "AND NOT " .. STATIC_PATHS .. " AND path NOT GLOB '" .. TESTDATA ..
  "' AND path NOT GLOB '" .. NESTED_TESTDATA .. "'"

--- The globs of [`kinds`].
local DECL_GLOB <const> = "*.d.tl"
local TEST_GLOB <const> = "*_test.tl"
local EXAMPLE_GLOB <const> = "*_example.tl"
local MAIN_GLOB <const> = "cmd/*/main.tl"
local MAIN_EXCEPT <const> = "cmd/*/*/*"

--- The kinds of [`named_kinds`].
local BINDING <const> = "binding"
local LANGUAGE <const> = "language"

--- What a line names a kind by, before the kind.
local KIND_TAG <const> = "--- @kind "

--- The text of a row of `files` in the `inputs` view, a file saved with CR LF line ends read as one with LF, and a
--- line feed after its last line.
local FILE_TEXT <const> = "(replace(CAST(data AS TEXT), char(13) || char(10), char(10)) || char(10))"

--- The doc block that opens [`FILE_TEXT`]: the cut [`leading_block`] makes, found by a recursive walk over the lines,
--- which `GLOB` and `instr` cannot do.
local FILE_BLOCK <const> = "substr(" .. FILE_TEXT .. ", 1, (WITH RECURSIVE r(p) AS (SELECT 1 UNION ALL SELECT p + " ..
  "instr(substr(" .. FILE_TEXT .. ", p), char(10)) FROM r WHERE substr(" .. FILE_TEXT .. ", p, 2) = '--') " ..
  "SELECT max(p) FROM r) - 1)"

--- The SQL expression for the kind of the row of `files` in the `inputs` view: `binding`, `language`, `decl`, `test`,
--- `example`, `main` or `module` ([`kinds`]). A declaration file whose doc block ([`FILE_BLOCK`]) names its kind
--- ([`named_kinds`]) on a line of its own is that kind.
local KIND_CASE <const> = "CASE" ..
  " WHEN path GLOB '" .. DECL_GLOB .. "' AND instr(char(10) || " .. FILE_BLOCK .. ", char(10) || '" .. KIND_TAG ..
  BINDING .. "' || char(10)) > 0 THEN '" .. BINDING .. "'" ..
  " WHEN path GLOB '" .. DECL_GLOB .. "' AND instr(char(10) || " .. FILE_BLOCK .. ", char(10) || '" .. KIND_TAG ..
  LANGUAGE .. "' || char(10)) > 0 THEN '" .. LANGUAGE .. "'" ..
  " WHEN path GLOB '" .. DECL_GLOB .. "' THEN 'decl'" ..
  " WHEN path GLOB '" .. TEST_GLOB .. "' THEN 'test'" ..
  " WHEN path GLOB '" .. EXAMPLE_GLOB .. "' THEN 'example'" ..
  " WHEN path GLOB '" .. MAIN_GLOB .. "' AND path NOT GLOB '" .. MAIN_EXCEPT .. "' THEN 'main'" ..
  " ELSE 'module' END"

local DERIVED <const> = [[CREATE TABLE IF NOT EXISTS derived (file TEXT PRIMARY KEY,
                                        path TEXT NOT NULL,
                                        kind TEXT NOT NULL,
                                        origin TEXT NOT NULL,
                                        from_hash TEXT NOT NULL,
                                        source TEXT NOT NULL,
                                        source_hash TEXT NOT NULL) WITHOUT ROWID]]
local INPUTS <const> = [[CREATE VIEW IF NOT EXISTS inputs AS
      SELECT path AS file,
             replace(CASE WHEN path GLOB '*/init.d.tl' THEN substr(path, 1, length(path) - 10)
                          WHEN path GLOB '*.d.tl' THEN substr(path, 1, length(path) - 5)
                          WHEN path GLOB '*/init.tl' THEN substr(path, 1, length(path) - 8)
                          ELSE substr(path, 1, length(path) - 3) END, '/', '.') AS path,
             ]] .. KIND_CASE .. [[ AS kind,
             'tree' AS origin,
             sha256 AS from_hash,
             CAST(data AS TEXT) AS source,
             sha256 AS source_hash
        FROM files WHERE path GLOB '*.tl'
          ]] .. OUTSIDE_APART .. [[
      UNION ALL
      SELECT file, path, kind, origin, from_hash, source, source_hash FROM derived]]
local PARSED <const> = [[CREATE TABLE IF NOT EXISTS parsed (source_hash TEXT PRIMARY KEY,
                                       has_return INTEGER NOT NULL,
                                       export TEXT NOT NULL) WITHOUT ROWID]]
local REQUIRES <const> = [[CREATE TABLE IF NOT EXISTS requires (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local TESTS <const> = [[CREATE TABLE IF NOT EXISTS tests (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local CATALOG <const> = [[CREATE TABLE IF NOT EXISTS catalog (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        symbol TEXT NOT NULL,
                                        message TEXT NOT NULL,
                                        line INTEGER NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local DOCS <const> = [[CREATE TABLE IF NOT EXISTS docs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     symbol TEXT NOT NULL,
                                     source_symbol TEXT NOT NULL,
                                     exported INTEGER NOT NULL,
                                     kind TEXT NOT NULL,
                                     signature TEXT NOT NULL,
                                     text TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local REFS <const> = [[CREATE TABLE IF NOT EXISTS refs (source_hash TEXT NOT NULL,
                                     ordinal INTEGER NOT NULL,
                                     module TEXT NOT NULL,
                                     member TEXT NOT NULL,
                                     line INTEGER NOT NULL,
                                     PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local BOUND <const> = [[CREATE TABLE IF NOT EXISTS bound (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      name TEXT NOT NULL,
                                      module TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local EXAMPLES <const> = [[CREATE TABLE IF NOT EXISTS examples (source_hash TEXT NOT NULL,
                                         ordinal INTEGER NOT NULL,
                                         name TEXT NOT NULL,
                                         text TEXT NOT NULL,
                                         source TEXT NOT NULL,
                                         line INTEGER NOT NULL,
                                         PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local TEST_INPUTS <const> = [[CREATE TABLE IF NOT EXISTS test_inputs (source_hash TEXT NOT NULL,
                                            ordinal INTEGER NOT NULL,
                                            field TEXT NOT NULL,
                                            value TEXT NOT NULL,
                                            PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local LINKS <const> = [[CREATE TABLE IF NOT EXISTS links (source_hash TEXT NOT NULL,
                                      ordinal INTEGER NOT NULL,
                                      line INTEGER NOT NULL,
                                      column INTEGER NOT NULL,
                                      form TEXT NOT NULL,
                                      doc INTEGER NOT NULL,
                                      text TEXT NOT NULL,
                                      target TEXT NOT NULL,
                                      own INTEGER NOT NULL,
                                      alias TEXT NOT NULL,
                                      PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local STUBS <const> = [[CREATE TABLE IF NOT EXISTS stubs (source_hash TEXT PRIMARY KEY,
                                      text TEXT NOT NULL,
                                      pruned INTEGER NOT NULL) WITHOUT ROWID]]
local GLOBALS <const> = [[CREATE TABLE IF NOT EXISTS globals (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        line INTEGER NOT NULL,
                                        column INTEGER NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local PLACES <const> = [[CREATE TABLE IF NOT EXISTS places (source_hash TEXT NOT NULL,
                                       ordinal INTEGER NOT NULL,
                                       symbol TEXT NOT NULL,
                                       kind TEXT NOT NULL,
                                       line INTEGER NOT NULL,
                                       column INTEGER NOT NULL,
                                       length INTEGER NOT NULL,
                                       plain INTEGER NOT NULL,
                                       PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local MEMBERS <const> = [[CREATE TABLE IF NOT EXISTS members (source_hash TEXT NOT NULL,
                                        ordinal INTEGER NOT NULL,
                                        owner TEXT NOT NULL,
                                        name TEXT NOT NULL,
                                        kind TEXT NOT NULL,
                                        scope TEXT NOT NULL,
                                        type TEXT NOT NULL,
                                        PRIMARY KEY (source_hash, ordinal)) WITHOUT ROWID]]
local EXECUTABLE <const> = [[CREATE TABLE IF NOT EXISTS executable (source_hash TEXT PRIMARY KEY,
                                           lines TEXT NOT NULL) WITHOUT ROWID]]

--- The tables and the view of a parse, as one schema: [`build.work`]'s `Database` joins it, and a handle of that
--- reads every table here. Alone it holds no `files`, which the `inputs` view reads.
local schema Analysis = DERIVED .. ";\n" ..
  INPUTS .. ";\n" ..
  PARSED .. ";\n" ..
  REQUIRES .. ";\n" ..
  TESTS .. ";\n" ..
  CATALOG .. ";\n" ..
  DOCS .. ";\n" ..
  REFS .. ";\n" ..
  BOUND .. ";\n" ..
  EXAMPLES .. ";\n" ..
  TEST_INPUTS .. ";\n" ..
  LINKS .. ";\n" ..
  STUBS .. ";\n" ..
  GLOBALS .. ";\n" ..
  PLACES .. ";\n" ..
  MEMBERS .. ";\n" ..
EXECUTABLE

local record analysis_schema
  --- The statements that create `derived` and `inputs`, then each of
  --- `tables`, in order.
  mut statements: {string}
  --- The tables a parse or a generator fills, keyed by the source they
  --- came from: rows in them are only ever as right as the code that
  --- derived them.
  mut tables: {string}
  --- The schema of [`analysis_schema.statements`], joined ([`Analysis`]).
  type Analysis = Analysis

  --- A static asset ([`analysis_schema.static_asset`]).
  record StaticAsset
    --- The program it is for: "" for one under `static/`, every program's, and `<name>` for one under
    --- `cmd/<name>/static/`.
    program: string
    --- Its path below that `static/` ("css/app.css").
    path: string
  end
end

--- Where a build reads no module from, as `GLOB` patterns of a path
--- below the root: the programs a `testdata` directory holds for other
--- projects. A static asset ([`analysis_schema.static_asset`]) is none
--- either. The `inputs` view leaves the Teal there out, and
--- [`build.derivation`] the templates.
local apart <const>: {string} = { TESTDATA, NESTED_TESTDATA }

--- The static asset ([`cosmic.layout`]'s `static`) the file `path`, below
--- the root, is, or nil when it is none: `static/css/app.css` is the asset
--- `css/app.css` of every program, whose program is "", and
--- `cmd/spam/static/css/app.css` is the asset `css/app.css` of `spam` alone,
--- which it holds in place of the other.
function analysis_schema.static_asset(path: string): analysis_schema.StaticAsset?
  if path:sub(1, 7) == "static/" and #path > 7 then return { program = "", path = path:sub(8) } end
  local name, asset = path:match("^cmd/([^/]+)/static/(.+)$")
  if name ~= nil and asset ~= nil then return { program = name, path = asset } end
  return nil
end

--- `sql`, written of the column `path`, of the column `column`: an SQL
--- identifier of the query, never data.
local function of_column(sql: string, column: string): string
  return (sql:gsub("%f[%w_]path%f[^%w_]", function(): string return column end))
end

--- The SQL condition under which the path in `column` is a static asset
--- ([`STATIC_PATHS`]).
function analysis_schema.static_files(column: string): string
  return of_column(STATIC_PATHS, column)
end

--- The SQL that holds the path in `column` outside every pattern of
--- [`apart`] and outside the static assets ([`OUTSIDE_APART`]).
function analysis_schema.outside_apart(column: string): string
  return of_column(OUTSIDE_APART, column)
end

--- Whether `path` matches the `GLOB` pattern `glob`, its `*` any run of characters (a `/` too).
local function globbed(glob: string, path: string): boolean
  return path:match("^" .. glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$") ~= nil
end

--- Whether a build reads the file `path`, a path below the root, as a
--- module: Teal or a template, no static asset, and outside [`apart`], each
--- pattern matched as `GLOB` matches it, its `*` any run of characters.
function analysis_schema.is_module_file(path: string): boolean
  if path:match("%.tl$") == nil and path:match("%.tmpl$") == nil then return false end
  if analysis_schema.static_asset(path) ~= nil then return false end
  for _, pattern in ipairs(apart) do
    if globbed(pattern, path) then return false end
  end
  return true
end

--- What a Teal file is by its path, in the order they are asked: a declaration, a test, an example, a program's main
--- (`except` a main of a directory below `cmd/<name>/`), else a module. The one definition of the kind: the `inputs` view
--- asks it in SQL ([`KIND_CASE`]) and everything else through [`analysis_schema.kind_of`], both of these constants, in
--- this order.
local kinds <const>: {{string}} = {
  { DECL_GLOB, "decl", "" },
  { TEST_GLOB, "test", "" },
  { EXAMPLE_GLOB, "example", "" },
  { MAIN_GLOB, "main", MAIN_EXCEPT },
}

--- The kinds a declaration file names itself by, a line of its leading doc block: `--- @kind <kind>`. A declaration that
--- names none is refused by a build ([`build.driver`]'s `naming`). `binding` is a module implemented in C: a declaration the
--- contract of the error slots ([`build.syntax_contracts`]) holds the calls of; the generator of a derived declaration
--- writes it too ([`build.gen_syscalls`]). `language` is the language's own declarations, the build's globals
--- ([`analysis_schema.is_language_file`]). This list is the one source of the kinds a declaration may name, asked in SQL
--- ([`KIND_CASE`]) and in Teal ([`analysis_schema.kind_of`]).
local named_kinds <const>: {string} = { BINDING, LANGUAGE }

--- The line a declaration file holds to name `kind` (one of [`named_kinds`]).
local function tag_of(kind: string): string
  return KIND_TAG .. kind
end

--- The line a declaration file holds to say it declares a table of C bindings, as [`analysis_schema.declares_binding`] reads it.
function analysis_schema.binding_tag(): string
  return tag_of("binding")
end

--- The line a declaration file holds to say it holds the language's own declarations, as
--- [`analysis_schema.declares_language`] reads it.
function analysis_schema.language_tag(): string
  return tag_of("language")
end

--- The lines that name a kind of declaration, which are for the build and which the docs leave out.
function analysis_schema.kind_tags(): {string}
  local out: mut {string} = {}
  for _, kind in ipairs(named_kinds) do out[#out + 1] = tag_of(kind) end
  return out
end

local prelude_file <const> = "lang/prelude.d.tl"
local stdlib_file <const> = "lang/stdlib.d.tl"

--- The file of the prelude, below the root of the tree.
function analysis_schema.prelude_file(): string
  return prelude_file
end

--- The file of the standard library's declarations, below the root of the tree.
function analysis_schema.stdlib_file(): string
  return stdlib_file
end

--- Whether `path`, below the root, may name its kind `language`: the two files that are the build's globals, and no other.
--- A project has no declarations of the language of its own.
function analysis_schema.is_language_file(path: string): boolean
  return path == prelude_file or path == stdlib_file
end

--- The doc block that opens `text`: its first lines up to the first one that does not begin with `--`, a blank line
--- among them, each ended by a line feed, whatever line ends the file has. A tag outside it (in a string, a function's
--- doc, the code) says nothing. [`FILE_BLOCK`] is the same cut in SQL.
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

--- Whether the text of a declaration file holds [`analysis_schema.binding_tag`] as a line of its own, a file saved with
--- CR LF line ends as well as one with LF.
function analysis_schema.declares_binding(text: string): boolean
  return holds_line(text, tag_of("binding"))
end

--- The kinds of [`named_kinds`] whose line the doc block that opens `text` holds, in that order: more than one is a
--- declaration that does not say what it is, which a build refuses ([`build.driver`]'s `naming`).
function analysis_schema.kinds_named(text: string): {string}
  local out: mut {string} = {}
  for _, kind in ipairs(named_kinds) do
    if holds_line(text, tag_of(kind)) then out[#out + 1] = kind end
  end
  return out
end

--- Whether the text of a declaration file holds [`analysis_schema.language_tag`] as a line of its own.
function analysis_schema.declares_language(text: string): boolean
  return holds_line(text, tag_of("language"))
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

local declaration_kind <const> = "decl"

--- The kinds that are a declaration, a file of types that no program runs, not a module: the one place that says
--- which, asked in SQL ([`analysis_schema.declaration`]) and in Teal ([`analysis_schema.is_declaration`]). A kind a
--- derived declaration is given belongs here before it is written to the `derived` table. A `binding` is a declaration
--- of a table of C, a `language` the language's own.
local declarations <const>: {string} = { declaration_kind, "binding", "language" }

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

--- The complaint about two files one import path could mean (`x.tl` and `x/init.tl`), `files` being their names joined with
--- " and ": the derive's refusal of them ([`build.derivation`]), which the editor words the same.
function analysis_schema.sharing(files: string, path: string): string
  return files .. " both answer to import path '" .. path .. "'; delete or rename one"
end

--- Whether `kind`, the kind of a module of a build, is a declaration.
function analysis_schema.is_declaration(kind: string): boolean
  for _, each in ipairs(declarations) do
    if kind == each then return true end
  end
  return false
end

--- The kind of the Teal file `path`, below the root, as the `inputs` view says it: `binding`, `language`, `decl`, `test`,
--- `example`, `main` or `module`. A declaration is named for its kind only given its `text`; asked of the path alone it is
--- `decl`, which is also a declaration that names none (a build refuses that).
function analysis_schema.kind_of(path: string, text?: string): string
  if text ~= nil and globbed("*.d.tl", path) then
    for _, kind in ipairs(named_kinds) do
      if holds_line(text, tag_of(kind)) then return kind end
    end
  end
  for _, rule in ipairs(kinds) do
    local glob, kind, except = assert(rule[1]), assert(rule[2]), assert(rule[3])
    if globbed(glob, path) and (except == "" or not globbed(except, path)) then return kind end
  end
  return "module"
end

analysis_schema.tables = {
  "parsed", "requires", "tests", "catalog", "docs", "refs", "bound", "examples", "test_inputs", "links",
  "stubs", "globals", "places", "members", "executable",
}

analysis_schema.statements = {
  DERIVED,
  INPUTS,
  PARSED,
  REQUIRES,
  TESTS,
  CATALOG,
  DOCS,
  REFS,
  BOUND,
  EXAMPLES,
  TEST_INPUTS,
  LINKS,
  STUBS,
  GLOBALS,
  PLACES,
  MEMBERS,
  EXECUTABLE,
}

return analysis_schema
