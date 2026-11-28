--- What a database says about a symbol: the lookup, the search and the pages behind `cosmic docs` and `cosmic
--- uses`, read off the `docs`, `uses`, `links` and `examples` tables a build writes. The tool asks it of its own
--- databases and a project's; a program built with `cosmic build` carries its project's public rows and may ask
--- it of those.
---
--- A caller lists its databases in a [`Doc.view`], in the order they are read, and asks the view: [`Doc.lookup`]
--- for what a query names, [`Doc.render`] for an entry's page, [`Doc.answer`] for the page of some words whole,
--- [`Doc.uses`] for where a symbol is referred to.
---
--- A query is a symbol first -- [`Fs.read`], `read`, [`cosmic.fs`] -- and
--- words to search the documentation for when no symbol is called that.
--- A qualified name that names nothing (Proc.which) resolves to what
--- its qualifier offers, and a search ranks first the functions whose
--- documentation names its first word as what they stand in for.

local Failure = require("cosmic.failure")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local link_text = require("cosmic.internal.link_text")
local source_run = require("cosmic.internal.source_run")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local type Command = Types.Command
local type View = Types.View
local type Entry = Types.Entry
local type Lookup = Types.Lookup
local type Answer = Types.Answer
local type Summary = Types.Summary
local type Taking = Types.Taking

local Examples = require("cosmic.doc.examples")
local Search = require("cosmic.doc.search")
local Usage = require("cosmic.doc.usage")
local Pages = require("cosmic.doc.pages")
local Members = require("cosmic.doc.members")
local Resolve = require("cosmic.doc.resolve")
local NOTE_LIMIT = Search.NOTE_LIMIT
local across = Usage.across
local clipped = Search.clipped
local coded = Usage.coded
local columns = Examples.columns
local database_of = Usage.database_of
local docs_command = Usage.docs_command
local documented_text = Search.documented_text
local effective_counts = Usage.effective_counts
local entries_of = Examples.entries_of
local entry_module = Usage.entry_module
local example_of = Search.example_of
local first_sentence = Search.first_sentence
local has_docs = Search.has_docs
local heading = Search.heading
local is_library = Usage.is_library
local is_public = Usage.is_public
local lookup = Resolve.lookup
local lookup_names = Resolve.lookup_names
local member_of = Members.member_of
local module_symbol = Search.module_symbol
local modules_ending = Search.modules_ending
local modules_of = Search.modules_of
local named = Search.named
local named_all = Search.named_all
local refuse_pure = Search.refuse_pure
local render_text = Pages.render_text
local taking_of = Members.taking_of
local text = Examples.text
local uses_text = Members.uses_text

local record Doc
  type Command = Types.Command
  type View = Types.View
  type Example = Types.Example
  type Entry = Types.Entry
  type Lookup = Types.Lookup
  type Answer = Types.Answer
  type Record = Types.Record
  type Records = Types.Records
  type Summary = Types.Summary
  type Taking = Types.Taking
  type Use = Types.Use
  type Unused = Types.Unused
end

--- Whether `db` holds documentation at all: what a caller asks of a database before it lists it among a view's,
--- one that holds none finds nothing. Nil and a [`Failure`] when it cannot be read.
function Doc.documented(db: Sqlite.Handle): (boolean) | (nil, Failure)
  local value, why = documented_text(db)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.view, its failure in words.
local function view_text(databases: {Sqlite.Handle}, public?: {boolean}): View?, string
  local scope: mut {integer: boolean} = {}
  for index, flag in ipairs(public or {}) do
    scope[index] = flag
  end
  local owners: mut {string: integer} = {}
  for index, db in ipairs(databases) do
    local rows, trouble = db:rows(symbols.owned_modules(""))
    if rows == nil then
      refuse_pure(db)
      return nil, tostring(trouble)
    end
    for _, row in ipairs(rows) do
      if owners[row:text(1)] == nil then
        owners[row:text(1)] = index
      end
    end
  end
  return { databases = databases, public = scope, owners = owners,
    use_counts = {}, link_counts = {}, value_records = {}, public_modules = {}, commands = {} }, ""
end

--- Resolves module ownership once for a docs command or direct caller.
--- Membership comes from `modules`, even when the owning database has
--- no documentation for that module, and from `decls` -- [`cosmic.sys`]
--- is only a declaration -- where it does: a database that copied a
--- declaration without its documentation must not hide the one that
--- documents it.
--- @param public which databases, by index, are public sources
function Doc.view(databases: {Sqlite.Handle}, public?: {boolean}): (Doc.View) | (nil, Failure)
  local value, why = view_text(databases, public)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- Returns the documentation of the project's last build as a `cmd/<name>/main.tl` run from its source would
--- carry it built ([`build.embed`]), in place of `db`, the store's connection to that build. The run names the
--- program and the build ([`cosmic.internal.source_run`]'s `main` and `projection`). What it carries: the docs of
--- each module it carries that any module may require, or that sits under its own `cmd/<name>/` (the main, a
--- test, an example and one under `internal/` aside), and the guides, its own in place of the project's of the
--- same name. A module it carries is one its main requires, directly or not, one under its own `cmd/<name>/`, or
--- the one it names as its pages (`pages`), documented wherever it sits, as its build carries it.
---
--- The store's connections only read, so this opens one of its own to the build and fills, in its `temp`
--- schema, a `public_modules` and a `docs` of those rows, an `examples` of the examples of those modules and a
--- `catalog` of the rows of every module it carries, as its build carries them, each with the stored table's
--- indexes; and the index of each (`docs_fts`, `examples_fts`, `catalog_fts`) and the words `docs_words` of that
--- `docs`, as the program's build makes them of the rows it carries ([`build.schema`]'s `rebuild`), so a word
--- is searched, ranked and put right among them alone. They stand in for the stored ones in every statement here
--- that does not name its schema. `db` itself for any other run, and for a database that does not hold the main
--- (the tool's own). Nil and why where the build cannot be read so.
local function scope_to_program(db: Sqlite.Handle, pages?: string): Sqlite.Handle?, string
  local main = source_run.main
  local projection = source_run.projection
  if main == nil or projection == nil then return db, "" end
  local name = main:match("^cmd%.([^%.]+)%.main$")
  if name == nil then return db, "" end
  local held, held_trouble = db:rows("SELECT 1 FROM main.modules WHERE path = ?1", { text(main) })
  if held == nil then return nil, tostring(held_trouble) end
  if #held == 0 then return db, "" end
  -- Opened by its path, as the store attached it: a build that replaced the file since is read in its place.
  local opened, open_trouble = Sqlite.open(projection)
  if opened == nil then return nil, projection .. ": " .. tostring(open_trouble) end
  local function failed(trouble: string): Sqlite.Handle?, string
    local _, _ = opened:close()
    return nil, trouble
  end
  local own = "cmd." .. name .. "."
  local own_guides = own .. "doc.guides."
  -- The module the program names as its pages, which its build carries for being named
  -- ([`build.embed`]'s `pages_named`) where it is the project's, and none a program would not carry for its own:
  -- the rule [`embed.database`] holds a build to, which a change to one changes in both.
  local paged = "(m.path = " .. Sqlite.literal(pages or "") .. " AND m.kind = 'module' AND " ..
    "instr('/' || m.file, '/internal/') = 0 AND (m.path NOT GLOB 'cmd.*' OR substr(m.path, 1, " .. tostring(#own) ..
    ") = " .. Sqlite.literal(own) .. "))"
  local docs_columns, columns_trouble = opened:rows("SELECT name FROM pragma_table_info('docs', 'main')")
  if docs_columns == nil then return failed(tostring(columns_trouble)) end
  local names: mut {string} = {}
  local selected: mut {string} = {}
  for _, column in ipairs(docs_columns) do
    local column_name = column:text(1)
    names[#names + 1] = column_name
    if column_name == "module" then
      selected[#selected + 1] = "CASE WHEN substr(module, 1, " .. tostring(#own_guides) .. ") = " ..
        Sqlite.literal(own_guides) .. " THEN 'doc.guides.' || substr(module, " .. tostring(#own_guides + 1) ..
        ") ELSE module END"
    else
      selected[#selected + 1] = column_name
    end
  end
  local indexes, indexes_trouble = opened:rows(
    "SELECT name, sql FROM main.sqlite_master WHERE name IN ('catalog_fts', 'docs_fts', 'docs_words', " ..
      "'examples_fts') ORDER BY name")
  if indexes == nil then return failed(tostring(indexes_trouble)) end
  local statements: mut {string} = {}
  for _, dropped in ipairs({ "catalog_fts", "docs_fts", "docs_words", "examples_fts", "public_modules", "carried",
      "catalog", "docs", "examples" }) do
    statements[#statements + 1] = "DROP TABLE IF EXISTS temp." .. dropped
  end
  for _, made in ipairs({
      "CREATE TEMP TABLE carried (path TEXT PRIMARY KEY) WITHOUT ROWID",
      "CREATE TEMP TABLE public_modules (path TEXT PRIMARY KEY) WITHOUT ROWID",
      "WITH RECURSIVE carried(path) AS (SELECT " .. Sqlite.literal(main) .. " UNION SELECT path FROM main.modules " ..
        "WHERE kind = 'module' AND substr(path, 1, " .. tostring(#own) .. ") = " .. Sqlite.literal(own) ..
        " UNION SELECT m.path FROM main.modules m WHERE " .. paged ..
        " UNION SELECT i.requires FROM main.imports i JOIN carried c ON i.path = c.path) " ..
        "INSERT INTO temp.carried (path) SELECT path FROM main.modules WHERE path IN (SELECT path FROM carried) " ..
        "ORDER BY path",
      "INSERT INTO temp.public_modules (path) SELECT m.path FROM main.modules m " ..
        "WHERE m.path IN (SELECT path FROM temp.carried) AND (m.path IN (SELECT path FROM main.public_modules) OR " ..
        "(substr(m.path, 1, " .. tostring(#own) .. ") = " .. Sqlite.literal(own) .. " AND m.path <> " ..
        Sqlite.literal(main) .. " AND m.kind = 'module' AND instr('/' || m.file, '/internal/') = 0) OR " .. paged ..
        ") ORDER BY m.path",
  }) do
    statements[#statements + 1] = made
  end
  -- Each stored table and its indexes, made again in `temp`.
  for _, table_name in ipairs({ "catalog", "docs", "examples" }) do
    local definitions, definitions_trouble = opened:rows(
      "SELECT type, sql FROM main.sqlite_master WHERE tbl_name = ?1 AND type IN ('table', 'index') AND " ..
        "sql IS NOT NULL ORDER BY type = 'index', name", { text(table_name) })
    if definitions == nil then return failed(tostring(definitions_trouble)) end
    for _, row in ipairs(definitions) do
      local sql = row:text(2)
      if row:text(1) == "table" then
        statements[#statements + 1] = (sql:gsub("^CREATE TABLE", "CREATE TEMP TABLE", 1))
      else
        statements[#statements + 1] = (sql:gsub("^CREATE (%a* ?)INDEX ", "CREATE %1INDEX temp.", 1))
      end
    end
  end
  -- The examples of the modules it documents, and the catalog of every module it carries, as its build carries
  -- them ([`build.embed`]'s `copy_documentation`, and its catalog of the modules it carries).
  statements[#statements + 1] = "INSERT INTO temp.examples SELECT * FROM main.examples " ..
    "WHERE module IN (SELECT path FROM temp.public_modules) ORDER BY id"
  statements[#statements + 1] = "INSERT INTO temp.catalog SELECT * FROM main.catalog " ..
    "WHERE module IN (SELECT path FROM temp.carried) ORDER BY id"
  -- The rows the program carries: those of each module it documents, its own guides' own rows under the guide's
  -- name, and the project's guides' own rows it has none of its own in place of.
  statements[#statements + 1] = "INSERT INTO temp.docs (" .. table.concat(names, ", ") .. ") SELECT " ..
    table.concat(selected, ", ") .. " FROM main.docs d WHERE d.module IN (SELECT path FROM temp.public_modules) OR " ..
    "(d.symbol = '' AND substr(d.module, 1, " .. tostring(#own_guides) .. ") = " .. Sqlite.literal(own_guides) ..
    " AND instr(substr(d.module, " .. tostring(#own_guides + 1) .. "), '.') = 0) OR (d.symbol = '' AND " ..
    symbols.guide_module("d.module") .. " AND NOT EXISTS (SELECT 1 FROM main.docs o WHERE o.symbol = '' AND " ..
    "o.module = " .. Sqlite.literal(own_guides) .. " || substr(d.module, 12))) ORDER BY d.id"
  -- The index of each and the words of those rows: each stored index made again in `temp`, where its content
  -- table is the one above, and the words counted as [`build.schema`]'s `rebuild` counts them, unstemmed.
  for _, row in ipairs(indexes) do
    local index_name = row:text(1)
    local sql = row:text(2)
    if index_name ~= "docs_words" then
      statements[#statements + 1] = (sql:gsub("^CREATE VIRTUAL TABLE ", "CREATE VIRTUAL TABLE temp.", 1))
      statements[#statements + 1] = "INSERT INTO temp." .. index_name .. " (" .. index_name .. ") VALUES ('rebuild')"
    else
      statements[#statements + 1] = (sql:gsub("^CREATE TABLE", "CREATE TEMP TABLE", 1))
      for _, counting in ipairs({
          "DROP TABLE IF EXISTS temp.scoped_whole_words",
          "DROP TABLE IF EXISTS temp.scoped_whole",
          "CREATE VIRTUAL TABLE temp.scoped_whole USING fts5(symbol, signature, text, content='', " ..
            "tokenize='unicode61')",
          "INSERT INTO temp.scoped_whole (rowid, symbol, signature, text) SELECT id, symbol, signature, text " ..
            "FROM temp.docs ORDER BY id",
          "CREATE VIRTUAL TABLE temp.scoped_whole_words USING fts5vocab('temp', 'scoped_whole', 'row')",
          "INSERT INTO temp.docs_words (word, rows) SELECT term, doc FROM temp.scoped_whole_words " ..
            "WHERE length(term) >= 3 AND term NOT GLOB '*[^a-z]*' ORDER BY term",
          "DROP TABLE temp.scoped_whole_words",
          "DROP TABLE temp.scoped_whole",
      }) do
        statements[#statements + 1] = counting
      end
    end
  end
  for _, statement in ipairs(statements) do
    local ok, trouble = opened:run(statement, {})
    if not ok then return failed(tostring(trouble)) end
  end
  return opened, ""
end

-- Doc.program, its failure in words.
local function program_text(databases: {Sqlite.Handle}, program: string, commands?: {Command},
                            pages?: string): View?, string
  local documented: mut {Sqlite.Handle} = {}
  local public: mut {boolean} = {}
  for _, db in ipairs(databases) do
    local holds, holds_trouble = has_docs(db)
    if holds == nil then
      return nil, holds_trouble
    end
    if holds then
      local in_scope, scope_trouble = scope_to_program(db, pages)
      if in_scope == nil then
        return nil, scope_trouble
      end
      documented[#documented + 1] = in_scope
      public[#public + 1] = true
    else
      refuse_pure(db)
    end
  end
  local view, trouble = view_text(documented, public)
  if view == nil then
    return nil, trouble
  end
  -- The databases that document the standard library, by index: the tool's own, and a test's store, which holds
  -- the library's rows its closure requires beside its tree's. Of the guides each holds, by index, those whose
  -- module it holds too: a tree's own guides are modules of it, where the tool carries only their rows.
  local of_library: mut {integer: boolean} = {}
  local own_guides: mut {integer: {string: boolean}} = {}
  for index, db in ipairs(documented) do
    local recorded, recorded_trouble = symbols.public_modules(db)
    if recorded == nil then
      return nil, recorded_trouble
    end
    for module in pairs(recorded) do
      if symbols.is_library_module(module) then of_library[index] = true end
    end
    if of_library[index] == true then
      local rows, rows_trouble = db:rows("SELECT path FROM modules WHERE " ..
          symbols.guide_module("path"))
      if rows == nil then
        return nil, tostring(rows_trouble)
      end
      local held: mut {string: boolean} = {}
      for _, row in ipairs(rows) do held[row:text(1)] = true end
      own_guides[index] = held
    end
  end
  local owners: mut {string: integer} = {}
  for module, owner in pairs(view.owners) do
    local guide = module:sub(1, 11) == "doc.guides."
    local tools = guide and of_library[owner] == true and (own_guides[owner] or {})[module] ~= true
    if not symbols.is_library_module(module) and not tools then
      owners[module] = owner
    end
  end
  return { databases = view.databases, public = view.public, owners = owners, use_counts = {}, link_counts = {},
    value_records = {}, public_modules = {}, commands = commands or {}, program = program }, ""
end

--- A view of a program's own documentation, for the program to show its users: `databases` are its
--- store's, each a public source, so only the modules any module may require are found. The standard library's
--- show nothing, a program's users being asked about the program: neither a `cosmic.*` module nor a guide
--- the tool carries, which is a guide's row in a database that documents the standard library without the
--- guide's module. A test's store, which declares `store_text`, holds its tree's public guides as modules, so
--- there they are found as they are in the built program. So the built
--- program reads what `cosmic build` put in it, and the same program run from its source by the tool
--- reads the project's last build, which the tool's store holds beside its own. A database that
--- holds no documentation is left out. `program` is what its user types to run it, which the hints of a page
--- name, and `commands` are its commands, as [`Doc.Command`] says. Nil and a [`Failure`] when a database cannot be read;
--- raises on a test's store that withholds the documentation, naming `store_text`. A `cmd/<name>/main.tl` run
--- from its source finds what it would find built ([`scope_to_program`]), `pages` the module its commands' pages are
--- read from ([`Flags.Documented`]), which a build carries for being named.
function Doc.program(databases: {Sqlite.Handle}, program: string, commands?: {Doc.Command},
                     pages?: string): (Doc.View) | (nil, Failure)
  local value, why = program_text(databases, program, commands, pages)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.guide, its failure in words.
local function guide_text(view: View, name: string): string?, string
  local module = "doc.guides." .. name
  local owner = view.owners[module]
  if owner == nil or not symbols.is_public_guide(module) then
    return nil, ""
  end
  local rows, trouble = database_of(view, owner):rows(
    "SELECT text FROM docs WHERE module = ?1 AND symbol = '' ORDER BY id LIMIT 1", { text(module) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local row = rows[1]
  if row == nil then
    return nil, ""
  end
  return Doc.shown(row:text(1)), ""
end

--- The text of the guide `name` of `view`'s documentation, `doc/guides/<name>.md`, as a reader is shown it
--- ([`Doc.shown`]): what follows its title. A guide under `doc/guides/internal/`, or one the view does not cover
--- (the tool's, in [`Doc.program`]'s view), is none. False where there is none; nil and a [`Failure`]
--- when a database cannot be read.
function Doc.guide(view: Doc.View, name: string): (string | false) | (nil, Failure)
  local value, why = guide_text(view, name)
  if value == nil then
    if why == "" then return false end
    return nil, Failure.new(why)
  end
  return value
end

-- Doc.lookup, its failure in words.
local function lookup_text(view: View, query: string): Lookup?, string
  local rule, rule_trouble = coded(view, query)
  if rule == nil then
    return nil, rule_trouble
  end
  local names, trouble = lookup_names(view, query)
  if names == nil then
    return nil, trouble
  end
  if #rule == 0 then
    return names, ""
  end
  if not names.exact then
    return lookup(rule, true, #rule), ""
  end
  local ruled = lookup(names, true, names.named + #rule, false, rule)
  ruled.verb = names.verb
  ruled.modules = if names.verb ~= nil then names.modules + #rule else 0 end
  return ruled, ""
end

--- What `query` names, as [`lookup_names`] finds it, and ahead of it the row of the code of the checker it is, when it is
--- one (`not_assignable`): the rule behind the code, then the symbols that share its name (the enum member of [`Codes.Code`]),
--- which stay reachable. A query that only searches (nothing is named exactly) finds the code's row alone. A program's
--- own view ([`Doc.program`]) finds no code.
function Doc.lookup(view: Doc.View, query: string): (Doc.Lookup) | (nil, Failure)
  local value, why = lookup_text(view, query)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.index, its failure in words.
local function index_text(view: View): {Summary}?, string
  local found, trouble = across(view, modules_of, entry_module)
  if found == nil then
    return nil, trouble
  end
  local said: mut {string: string} = {}
  for _, entry in ipairs(found) do
    if entry.symbol == "" then
      said[entry.module] = first_sentence(entry.text)
    end
  end
  local out: mut {Summary} = {}
  for module, owner in pairs(view.owners) do
    local listed = module:sub(-5) ~= "_test" and module:sub(-8) ~= "_example" and
      (view.public[owner] ~= true or is_public(view, module) or
        symbols.is_public_guide(module))
    if listed then
      out[#out + 1] = { module = module, text = said[module] or "", closed = "" }
    end
  end
  table.sort(out, function(a: Summary, b: Summary): boolean
    return a.module < b.module
  end)
  return out, ""
end

--- Every module `view` holds, by name, with the first sentence of its
--- documentation ("" for one it does not document) -- no test or
--- example, which a reader never calls: what `cosmic docs` lists when
--- asked nothing. Each `closed` is "": the list `cosmic docs` prints
--- judges it ([`marked`]), which no other reader of the index pays for.
function Doc.index(view: Doc.View): ({Doc.Summary}) | (nil, Failure)
  local value, why = index_text(view)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.named_all, its failure in words.
local function named_all_text(view: View, names: {string}): {Entry}?, string
  if #names == 0 then
    return {}, ""
  end
  local found, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      return named_all(db, public, names)
    end, entry_module)
  if found == nil then
    return nil, trouble
  end
  local counted, count_trouble = effective_counts(view, found)
  if not counted then
    return nil, count_trouble
  end
  return found, ""
end

--- Every one of `names` that names a symbol exactly, or a module in full
--- (its own row), in one query per database rather than one lookup per
--- name -- built for a caller that needs several known symbols in one
--- command, such as `cosmic help` reading every verb's module. `#names == 0` finds nothing without
--- querying. A name absent from the result was not found; this never
--- fails for that, only for real trouble reading a database.
function Doc.named_all(view: Doc.View, names: {string}): ({Doc.Entry}) | (nil, Failure)
  local value, why = named_all_text(view, names)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.exact, its failure in words.
local function exact_text(view: View, query: string): {Entry}?, string
  if query:match("^%l[%w_]*$") ~= nil then
    local modules, modules_trouble = across(view,
      function(db: Sqlite.Handle, _: boolean): {Entry}?, string
        return modules_ending(db, query)
      end, entry_module)
    if modules == nil then
      return nil, modules_trouble
    end
    if #modules > 0 then
      return modules, ""
    end
  end
  local found, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      return named(db, public, query)
    end, entry_module)
  if found == nil then
    return nil, trouble
  end
  if #found > 0 then
    return found, ""
  end
  local owner = view.owners[query]
  if owner ~= nil then
    local held, held_trouble = module_symbol(database_of(view, owner), view.public[owner] == true, query)
    if held == nil then
      return nil, held_trouble
    end
    if #held > 0 then
      return held, ""
    end
  end
  return Members.in_full(view, query)
end

--- What `query` names exactly, by the rule [`Doc.lookup`] applies to
--- an exact query: the public modules a bare lowercase name ends
--- (only those, when there are any), else every row `named` finds,
--- else the module the index lists under that whole name, else the
--- member of a type an alias stands for ([`Sqlite.Handle.close`], whose
--- row is the aliased record's), else a module's member written in
--- full ([`cosmic.fs.read`]). It neither searches nor counts uses, so it
--- is cheap to ask once per name.
function Doc.exact(view: Doc.View, query: string): ({Doc.Entry}) | (nil, Failure)
  local value, why = exact_text(view, query)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- Every place across `databases` that refers to what `query` names,
--- in file and line order: one per line for each thing it names there.
--- A module's member, written in full ([`cosmic.cli.order`]) or from the
--- module's last name (`Cli.order`), is found as [`Doc.lookup`] finds
--- it, and its uses and links are those of that module's member alone.
function Doc.uses(view: Doc.View, query: string): ({Doc.Use}) | (nil, Failure)
  local value, why = uses_text(view, query)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- The exported functions of the tree's own modules that no code outside their own file uses, tests left out: what
--- could be local, or dropped. A link to one is no use.
function Doc.unused(view: Doc.View): ({Doc.Unused}) | (nil, Failure)
  local found, trouble = across(view, Usage.unused_of, function(u: Doc.Unused): string
    return u.module
  end)
  if found == nil then return nil, Failure.new(trouble) end
  return found
end

--- The exported functions that take a parameter named `word`, as their signatures write it: what a module named for a
--- word (`cosmic.path`) may have meant is the module most of them are in ([`Fs.basename`] takes a `path`).
function Doc.taking(view: Doc.View, word: string): ({Doc.Taking}) | (nil, Failure)
  local found, trouble = across(view, function(db: Sqlite.Handle, public: boolean): {Taking}?, string
    return taking_of(db, public, word)
  end, function(t: Taking): string return t.module end)
  if found == nil then return nil, Failure.new(trouble) end
  return found
end

--- One entry, as `cosmic docs` prints it: where it is, its signature,
--- its documentation indented under that, and how many places use it.
--- A module's row lists the symbols it declares instead of a signature.
--- Nil and a [`Failure`] when a database cannot be read.
function Doc.render(view: Doc.View, entry: Doc.Entry): ({string}) | (nil, Failure)
  local value, why = render_text(view, entry)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- How many entries a search shows whole, when nothing is named
--- exactly; the rest it lists a line each. A search ("read whole
--- file") touches dozens of entries, each a page with its examples.
--- What a query names exactly is shown whole however many there are:
--- the reader asked for each of them by name.
local SHOWN_WHOLE <const> = 5

--- How long the note after a listed entry's heading runs.
local LISTED_NOTE <const> = 80

--- Whether `word` is written as a qualified name ([`Fs.read`],
--- [`cosmic.fs`], `Lid:open`) rather than as a word of prose: several of
--- them are looked up one by one, where bare words are searched for
--- together, since a bare word often names something exactly too
--- ("find", "path").
local function qualified(word: string): boolean
  return word:match("^[%a_][%w_]*[.:][%a_][%w_.:]*$") ~= nil and
    word:find("[.:][.:]") == nil and word:match("[.:]$") == nil
end

--- The lines `found`, what `query` looked up, prints as: every entry
--- whole when the query names it; else a line saying they only relate,
--- the first [`SHOWN_WHOLE`] whole, and the rest a line each.
local function page(view: View, found: Lookup,
                    query: string): {string}?, string
  local lines: mut {string} = {}
  local meant = found.respelled
  if meant ~= nil then
    lines[#lines + 1] = "Nothing named or documented as '" .. query .. "'; showing '" .. meant .. "':"
    lines[#lines + 1] = ""
  end
  if found.closest then
    lines[#lines + 1] = "No entry has every word of '" .. (meant or query) .. "'; closest matches:"
    lines[#lines + 1] = ""
  elseif not found.exact then
    lines[#lines + 1] = "No exact symbol match for '" .. (meant or query) ..
      "'; showing related documentation:"
    lines[#lines + 1] = ""
  end
  local whole = if found.exact then #found else math.min(#found, SHOWN_WHOLE) end
  for index = 1, whole do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    local rendered, trouble = render_text(view, (assert(found[index], "index is within the lookup")))
    if rendered == nil then
      return nil, trouble
    end
    for _, line in ipairs(rendered) do lines[#lines + 1] = line end
    local verb = found.verb
    if verb ~= nil and index == found.modules then
      lines[#lines + 1] = ""
      local program = view.program or "cosmic"
      local asked = if verb.symbol == "" then verb.module else verb.source_symbol end
      lines[#lines + 1] = "See also: the command `" .. program .. " " .. query .. "` (`" .. docs_command(view) .. " " ..
        asked .. "`, `" .. program .. " help " .. query .. "`)."
    end
  end
  if #found > whole then
    lines[#lines + 1] = ""
    lines[#lines + 1] = tostring((#found - whole)) .. " more; narrow the search, or look one up by name:"
    for index = whole + 1, #found do
      local entry = (assert(found[index], "index is within the lookup"))
      local said = if entry.kind == "example" then example_of(entry).text else entry.text end
      local note = clipped(first_sentence(said), LISTED_NOTE)
      lines[#lines + 1] = "  " .. heading(entry) .. (if note ~= "" then " -- " .. note else "" end)
    end
  end
  return lines, ""
end

--- The modules of `index` a line each, aligned, with the first sentence
--- of each, cut to `limit` bytes when there is one.
local function index_lines(index: {Summary}, limit?: integer): mut {string}
  local width = 0
  for _, summary in ipairs(index) do
    width = math.max(width, #summary.module)
  end
  local lines: mut {string} = {}
  for _, summary in ipairs(index) do
    local line = summary.module
    local about = if limit ~= nil then clipped(summary.text, limit) else summary.text end
    if summary.closed ~= "" then
      about = "(" .. summary.closed .. ")" .. (if about ~= "" then " " .. about else "" end)
    end
    if about ~= "" then
      line = line .. string.rep(" ", width - #line + 2) .. about
    end
    lines[#lines + 1] = line
  end
  return lines
end

--- The queries `cosmic docs <words...>` looks up, each as
--- [`Doc.lookup`] resolves it: every word alone when there are several
--- and each is a qualified name, else the words together. Nil for no words or
--- `cosmic` alone, for which [`Doc.answer`] lists the modules.
function Doc.asked(words: {string}): {string}?
  local query = table.concat(words, " ")
  if query == "" or query == "cosmic" or query == "cosmic." then
    return nil
  end
  if #words < 2 then
    return { query }
  end
  for _, word in ipairs(words) do
    if not qualified(word) then
      return { query }
    end
  end
  return words
end

--- The queries `words` ask of `view`, as [`Doc.asked`] names them; a program's view has no list of the standard
--- library, so `cosmic` is a word to it like any other.
local function asked_of(view: View, words: {string}): {string}?
  local asked = Doc.asked(words)
  local query = table.concat(words, " ")
  if asked == nil and view.program ~= nil and query ~= "" then
    return { query }
  end
  return asked
end

--- `index` with each `closed` judged (the view's `marks`), for a module of a database of the tree's own only: a public
--- source's module (the standard library a project builds with) is no module of the tree, and the rule refuses no
--- require of it.
local function marked(view: View, index: {Summary}): {Summary}
  local by_owner: mut {integer: {string: string}} = {}
  local out: mut {Summary} = {}
  for _, summary in ipairs(index) do
    local owner = view.owners[summary.module]
    local closed = ""
    if owner ~= nil and view.public[owner] ~= true then
      local marks = by_owner[owner]
      local judge = view.marks
      if marks == nil and judge ~= nil then
        marks = judge(database_of(view, owner))
        by_owner[owner] = marks
      end
      closed = if marks ~= nil then marks[summary.module] or "" else "" end
    end
    out[#out + 1] = { module = summary.module, text = summary.text, closed = closed }
  end
  return out
end

--- The modules `cosmic docs <words...>` lists when [`Doc.asked`] names no
--- query: every module for no words, the standard library's modules and
--- guides for `cosmic`. Nil and why when a database cannot be read; a mark that cannot be judged
--- is left off.
local function modules_asked(view: View, words: {string}): {Summary}?, string
  local index, trouble = index_text(view)
  if index == nil then
    return nil, trouble
  end
  -- Only the list of every module is marked: `cosmic` lists the library's public modules and guides, none of which
  -- is ever marked.
  if table.concat(words, " ") == "" then
    return marked(view, index), ""
  end
  local library: mut {Summary} = {}
  for _, summary in ipairs(index) do
    if is_library(view, summary.module) or
        symbols.is_public_guide(summary.module) then
      library[#library + 1] = summary
    end
  end
  return library, ""
end

-- Doc.answer, its failure in words.
local function answer_text(view: View, words: {string}): Answer?, string
  local query = table.concat(words, " ")
  local asked = asked_of(view, words)
  if asked == nil then
    local index, index_trouble = modules_asked(view, words)
    if index == nil then
      return nil, index_trouble
    end
    local hint = "`" .. docs_command(view) .. " <module>` shows one, with what it offers; `" ..
      docs_command(view) .. " <words>` searches them all."
    if query ~= "" then
      hint = "`cosmic docs <module>` shows one (cosmic.fs, or fs), with what it " ..
        "offers; `cosmic docs Fs.read` a symbol; `cosmic docs <words>` searches."
    end
    local lines = index_lines(index, if query ~= "" then NOTE_LIMIT else nil end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = hint
    return { lines = lines, found = true, said = String.counted(#index, "module") }, ""
  end
  local each = #asked > 1
  local lines: mut {string} = {}
  local naming, standing, related = 0, 0, 0
  local missed: mut {string} = {}
  for at, asking in ipairs(asked) do
    local found, trouble = lookup_text(view, asking)
    if found == nil then
      return nil, trouble
    end
    if at > 1 then
      lines[#lines + 1] = ""
    end
    if #found == 0 then
      missed[#missed + 1] = "'" .. asking .. "'"
      if each then
        lines[#lines + 1] = "Nothing named or documented as '" .. asking .. "'."
      end
    else
      local shown, page_trouble = page(view, found, asking)
      if shown == nil then
        return nil, page_trouble
      end
      for _, line in ipairs(shown) do lines[#lines + 1] = line end
      if found.exact then
        naming = naming + found.named
        standing = standing + #found - found.named
      else
        related = related + #found
      end
    end
  end
  if #lines > 0 then
    lines[#lines + 1] = ""
  end
  local said: mut {string} = {}
  if #missed > 0 then
    said[#said + 1] = "nothing named or documented as " .. table.concat(missed, ", ")
  end
  if naming > 0 then said[#said + 1] = tostring(naming) .. " named" end
  if standing > 0 then said[#said + 1] = tostring(standing) .. " standing in" end
  if related > 0 then said[#said + 1] = tostring(related) .. " found" end
  return { lines = lines, found = #missed == 0, said = table.concat(said, ", ") }, ""
end

--- What `cosmic docs <words...>` prints, short of its summary:
--- - no words: every module ([`Doc.index`]);
--- - `cosmic` (or `cosmic.`) alone: the standard library's modules and
---   guides, which no search for the word could list in a page;
--- - several words, each a qualified name ([`Fs.read`] [`Fs.write`]):
---   each looked up in turn, as it would be alone;
--- - else the words together, as one query to [`Doc.lookup`]: a
---   symbol, a module or words to search for. A search names at most
---   [`SHOWN_WHOLE`] entries whole.
--- Nil and a [`Failure`] when a database cannot be read.
function Doc.answer(view: Doc.View, words: {string}): (Doc.Answer) | (nil, Failure)
  local value, why = answer_text(view, words)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- How long the signature on a line of [`Doc.brief`] runs.
local BRIEF_SIGNATURE <const> = 90

--- How long the note on a line of [`Doc.brief`] runs.
local BRIEF_NOTE <const> = 100

--- What a search for `words` finds, a line each and no page: `Module.name(signature) -- first sentence`, for each
--- function the query names or the search relates to, in the order [`Doc.lookup`] gives, leaving out the modules'
--- tests and examples. For a name that several modules share ("walk"), or a word to search for, which a page of each
--- would show whole and at length. `found` is false when there is no line; `said` counts them.
--- Nil and a [`Failure`] when a database cannot be read.
function Doc.brief(view: Doc.View, words: {string}): (Doc.Answer) | (nil, Failure)
  -- Several by_name names are each looked up as alone, as [`Doc.answer`] does; other words are one query.
  local by_name = #words > 1
  for _, word in ipairs(words) do
    if word:find(".", 1, true) == nil then by_name = false end
  end
  local queries: mut {string} = {}
  if by_name then
    for _, word in ipairs(words) do queries[#queries + 1] = word end
  else
    queries[1] = table.concat(words, " ")
  end
  local found: mut {Types.Entry} = {}
  for _, query in ipairs(queries) do
    local part, why = lookup_text(view, query)
    if part == nil then return nil, Failure.new(why) end
    for _, entry in ipairs(part) do found[#found + 1] = entry end
  end
  local lines: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, entry in ipairs(found) do
    local listed = (entry.kind == "function" and entry.signature:sub(1, 15) ~= "local function ") or entry.kind == "module"
    local module = entry.module
    if listed and module:sub(-5) ~= "_test" and module:sub(-8) ~= "_example" then
      local name = if entry.kind == "module" then module else module .. " " .. clipped(entry.signature:gsub("^function ", ""), BRIEF_SIGNATURE) end
      if seen[name] ~= true then
        seen[name] = true
        local note = clipped(first_sentence(entry.text), BRIEF_NOTE)
        lines[#lines + 1] = name .. (if note ~= "" then " -- " .. note else "" end)
      end
    end
  end
  return { lines = lines, found = #lines > 0, said = String.counted(#lines, "line") }
end

--- What `cosmic docs` prints for `query` (words), as text: [`Doc.answer`]'s lines joined. Nil and a [`Failure`] that
--- says what to do where `query` holds no word, nothing is found, or a database cannot be read.
function Doc.text(view: Doc.View, query: string): (string) | (nil, Failure)
  local words: mut {string} = {}
  for word in query:gmatch("%S+") do words[#words + 1] = word end
  if #words == 0 then
    return nil, Failure.new("name a module, a function or words to search for")
  end
  local answer, answer_why = Doc.answer(view, words)
  if answer == nil then return nil, answer_why end
  if not answer.found then return nil, Failure.new("nothing is found for " .. Json.quote(query)) end
  return table.concat(answer.lines, "\n")
end

-- Doc.records, its failure in words.
local function records_text(view: View, words: {string}, stale?: boolean): Types.Records?, string
  local entries: mut {Types.Record} = {}
  local all = true
  local asked = asked_of(view, words)
  local old: boolean? = if stale == true then true else nil end
  if asked == nil then
    local index, trouble = modules_asked(view, words)
    if index == nil then
      return nil, trouble
    end
    for _, summary in ipairs(index) do
      entries[#entries + 1] = {
        query = table.concat(words, " "), exact = false, module = summary.module,
        symbol = "", kind = "module", signature = "", text = summary.text,
        closed = if summary.closed ~= "" then summary.closed else nil end, stale = old,
      }
    end
    return { entries = entries, found = true }, ""
  end
  for _, asking in ipairs(asked) do
    local found, trouble = lookup_text(view, asking)
    if found == nil then
      return nil, trouble
    end
    if #found == 0 then all = false end
    for index, entry in ipairs(found) do
      local symbol = if entry.symbol == "" then "" else entry.source_symbol end
      local said = entry.text
      local file: string? = nil
      local line: integer? = nil
      local code: string? = nil
      if entry.kind == "example" then
        local ex = example_of(entry)
        symbol, said, file, line, code = ex.name, ex.text, ex.file, ex.line, ex.source
      else
        if entry.kind == "section" or entry.symbol == "" then
          said = link_text.unlinked(entry.text)
        end
        if entry.file ~= "" then file = entry.file end
        if entry.line > 0 then line = entry.line end
      end
      entries[#entries + 1] = {
        query = asking, exact = found.exact and index <= found.named,
        module = entry.module, kind = entry.kind, signature = entry.signature, symbol = symbol, text = said,
        file = file, line = line, code = code, stale = old, respelled = found.respelled,
        verb = if found.verb ~= nil and index == found.modules then asking else nil end,
      }
    end
  end
  return { entries = entries, found = all }, ""
end

--- The entries of `cosmic docs --json <words...>`, which it prints as a JSON
--- object a line, for what the page of [`Doc.answer`] shows, every
--- entry and not the first few, in its order:
--- - an entry [`Doc.lookup`] finds for each query [`Doc.asked`] names:
---   `query`, `exact` (whether the query names the entry, and it does not
---   stand in for a name it did), `module`, `symbol` (as the page names it:
---   [`Fs.read`], `doc.guides.x#heading`; "" for a module), `kind`, `signature`
---   and `text`, with `file` and `line` where it has them (a guide's
---   section or a code entry has no line, and the key is absent), and `verb`
---   (the command `cosmic <query>`, which the page points to) on the last
---   module entry of a query that names one, and `respelled` (the query as
---   it was searched for) where a misspelled word of it was taken for the
---   nearest the documentation holds;
--- - no words, or `cosmic`, name no query: each module the page lists, as
---   `kind` "module", with its `text` the first sentence, and `closed`
---   ([`Doc.Summary`]) where not every module may require it.
--- A query that finds nothing has no line. Each object carries `stale`, true,
--- where `stale` is set: the lookup reads the last build, the tree not
--- building as it stands. Nil and a [`Failure`] when a database
--- cannot be read; `found` is false when a query found nothing.
function Doc.records(view: Doc.View, words: {string}, stale?: boolean): (Doc.Records) | (nil, Failure)
  local value, why = records_text(view, words, stale)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Doc.member, its failure in words.
local function member_text(view: View, module: string, name: string): Entry?, string
  local found, trouble = member_of(view, module, name)
  if found == nil then
    return nil, trouble
  end
  if #found > 0 then
    return found[1], ""
  end
  local declared, declared_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      local rows, rows_trouble = db:rows(
        "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
          "(d.symbol = ?2 OR d.source_symbol GLOB '*.' || ?2) AND " .. symbols.shown_in(db, "d", public) ..
          " ORDER BY length(d.source_symbol), d.id LIMIT 1",
        { text(module), text(name) })
      if rows == nil then
        return nil, tostring(rows_trouble)
      end
      return entries_of(rows), ""
    end, entry_module)
  if declared == nil then
    return nil, declared_trouble
  end
  return declared[1], ""
end

--- The row that documents `module`'s member `name`: a field of the record the module returns, or a function it
--- offers; else, where the module's own row does not say what it returns (a module with no doc comment of its
--- own has none), the field or function of that name its file declares, the least nested first. False
--- where the view holds no such member; nil and a [`Failure`] when a database cannot be read.
function Doc.member(view: Doc.View, module: string, name: string): (Doc.Entry | false) | (nil, Failure)
  local value, why = member_text(view, module, name)
  if value == nil then
    if why == "" then return false end
    return nil, Failure.new(why)
  end
  return value
end

--- `comment`, a doc comment, as a reader is shown it: a link as its code span alone.
function Doc.shown(comment: string): string
  return String.trim(link_text.unlinked(comment))
end

return Doc
