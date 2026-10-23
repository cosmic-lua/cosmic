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
local Log = require("cosmic.log")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local identities = require("build.identity")
-- The pipeline is required where a build in the new grammar asks for it: `cosmic boot` compiles what the tool requires at load
-- with the bootstrap release, whose checker reads the new checker's closure otherwise than the tree's does.
local type Pipeline = require("build.pipeline")
local analysis_schema = require("build.analysis_schema")
local positions = require("build.positions")
local receivers = require("build.receivers")
local symbols = require("build.symbols")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local type compiler = require("build.compiler")
local bind = require("build.bind")
local plural = require("build.plural")

local compilation = require("build.compilation")
local derivation = require("build.derivation")
local type GrammarMode = require("build.grammar_mode")

local type Module = compilation.Module
local type Source = derivation.Source

local log = Log.new("cosmic")

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
    requires: function(string): {string} | nil, string
    source: function(string): string | nil, string
  end

  record Result
    modules: {Module}
    --- The compiler identity every key in `modules` carries.
    tool: string
    main: string | nil
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: {string}
    --- One line per module a file run ([`importer.compile_for`]) left
    --- out, since it does not parse or compile and the file does not
    --- reach it. A module left out only because it requires one of
    --- these has no line, nor is it in `modules`.
    left_out: {string}
    -- How many modules were compiled this run, and how many came back
    -- from `compiled` under a key that stood.
    compiled: integer
    cached: integer
    --- How many of those `cached` came from the compiles every
    --- checkout shares ([`Shared`]) rather than this one's own.
    shared: integer
    --- How many of those `compiled` a worker compiled ([`build.worker`]).
    worked: integer
    --- What the derive the compile began with parsed.
    parses: derivation.Parses
    --- Writes the rows the checker that compiled adds to the shipped catalog (`catalog` of the attached schema `schema`,
    --- "" for the main one), after the extracted ones: the rule behind each code the new checker emits
    --- ([`build.error_catalog`]). nil for the fork's compile, which adds none.
    catalog: Catalog | nil
  end

  --- Writes rows to the `catalog` table of `db` (of the attached schema `schema`, "" for the main one): how many, or nil and
  --- why.
  type Catalog = function(db: Sqlite.Handle, schema: string): integer | nil, string

  --- What a derive parsed ([`importer.derive`]): how many sources it
  --- parsed, and how many more another checkout's parse stood in for.
  Parses: derivation.Parses

  --- The databases a hint looks a name up in, and whether each is read
  --- as the public standard library's ([`importer.said`]).
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
      references: {receivers.Reference}
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
    --- `mapped` or not ([`build.derivation`]'s `origin_lines`), or nil.
    parse: function(analyzer: string, hash: string, mapped: boolean): derivation.Parse | nil
    --- Offers a parse `analyzer` made here to every other checkout.
    offer: function(analyzer: string, hash: string, mapped: boolean, made: derivation.Parse)
    --- The compile another checkout made of `m` in a tree that is or
    --- is not cosmic's own, or nil.
    look: function(m: Module, own_tree: boolean): Compile | nil
    --- Offers a compile of `m` made here to every other checkout.
    keep: function(m: Module, own_tree: boolean, made: Compile)
    --- Writes what was offered; `compile` calls it once, as it ends,
    --- whether or not it compiled everything, and after it nothing is
    --- looked up or offered.
    finish: function()
  end

  --- What the workers made of a compile, read back as the build reaches
  --- each module.
  record Ahead
    --- What compiling the module at `path` made, or nil where no worker
    --- reached it, and the build compiles it.
    take: function(path: string): compilation.Generated | nil
    --- Releases the workers' results.
    close: function()
  end

  --- The processes a build parses and compiles in beside its own
  --- ([`build.workers`]), as the caller that makes them hands them to
  --- `derive` and `compile`. A build asks `ready` of how much source it
  --- has, and the processes serve it only where that is worth them.
  --- What they make is what this process would, and what they leave
  --- undone this process does.
  record Workers
    --- Whether processes serve `bytes` of source, starting them first
    --- where that many are worth it.
    ready: function(bytes: integer): boolean
    --- Parses `fresh`, as [`derivation.parse_fresh`] does into `db`,
    --- counting each source a process parsed in `tally.worked`.
    parse: function(db: Sqlite.Handle, built: compiler, fresh: {derivation.Fresh},
                    tally: derivation.Parses, made: {derivation.Source},
                    broken?: {derivation.Broken}): boolean, string
    --- Compiles `wanted`, each module a process does as
    --- [`compilation.generate`] would, for `compile` to take: nil and why
    --- where it could not, and nil and "" where one process does as well.
    compile: function(db: Sqlite.Handle, root: string, order: {Module},
                      wanted: {string:boolean}, own_tree: boolean,
                      judged: boolean): importer.Ahead | nil, string
    --- Ends the processes.
    close: function()
  end

  --- The statement that drops the record-field uses of every compile
  --- `compiled` no longer holds, run at the end of each compile.
  prune_references: string

  --- The worked examples a checker diagnostic points its reader to
  --- (`cosmic docs <name>`), by the kind of diagnostic:
  --- [`build.tree_checks`] holds the tree to answering each.
  diagnostic_queries: {string: string}
end

importer.diagnostic_queries = {
  arguments = "generics_functions_returns",
  record_key = "records_interfaces_methods",
}

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

-- The statement that drops the stub verdicts of every compile `compiled`
-- no longer holds, run beside the one above. Spelt as
-- [`importer.prune_references`] is, for the reason given there.
local prune_stub_holds <const> =
  "DELETE FROM stub_holds WHERE key NOT IN (SELECT +key FROM compiled)"

--- A compile found under an interface key, to be kept under a module's key.
local record Reuse
  lua: string
  bytecode: string
end

--- The statement that drops the interface keys of every compile `compiled`
--- no longer holds.
local prune_interfaces <const> =
  "DELETE FROM compiled_interface WHERE key NOT IN (SELECT +key FROM compiled)"

--- The derivation and the extractors, generators and parser it calls:
--- the roots of
--- [`importer.analyzer_modules`]. "The analyzer" in these names is that
--- whole set, of which the source analyzer [`build.analyzer`] is one.
--- Each is a root of the compiler's identity too ([`build.identity`]'s
--- `compiler_roots`), which the analyzer's starts from. The schema of the
--- rows a parse stores ([`build.analysis_schema`]) is among them: what a
--- source parses to is recorded in its columns.
local analyzer_roots: {string} = {
  "build.derivation", "build.analysis_schema", "build.analyzer", "build.ast", "build.bind",
  "build.compiler", "build.doctest", "build.gen_syscalls", "build.link_text",
}

--- The modules whose code decides what the analysis tables record: the
--- derivation and every module that its extractors, generators and
--- parser reach through `require`,
--- as `code` records it: the running binary's own `imports` table by
--- default. What a source parses to is a function of these and of the
--- compiler, and of nothing else in the tool. Cache coordination and
--- diagnostic presentation belong to the importer, outside this closure.
function importer.analyzer_modules(code?: importer.Code): {string} | nil, string
  -- A name at a time ([`Store.requires`]), not a query of a handle on
  -- the binary's database, which would read every module's rows.
  local requires = code ~= nil and code.requires or Store.requires
  local source_of = code ~= nil and code.source or Store.source
  local reached: {string:boolean} = {}
  local stack: {string} = {}
  for _, name in ipairs(analyzer_roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not reached[name] then
      reached[name] = true
      local required, trouble = requires(name)
      if required == nil then return nil, trouble end
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local names: {string} = {}
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
function importer.tree_code(handle: work.Handle): importer.Code | nil, string
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
  local function requires(name: string): {string} | nil, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT DISTINCT r.name FROM inputs i " ..
        "JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = ?1 " ..
        "AND ?1 IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "AND r.name IN (SELECT path FROM inputs WHERE kind <> 'decl') " ..
        "ORDER BY r.name", { text(name) })
    if rows == nil then
      return nil, rows_trouble
    end
    local names: {string} = {}
    for _, row in ipairs(rows) do names[#names + 1] = row:text(1) end
    return names, ""
  end
  -- What [`Store.source`] answers: a declaration's source ahead of a
  -- module's.
  local function source(name: string): string | nil, string
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
-- the whole compiler's identity, which build.teal, build.contracts,
-- build.receivers and build.tree move though no parse runs them, so an
-- edit to one parses every source again. Waits on a change that moves
-- every parse key at once, one of its own.
function importer.analyzer_identity(code?: importer.Code): string
  local parts: {string} = { code ~= nil and code.compiler or Store.meta("compiler") or "" }
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
local function running_analyzer(handle: work.Handle, grammar?: GrammarMode.Mode): string | nil, string
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
  -- The new checker's readers write the rows of a parse: another analyzer, whose rows and whose shared parses are told apart
  -- from the fork's, and by the code that reads them.
  if grammar == "new" and not nameless(identity) then
    local pipeline = require("build.pipeline")
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
local function recorded_analyzer(db: Sqlite.Handle): string | nil, string
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
local function forget_stale_analysis(handle: work.Handle, grammar?: GrammarMode.Mode): boolean | nil, string
  local db = handle.db
  local identity, identity_trouble = running_analyzer(handle, grammar)
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

--- Forgets every compile, and the record-field uses found with it,
--- when the code that finds those uses has changed since: a compile
--- whose key stands is never checked again, so a `typed_refs` row is
--- only as right as the [`build.receivers`] that ran beside the checker.
local function forget_stale_receivers(db: Sqlite.Handle): boolean, string
  local identity, identity_trouble = compilation.receivers_identity(db)
  if identity == nil then
    return false, identity_trouble
  end
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'receivers'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1]:text(1) == identity then
    return true, ""
  end
  for _, statement in ipairs({ "DELETE FROM compiled", "DELETE FROM typed_refs" }) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('receivers', ?1)",
    { text(identity) })
end

--- What a boot names its analyzer ([`running_analyzer`]) with `guessed`,
--- by hash, written as `requires` rows for the while, then taken back.
local function named_over(handle: work.Handle, guessed: {string:{string}},
                          grammar?: GrammarMode.Mode): string | nil, string
  local db = handle.db
  local begun, begin_trouble = db:exec("SAVEPOINT shared_analyzer")
  if not begun then return nil, begin_trouble end
  local function named(): string | nil, string
    for hash, names in pairs(guessed) do
      for ordinal, name in ipairs(names) do
        local ok, why = Sqlite.run(db,
          "INSERT OR REPLACE INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
          { text(hash), { integer = ordinal }, text(name) })
        if not ok then return nil, why end
      end
    end
    return running_analyzer(handle, grammar)
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
                               sources: {Source}, grammar?: GrammarMode.Mode): string | nil, string
  if Store.meta("boot_hash") ~= nil then
    return running_analyzer(handle, grammar)
  end
  local db = handle.db
  local roots: {string} = {}
  for _, name in ipairs(analyzer_roots) do roots[#roots + 1] = name end
  local found, trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT source_hash FROM inputs WHERE kind <> 'decl' " ..
      "AND path IN (SELECT value FROM json_each(?1)) ORDER BY source_hash",
    { text('["' .. table.concat(roots, '","') .. '"]') })
  if found == nil then return nil, trouble end
  if #found == 0 then return "", "" end
  local root_hashes: {string} = {}
  for _, row in ipairs(found) do root_hashes[#root_hashes + 1] = row:text(1) end
  local hashes: {string} = {}
  local fresh: {string:boolean} = {}
  for _, source in ipairs(sources) do
    hashes[#hashes + 1] = source.source_hash
    fresh[source.source_hash] = true
  end
  local planned, planned_trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash FROM inputs WHERE kind <> 'decl'")
  if planned == nil then return nil, planned_trouble end
  local hash_of: {string:string} = {}
  for _, row in ipairs(planned) do hash_of[row:text(1)] = row:text(2) end
  -- A module the roots reach through `guessed`, and through the rows
  -- the tables hold of what is parsed already, of which `guessed` has
  -- no parse: "" for none.
  local function unguessed(guessed: {string:{string}}): string | nil, string
    local reached: {string:boolean} = {}
    local stack: {string} = {}
    for _, name in ipairs(roots) do stack[#stack + 1] = name end
    while #stack > 0 do
      local name = table.remove(stack)
      local hash = hash_of[name]
      if not reached[name] and hash ~= nil then
        reached[name] = true
        local names = guessed[hash]
        if fresh[hash] and names == nil then return name, "" end
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
      local identity, identity_trouble = named_over(handle, guessed, grammar)
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
                           tally: importer.Parses, grammar?: GrammarMode.Mode): string | nil, string
  local identity, trouble = shared_analyzer(handle, shared, sources, grammar)
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
local function offer_parses(db: Sqlite.Handle, shared: importer.Shared | nil, identity: string,
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

--- Parses every source no parse has seen, as
--- [`derivation.parse_fresh`] does, in the processes of `pool` when it
--- has them for that much source and here otherwise. The rows land in
--- hash order either way. `broken`, when given, lists what does not
--- parse rather than stopping there.
local function parse_new(handle: work.Handle, built: compiler, tally: importer.Parses,
                         made: {Source}, pool: importer.Workers | nil,
                         broken: {derivation.Broken} | nil, grammar?: GrammarMode.Mode): boolean, string
  local db = handle.db
  local fresh, trouble = derivation.fresh(db)
  if fresh == nil then
    return false, trouble
  end
  if grammar == "new" then
    -- The syntax tree of the new checker is read in this process, whose tree the readers take.
    local pipeline = require("build.pipeline")
    local own, own_trouble = tree.is_own(handle.root)
    if own == nil then
      return false, own_trouble
    end
    return pipeline.derive(db, built, fresh, tally, made, broken, not own)
  end
  if pool ~= nil and #fresh > 1 then
    local bytes = 0
    for _, one in ipairs(fresh) do bytes = bytes + #one.source end
    if pool.ready(bytes) then
      return pool.parse(db, built, fresh, tally, made, broken)
    end
  end
  return derivation.parse_fresh(db, built, fresh, tally, made, broken)
end

--- Derives and parses what the staged tree holds that the tables do
--- not, and drops what no input refers to any more ([`importer.derive`]).
--- A source another checkout parsed is taken from `shared` rather than
--- parsed ([`take_parses`]). Counts what it parsed and took in `tally`,
--- lists what it parsed in `made`, and what does not parse in `broken`
--- when given ([`parse_new`]), and answers the analyzer whose parses it
--- took, "" for none.
local function derive_new(handle: work.Handle, built: compiler, tally: importer.Parses,
                          made: {Source}, shared: importer.Shared | nil,
                          pool: importer.Workers | nil,
                          broken: {derivation.Broken} | nil, grammar?: GrammarMode.Mode): string | nil, string
  local db = handle.db
  local swept, sweep_trouble = db:exec(
    "DELETE FROM derived WHERE origin <> 'vendor' AND NOT EXISTS " ..
      "(SELECT 1 FROM files f WHERE f.path = derived.file " ..
      "AND f.sha256 = derived.from_hash)")
  if not swept then
    return nil, sweep_trouble
  end
  local derived, derived_trouble = derivation.inputs(db, grammar == "new")
  if not derived then return nil, derived_trouble end
  local taken = ""
  if shared ~= nil then
    local sources, sources_trouble = derivation.unparsed(db)
    if sources == nil then
      return nil, sources_trouble
    end
    if #sources > 0 then
      local identity, take_trouble = take_parses(handle, shared, sources, tally, grammar)
      if identity == nil then
        return nil, take_trouble
      end
      taken = identity
    end
  end
  local parsed, parse_trouble = parse_new(handle, built, tally, made, pool, broken, grammar)
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
--- @param built the compiler, loaded and ready
--- @param shared the parses every checkout shares, or nil for none: a
---   source another checkout's analyzer parsed, where that analyzer is
---   this one ([`shared_analyzer`]), is taken from them rather than
---   parsed, and every parse made here is offered them. This borrows the
---   cache; a compile entry point or the caller must finish it.
--- @param pool the processes to parse in, or nil for none: a build with
---   much to parse starts them and the parses are written as they would
---   be without. This borrows the pool; a compile entry point or the
---   caller must close it.
--- @param broken where a source that does not parse is listed, rather
---   than stopping the derive ([`derivation.parse_fresh`]), or nil to stop
--- @param grammar `new` to read the sources with the new checker's syntax
---   tree ([`build.pipeline`]'s `derive`), in this process (no pool is
---   asked): the rows are then another analyzer's, kept apart from the
---   fork's by its name ([`running_analyzer`]); nil or `teal` for the fork's
--- @return what it parsed and took, or nil and why it could not
function importer.derive(handle: work.Handle, self_tree: boolean,
                         built: compiler, shared?: importer.Shared,
                         pool?: importer.Workers,
                         broken?: {derivation.Broken}, grammar?: GrammarMode.Mode): importer.Parses | nil, string
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

  local tally: importer.Parses = { parsed = 0, shared = 0, worked = 0 }
  local made: {Source} = {}
  local forgotten, forget_trouble = forget_stale_analysis(handle, grammar)
  if forgotten == nil then
    return nil, forget_trouble
  end
  local taken, derive_trouble = derive_new(handle, built, tally, made, shared, pool, broken, grammar)
  if taken == nil then
    return nil, derive_trouble
  end
  if Store.meta("boot_hash") ~= nil then
    if shared ~= nil and #made > 0 then
      local identity, identity_trouble = running_analyzer(handle, grammar)
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
  local after, after_trouble = running_analyzer(handle, grammar)
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
    tally.parsed, tally.shared, tally.worked = 0, 0, 0
    if broken ~= nil then
      while #broken > 0 do table.remove(broken) end
    end
    local again, again_trouble = derive_new(handle, built, tally, made, nil, pool, broken, grammar)
    if again == nil then
      return nil, again_trouble
    end
    after, after_trouble = running_analyzer(handle, grammar)
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

--- Adds to an unused-variable or unused-argument warning the way to
--- silence it. tl's checker treats a name starting with `_` as
--- intentionally unused (the checker's `var_name:sub(1, 1) == "_"` check),
--- but the warning for any other name does not say so, and every
--- warning is a refused compile on cosmic's paths (see `generate`).
--- Added here, where every message is rendered, rather than in
--- the checker's own text.
local function with_unused_hint(e: compiler.Error): string
  local declares = e.declares
  if e.code == "unused" and (declares == "variable" or declares == "argument") then
    return e.msg .. " -- name it _ or _<name> to mark it intentionally unused"
  end
  return e.msg
end

--- The bare name the checker names in an error reporting that nothing by
--- that name exists: an unknown variable (a global reference --
--- `os.time()`, once [`build.teal`] strips `os` from the checker's own
--- environment for exactly this) or a module not found (a `require` of a
--- literal string nothing provides). `nil` for any other error, since only
--- these two name a single missing word worth looking up.
local function unresolved_name(e: compiler.Error): string | nil
  local code = e.code
  if code == "unknown_variable" then
    return e.variable
  elseif code == "module_not_found" then
    return e.key
  end
  return nil
end

--- The databases a hint looks a name up in, and whether each is read as
--- the public standard library's, asked for only when a message earns a
--- hint: a handle on the store's databases is one a test worker's hold
--- on the store refuses ([`Store.databases`]), which a build that
--- compiles clean never asks for.
local type Hints = importer.Hints

--- Appends a pointer at whatever `cosmic docs` already answers for the
--- name a resolution failure names, when [`symbols.named`] finds it
--- exactly -- the same rule `cosmic docs <word>` itself matches by, so
--- this can never point somewhere that command would disagree with.
--- Only the symbol's name, never its documentation: the error already
--- says where to read that in full (`cosmic docs <name>`), and a
--- compile failure is not the place to reprint it.
local function with_docs_hint(msg: string, e: compiler.Error, hints: Hints): string
  local name = unresolved_name(e)
  if name == nil then
    return msg
  end
  local databases, public = hints()
  local found = symbols.named(databases, public, name)
  if #found == 0 then
    return msg
  end
  return msg .. " -- see also in docs: " .. table.concat(found, ", ")
end

--- Checker forms that reliably identify a language topic. Argument failures
--- point to the general checked function-contract guide; a diagnostic does
--- not carry enough AST binding information here to claim a particular call.
--- Only a message [`teal.replacement`] leaves unanswered is pointed here
--- ([`with_hint`]).
local function diagnostic_docs(e: compiler.Error): string | nil
  local code = e.code
  if code == "arity" or (code == "mismatch" and e.context == "argument" and not e.nested) then
    return importer.diagnostic_queries.arguments
  elseif code == "invalid_key" and e.variable ~= nil and e.resolved_kind ~= "interface" then
    return importer.diagnostic_queries.record_key
  end
  return nil
end

local function with_diagnostic_docs(msg: string, e: compiler.Error, hints: Hints): string
  local query = diagnostic_docs(e)
  if query == nil then
    return msg
  end
  local databases, public = hints()
  if not symbols.has_example_query(databases, public, query) then
    return msg
  end
  return msg .. " -- see also: cosmic docs " .. query
end

--- Every hint a checker message earns, appended once, at the one place
--- every message is rendered, rather than patched into the vendored
--- checker's own text or duplicated at each call site. A message
--- [`teal.replacement`] answers says what to write instead, which a
--- reader acts on where a pointer at the docs goes unread, so it is
--- given no such pointer.
local function with_hint(e: compiler.Error, hints: Hints, answered: boolean): string
  local said = with_docs_hint(with_unused_hint(e), e, hints)
  if answered then
    return said
  end
  return with_diagnostic_docs(said, e, hints)
end

--- What a build says of the checker's error `e` met checking `file`,
--- whose source is `source`: the checker's words, then what to write
--- instead where [`teal.replacement`] answers (`refused` is what
--- [`teal.refused_type_requires`] found of the check), then every hint it
--- earns ([`with_hint`]), whole, as the first line of a build's
--- complaint to earn it reads.
function importer.said(e: compiler.Error, file: string, source: string,
                       refused: {string:boolean}, hints: Hints): string
  local instead: string | nil = nil
  local named = e.filename
  if named == "" or named == file then
    instead = teal.replacement(e, source, file, refused)
  end
  local said = with_hint(e, hints, instead ~= nil)
  if instead ~= nil then
    said = e.msg .. " -- " .. instead .. said:sub(#e.msg + 1)
  end
  return said
end

--- `file`'s own complaints, one line each. A removed name's replacement
--- ([`teal.replacement`]) comes straight after the checker's own words,
--- ahead of any pointer at the docs: it is the answer, they are more.
--- A hint repeated word for word in one file (one variable's every
--- field read, each unused name's) is printed on the first line that
--- earns it, with how many more lines it holds for, and those lines
--- carry the checker's words alone.
local function complain(file: string, source: string, result: compiler.Result,
                        hints: Hints): string
  local lines: {string} = {}
  local hinted: {string:integer} = {}
  local repeats: {integer:integer} = {}
  local refused = teal.refused_type_requires(file, source, result)
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or {}) do
      local where = e.filename ~= "" and e.filename or file
      local said = importer.said(e, file, source, refused, hints)
      local hint = said:sub(#e.msg + 1)
      local seen = where .. "\0" .. hint
      local first = hint ~= "" and hinted[seen] or nil
      if first ~= nil then
        repeats[first] = (repeats[first] or 0) + 1
        said = e.msg
      elseif hint ~= "" then
        hinted[seen] = #lines + 1
      end
      lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. said
    end
  end
  for at, more in pairs(repeats) do
    lines[at] = lines[at] .. " (same for " .. more .. " more)"
  end
  return table.concat(lines, "\n")
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

local function prepare_cache(handle: work.Handle, tool: string): Cache | nil, string
  local db = handle.db
  -- A compile build.contracts refused, kept anyway by an unjudged run,
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
    put = put, plan = plan }
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
                        lua: string | nil, bytecode: string | nil,
                        refused: boolean): boolean, string
  if lua ~= nil and bytecode ~= nil then
    local put = cache.put
    local bound, bind_trouble = put:bind_text(1, key)
    if bound then bound, bind_trouble = put:bind_text(2, cache.tool) end
    if bound then bound, bind_trouble = put:bind_text(3, lua) end
    if bound then bound, bind_trouble = put:bind_blob(4, bytecode) end
    if bound then bound, bind_trouble = put:bind_integer(5, refused and -1 or cache.run) end
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

--- The compiler, planned and cached like any module: its Lua
--- is its source, so only the bytecode is made, and only once per
--- compiler identity. Nothing to do when the working database holds no compiler,
--- as a project's does not. Never taken from the compiles every checkout
--- shares ([`Shared`]): loading and dumping it takes some ten milliseconds,
--- about what reading its half-megabyte row back would.
local function plan_compiler(handle: work.Handle, cache: Cache,
                             tool: string, ordinal: integer): boolean, string
  local rows, trouble = Sqlite.text_rows(handle.db,
    "SELECT source FROM inputs WHERE kind = 'vendor'")
  if rows == nil then
    return false, trouble
  end
  if #rows == 0 then
    return true, ""
  end
  if #rows > 1 then
    return false, "the working database holds " .. plural.count(#rows, "compiler") ..
      "; there is only ever one (derivation.put_compiler)"
  end
  local source = rows[1]:text(1)
  local key = compilation.vendor_key(source, tool)
  local stands, look_trouble = cached_stands(cache, key)
  if stands then
    return remember(cache, "vendor.tl", key, ordinal, nil, nil, false)
  end
  if look_trouble ~= "" then
    return false, look_trouble
  end
  local bytecode, dump_trouble = compilation.vendor_bytecode(source)
  if bytecode == nil then return false, dump_trouble end
  return remember(cache, "vendor.tl", key, ordinal, source, bytecode, false)
end

--- What [`compile_derived`] keeps as it compiles, for the closure
--- that compiles every module to write and its caller to read.
local record Progress
  --- Why the compile stopped, "" while it has not.
  failure: string
  env: compiler.Env | nil
  typed: receivers.State | nil
  ahead: importer.Ahead | nil
  scanned: boolean
end

--- What a compile with the new checker reads ([`build.pipeline`]): the options, and the program, made when the first module
--- that no cache answers needs it.
local record Reading
  options: Pipeline.Options | nil
  built: Pipeline.Built | nil
end

--- The databases a hint looks the name of a refused module up in, found
--- when the first refusal asks, and the projection among them that the
--- end of the compile closes.
local record Hinting
  databases: {Sqlite.Handle} | nil
  public: {boolean} | nil
  projection: Sqlite.Handle | nil
end

--- Every module path `target` reaches through what each source at a
--- path requires, itself included: a declaration's requires as well as
--- its implementation's, since a caller is checked against the one and
--- runs the other. A name no source of the tree is (a standard-library
--- module), or one whose only source does not parse, reaches no further.
local function reach(db: Sqlite.Handle, target: string): {string:boolean} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, r.name FROM inputs i JOIN requires r ON r.source_hash = i.source_hash " ..
      "WHERE i.kind <> 'vendor' ORDER BY i.path, r.ordinal")
  if rows == nil then
    return nil, trouble
  end
  local requires: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = requires[row:text(1)]
    if list == nil then
      list = {}
      requires[row:text(1)] = list
    end
    list[#list + 1] = row:text(2)
  end
  local reached: {string:boolean} = { [target] = true }
  local pending: {string} = { target }
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

--- What a module's key moving without its interface does: a compile made
--- under another key, of the same source against the same interfaces, stands
--- for this one ([`compilation.interface_keys`]). `reuse` copies such a
--- compile under `key`, and `note` keeps the one just made for the next
--- run. Only where the stubs are served (`serving`), as the interfaces are
--- theirs.
local record Interfacing
  reuse: function(Module, string): Reuse | nil
  note: function(Module, string)
end

-- TODO: offer a reused compile to the shared cache ([`build.shared_compiles`]) as a compiled one is, once
-- `reuse` reads its record-field uses back from `typed_refs` in the shape `shared.keep` takes: until then
-- another checkout compiles what this one only copied.

--- How many modules the loop compiles itself, of those no compile stands in for, before it hands every
--- module after them to the pool, where an earlier compile is kept to stand in for one ([`importer.Workers`]). A module that changed is compiled first, here, so
--- that the verdict on its stub ([`compilation.stub_held`]) is given before the modules that reach it ask
--- for their interface keys, and the pool is not made to compile the many a compile stands in for. An edit
--- that moves an interface compiles this many here besides, a few tenths of a second each.
-- TODO: compile the modules that changed in a first wave of the pool, and ask for the interface key of the rest once
-- their stubs are judged, rather than compile `seeds` here and the rest ahead: once the pool serves a job too small
-- for two shards (`count < 2` in build/worker.tl's `compile`), an edit of more than `seeds` modules has the pool
-- compile ahead modules a compile stands in for.
local seeds <const> = 6

local function interfacing_for(db: Sqlite.Handle, built: compiler, tool: string, serving: boolean,
                               modules: {Module}, keys: {string:compilation.Keys},
                               progress: Progress): Interfacing
  local made: {function(Module): string | nil, string} = {}
  local function interface_key(m: Module): string | nil
    if not serving then return nil end
    local interfaces = made[1]
    if interfaces == nil then
      local built_keys, _ = compilation.interface_keys(db, modules, tool, keys, function(path: string): boolean
        return compilation.stub_held(db, built, progress.env, keys, path)
      end)
      if built_keys == nil then return nil end
      made[1] = built_keys
      interfaces = built_keys
    end
    local found, _ = interfaces(m)
    return found
  end
  local function reuse(m: Module, key: string): Reuse | nil
    local interface = interface_key(m)
    if interface == nil then return nil end
    local rows, _ = Sqlite.text_rows(db,
      "SELECT c.key, c.lua, c.bytecode FROM compiled_interface i JOIN compiled c ON c.key = i.key " ..
        "WHERE i.ikey = ?1 AND c.tool = ?2 AND c.seen >= 0", { text(interface), text(tool) })
    local first: Sqlite.Row | nil = nil
    if rows ~= nil then first = rows[1] end
    if first == nil then return nil end
    local old = first:text(1)
    -- What else is kept under a compile's key: the record-field uses it
    -- found, and the verdicts on the stub of its module.
    local copied, _ = Sqlite.run(db, "DELETE FROM typed_refs WHERE key = ?1", { text(key) })
    if copied then
      copied, _ = Sqlite.run(db, "INSERT INTO typed_refs (key, ordinal, module, member, line) " ..
          "SELECT ?1, ordinal, module, member, line FROM typed_refs WHERE key = ?2",
        { text(key), text(old) })
    end
    if copied then
      copied, _ = Sqlite.run(db, "INSERT OR REPLACE INTO stub_holds (key, stub, held) " ..
          "SELECT ?1, stub, held FROM stub_holds WHERE key = ?2", { text(key), text(old) })
    end
    if not copied then return nil end
    -- The next edit reaches this compile, which stands this run, and not the
    -- older one a cache that is not used for a while drops.
    local _, _ = Sqlite.run(db, "INSERT OR REPLACE INTO compiled_interface (ikey, key) VALUES (?1, ?2)",
      { text(interface), text(key) })
    local found: Reuse = { lua = first:text(2), bytecode = first:bytes(3) }
    return found
  end
  local function note(m: Module, key: string)
    local interface = interface_key(m)
    if interface == nil then return end
    local _, _ = Sqlite.run(db, "INSERT OR REPLACE INTO compiled_interface (ikey, key) VALUES (?1, ?2)",
      { text(interface), text(key) })
  end
  return { reuse = reuse, note = note }
end

--- Whether an earlier compile is kept for a module to stand in for another's
--- ([`Interfacing`]): none is in a tree built for the first time, whose
--- modules the pool compiles from the first.
local function interfaces_kept(db: Sqlite.Handle): boolean
  local rows, _ = Sqlite.text_rows(db, "SELECT 1 FROM compiled_interface LIMIT 1")
  return rows ~= nil and #rows > 0
end

-- Which modules from `first` on must be compiled, before the loop
-- gets to them: the pool compiles them together, and the loop takes
-- each result in order. Started once the loop has met modules it
-- cannot take a compile for ([`seeds`]), so a module a compile stands
-- in for ([`Interfacing`]) is not compiled twice.
local function start_pool(first: integer, open: Cache, workers: importer.Workers, handle: work.Handle,
                          in_order: {Module}, by_path: {string:compilation.Keys}, shared: importer.Shared | nil,
                          looked: {string:importer.Shared.Compile}, progress: Progress,
                          own_tree: boolean, judged: boolean): boolean, string
  local wanted: {string:boolean} = {}
  local bytes = 0
  -- Which compiles stand, asked once rather than for each module.
  local standing, standing_trouble = Sqlite.text_rows(handle.db, "SELECT key FROM compiled WHERE seen >= 0")
  if standing == nil then
    finish_cache(open)
    return false, standing_trouble
  end
  local stands_by: {string:boolean} = {}
  for _, row in ipairs(standing) do stands_by[row:text(1)] = true end
  for ordinal = first, #in_order do
    local m = in_order[ordinal]
    local key = by_path[m.path].key
    m.key = key
    m.graph_key = by_path[m.path].graph
    if compilation.refusal(m) == nil then
      if stands_by[key] ~= true then
        local elsewhere = shared ~= nil and shared.look(m, own_tree) or nil
        if elsewhere ~= nil then
          looked[m.path] = elsewhere
        else
          wanted[m.path] = true
          bytes = bytes + #m.source
        end
      end
    end
  end
  progress.scanned = true
  if bytes > 0 and workers.ready(bytes) then
    -- The workers answer only when they are done, so this is the one
    -- line a long compile says before its result.
    -- TODO: say how many modules the workers have finished, every
    -- few seconds (build.progress's phase, which this module cannot
    -- require without joining the compiler's identity): once a
    -- worker's reply can be read with a timeout, the wait on it in
    -- build/workers.tl's `run` being the other TODO there.
    local count = 0
    for _ in pairs(wanted) do count = count + 1 end
    local _, _ = log:complain("build: compiling " .. plural.count(count, "module") ..
        " in worker processes")
    local made_ahead, ahead_trouble = workers.compile(handle.db, handle.root, in_order, wanted,
      own_tree, judged)
    if made_ahead == nil and ahead_trouble ~= "" then
      local _, _ = log:complain("build: workers: " .. ahead_trouble ..
          "; compiling in this process")
    end
    progress.ahead = made_ahead
  end
  return true, ""
end

--- Plans and compiles an already derived tree. Only the entry points
--- below own the shared cache; every failure here returns through them.
local function compile_derived(handle: work.Handle, built: compiler, tool: string,
                               own_tree: boolean, parses: importer.Parses,
                               unjudged: boolean | nil, shared: importer.Shared | nil,
                               pool: importer.Workers | nil,
                               checks: boolean, target: string | nil,
                               broken: {derivation.Broken} | nil,
                               grammar?: GrammarMode.Mode): importer.Result | nil, string
  local modules, trouble = compilation.collect(handle.db)
  if modules == nil then
    return nil, trouble
  end
  -- For a file run, what `target` reaches is `needed`; a module outside
  -- it that does not parse or compile is left out (`failed`), and so is
  -- each module that requires one, rather than stopping the run.
  local needed: {string:boolean} | nil = nil
  local failed: {string:boolean} = {}
  local left: {string} = {}
  -- A run with the new checker reads every module and goes on past one it refuses, so that one refusal does not hide the
  -- rest of the tree: a refused module, a module that does not parse and each module that requires one are named in the
  -- result's `refused`, run no tests, and fail the run ([`build.test`]).
  local lenient = grammar == "new" and target == nil
  local refusals: {string} = {}
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
  local order, why = compilation.ordered(modules)
  if order == nil then
    return nil, why
  end
  local refused_globals, globals_trouble = compilation.refuse_globals(handle.db)
  if globals_trouble ~= "" then
    return nil, globals_trouble
  end
  if refused_globals ~= nil then
    return nil, refused_globals
  end
  local keys, keys_trouble = compilation.dependency_keys(handle.db, modules, tool)
  if keys == nil then
    return nil, keys_trouble
  end
  -- In cosmic's own tree, a module that requires one whose stub has been
  -- held to its source's type is checked against the stub, which the
  -- checker reads in a fraction of the time ([`compilation.stub_lookup`]).
  --
  -- TODO: serve the new checker's compile ([`build.pipeline`]) the verified stubs too: it
  -- reads every module of the tree from source whatever it checks, and waits on
  -- a verdict that a stub has the type its source has under that checker, which
  -- `stub_holds` does not record.
  local serving = own_tree and grammar ~= "new"
  local stubbed = compilation.stub_lookup(handle.db, keys, serving)
  -- The new checker's compile: what it is made over ([`build.pipeline`]), read once the first module needs it. A module is
  -- keyed by the ceilings that hold it too, so that a pin that falls judges it again.
  local reading: Reading = { options = nil, built = nil }
  if grammar == "new" then
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
  end
  local result: importer.Result = {
    modules = {}, tool = tool, main = nil, refused = refusals, left_out = left,
    compiled = 0, cached = 0, shared = 0, worked = 0, parses = parses,
    catalog = grammar == "new" and require("build.pipeline").catalog or nil,
  }
  local db = handle.db
  -- `env` and `typed` are made on first use, by whichever module first
  -- fails to find a cached compile below: a run that compiles nothing
  -- never pays for `new_env`'s parse and type-check of tl's own prelude
  -- and stdlib. `ahead` is what the pool's processes compiled ahead of
  -- the loop below, and `scanned` whether the loop below has looked at
  -- every module for a compile elsewhere.
  local progress: Progress = { failure = "", scanned = false }

  local interfacing = interfacing_for(db, built, tool, serving, modules, keys, progress)

  -- Where a hint ([`with_docs_hint`]) looks up the name a refused module
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
      local databases: {Sqlite.Handle} = {}
      local public: {boolean} = {}
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

  -- The compiles found elsewhere in the same look at the modules.
  local looked: {string:importer.Shared.Compile} = {}

  local compile_all = function(): boolean, string
    local cleared, clear_trouble = db:exec("DELETE FROM plan")
    if not cleared then
      return false, clear_trouble
    end
    local forgotten, forget_trouble = forget_stale_receivers(db)
    if not forgotten then
      return false, forget_trouble
    end
    local judged = not unjudged
    local cache, prepare_trouble = prepare_cache(handle, tool)
    if cache == nil then
      return false, prepare_trouble
    end

    -- The modules compiled in this process so far, which meets the first
    -- `seeds` of those no compile stands in for before it hands the rest to
    -- the pool.
    local compiled_here = 0
    for ordinal, m in ipairs(order) do
      local key = keys[m.path].key
      m.key = key
      m.graph_key = keys[m.path].graph

      local refusal = compilation.refusal(m)
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
        local lua: string | nil = nil
        local bytecode: string | nil = nil
        local refused = false
        -- Another checkout's compile stands for one made here: its key
        -- and what else decides it are the same ([`build.shared_compiles`]),
        -- and it lands as a compile does, uses and all.
        local elsewhere: importer.Shared.Compile | nil = nil
        if not stands and progress.scanned then
          elsewhere = looked[m.path]
          looked[m.path] = nil
        elseif not stands and shared ~= nil then
          elsewhere = shared.look(m, own_tree)
        end
        -- A compile of the same source against the same interfaces, made
        -- under another key, is copied under this one.
        if not stands and elsewhere == nil then
          local reused = interfacing.reuse(m, key)
          if reused ~= nil then
            lua = reused.lua
            bytecode = reused.bytecode
          end
        end
        if stands or lua ~= nil then
          result.cached = result.cached + 1
        elseif elsewhere ~= nil then
          lua = elsewhere.lua
          bytecode = elsewhere.bytecode
          result.cached = result.cached + 1
          result.shared = result.shared + 1
          local kept_refs, refs_trouble = compilation.keep_references(db, key, elsewhere.references)
          if not kept_refs then
            finish_cache(cache)
            return false, m.file .. ": " .. refs_trouble
          end
        else
          -- A module the pool did not reach is compiled here, which is
          -- also how a refusal is told: the pool only knows it did not
          -- compile.
          if pool ~= nil and not progress.scanned and (compiled_here >= seeds or not interfaces_kept(db)) then
            local started, start_trouble = start_pool(ordinal, cache, pool, handle, order, keys, shared, looked, progress, own_tree, judged)
            if not started then
              return false, start_trouble
            end
          end
          local early: compilation.Generated | nil = nil
          local ahead = progress.ahead
          if ahead ~= nil then
            early = ahead.take(m.path)
          end
          local generated: compilation.Generated | nil = nil
          if early ~= nil then
            generated = early
            result.worked = result.worked + 1
            -- A compile that was not refused of a standard-library module
            -- has held its stub to its source's type
            -- ([`compilation.generate`]), as the verdict under its key says
            -- for the modules that reach it ([`compilation.interface_keys`]).
            if own_tree and not early.refused then
              local noted, note_trouble = compilation.note_held(db, keys, m)
              if not noted then
                finish_cache(cache)
                return false, m.file .. ": " .. note_trouble
              end
            end
          else
            compiled_here = compiled_here + 1
            local made_generated: compilation.Generated | nil = nil
            local generate_trouble = ""
            if grammar == "new" then
              -- Read the tree once, when the first module that is not cached asks.
              if reading.built == nil then
                local pipeline = require("build.pipeline")
                local made_built, built_trouble = pipeline.build(handle.db, assert(reading.options))
                if made_built == nil then
                  progress.failure = built_trouble
                  break
                end
                reading.built = made_built
              end
              made_generated, generate_trouble = require("build.pipeline").generate(m, assert(reading.built), checks, judged, hints)
            else
              if progress.env == nil then
                local made_env, env_trouble = teal.environment_for(built, handle.db, handle.root, checks, stubbed)
                if made_env == nil then
                  progress.failure = env_trouble
                  break
                end
                progress.env = made_env
                progress.typed = receivers.install(made_env)
              end
              made_generated, generate_trouble =
                compilation.generate(m, built, assert(progress.env), assert(progress.typed), own_tree, judged,
                  function(file: string, source: string, checked: compiler.Result): string
                    return complain(file, source, checked, hints)
                  end)
            end
            if made_generated == nil then
              if lenient then
                result.refused[#result.refused + 1] = generate_trouble
                failed[m.path] = true
              elseif needed == nil or needed[m.path] == true then
                progress.failure = generate_trouble
                break
              end
              result.left_out[#result.left_out + 1] = left_out(m.file, m.file, generate_trouble)
              failed[m.path] = true
            end
            generated = made_generated
          end
          if generated ~= nil then
            lua = generated.lua
            bytecode = generated.bytecode
            refused = generated.refused
            result.compiled = result.compiled + 1
            local kept_refs, refs_trouble = compilation.keep_references(db, key,
              generated.references)
            if not kept_refs then
              finish_cache(cache)
              return false, m.file .. ": " .. refs_trouble
            end
            if not refused then
              interfacing.note(m, key)
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

    if progress.failure == "" then
      local planned, plan_trouble = plan_compiler(handle, cache, tool,
        #order + 1)
      if not planned then
        finish_cache(cache)
        return false, plan_trouble
      end
    end
    finish_cache(cache)
    -- What this run read of the tree's modules from their source, and what it
    -- compiled, are the types a stub is held to, and the next run reads
    -- those stubs instead.
    local compiled_env = progress.env
    if own_tree and compiled_env ~= nil and progress.failure == "" then
      local held, hold_trouble = compilation.hold_stubs(db, built, compiled_env, keys)
      if not held then
        return false, hold_trouble
      end
    end
    local pruned, prune_trouble = Sqlite.run(db,
      "DELETE FROM compiled WHERE tool <> ?1 OR (seen >= 0 AND seen < ?2)" ..
        (judged and " OR seen < 0" or ""),
      { text(tool), { integer = handle.run - kept_runs - refresh_after } })
    if not pruned then
      return false, prune_trouble
    end
    local forgotten_verdicts, forgotten_trouble = db:exec(prune_stub_holds)
    if not forgotten_verdicts then
      return false, forgotten_trouble
    end
    local forgotten_interfaces, interfaces_trouble = db:exec(prune_interfaces)
    if not forgotten_interfaces then
      return false, interfaces_trouble
    end
    -- Run whether or not the prune above dropped anything: a run that
    -- failed between a compile's [`compilation.keep_references`] and its `remember`
    -- commits the uses without the compile (build.dispatch closes the
    -- handle, keeping what the run did), and only this sweeps them.
    return db:exec(importer.prune_references)
  end
  local made, compile_trouble = compile_all()
  local ahead = progress.ahead
  if ahead ~= nil then
    ahead.close()
  end
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
  return result
end

--- The compiler a self-build runs, chosen once the tree's identities are
--- recorded.
local type Choose = function(identities.Identities): string | nil, string

--- A self-build chooses the compiler that actually runs only after the
--- analyzer has stabilized and the complete tree identities are recorded.
local function prepare_compile(handle: work.Handle, built: compiler, tool: string,
                               unjudged: boolean | nil, shared: importer.Shared | nil,
                               pool: importer.Workers | nil,
                               choose: Choose | nil,
                               checks: boolean, target: string | nil,
                               grammar?: GrammarMode.Mode): importer.Result | nil, string
  local own_tree, own_trouble = tree.is_own(handle.root)
  if own_tree == nil then return nil, own_trouble end
  local broken: {derivation.Broken} | nil = nil
  if target ~= nil or grammar == "new" then broken = {} end
  local parses, derive_trouble = importer.derive(handle, own_tree, built, shared, pool, broken, grammar)
  if parses == nil then return nil, derive_trouble end
  if choose ~= nil then
    local recorded, record_trouble = identities.record_identities(handle.db)
    if recorded == nil then return nil, record_trouble end
    local selected, select_trouble = choose(recorded)
    if selected == nil then return nil, select_trouble end
    tool = selected
    if grammar == "new" then
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
  end
  return compile_derived(handle, built, tool, own_tree, parses, unjudged, shared, pool, checks,
    target, broken, grammar)
end

--- The cache belongs to the whole derive/identity/compile operation,
--- including successful rows offered before a later phase fails.
local function consuming_compile(handle: work.Handle, built: compiler, tool: string,
                                 unjudged: boolean | nil, shared: importer.Shared | nil,
                                 pool: importer.Workers | nil,
                                 choose?: function(identities.Identities): string | nil, string,
                                 checks?: boolean, target?: string,
                                 grammar?: GrammarMode.Mode): importer.Result | nil, string
  local result, trouble = prepare_compile(handle, built, tool, unjudged, shared, pool, choose,
    checks == true, target, grammar)
  if shared ~= nil then shared.finish() end
  if pool ~= nil then pool.close() end
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
--- generator writes at the reads a test narrowed ([`lang.fact_wraps`]), and not
--- the fork's `__cosmic_tc`: the Lua of the two differs, so their keys do. A
--- compile cached with the one is never the answer to a request for the other,
--- nor for none.
function importer.checked_tool(tool: string, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (wraps == true and "\0fact-wraps" or "\0run-time-checks"))
end

--- What a compile that asked to be reused stood on, and what it made.
local record Standing
  root: string
  tool: string
  unjudged: boolean
  checks: boolean
  grammar: string
  --- [`tree_state`] as the compile left it.
  state: string
  result: importer.Result
end

--- What this process holds of it, if anything.
local record Held
  standing: Standing | nil
end

local kept: Held = { standing = nil }

--- A digest of what a compile reads of the working database and leaves in
--- it: each staged file by its hash, each derived source, and the plan of
--- modules and keys it wrote. Nil where the database will not say.
local function tree_state(db: Sqlite.Handle): string | nil
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
--- The checker's environment ([`build.teal`]'s `environment_for`) is made
--- on first use, right before the first module that actually needs one
--- to compile, rather than up front: `new_env` parses and type-checks
--- tl's own prelude and stdlib declarations, so a build that finds
--- every module already cached never pays for it.
--- @param handle the working database the tree is staged in
--- @param built the compiler, loaded and ready
--- @param tool the identity of the compiler doing the compiling, which
---   every key carries
--- @param unjudged whether a module [`build.contracts`] refuses is kept
---   rather than refused: a stale tool rebuilding itself ([`build.reboot`])
---   judges the tree by its own, older rules and exemptions, so it
---   leaves the last word to the tool it builds, which re-enters the
---   command. A compile the old rules refuse is kept only for this run's
---   database, never reused, so the next run compiles and judges the
---   module again; one they pass is cached as any other, since a change
---   to the rules themselves forgets every compile ([`forget_stale_receivers`]).
--- @param shared the compiles and parses every checkout shares, or nil
---   for none: a module whose key misses here is taken from them rather
---   than compiled, and every compile made here but a refused one is
---   offered them, as its derive takes and offers parses
---   ([`importer.derive`]). Finished before this returns, whatever it
---   returns, with whatever an earlier derive given them offered.
--- @param pool the processes to parse and compile in, or nil for none
---   ([`importer.derive`]): a build with much to compile starts them,
---   and each module is compiled to the same Lua and bytecode in
---   whichever process compiles it, so the rows written do not depend on
---   the pool. Closed before this returns, whatever it returns.
--- @param grammar `new` to read, check and write the tree with the new checker ([`build.pipeline`]) in place of the
---   fork's; `tool` is then the one [`build.grammar_mode`] chose, and the keys hold the code that reads as well
---   ([`build.pipeline`]'s `coded`). nil or `teal` for the fork's, which is every other caller's.
--- @param checks whether the compiled Lua checks a value against its declared
---   kind at each declared parameter, return value and record field write,
---   and reports a mismatch to the hook `__cosmic_tc` ([`build.test_worker`]
---   installs one). It keys every compile by [`importer.checked_tool`], so no
---   cache shares an entry between the two. A pool is refused: the environment
---   that writes the checks is this process's. With the new checker (`grammar`)
---   the checks are the facts alone: each read of a place a test narrowed is
---   wrapped in a call of `__fact` ([`lang.fact_wraps`]), and the declared
---   parameters, returns and field writes are checked by none.
function importer.compile(handle: work.Handle, built: compiler,
                          tool: string, unjudged?: boolean,
                          shared?: importer.Shared,
                          pool?: importer.Workers,
                          checks?: boolean,
                          grammar?: GrammarMode.Mode,
                          again?: boolean): importer.Result | nil, string
  if grammar == "new" then
    -- The new checker reads the tree in this process.
    if pool ~= nil then
      pool.close()
      if shared ~= nil then shared.finish() end
      return nil, "a compile with the new checker (COSMIC_GRAMMAR=new) is made in this process: it takes no pool"
    end
    -- What it is made by is the code that reads: the checker and the readers.
    local pipeline = require("build.pipeline")
    tool = pipeline.coded(tool)
  end
  if checks == true then
    -- The pool's processes compile in environments of their own, which write
    -- no checks: given one, the compile would be keyed as checked and not be.
    if pool ~= nil then
      pool.close()
      if shared ~= nil then shared.finish() end
      return nil, "a compile with run-time checks is made in this process: it takes no pool"
    end
    -- The new checker's checks are the calls of `__fact` at the reads a test narrowed, the fork's the calls of
    -- `__cosmic_tc`: each is another program, keyed apart from the other and from none.
    tool = importer.checked_tool(tool, grammar == "new")
  end
  if again ~= true then
    return consuming_compile(handle, built, tool, unjudged, shared, pool, nil, checks, nil, grammar)
  end
  -- The caller built this tree already, in this process, and asks for that
  -- build where nothing it stands on has moved.
  local before = kept.standing
  if before ~= nil and before.root == handle.root and before.tool == tool and before.unjudged == (unjudged == true) and
      before.checks == (checks == true) and before.grammar == (grammar or "teal") and before.state == tree_state(handle.db) then
    if shared ~= nil then shared.finish() end
    if pool ~= nil then pool.close() end
    local was = before.result
    local again_result: importer.Result = {
      modules = was.modules, tool = was.tool, main = was.main, refused = was.refused, left_out = was.left_out,
      compiled = 0, cached = #was.modules, shared = 0, worked = 0, parses = was.parses, catalog = was.catalog,
    }
    return again_result, ""
  end
  local result, trouble = consuming_compile(handle, built, tool, unjudged, shared, pool, nil, checks, nil, grammar)
  kept.standing = nil
  if result == nil then return nil, trouble end
  local state = tree_state(handle.db)
  if state ~= nil then
    kept.standing = { root = handle.root, tool = tool, unjudged = unjudged == true, checks = checks == true,
      grammar = grammar or "teal", state = state, result = result }
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
--- the same message. Consumes `shared` and `pool` as that does, and compiles
--- with the checker `grammar` names as it does.
--
-- TODO: leave out a module outside `target`'s reach that a tree-wide check
-- refuses too -- a misplaced [`Test.policy`], a cycle of imports, a global, an
-- unknown `cosmic.*` require -- once those checks name the modules they
-- refuse rather than answering one message for the tree: today any of them
-- stops a file run whatever the file reaches.
function importer.compile_for(handle: work.Handle, built: compiler, tool: string,
                              target: string, shared?: importer.Shared,
                              pool?: importer.Workers,
                              grammar?: GrammarMode.Mode): importer.Result | nil, string
  if grammar == "new" then
    -- As [`importer.compile`] makes it: in this process, keyed by the code that reads.
    if pool ~= nil then
      pool.close()
      if shared ~= nil then shared.finish() end
      return nil, "a compile with the new checker (COSMIC_GRAMMAR=new) is made in this process: it takes no pool"
    end
    tool = require("build.pipeline").coded(tool)
  end
  return consuming_compile(handle, built, tool, false, shared, pool, nil, false, target, grammar)
end

--- Compiles a self-build after deriving its sources and recording its
--- complete identities. `choose` selects the compiler actually running:
--- the tree's for a boot, the running tool's until a rebuild settles.
--- Like [`importer.compile`], consumes `shared` and `pool`, finishing
--- each exactly once on success or failure. The working database and its
--- transaction remain the caller's, as does publishing the completed
--- projection. With `grammar` `new` the tree is read, checked and written by the
--- new checker ([`build.pipeline`]) in this process, so a `pool` is closed unused, and `choose` answers the tool string
--- [`build.grammar_mode`] makes of the compiler's identity: the tool the build leaves is told apart from one the fork
--- built ([`build.reboot`]).
function importer.compile_tree(handle: work.Handle, built: compiler,
                               choose: function(identities.Identities): string | nil, string,
                               unjudged: boolean, shared?: importer.Shared,
                               pool?: importer.Workers, grammar?: GrammarMode.Mode): importer.Result | nil, string
  if grammar == "new" then
    -- As [`importer.compile`]: the new checker reads the tree in this process.
    if pool ~= nil then pool.close() end
  end
  local pooled = pool
  if grammar == "new" then
    pooled = nil
  end
  return consuming_compile(handle, built, "", unjudged, shared, pooled, choose, false, nil, grammar)
end

return importer
