--- The staged tree, read by position into modules.
---
--- A source's path relative to the root is its import path, so nothing
--- lists what a module is: [`cosmic/fs.tl`] is [`cosmic.fs`]. A `*.d.tl`
--- declares a module the core provides and holds no code, so it is read
--- for its type and never stored.
---
--- Nothing here reads a path: [`build.work`] has already staged every
--- input into the working database, and the tree is the rows of its
--- `files` table, which its `inputs` view reads by position. What a
--- build derives beyond that -- the test module a doc guide extracts
--- to, the declaration the syscall header generates to, and what one
--- parse of each source finds -- is written back as rows too, each
--- keyed so it is redone only when what it came from changed, and the
--- modules to compile are a query over them.
---
--- A module's key is its kind, the content hash of its source, the
--- keys of everything it imports, and the identity of the compiler
--- that compiled it -- see [`build.identity`]'s `Identities`. An unchanged
--- key is a stat; a changed one recompiles what depended on it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local identities = require("build.identity")
-- The pipeline is required where a build in the new grammar asks for it: `cosmic boot` compiles what the tool requires at load
-- with the bootstrap release, whose checker reads the new checker's closure otherwise than the tree's does.
local type Pipeline = require("build.pipeline")
local analysis_schema = require("build.analysis_schema")
local positions = require("build.positions")
local type SyntaxReceivers = require("build.syntax_receivers")
local tree = require("build.tree")
local work = require("build.work")
local bind = require("build.bind")

local plans = require("build.plans")
local derivation = require("build.derivation")

local type Module = plans.Module
local type Source = derivation.Source

local record importer
  Module: Module

  --- Where the code that analyzes is read from, as [`Store.requires`]
  --- and [`Store.source`] read it of the binary ([`importer.tree_code`]
  --- reads it of the tree): what a module requires among the modules a
  --- build plans, of which a declaration alone is none, sorted; and a
  --- module's source, a declaration's ahead of a module's of the same
  --- name. `compiler` is the identity of the compiler it runs beside
  --- ([`build.identity`]'s `Identities`).
  record Code
    compiler: string
    requires: function(string): {string}?, string
    source: function(string): string?, string
  end

  record Result
    modules: {Module}
    --- The compiler identity every key in `modules` carries.
    tool: string
    main?: string
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: mut {string}
    --- One line per module a file run ([`importer.compile_for`]) left
    --- out, since it does not parse or compile and the file does not
    --- reach it. A module left out only because it requires one of
    --- these has no line, nor is it in `modules`.
    left_out: mut {string}
    -- How many modules were compiled this run, and how many came back
    -- from `compiled` under a key that stood.
    compiled: integer
    cached: integer
    --- How many of those `cached` came from the compiles every
    --- checkout shares ([`Shared`]) rather than this one's own.
    shared: integer
    --- What the derive the compile began with parsed.
    parses: derivation.Parses
    --- Writes the rows the checker that compiled adds to the shipped catalog (`catalog` of the attached schema `schema`,
    --- "" for the main one), after the extracted ones: the rule behind each code the new checker emits
    --- ([`build.error_catalog`]). nil where the compile adds none.
    catalog?: Catalog
  end

  --- Writes rows to the `catalog` table of `db` (of the attached schema `schema`, "" for the main one): how many, or nil and
  --- why.
  type Catalog = function(db: Sqlite.Handle, schema: string): integer?, string

  --- What a derive parsed ([`importer.derive`]): how many sources it
  --- parsed, and how many more another checkout's parse stood in for.
  Parses: derivation.Parses

  --- The databases a hint looks a name up in, and whether each is read
  --- as the public standard library's (importer.said).
  type Hints = function(): {Sqlite.Handle}, {boolean}

  --- The compiles and parses every checkout shares
  --- ([`build.shared_compiles`]), as the caller that opened them hands
  --- them to `derive` and `compile`: looked in when a source or a
  --- module misses this checkout's own, and given every parse, and
  --- every compile that is not refused, made here.
  record Shared
    --- One compile: what a compile writes of a module.
    record Compile
      lua: string
      bytecode: string
      --- The record-field uses its checker found (`typed_refs`).
      references: {SyntaxReceivers.Reference}
    end
    --- One parse: what a parse writes of a source in every table
    --- `analysis_tables` names.
    type Parse = derivation.Parse
    --- The analyzers another checkout parsed every one of `hashes`
    --- with, the most lately used first.
    analyzers: function(hashes: {string}): {string}
    --- What `analyzer` found each of `hashes` requires, by hash, of
    --- those it parsed: a guess, read without its row's digest.
    requires: function(analyzer: string, hashes: {string}): {string:{string}}
    --- The parse `analyzer` made of the source `hash`, its docs' lines
    --- `mapped` or not ([`build.syntax_derivation`]'s `origin_lines`), or nil.
    parse: function(analyzer: string, hash: string, mapped: boolean): derivation.Parse?
    --- Offers a parse `analyzer` made here to every other checkout.
    offer: function(analyzer: string, hash: string, mapped: boolean, made: derivation.Parse)
    --- The compile another checkout made of `m` in a tree that is or
    --- is not cosmic's own, or nil.
    look: function(m: Module, own_tree: boolean): Compile?
    --- Offers a compile of `m` made here to every other checkout.
    keep: function(m: Module, own_tree: boolean, made: Compile)
    --- Writes what was offered; `compile` calls it once, as it ends,
    --- whether or not it compiled everything, and after it nothing is
    --- looked up or offered.
    finish: function()
  end

  --- The statement that drops the record-field uses of every compile
  --- `compiled` no longer holds, run at the end of each compile.
  prune_references: string
end

local type Hints = importer.Hints

-- `NOT IN (SELECT key FROM compiled)` leads SQLite to probe
-- `compiled`'s primary key once per `typed_refs` row ("USING INDEX
-- sqlite_autoindex_compiled_1 FOR IN-OPERATOR"), and that key is the
-- WITHOUT ROWID table itself, its `lua` and `bytecode` inline, so each
-- probe reads the overflow chain of every cell it compares: on
-- cosmic's own tree, about 5900 rows cost 200,000-780,000 pread64
-- calls (two measurements, by the database's layout) and 300-390 ms
-- of a warm build that otherwise takes about 200. The unary `+` makes
-- `key` an expression, which SQLite's documented rule keeps from
-- using an index, so the planner reads `compiled` once into a list
-- ("LIST SUBQUERY") and the statement takes about 2 ms. Neither `key`
-- is ever NULL (`typed_refs`' is declared so, `compiled`'s is a
-- WITHOUT ROWID primary key), so `NOT IN` meets no NULL.
importer.prune_references =
  "DELETE FROM typed_refs WHERE key NOT IN (SELECT +key FROM compiled)"

--- The derivation and the extractors, generators and parser it calls:
--- the roots of
--- [`importer.analyzer_modules`]. "The analyzer" in these names is that
--- whole set, of which the source analyzer [`build.syntax_analyzer`] is one.
--- Each is a root of the compiler's identity too ([`build.identity`]'s
--- `compiler_roots`), which the analyzer's starts from. The schema of the
--- rows a parse stores ([`build.analysis_schema`]) is among them: what a
--- source parses to is recorded in its columns.
local analyzer_roots: {string} = {
  "build.derivation", "build.analysis_schema", "build.bind",
  "build.doctest", "build.gen_syscalls", "build.link_text",
}

--- The modules whose code decides what the analysis tables record: the
--- derivation and every module that its extractors, generators and
--- parser reach through `require`,
--- as `code` records it: the running binary's own `imports` table by
--- default. What a source parses to is a function of these and of the
--- compiler, and of nothing else in the tool. Cache coordination and
--- diagnostic presentation belong to the importer, outside this closure.
function importer.analyzer_modules(code?: importer.Code): {string}?, string
  -- A name at a time ([`Store.requires`]), not a query of a handle on
  -- the binary's database, which would read every module's rows.
  local requires = code ~= nil and code.requires or Store.requires
  local source_of = code ~= nil and code.source or Store.source
  local reached: mut {string:boolean} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(analyzer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if reached[name] ~= true then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reached) do
    -- What the binary holds a module or a declaration of: what
    -- [`Store.source`] answers, of a name no hold holds.
    local source, _ = source_of(name)
    if source ~= nil then names[#names + 1] = name end
  end
  table.sort(names)
  return names, ""
end

local text = bind.text

--- The tables a parse or a generator fills ([`build.analysis_schema`]).
local analysis_tables = analysis_schema.tables

--- The code that analyzes as the tree holds it, staged in the working
--- database of `handle`: what [`importer.analyzer_modules`] and
--- [`importer.analyzer_identity`] read of the binary a boot writes, read
--- before that binary exists. A boot carries no database and runs the
--- tree's own code, so this is the code deriving in a boot. What a
--- module requires is what the last parse of its source found, and the
--- compiler's identity is taken over those finds too
--- ([`identities.compiler_identity`]): before a parse, a module whose source
--- is new has none, but its source alone already moves the identity.
function importer.tree_code(handle: work.Handle): importer.Code?, string
  local identity, trouble = identities.compiler_identity(handle.db)
  if identity == nil then
    return nil, trouble
  end
  local db = handle.db
  -- What the binary's `imports` holds ([`build.writer`]): the requires of
  -- each module the build plans, kept where they name a planned module.
  -- Every input but a declaration stands for a planned one here: the
  -- only others left out -- a test or an example the compile refuses,
  -- and every test and example once the tool's carried database drops
  -- them -- no analyzer module requires, so the walk from the analyzer
  -- never reaches them.
  local function requires(name: string): {string}?, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
        "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
        "AND ?1 IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "AND r.name IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "ORDER BY r.name", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    local names: mut {string} = {}
    for _, row in ipairs(rows) do names[#names + 1] = row:text(1) end
    return names, ""
  end
  -- What [`Store.source`] answers: a declaration's source ahead of a
  -- module's.
  local function source(name: string): string?, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT source FROM inputs WHERE path = ?1 " ..
        "ORDER BY kind = 'decl' DESC LIMIT 1", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    if #rows == 0 then
      return nil, "no module '" .. name .. "' in the tree"
    end
    return rows[1]:text(1), ""
  end
  return { compiler = identity, requires = requires, source = source }, ""
end

--- The identity of the analyzer `code` holds: the compiler, and the
--- source of every one of [`importer.analyzer_modules`]. `code` defaults
--- to the running binary's, the code actually deriving; in a stale tool
--- rebuilding itself that is older than the tree's. A boot names the
--- tree's ([`importer.tree_code`]), the code it runs, so the tool it
--- writes finds the rows the boot derived as its own. A binary that
--- carries no source for one of them, or no record of what they import,
--- can only be named whole.
-- TODO: name the analyzer by what a parse runs alone -- the pins
-- (`runtime_basis`), build.derivation and these modules -- rather than
-- the whole compiler's identity, which build.syntax_contracts, build.syntax_receivers and build.tree move though no
-- parse runs them, so an
-- edit to one parses every source again. Waits on a change that moves
-- every parse key at once, one of its own.
function importer.analyzer_identity(code?: importer.Code): string
  local parts: mut {string} = { code ~= nil and code.compiler or Store.meta("compiler") or "" }
  local modules, _ = importer.analyzer_modules(code)
  if modules == nil then
    return "binary " .. (Store.meta("boot_hash") or "")
  end
  local source_of = code ~= nil and code.source or Store.source
  for _, name in ipairs(modules) do
    local source, _ = source_of(name)
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = name .. "\n" .. source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- Whether `identity` names an analyzer at all: one named by a binary
--- with no boot hash ([`importer.analyzer_identity`]) is every such
--- binary's, so no parse is shared under it.
local function nameless(identity: string): boolean
  return identity == "binary "
end

--- The identity of the analyzer that is running ([`importer.analyzer_identity`]):
--- the binary's, or in a boot, which carries no database, the tree's.
local function running_analyzer(handle: work.Handle): string?, string
  local identity = ""
  if Store.meta("boot_hash") ~= nil then
    identity = importer.analyzer_identity()
  else
    local code, trouble = importer.tree_code(handle)
    if code == nil then
      return nil, trouble
    end
    identity = importer.analyzer_identity(code)
  end
  -- The new checker's readers write the rows of a parse: the analyzer is named by the code that reads them too.
  if not nameless(identity) then
    local pipeline = require("build.pipeline")
    -- A boot carries no database, so the code it carries is none and every boot would name the same checker: it
    -- names the tree's, as the compile keys do ([`prepare_compile`]), or the tool it writes would find a name
    -- other than its own on every row and parse the whole tree again on its first run. Where the tree is not
    -- parsed yet its checker's requires are not known, and the name stands for the while on what it carries; the
    -- name [`importer.derive`] takes after the parse is the one recorded.
    if Store.meta("boot_hash") == nil then
      local staged, _ = pipeline.coded_of(identity, handle.db)
      if staged ~= nil then
        return staged, ""
      end
    end
    return pipeline.coded(identity), ""
  end
  return identity, ""
end

--- Names the rows the analysis tables hold as derived by `identity`.
local function record_analyzer(db: Sqlite.Handle, identity: string): boolean, string
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
    { text(identity) })
end

--- What `meta` names the analysis tables' rows as derived by, "" for
--- none.
local function recorded_analyzer(db: Sqlite.Handle): string?, string
  local last, trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'analyzer'")
  if last == nil then
    return nil, trouble
  end
  return #last > 0 and last[1]:text(1) or "", ""
end

--- Forgets every derived row: every parse, and every derivation but
--- the compiler's.
local function forget_analysis(db: Sqlite.Handle): boolean, string
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name)
    if not ok then
      return false, trouble
    end
  end
  return db:exec("DELETE FROM derived WHERE origin <> 'vendor'")
end

--- Forgets every derived row when the code that derives them has
--- changed since they were made, and answers whether it did. A row
--- keyed by its source's hash is found again for as long as that
--- source stands, which is right only while the analyzer stands too: an
--- extractor that learns to see something new, or a generator that
--- emits differently, must see every source again. The analyzer is
--- named by the code that is running it ([`running_analyzer`]), not by
--- the tree: a stale tool rebuilding itself derives and parses with its
--- own, older code before the new tool re-enters, and must not leave
--- rows the new tool takes for its own. Only a change to that code
--- reparses everything; an edit anywhere else in the tool reparses just
--- what it edited. A boot does not forget as a side effect of being one:
--- the analyzer's name is a function of the compiler, the pins and the
--- Teal sources it reaches, and of nothing else, so a change to the
--- core's C or build.zig does not move it, by design.
local function forget_stale_analysis(handle: work.Handle): boolean?, string
  local db = handle.db
  local identity, identity_trouble = running_analyzer(handle)
  if identity == nil then
    return nil, identity_trouble
  end
  local last, last_trouble = recorded_analyzer(db)
  if last == nil then
    return nil, last_trouble
  end
  if last == identity then
    return false, ""
  end
  local forgot, forget_trouble = forget_analysis(db)
  if not forgot then
    return nil, forget_trouble
  end
  local recorded, record_trouble = record_analyzer(db, identity)
  if not recorded then
    return nil, record_trouble
  end
  return true, ""
end

--- The identity of the code that finds the record-field uses and judges the discipline beside the checker
--- ([`build.syntax_receivers`], [`build.syntax_contracts`]): a boot names them by the tree's source, a built tool by the
--- source it carries.
local function receivers_identity(db: Sqlite.Handle): string?, string
  local booting = Store.meta("boot_hash") == nil
  local parts: mut {string} = {}
  for _, name in ipairs({ "build.syntax_receivers", "build.syntax_contracts" }) do
    local source: string? = nil
    if booting then
      local rows, trouble = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE path = ?1", { text(name) })
      if rows == nil then
        return nil, trouble
      end
      local first = rows[1]
      if first ~= nil then
        source = first:text(1)
      end
    else
      local carried, _ = Store.source(name)
      source = carried
    end
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or ""), ""
    end
    parts[#parts + 1] = source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n")), ""
end

--- Forgets every compile, and the record-field uses found with it, when the code that finds those uses has changed since:
--- a compile whose key stands is never checked again, so a `typed_refs` row is only as right as the readers that ran
--- beside the checker.
local function forget_stale_receivers(db: Sqlite.Handle): boolean, string
  local identity, identity_trouble = receivers_identity(db)
  if identity == nil then
    return false, identity_trouble
  end
  local last, last_trouble = Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'receivers'")
  if last == nil then
    return false, last_trouble
  end
  local recorded = last[1]
  if recorded ~= nil and recorded:text(1) == identity then
    return true, ""
  end
  for _, statement in ipairs({ "DELETE FROM compiled", "DELETE FROM typed_refs" }) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return Sqlite.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('receivers', ?1)", { text(identity) })
end

--- What a boot names its analyzer ([`running_analyzer`]) with `guessed`,
--- by hash, written as `requires` rows for the while, then taken back.
local function named_over(handle: work.Handle, guessed: {string:{string}}): string?, string
  local db = handle.db
  local begun, begin_trouble = db:exec("SAVEPOINT shared_analyzer")
  if not begun then return nil, begin_trouble end
  local function named(): string?, string
    for hash, names in pairs(guessed) do
      for ordinal, name in ipairs(names) do
        local ok, why = Sqlite.run(db,
          "INSERT OR REPLACE INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
          { text(hash), { integer = ordinal }, text(name) })
        if not ok then return nil, why end
      end
    end
    return running_analyzer(handle)
  end
  local identity, identity_trouble = named()
  local _, _ = db:exec("ROLLBACK TO shared_analyzer")
  local _, _ = db:exec("RELEASE shared_analyzer")
  if identity == nil then return nil, identity_trouble end
  return identity, ""
end

--- The analyzer whose shared parses of `sources` are this tree's own:
--- "" for none.
---
--- A tool names the analyzer running it by what it carries
--- ([`importer.analyzer_identity`]), which no parse here moves, so its
--- name stands before the parse as after it, and its parses are the
--- ones to take. A boot names it by the tree ([`importer.tree_code`]),
--- whose `requires` rows decide which modules the name covers, so
--- before a parse it is inexact: on a fresh working database it covers
--- the roots alone. So a boot asks the cache instead, for a fixed point.
--- For each analyzer X that parsed this tree's own
--- analyzer roots (`analyzer_roots`) -- few: one
--- per state of those roots the cache keeps -- it writes the `requires`
--- rows X found of these sources, names the tree's analyzer over them,
--- and takes those rows back. When the name is X, X's parses are this
--- tree's:
---
--- - X is a digest of the compiler's identity and of each analyzer
---   module's name and source, so naming it again over this tree's
---   sources lists the same modules and sources X did, and the same
---   compiler: X's code is the code this boot runs.
--- - A parse is a function of that code and the source alone, so X's
---   parse of each of these sources, `requires` rows included, is the
---   parse this boot would make, and the rows that named X are what the
---   boot's own parse would have written -- a fixed point: parsing with
---   X yields the rows that name X.
---
--- The `requires` rows it guesses by are read without their rows'
--- digests, so they can only lead astray to a name that is not X,
--- which declines X, or to X where some row is damaged: that row's
--- digest fails when it is taken, the source is parsed here, and
--- [`importer.derive`] checks the name again after the parse, forgetting
--- every row and parsing the tree afresh if it moved. Where no X names
--- itself -- the cache holds no parse of the tree's analyzer as it is
--- here -- every source is parsed here, and its rows are offered under
--- the name the whole parse settles on.
---
--- Before that trial, which costs tens of milliseconds, X is passed over
--- where the modules its `requires` rows reach from the roots include
--- one it holds no parse of (`unguessed`): the roots change less often
--- than what they reach, so X's of several states of the rest can
--- gather. Only the trial accepts an X.
-- Nothing but the compiler, the pins and the analyzer's Teal sources is
-- in X, by design ([`forget_stale_analysis`]): the core's C, which runs
-- the parse, is not, so a branch whose C parses otherwise shares rows
-- with main under the same X, as compiles do under their keys, and as
-- one checkout switching between the two keeps its rows. The semantic
-- row encoding belongs to build.derivation, in X; the outer shared-cache
-- format is versioned by build.shared_compiles' `parsed_version`.
local function shared_analyzer(handle: work.Handle, shared: importer.Shared,
                               sources: {Source}): string?, string
  if Store.meta("boot_hash") ~= nil then
    return running_analyzer(handle)
  end
  local db = handle.db
  local roots: mut {string} = {}
  for _, name in ipairs(analyzer_roots) do roots[#roots + 1] = name end
  local found, trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT source_hash FROM inputs WHERE kind <> 'decl' " ..
      "AND path IN (SELECT value FROM json_each(?1)) ORDER BY source_hash",
    { text('["' .. table.concat(roots, '","') .. '"]') })
  if found == nil then return nil, trouble end
  if #found == 0 then return "", "" end
  local root_hashes: mut {string} = {}
  for _, row in ipairs(found) do root_hashes[#root_hashes + 1] = row:text(1) end
  local hashes: mut {string} = {}
  local fresh: mut {string:boolean} = {}
  for _, source in ipairs(sources) do
    hashes[#hashes + 1] = source.source_hash
    fresh[source.source_hash] = true
  end
  local planned, planned_trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash FROM inputs WHERE kind <> 'decl'")
  if planned == nil then return nil, planned_trouble end
  local hash_of: mut {string:string} = {}
  for _, row in ipairs(planned) do hash_of[row:text(1)] = row:text(2) end
  -- A module the roots reach through `guessed`, and through the rows
  -- the tables hold of what is parsed already, of which `guessed` has
  -- no parse: "" for none.
  local function unguessed(guessed: {string:{string}}): string?, string
    local reached: mut {string:boolean} = {}
    local stack: mut {string} = {}
    for _, name in ipairs(roots) do stack[#stack + 1] = name end
    while #stack > 0 do
      local name = table.remove(stack)
      local hash = hash_of[name]
      if reached[name] ~= true and hash ~= nil then
        reached[name] = true
        local names = guessed[hash]
        if fresh[hash] == true and names == nil then return name, "" end
        if names == nil then
          local rows, rows_trouble = Sqlite.text_rows(db,
            "SELECT name FROM requires WHERE source_hash = ?1 ORDER BY ordinal", { text(hash) })
          if rows == nil then return nil, rows_trouble end
          names = {}
          for _, row in ipairs(rows) do names[#names + 1] = row:text(1) end
        end
        for _, next_name in ipairs(names) do stack[#stack + 1] = next_name end
      end
    end
    return "", ""
  end
  for _, candidate in ipairs(shared.analyzers(root_hashes)) do
    local guessed = shared.requires(candidate, hashes)
    local missing, missing_trouble = unguessed(guessed)
    if missing == nil then return nil, missing_trouble end
    if missing == "" then
      local identity, identity_trouble = named_over(handle, guessed)
      if identity == nil then return nil, identity_trouble end
      if identity == candidate then return candidate, "" end
    end
  end
  return "", ""
end

--- Takes the parse another checkout made of each of `sources` from
--- `shared`, where its analyzer is this tree's ([`shared_analyzer`]), and
--- writes it as the parse would have, counting it in `tally`; the rest
--- are left to [`parse_new`]. Answers that analyzer, "" for none.
local function take_parses(handle: work.Handle, shared: importer.Shared, sources: {Source},
                           tally: importer.Parses): string?, string
  local identity, trouble = shared_analyzer(handle, shared, sources)
  if identity == nil then return nil, trouble end
  if identity == "" or nameless(identity) then return "", "" end
  local db = handle.db
  local widths, widths_trouble = derivation.table_widths(db)
  if widths == nil then return nil, widths_trouble end
  for _, source in ipairs(sources) do
    local found = shared.parse(identity, source.source_hash, source.mapped)
    local rows = found ~= nil and derivation.unpacked_parse(found.rows, widths) or nil
    if found ~= nil and rows ~= nil then
      -- One the tables refuse is left to the parse, which says why.
      local put, _ = derivation.put_parse(db, source.source_hash, found.requires, rows)
      if put then tally.shared = tally.shared + 1 end
    end
  end
  return identity, ""
end

--- Offers `shared` the parse of each of `made`, made here by the
--- analyzer named `identity`.
local function offer_parses(db: Sqlite.Handle, shared: importer.Shared?, identity: string,
                            made: {Source}): boolean, string
  if shared == nil or #made == 0 or nameless(identity) then return true, "" end
  local packed, trouble = derivation.packed_parses(db, made)
  if packed == nil then return false, trouble end
  for _, source in ipairs(made) do
    local one = packed[source.source_hash]
    if one ~= nil then shared.offer(identity, source.source_hash, source.mapped, one) end
  end
  return true, ""
end

--- Parses every source no parse has seen, with the new checker's syntax tree ([`build.pipeline`]'s `derive`), in this
--- process. The rows land in hash order. `broken`, when given, lists what does not parse rather than stopping there.
local function parse_new(handle: work.Handle, tally: importer.Parses, made: {Source},
                         broken: {derivation.Broken}?): boolean, string
  local db = handle.db
  local fresh, trouble = derivation.fresh(db)
  if fresh == nil then
    return false, trouble
  end
  return require("build.pipeline").derive(db, fresh, tally, made, broken)
end

--- Derives and parses what the staged tree holds that the tables do
--- not, and drops what no input refers to any more ([`importer.derive`]).
--- A source another checkout parsed is taken from `shared` rather than
--- parsed ([`take_parses`]). Counts what it parsed and took in `tally`,
--- lists what it parsed in `made`, and what does not parse in `broken`
--- when given ([`parse_new`]), and answers the analyzer whose parses it
--- took, "" for none.
local function derive_new(handle: work.Handle, tally: importer.Parses,
                          made: {Source}, shared: importer.Shared?,
                          broken: {derivation.Broken}?): string?, string
  local db = handle.db
  local swept, sweep_trouble = db:exec(
    "DELETE FROM derived WHERE origin <> 'vendor' AND NOT EXISTS " ..
      "(SELECT 1 FROM files f WHERE f.path = derived.file " ..
      "AND f.sha256 = derived.from_hash)")
  if not swept then
    return nil, sweep_trouble
  end
  local derived, derived_trouble = derivation.inputs(db)
  if not derived then return nil, derived_trouble end
  local taken = ""
  if shared ~= nil then
    local sources, sources_trouble = derivation.unparsed(db)
    if sources == nil then
      return nil, sources_trouble
    end
    if #sources > 0 then
      local identity, take_trouble = take_parses(handle, shared, sources, tally)
      if identity == nil then
        return nil, take_trouble
      end
      taken = identity
    end
  end
  local parsed, parse_trouble = parse_new(handle, tally, made, broken)
  if not parsed then
    return nil, parse_trouble
  end
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name ..
        " WHERE source_hash NOT IN (SELECT source_hash FROM inputs)")
    if not ok then
      return nil, trouble
    end
  end
  return taken, ""
end

--- Brings `derived` and the parse tables up to the staged tree, inside
--- the run's transaction: a derived row whose file changed or vanished goes, and
--- only what is new is extracted, generated, or parsed. The compiler's
--- row has no file and is Lua, so it is neither dropped nor parsed
--- here; the plan carries it. What no input refers to any more is
--- dropped, so the tables describe this tree and nothing older.
--- Both compile entry points do this once before planning modules. A
--- self-build records its identities afterward, since
--- [`identities.record_identities`] closes over the parsed `requires`.
--- @param self_tree whether the tree is cosmic's own, where the
---   `cosmic.` namespace is not reserved against the tree itself
--- @param shared the parses every checkout shares, or nil for none: a
---   source another checkout's analyzer parsed, where that analyzer is
---   this one ([`shared_analyzer`]), is taken from them rather than
---   parsed, and every parse made here is offered them. This borrows the
---   cache; a compile entry point or the caller must finish it.
--- @param broken where a source that does not parse is listed, rather
---   than stopping the derive, or nil to stop
--- @return what it parsed and took, or nil and why it could not
function importer.derive(handle: work.Handle, self_tree: boolean, shared?: importer.Shared,
                         broken?: mut {derivation.Broken}): importer.Parses?, string
  local db = handle.db
  if not self_tree then
    local reserved, reserved_trouble = Fs.is_dir(handle.root .. "/cosmic")
    if reserved == nil then
      return nil, reserved_trouble
    end
    if reserved then
      return nil, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree"
    end
    local claimed, trouble = Sqlite.text_rows(db,
      "SELECT path FROM files WHERE path GLOB 'cosmic/*' ORDER BY path LIMIT 1")
    if claimed == nil then
      return nil, trouble
    end
    if #claimed > 0 then
      return nil, claimed[1]:text(1) .. ": the 'cosmic' directory is reserved to " ..
        "cosmic's own tree"
    end
  end

  local tally: importer.Parses = { parsed = 0, shared = 0 }
  local made: {Source} = {}
  local forgotten, forget_trouble = forget_stale_analysis(handle)
  if forgotten == nil then
    return nil, forget_trouble
  end
  local taken, derive_trouble = derive_new(handle, tally, made, shared, broken)
  if taken == nil then
    return nil, derive_trouble
  end
  if Store.meta("boot_hash") ~= nil then
    if shared ~= nil and #made > 0 then
      local identity, identity_trouble = running_analyzer(handle)
      if identity == nil then
        return nil, identity_trouble
      end
      local offered, offer_trouble = offer_parses(db, shared, identity, made)
      if not offered then
        return nil, offer_trouble
      end
    end
    return tally, ""
  end
  -- A boot names its analyzer again now that every source is parsed:
  -- what an analyzer module whose source is new requires is found only
  -- by this parse, and the tool the boot writes walks it
  -- ([`importer.tree_code`]). A name the parse moved when nothing was
  -- forgotten can only come of rows that were not the whole of a parse
  -- (one cut short, say), and a name other than that of the analyzer
  -- whose shared parses were taken only of one of them that was not
  -- what it seemed ([`shared_analyzer`]), so the rows are forgotten and
  -- the tree parsed again, here, rather than kept under a name they do
  -- not hold to.
  local before, before_trouble = recorded_analyzer(db)
  if before == nil then
    return nil, before_trouble
  end
  local after, after_trouble = running_analyzer(handle)
  if after == nil then
    return nil, after_trouble
  end
  if (after ~= before and not forgotten) or (taken ~= "" and after ~= taken) then
    local forgot, forgot_trouble = forget_analysis(db)
    if not forgot then
      return nil, forgot_trouble
    end
    -- What this pass parses is all the derive parsed, and none of it
    -- another checkout's.
    made = {}
    tally.parsed, tally.shared = 0, 0
    if broken ~= nil then
      while #broken > 0 do table.remove(broken) end
    end
    local again, again_trouble = derive_new(handle, tally, made, nil, broken)
    if again == nil then
      return nil, again_trouble
    end
    after, after_trouble = running_analyzer(handle)
    if after == nil then
      return nil, after_trouble
    end
  end
  local recorded, record_trouble = record_analyzer(db, after)
  if not recorded then
    return nil, record_trouble
  end
  local offered, offer_trouble = offer_parses(db, shared, after, made)
  if not offered then
    return nil, offer_trouble
  end
  return tally, ""
end

--- The statements one compile pass runs, prepared once each.
local record Cache
  run: integer
  tool: string
  look: Sqlite.Statement
  touch: Sqlite.Statement
  put: Sqlite.Statement
  plan: Sqlite.Statement
end

local function prepare_cache(handle: work.Handle, tool: string): Cache?, string
  local db = handle.db
  -- A compile build.syntax_contracts refused, kept anyway by an unjudged run,
  -- is marked seen -1 and never reused: the next run compiles and
  -- judges the module again. Changing which verdict may stand is a
  -- semantic change: invalidate the stored keys or the cache schema,
  -- rather than treating it as a transport-only edit.
  -- By the index that holds `seen` beside the key (`compiled_by_seen`,
  -- [`build.work`]): a row holds the module's Lua and bytecode before its
  -- `seen`, and SQLite reaches a column by reading through every page
  -- of the ones before it, 27 MB a run for a tree's modules.
  local look, look_trouble = db:prepare(
    "SELECT seen FROM compiled INDEXED BY compiled_by_seen WHERE key = ?1 AND seen >= 0")
  if look == nil then
    return nil, look_trouble
  end
  local touch, touch_trouble = db:prepare(
    "UPDATE compiled SET seen = ?2 WHERE key = ?1 AND seen >= 0")
  if touch == nil then
    look:finalize()
    return nil, touch_trouble
  end
  local put, put_trouble = db:prepare(
    "INSERT OR REPLACE INTO compiled (key, tool, lua, bytecode, seen) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)")
  if put == nil then
    look:finalize()
    touch:finalize()
    return nil, put_trouble
  end
  local plan, plan_trouble = db:prepare(
    "INSERT INTO plan (path, key, ordinal) VALUES (?1, ?2, ?3)")
  if plan == nil then
    look:finalize()
    touch:finalize()
    put:finalize()
    return nil, plan_trouble
  end
  return { run = handle.run, tool = tool, look = look, touch = touch,
    put = put, plan = plan }, ""
end

local function finish_cache(cache: Cache)
  cache.look:finalize()
  cache.touch:finalize()
  cache.put:finalize()
  cache.plan:finalize()
end

--- How many runs a compile stays cached after the last one that used
--- it. [`cached_stands`] writes a compile's `seen` only once it is
--- `refresh_after` runs old, so one goes between `kept_runs` and
--- `kept_runs + refresh_after` runs after its last use.
local kept_runs = 100

--- How stale a cached compile's `seen` may be before a run that uses it
--- writes it again. A row holds the module's Lua and bytecode, so a write
--- of `seen` alone rewrites all of it: marking each of a tree's modules
--- on every run cost most of an idle run.
local refresh_after = 10

local once = bind.once

--- Whether a compile stands under `key`, marked as used by this run (see
--- `refresh_after`). Its Lua is not read: no caller of a compile asked
--- for that of a module it did not make ([`build.module`]'s `lua`).
local function cached_stands(cache: Cache, key: string): boolean, string
  local look = cache.look
  local bound, bind_trouble = look:bind_text(1, key)
  if not bound then
    return false, bind_trouble
  end
  local state, trouble = look:step()
  if state == nil then
    return false, trouble
  end
  local stands = false
  local stale = false
  if state == "row" then
    stands = true
    stale = look:integer(0) < cache.run - refresh_after
  end
  local reset, reset_trouble = look:reset()
  if not reset then
    return false, reset_trouble
  end
  if stale then
    local touch = cache.touch
    bound, bind_trouble = touch:bind_text(1, key)
    if bound then bound, bind_trouble = touch:bind_integer(2, cache.run) end
    if not bound then
      return false, bind_trouble
    end
    local touched, touch_trouble = once(touch)
    if not touched then
      return false, touch_trouble
    end
  end
  return stands, ""
end

--- Puts one compile in the cache under its key, and the module in
--- this run's plan. A `refused` compile is kept for this run alone.
local function remember(cache: Cache, path: string, key: string, ordinal: integer,
                        lua: string?, bytecode: string?,
                        refused: boolean): boolean, string
  if lua ~= nil and bytecode ~= nil then
    local put = cache.put
    local bound, bind_trouble = put:bind_text(1, key)
    if bound then bound, bind_trouble = put:bind_text(2, cache.tool) end
    if bound then bound, bind_trouble = put:bind_text(3, lua) end
    if bound then bound, bind_trouble = put:bind_blob(4, bytecode) end
    if bound then
      bound, bind_trouble = put:bind_integer(5, if refused then -1 else cache.run end)
    end
    if not bound then
      return false, bind_trouble
    end
    local kept, put_trouble = once(put)
    if not kept then
      return false, put_trouble
    end
  end
  local plan = cache.plan
  local bound, bind_trouble = plan:bind_text(1, path)
  if bound then bound, bind_trouble = plan:bind_text(2, key) end
  if bound then bound, bind_trouble = plan:bind_integer(3, ordinal) end
  if not bound then
    return false, bind_trouble
  end
  return once(plan)
end

--- What [`compile_derived`] keeps as it compiles, for the closure
--- that compiles every module to write and its caller to read.
local record Progress
  --- Why the compile stopped, "" while it has not.
  mut failure: string
end

--- What a compile with the new checker reads ([`build.pipeline`]): the options, and the program, made when the first module
--- that no cache answers needs it.
local record Reading
  mut options: Pipeline.Options?
  mut built: Pipeline.Built?
end

--- The databases a hint looks the name of a refused module up in, found
--- when the first refusal asks, and the projection among them that the
--- end of the compile closes.
local record Hinting
  mut databases?: {Sqlite.Handle}
  mut public?: {boolean}
  mut projection?: Sqlite.Handle
end

--- Every module path `target` reaches through what each source at a
--- path requires, itself included: a declaration's requires as well as
--- its implementation's, since a caller is checked against the one and
--- runs the other. A name no source of the tree is (a standard-library
--- module), or one whose only source does not parse, reaches no further.
local function reach(db: Sqlite.Handle, target: string): {string:boolean}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, r.name FROM inputs i JOIN requires r ON r.source_hash = i.source_hash " ..
      "WHERE i.kind <> 'vendor' ORDER BY i.path, r.ordinal")
  if rows == nil then
    return nil, trouble
  end
  local requires: mut {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = requires[row:text(1)]
    if list == nil then
      list = {}
      requires[row:text(1)] = list
    end
    list[#list + 1] = row:text(2)
  end
  local reached: mut {string:boolean} = { [target] = true }
  local pending: mut {string} = { target }
  while #pending > 0 do
    for _, name in ipairs(requires[assert(table.remove(pending))] or {}) do
      if reached[name] ~= true then
        reached[name] = true
        pending[#pending + 1] = name
      end
    end
  end
  return reached, ""
end

--- Whether `m` requires a module the run left out (`failed`).
local function leans_on(m: Module, failed: {string:boolean}): boolean
  for _, name in ipairs(m.requires) do
    if failed[name] == true then
      return true
    end
  end
  return false
end

--- The line [`importer.Result`]'s `left_out` holds for `file`, refused
--- with `trouble`, which names `named` -- `file`, or another file of the
--- same source -- at the start of its lines: why, from its first line
--- (`named: named:y:x: why`, a parse's), or from the line after it where
--- the first only says the checker refused it (`named: the compiler
--- refused it`, then a line per error), with `named` there read as `file`.
local function left_out(file: string, named: string, trouble: string): string
  local first = trouble:match("^[^\n]*") or trouble
  local why = first
  if first == named .. ": the compiler refused it" then
    why = trouble:match("^[^\n]*\n([^\n]*)") or first
  elseif first:sub(1, #named + 2) == named .. ": " then
    why = first:sub(#named + 3)
  end
  if why:sub(1, #named + 1) == named .. ":" then
    why = file .. why:sub(#named + 1)
  end
  return file .. " is left out of this run, which does not require it: " .. why
end

--- Plans and compiles an already derived tree. Only the entry points
--- below own the shared cache; every failure here returns through them.
local function compile_derived(handle: work.Handle, tool: string,
                               own_tree: boolean, parses: importer.Parses,
                               unjudged: boolean?, shared: importer.Shared?,
                               checks: boolean, target: string?,
                               broken: {derivation.Broken}?): importer.Result?, string
  local modules, trouble = plans.collect(handle.db)
  if modules == nil then
    return nil, trouble
  end
  -- For a file run, what `target` reaches is `needed`; a module outside
  -- it that does not parse or compile is left out (`failed`), and so is
  -- each module that requires one, rather than stopping the run.
  local needed: {string:boolean}? = nil
  local failed: mut {string:boolean} = {}
  local left: mut {string} = {}
  -- A run with the new checker reads every module and goes on past one it refuses, so that one refusal does not hide the
  -- rest of the tree: a refused module, a module that does not parse and each module that requires one are named in the
  -- result's `refused`, run no tests, and fail the run ([`build.test`]).
  local lenient = target == nil
  local refusals: mut {string} = {}
  if lenient then
    for _, one in ipairs(broken or {}) do
      local holders, holders_trouble = Sqlite.text_rows(handle.db,
        "SELECT path FROM inputs WHERE source_hash = ?1 ORDER BY file", { text(one.source_hash) })
      if holders == nil then
        return nil, holders_trouble
      end
      refusals[#refusals + 1] = one.message
      for _, row in ipairs(holders) do
        failed[row:text(1)] = true
      end
    end
  end
  if target ~= nil then
    local reached, reach_trouble = reach(handle.db, target)
    if reached == nil then
      return nil, reach_trouble
    end
    needed = reached
    for _, one in ipairs(broken or {}) do
      -- Each file holding the broken source: files alike are one source.
      local holders, holders_trouble = Sqlite.text_rows(handle.db,
        "SELECT path, file FROM inputs WHERE source_hash = ?1 ORDER BY file", { text(one.source_hash) })
      if holders == nil then
        return nil, holders_trouble
      end
      for _, row in ipairs(holders) do
        if reached[row:text(1)] == true then
          return nil, one.message
        end
      end
      for _, row in ipairs(holders) do
        failed[row:text(1)] = true
        left[#left + 1] = left_out(row:text(2), one.file, one.message)
      end
    end
  end
  local positioned, position_trouble = positions.check(modules, own_tree,
    function(name: string): boolean
      -- A declaration has a source but no bytecode.
      local bytecode, _ = Store.bytecode(name)
      return bytecode ~= nil
    end)
  if not positioned then
    return nil, position_trouble
  end
  local order, why = plans.ordered(modules)
  if order == nil then
    return nil, why
  end
  local refused_globals, globals_trouble = plans.refuse_globals(handle.db)
  if globals_trouble ~= "" then
    return nil, globals_trouble
  end
  if refused_globals ~= nil then
    return nil, refused_globals
  end
  local keys, keys_trouble = plans.dependency_keys(handle.db, modules, tool)
  if keys == nil then
    return nil, keys_trouble
  end
  -- What the new checker's compile is made over ([`build.pipeline`]), read once the first module needs it. A module is
  -- keyed by the ceilings that hold it too, so that a pin that falls judges it again.
  local reading: Reading = { options = nil, built = nil }
  local pipeline = require("build.pipeline")
  local made_options, options_trouble = pipeline.options(handle.root)
  if made_options == nil then
    return nil, options_trouble
  end
  reading.options = made_options
  local pinned = pipeline.pinned(made_options.ceilings)
  for _, m in ipairs(modules) do
    local held = keys[m.path]
    local digest = pinned[m.file]
    if held ~= nil and digest ~= nil then
      held.key = Hash.hex_sha256(held.key .. "\0" .. digest)
    end
  end
  local result: importer.Result = {
    modules = {}, tool = tool, main = nil, refused = refusals, left_out = left,
    compiled = 0, cached = 0, shared = 0, parses = parses,
    catalog = pipeline.catalog,
  }
  local db = handle.db
  local progress: Progress = { failure = "" }

  -- Where a hint (with_docs_hint) looks up the name a refused module
  -- could not resolve, as [`docs.databases`] builds the same list for
  -- `cosmic docs`:
  -- * This tree's last projection, `cosmic.db`, unrestricted. It is
  --   the only place cosmic's own `build.*` symbols are documented,
  --   since the tool carries only the public standard library's
  --   ([`writer.carried`]).
  -- * Then the running binary's own, where a standard-library symbol
  --   such as one of [`cosmic.removed`]'s fields lives for any tree but
  --   cosmic's.
  -- The working database cannot stand in: its `docs` rows are keyed by
  -- source hash, with no module to name. A projection that is missing
  -- or unreadable is left out, since the hint is best effort.
  local hinting: Hinting = {}
  local hints: Hints = function(): {Sqlite.Handle}, {boolean}
    if hinting.databases == nil then
      local databases: mut {Sqlite.Handle} = {}
      local public: mut {boolean} = {}
      local projection, _ = Sqlite.open(handle.dir .. "/cosmic.db")
      if projection ~= nil then
        hinting.projection = projection
        databases[1] = projection
        public[1] = false
      end
      for _, store_db in ipairs(Store.databases()) do
        databases[#databases + 1] = store_db
        public[#public + 1] = not own_tree
      end
      hinting.databases, hinting.public = databases, public
    end
    return hinting.databases, hinting.public
  end

  local compile_all = function(): boolean, string
    local cleared, clear_trouble = db:exec("DELETE FROM plan")
    if not cleared then
      return false, clear_trouble
    end
    local forgotten, forget_trouble = forget_stale_receivers(db)
    if not forgotten then
      return false, forget_trouble
    end
    local judged = unjudged ~= true
    local cache, prepare_trouble = prepare_cache(handle, tool)
    if cache == nil then
      return false, prepare_trouble
    end

    for ordinal, m in ipairs(order) do
      local key = keys[m.path].key
      m.key = key
      m.graph_key = keys[m.path].graph

      local refusal = plans.refusal(m)
      if needed ~= nil and needed[m.path] ~= true and leans_on(m, failed) then
        -- Left out quietly: the module it requires was told of.
        failed[m.path] = true
      elseif lenient and leans_on(m, failed) then
        local lacking = ""
        for _, name in ipairs(m.requires) do
          if failed[name] == true and lacking == "" then
            lacking = name
          end
        end
        failed[m.path] = true
        result.refused[#result.refused + 1] = m.file .. ": not compiled: it requires " .. lacking ..
          ", which the new checker refused"
      elseif refusal ~= nil then
        result.refused[#result.refused + 1] = refusal
      else
        local stands, look_trouble = cached_stands(cache, key)
        if not stands and look_trouble ~= "" then
          finish_cache(cache)
          return false, look_trouble
        end
        -- The Lua of a compile made or copied here, not of one that stands.
        local lua: string? = nil
        local bytecode: string? = nil
        local refused = false
        -- Another checkout's compile stands for one made here: its key
        -- and what else decides it are the same ([`build.shared_compiles`]),
        -- and it lands as a compile does, uses and all.
        local elsewhere: importer.Shared.Compile? = nil
        if not stands and shared ~= nil then
          elsewhere = shared.look(m, own_tree)
        end
        if stands then
          result.cached = result.cached + 1
        elseif elsewhere ~= nil then
          lua = elsewhere.lua
          bytecode = elsewhere.bytecode
          result.cached = result.cached + 1
          result.shared = result.shared + 1
          local kept_refs, refs_trouble = plans.keep_references(db, key, elsewhere.references)
          if not kept_refs then
            finish_cache(cache)
            return false, m.file .. ": " .. refs_trouble
          end
        else
          local generated: plans.Generated? = nil
          -- Read the tree once, when the first module that is not cached asks.
          if reading.built == nil then
            local made_built, built_trouble = pipeline.build(handle.db, assert(reading.options))
            if made_built == nil then
              progress.failure = built_trouble
              break
            end
            reading.built = made_built
          end
          local made_generated, generate_trouble = pipeline.generate(m, assert(reading.built), checks, judged, hints)
          if made_generated == nil then
            if lenient then
              result.refused[#result.refused + 1] = generate_trouble
              failed[m.path] = true
            elseif needed == nil or needed[m.path] == true then
              progress.failure = generate_trouble
              break
            end
            table.insert(result.left_out, left_out(m.file, m.file, generate_trouble))
            failed[m.path] = true
          end
          generated = made_generated
          if generated ~= nil then
            lua = generated.lua
            bytecode = generated.bytecode
            refused = generated.refused
            result.compiled = result.compiled + 1
            local kept_refs, refs_trouble = plans.keep_references(db, key,
              generated.references)
            if not kept_refs then
              finish_cache(cache)
              return false, m.file .. ": " .. refs_trouble
            end
            -- A refused compile is this run's alone (`remember`), and
            -- never another checkout's.
            if shared ~= nil and not refused then
              shared.keep(m, own_tree, { lua = generated.lua, bytecode = generated.bytecode,
                references = generated.references })
            end
          end
        end
        -- Nothing stands, and nothing is made, only for a module left out
        -- above, of which nothing is kept.
        if stands or lua ~= nil then
          m.lua = lua
          local kept, keep_trouble = remember(cache, m.path, key, ordinal, lua,
            bytecode, refused)
          if not kept then
            finish_cache(cache)
            return false, m.file .. ": " .. keep_trouble
          end
          if m.kind == "main" then
            result.main = m.path
          end
          result.modules[#result.modules + 1] = m
        end
      end
    end

    finish_cache(cache)
    local pruned, prune_trouble = Sqlite.run(db,
      "DELETE FROM compiled WHERE tool <> ?1 OR (seen >= 0 AND seen < ?2)" ..
        (if judged then " OR seen < 0" else "" end),
      { text(tool), { integer = handle.run - kept_runs - refresh_after } })
    if not pruned then
      return false, prune_trouble
    end
    -- Run whether or not the prune above dropped anything: a run that
    -- failed between a compile's [`plans.keep_references`] and its `remember`
    -- commits the uses without the compile (build.dispatch closes the
    -- handle, keeping what the run did), and only this sweeps them.
    return db:exec(importer.prune_references)
  end
  local made, compile_trouble = compile_all()
  local hinting_projection = hinting.projection
  -- The projection the hints opened, once a message earned one.
  if hinting_projection ~= nil then
    local _, _ = hinting_projection:close()
  end
  if not made then
    return nil, compile_trouble
  end
  if progress.failure ~= "" then
    return nil, progress.failure
  end
  return result, ""
end

--- The compiler a self-build runs, chosen once the tree's identities are
--- recorded.
local type Choose = function(identities.Identities): string?, string

--- A self-build chooses the compiler that actually runs only after the
--- analyzer has stabilized and the complete tree identities are recorded.
local function prepare_compile(handle: work.Handle, tool: string,
                               unjudged: boolean?, shared: importer.Shared?,
                               choose: Choose?,
                               checks: boolean, target: string?): importer.Result?, string
  local own_tree, own_trouble = tree.is_own(handle.root)
  if own_tree == nil then return nil, own_trouble end
  local broken: {derivation.Broken} = {}
  local parses, derive_trouble = importer.derive(handle, own_tree, shared, broken)
  if parses == nil then return nil, derive_trouble end
  if choose ~= nil then
    local recorded, record_trouble = identities.record_identities(handle.db)
    if recorded == nil then return nil, record_trouble end
    local selected, select_trouble = choose(recorded)
    if selected == nil then return nil, select_trouble end
    tool = selected
    -- What it is made by is the code that reads: the checker and the readers. A boot runs the tree's own, which the
    -- tool it stands in for does not carry yet, so the tree says what it is; a rebuild runs the tool's.
    local pipeline = require("build.pipeline")
    if Store.meta("boot_hash") == nil then
      local coded, coded_trouble = pipeline.coded_of(tool, handle.db)
      if coded == nil then return nil, coded_trouble end
      tool = coded
    else
      tool = pipeline.coded(tool)
    end
  end
  return compile_derived(handle, tool, own_tree, parses, unjudged, shared, checks, target, broken)
end

--- The cache belongs to the whole derive/identity/compile operation,
--- including successful rows offered before a later phase fails.
local function consuming_compile(handle: work.Handle, tool: string,
                                 unjudged: boolean?, shared: importer.Shared?,
                                 choose?: function(identities.Identities): string?, string,
                                 checks?: boolean, target?: string): importer.Result?, string
  local result, trouble = prepare_compile(handle, tool, unjudged, shared, choose, checks == true, target)
  if shared ~= nil then shared.finish() end
  if result == nil then return nil, trouble end
  return result, ""
end

--- The identity of the compiler `tool` names when it writes the run-time
--- checks of a typed boundary into what it compiles ([`importer.compile`]'s
--- `checks`). Every key carries it in `tool`'s place, so a module compiled
--- with checks and one without share no row of the working database and no
--- entry of the compiles every checkout shares, and the verdict of a test
--- keyed by it is kept apart from a test run without.
---
--- `wraps` says the checks are the calls of `__fact` that the new checker's code
--- generator writes at the reads a test narrowed ([`lang.fact_wraps`]) and the calls of
--- `__cosmic_tc` at the typed parameters of a function ([`lang.boundary_checks`]), and not
--- the fork's `__cosmic_tc`: the Lua of the two differs, so their keys do. The key holds
--- what the compile adds, so a list of checks that grows (the returns and the fields written,
--- later) moves it and no entry compiled with fewer is the answer. A
--- compile cached with the one is never the answer to a request for the other,
--- nor for none.
function importer.checked_tool(tool: string, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (if wraps == true then "\0fact-wraps\0parameter-checks" else "\0run-time-checks" end))
end

--- What a compile that asked to be reused stood on, and what it made.
local record Standing
  root: string
  tool: string
  unjudged: boolean
  checks: boolean
  --- [`tree_state`] as the compile left it.
  state: string
  result: importer.Result
end

--- What this process holds of it, if anything.
local record Held
  mut standing: Standing?
end

local kept: Held = { standing = nil }

--- A digest of what a compile reads of the working database and leaves in
--- it: each staged file by its hash, each derived source, and the plan of
--- modules and keys it wrote. Nil where the database will not say.
local function tree_state(db: Sqlite.Handle): string?
  local rows, _ = Sqlite.text_rows(db,
    "SELECT lower(hex(sha256(" ..
      "coalesce((SELECT group_concat(path || char(0) || sha256, char(10)) FROM " ..
      "(SELECT path, sha256 FROM files ORDER BY path)), '') || char(1) || " ..
      "coalesce((SELECT group_concat(file || char(0) || path || char(0) || kind || char(0) || source_hash, " ..
      "char(10)) FROM (SELECT file, path, kind, source_hash FROM derived ORDER BY file, path)), '') || char(1) || " ..
      "coalesce((SELECT group_concat(path || char(0) || key || char(0) || ordinal, char(10)) FROM " ..
      "(SELECT path, key, ordinal FROM plan ORDER BY path)), ''))))")
  if rows == nil then return nil end
  local row = rows[1]
  if row == nil then return nil end
  return row:text(1)
end

--- Compiles every module, in import order, into Lua and bytecode --
--- or finds it already compiled under the same key. The keys and the
--- compiles land in the working database inside the run's
--- transaction, kept even when a later module refuses, so a run that
--- fails still pays for each module once; a compile another tool
--- made, or one no run has used lately, is dropped.
---
--- The tree is read, checked and written by the new checker ([`build.pipeline`]) in this process: `tool` is the one
--- [`build.grammar_mode`] chose, and the keys hold the code that reads as well ([`build.pipeline`]'s `coded`).
--- @param handle the working database the tree is staged in
--- @param tool the identity of the compiler doing the compiling, which
---   every key carries
--- @param unjudged whether a module build.syntax_contracts refuses is kept
---   rather than refused: a stale tool rebuilding itself ([`build.reboot`])
---   judges the tree by its own, older rules and exemptions, so it
---   leaves the last word to the tool it builds, which re-enters the
---   command. A compile the old rules refuse is kept only for this run's
---   database, never reused, so the next run compiles and judges the
---   module again; one they pass is cached as any other, since a change
---   to the rules themselves moves the tool's identity, and with it every key.
--- @param shared the compiles and parses every checkout shares, or nil
---   for none: a module whose key misses here is taken from them rather
---   than compiled, and every compile made here but a refused one is
---   offered them, as its derive takes and offers parses
---   ([`importer.derive`]). Finished before this returns, whatever it
---   returns, with whatever an earlier derive given them offered.
--- @param checks whether the compiled Lua checks a value against its declared
---   kind: each read of a place a test narrowed is wrapped in a call of `__fact` ([`lang.fact_wraps`]), and each function
---   with typed parameters checks them ([`lang.boundary_checks`]). It keys every
---   compile by [`importer.checked_tool`], so no cache shares an entry between the two.
function importer.compile(handle: work.Handle, tool: string, unjudged?: boolean,
                          shared?: importer.Shared, checks?: boolean, again?: boolean): importer.Result?, string
  -- What it is made by is the code that reads: the checker and the readers.
  local pipeline = require("build.pipeline")
  tool = pipeline.coded(tool)
  if checks == true then
    tool = importer.checked_tool(tool, true)
  end
  if again ~= true then
    return consuming_compile(handle, tool, unjudged, shared, nil, checks, nil)
  end
  -- The caller built this tree already, in this process, and asks for that
  -- build where nothing it stands on has moved.
  local before = kept.standing
  if before ~= nil and before.root == handle.root and before.tool == tool and before.unjudged == (unjudged == true) and
      before.checks == (checks == true) and before.state == tree_state(handle.db) then
    if shared ~= nil then shared.finish() end
    local was = before.result
    local again_result: importer.Result = {
      modules = was.modules, tool = was.tool, main = was.main, refused = was.refused, left_out = was.left_out,
      compiled = 0, cached = #was.modules, shared = 0, parses = was.parses, catalog = was.catalog,
    }
    return again_result, ""
  end
  local result, trouble = consuming_compile(handle, tool, unjudged, shared, nil, checks, nil)
  kept.standing = nil
  if result == nil then return nil, trouble end
  local state = tree_state(handle.db)
  if state ~= nil then
    kept.standing = { root = handle.root, tool = tool, unjudged = unjudged == true, checks = checks == true,
      state = state, result = result }
  end
  return result, ""
end

--- Compiles every module as [`importer.compile`] does, for a file run
--- whose file is the module `target`: a source that does not parse, or a
--- module that does not compile, stops the build only where `target`
--- reaches it through what it requires. One it does not reach is left out,
--- with a line in the result's `left_out`, and so is each module that
--- requires it, so a broken file beside the one run does not stop it.
--- Where `target` reaches one, it fails as [`importer.compile`] does, with
--- the same message. Consumes `shared` as that does.
--
-- TODO: leave out a module outside `target`'s reach that a tree-wide check
-- refuses too -- a misplaced [`Test.policy`], a cycle of imports, a global, an
-- unknown `cosmic.*` require -- once those checks name the modules they
-- refuse rather than answering one message for the tree: today any of them
-- stops a file run whatever the file reaches.
function importer.compile_for(handle: work.Handle, tool: string, target: string,
                              shared?: importer.Shared): importer.Result?, string
  return consuming_compile(handle, require("build.pipeline").coded(tool), false, shared, nil, false, target)
end

--- Compiles a self-build after deriving its sources and recording its
--- complete identities. `choose` selects the compiler actually running:
--- the tree's for a boot, the running tool's until a rebuild settles.
--- Like [`importer.compile`], consumes `shared`, finishing
--- it exactly once on success or failure. The working database and its
--- transaction remain the caller's, as does publishing the completed
--- projection. `choose` answers the tool string [`build.grammar_mode`] makes of the compiler's identity.
function importer.compile_tree(handle: work.Handle, choose: function(identities.Identities): string?, string,
                               unjudged: boolean, shared?: importer.Shared): importer.Result?, string
  return consuming_compile(handle, "", unjudged, shared, choose, false, nil)
end

return importer
