--- What the database says about a symbol: `cosmic docs` and `cosmic
--- uses`, read off the shipped `docs` and `uses` tables of every
--- database the store searches, and of a project's own `o/cosmic.db`
--- when the working directory holds one.
---
--- A query is a symbol first -- `Fs.read`, `read`, `cosmic.fs` -- and
--- words to search the documentation for when no symbol is called that.
--- A qualified name that names nothing (Proc.which) answers from what
--- its qualifier offers, and a search ranks first the functions whose
--- documentation names its first word as what they stand in for.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local clock = require("build.clock")
local narrow = require("build.narrow")
local reboot = require("build.reboot")
local symbols = require("build.symbols")
local tree = require("build.tree")

local log = require("build.verdict").log
local bind = require("build.bind")

local record docs
  --- The databases a lookup reads, in order, and which of them, by
  --- index, are public sources: what `view` takes.
  record Sources
    handles: {Sqlite.Handle}
    public: {boolean}
  end
  --- One ordered database view and the owner of every module in it.
  record View
    databases: {Sqlite.Handle}
    --- Which databases are public sources, by index: one answers only
    --- for the standard library's own modules -- `cosmic.*` that is
    --- neither `cosmic.internal.*` nor a test -- which is what a project
    --- sees of the binary it builds with. A project's own database, and
    --- every database inside cosmic's own tree, answer for everything.
    public: {integer: boolean}
    owners: {string: integer}
    --- How many places refer to a module/symbol pair, keyed by
    --- `use_key` -- computed on demand, once per command, by
    --- `effective_counts`, and cached here so several entries or
    --- renders naming the same symbol query `uses` only once.
    use_counts: {string: integer}
  end

  --- One worked example, matched to a symbol by content rather than by
  --- name -- see `examples_for`.
  record Example
    name: string
    text: string
    file: string
    line: integer
    source: string
  end

  --- One row of `docs`, with where it came from.
  record Entry
    module: string
    symbol: string
    source_symbol: string
    exported: boolean
    kind: string
    signature: string
    text: string
    file: string
    line: integer
    --- How many places in shipped modules refer to it.
    uses: integer
    --- How many worked examples match it -- see `examples_for`. A
    --- listing count, not the examples themselves: `render` fetches
    --- those separately, only for the one entry it is showing.
    examples: integer
    --- Examples whose comments or checked source matched a free-text
    --- search. Kept on the result only; the database remains unchanged.
    related: {Example}
  end

  record Lookup is {Entry}
    exact: boolean
    --- How many entries, from the first, are named by the query; any
    --- after them stand in for a raw binding it named (see `stand_ins`).
    named: integer
  end

  --- One module as the index lists it.
  record Summary
    module: string
    --- The first sentence of its documentation; "" when it has none.
    text: string
  end

  --- One row of `uses`.
  record Use
    module: string
    symbol: string
    from_module: string
    from_file: string
    line: integer
  end
end

local text = bind.text

--- A symbol as an `examples_fts` phrase: `Fs.read` and `Fs:read` alike
--- become `"Fs read"`, matching adjacent tokens in that order -- what
--- an example's own source reads as, tokenized, when it genuinely
--- calls the symbol it demonstrates. Looser than an exact join, and
--- deliberately so: this is what lets one example answer for every
--- symbol its code actually mentions, not only the one whose name it
--- happens to share.
---
--- On its own this over-matches: FTS5's tokenizer splits on `_`, so
--- `Hash.hex` and `Hash.hex_sha256` share the same first two tokens, and
--- `"Hash hex"` matches an example that only ever calls the second one.
--- `example_boundary` is the other half of every query this builds --
--- a phrase match narrows to candidates cheaply, the boundary check
--- on those few rows says whether the symbol is really there, whole.
local function example_phrase(symbol: string): string
  return '"' .. symbol:gsub("[%.:]", " ") .. '"'
end

--- A GLOB pattern matching `symbol` followed by a character that could
--- not continue the same identifier -- so `Hash.hex` matches `Hash.hex(`
--- but not `Hash.hex_sha256`. Checked against an example's own text and
--- source, space-joined so a match flush against the end of either
--- still has a boundary to land on.
local function example_boundary(symbol: string): string
  return "*" .. symbol .. "[^A-Za-z0-9_]*"
end

local EXAMPLE_BOUNDARY_SQL =
  "(e.text || ' ' || e.source || ' ') GLOB " ..
  "('*' || d.source_symbol || '[^A-Za-z0-9_]*')"

-- The row's use count is never read as queried: `effective_counts`
-- overwrites it on every path that renders `entry.uses` -- see
-- `entries_of` -- so this column is a placeholder, not a correlated
-- `uses` subquery run for every row of every listing or search.
local columns =
  "d.module, d.symbol, d.source_symbol, d.exported, d.kind, d.signature, " ..
  "d.text, d.file, d.line, " ..
  "0, " ..
  "CASE WHEN d.symbol = '' THEN 0 ELSE (SELECT count(*) FROM examples_fts " ..
  "JOIN examples e ON e.id = examples_fts.rowid " ..
  "WHERE e.module = d.module AND examples_fts MATCH " ..
  "('\"' || replace(replace(d.source_symbol, '.', ' '), ':', ' ') || '\"') " ..
  "AND " .. EXAMPLE_BOUNDARY_SQL .. ") END"

local function entries_of(rows: {{string}}): {docs.Entry}
  local out: {docs.Entry} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = {
      module = row[1], symbol = row[2], source_symbol = row[3],
      exported = row[4] == "1", kind = row[5], signature = row[6],
      text = row[7], file = row[8], line = math.tointeger(tonumber(row[9])) or 0,
      uses = math.tointeger(tonumber(row[10])) or 0,
      examples = math.tointeger(tonumber(row[11])) or 0,
      related = {},
    }
  end
  return out
end

--- Every worked example whose own text or source matches `symbol`, in
--- `module`, in the order its file declares them -- see
--- `example_phrase`. Several can match one symbol; each was written
--- deliberately for it once it matches at all, so source order reads
--- better than a relevance ranking would. `""` finds nothing, since a
--- module's own row has no code of its own to match.
local function examples_for(db: Sqlite.Handle, public: boolean, module: string,
                            symbol: string): {docs.Example} | nil, string
  if symbol == "" then
    return {}
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT e.name, e.text, e.file, e.line, e.source FROM examples_fts " ..
    "JOIN examples e ON e.id = examples_fts.rowid " ..
    "WHERE e.module = ?1 AND examples_fts MATCH ?2 " ..
    "AND (e.text || ' ' || e.source || ' ') GLOB ?3 " ..
    "AND " .. symbols.public_only("e.module", public) .. " " ..
    "ORDER BY e.line",
    { text(module), text(example_phrase(symbol)), text(example_boundary(symbol)) })
  if rows == nil then
    return nil, trouble
  end
  local out: {docs.Example} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { name = row[1], text = row[2], file = row[3],
      line = math.tointeger(tonumber(row[4])) or 0, source = row[5] }
  end
  return out
end

--- The rows named `query` exactly: a symbol as declared (`Fs.read`), a
--- symbol's last name alone (`read`, matching every `X.read` and
--- `X:read`), or a module's own row (`cosmic.fs`).
local function named(db: Sqlite.Handle, public: boolean, query: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE " .. symbols.named_where("d") ..
    " AND " .. symbols.public_only("d.module", public) .. " ORDER BY d.module, d.id",
    { text(query) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The rows named exactly by one of `names` (`d.symbol IN (...)`), in
--- one query -- unlike `named`, only the symbol as declared, never a
--- last name or a module's own row, since a caller passing several
--- names already knows exactly what each one is.
local function named_all(db: Sqlite.Handle, public: boolean,
                         names: {string}): {docs.Entry} | nil, string
  local placeholders: {string} = {}
  local args: {Sqlite.Value} = {}
  for index, name in ipairs(names) do
    placeholders[index] = "?" .. index
    args[index] = text(name)
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.symbol IN (" ..
    table.concat(placeholders, ", ") .. ") AND " ..
    symbols.public_only("d.module", public) .. " ORDER BY d.module, d.id",
    args)
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The symbols a module offers, for the listing under a module's own
--- documentation: everything its returned value reaches, and every type
--- it declares, since those are the names its signatures are written
--- in. A private helper function is left out -- a reader scanning the
--- module wants what they can call -- but `cosmic docs <name>` still
--- finds it.
local function declared_in(db: Sqlite.Handle, public: boolean, module: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 " ..
    "AND d.symbol <> '' AND d.kind NOT IN ('field', 'value') AND " ..
    "(d.exported = 1 OR d.kind NOT IN ('function', 'method')) AND " ..
    symbols.public_only("d.module", public) .. " ORDER BY d.id",
    { text(module) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- Every module's own documentation row, and every documented record
--- a module declares at its top: one of them says what a module is for
--- when its opening comment sits on it rather than above it.
local function modules_of(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE (d.symbol = '' OR " ..
    "(d.kind = 'record' AND d.symbol NOT LIKE '%.%' AND d.text <> '')) AND " ..
    symbols.public_only("d.module", public) .. " ORDER BY d.module, d.line",
    {})
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- A GLOB matching documentation that spells `word` as code: in
--- backticks, alone or leading a command line ("which", "mkdir -p").
--- Matched against lowercased text, so it is lowercased too.
local function spelled_as_code(word: string): string
  return "*`" .. word:lower() .. "[` ]*"
end

--- An SQL condition true when function `d` spells `?2` as code and `?3`
--- (lowercase) is not one of its own parameters: documentation backticks its
--- parameters (`path`, `name`) everywhere, so only a name that is not
--- one says what the function stands in for.
local STANDS_IN_SQL =
  "(d.kind IN ('function', 'method') AND lower(d.text) GLOB ?2 AND NOT (d.signature GLOB '*(' || ?3 || '[?:]*' " ..
  "OR d.signature GLOB '*, ' || ?3 || '[?:]*'))"

--- The first word of `query` a search keeps (see `fts_query`).
local function lead_word(query: string): string
  local first = ""
  for word in query:gmatch("[%w_]+") do
    if #word > 1 then
      return word
    end
    if first == "" then
      first = word
    end
  end
  return first
end

--- `query`'s words as an FTS5 query every one of them must match, each
--- quoted so it reads as a literal rather than as FTS5 syntax. A word of
--- one letter is left out when there are others: it is almost always a
--- flag ("cp -r", "rm -f") that no documentation spells alone, and
--- requiring it would find nothing.
local function fts_query(query: string): string
  local words: {string} = {}
  local short: {string} = {}
  for word in query:gmatch("[%w_]+") do
    if #word > 1 then
      words[#words + 1] = '"' .. word .. '"'
    else
      short[#short + 1] = '"' .. word .. '"'
    end
  end
  -- A query of nothing else ("x") still searches for what it has.
  if #words == 0 then
    words = short
  end
  return table.concat(words, " ")
end

--- The functions outside `cosmic.sys` whose documentation spells
--- `name` as code: what a reader who looked up a raw binding
--- ("unlink", "getpid") most likely wanted instead.
local function stand_ins(db: Sqlite.Handle, public: boolean,
                         name: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module <> 'cosmic.sys' " ..
    "AND d.kind IN ('function', 'method') AND d.exported = 1 AND lower(d.text) GLOB ?1 AND " ..
    symbols.public_only("d.module", public) .. " ORDER BY d.module, d.id LIMIT 20",
    { text(spelled_as_code(name)) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- For a qualified name that names nothing (`Proc.which`), what its
--- qualifier offers: the members whose documentation carries the last
--- name's words, best match first, or, when none does, every exported
--- function it declares. A reader who guessed the module right but the
--- name wrong sees the name they wanted among its neighbours, rather
--- than whatever elsewhere happens to use the word.
local function scoped(db: Sqlite.Handle, public: boolean, qualifier: string,
                      name: string): {docs.Entry} | nil, string
  -- The build keeps a member's own name in `symbol` (`find`) and the
  -- name it was written as in `source_symbol` (`Proc.find`).
  local member = qualifier .. "[.:]*"
  local fts = fts_query(name)
  if fts ~= "" then
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT " .. columns .. " FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
      "WHERE docs_fts MATCH ?1 AND d.source_symbol GLOB ?4 AND d.exported = 1 AND " ..
      symbols.public_only("d.module", public) ..
      " ORDER BY " .. STANDS_IN_SQL .. " DESC, bm25(docs_fts), d.module, d.id LIMIT 20",
      { text(fts), text(spelled_as_code(lead_word(name))), text(lead_word(name):lower()),
        text(member) })
    if rows == nil then
      return nil, trouble
    end
    if #rows > 0 then
      return entries_of(rows)
    end
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.source_symbol GLOB ?1 " ..
    "AND d.kind IN ('function', 'method') AND d.exported = 1 AND " ..
    symbols.public_only("d.module", public) .. " ORDER BY d.module, d.id",
    { text(member) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The rows whose symbol, signature or documentation carries every
--- word of `query`, best match first: those that spell its first word
--- as code, where it is not a parameter of theirs, then by relevance.
local function searched_docs(db: Sqlite.Handle, public: boolean, fts: string,
                             lead: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
    "WHERE docs_fts MATCH ?1 AND " .. symbols.public_only("d.module", public) ..
    " ORDER BY " .. STANDS_IN_SQL .. " DESC, bm25(docs_fts), d.module, d.id LIMIT 20",
    { text(fts), text(spelled_as_code(lead)), text(lead:lower()) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- Every worked example whose own name, comment, or checked source carries
--- every word of `query`. An example is its own honest search result: source
--- text cannot reliably say which one of several calls is its subject.
local function searched_examples(db: Sqlite.Handle, public: boolean, fts: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT e.module, e.name, e.text, e.file, e.line, e.source FROM examples_fts " ..
    "JOIN examples e ON e.id = examples_fts.rowid " ..
    "WHERE examples_fts MATCH ?1 AND " .. symbols.public_only("e.module", public) ..
    -- Names and prose describe intent; source often mentions incidental APIs.
    " ORDER BY bm25(examples_fts, 3.0, 2.0, 0.2), e.module, e.line LIMIT 20",
    { text(fts) })
  if rows == nil then
    return nil, trouble
  end
  local out: {docs.Entry} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row[1], symbol = "Example." .. row[2],
      source_symbol = "Example." .. row[2], exported = true, kind = "example",
      signature = "", text = row[3],
      file = row[4], line = math.tointeger(tonumber(row[5])) or 0,
      uses = 0, examples = 0,
      related = { { name = row[2], text = row[3], file = row[4],
        line = math.tointeger(tonumber(row[5])) or 0, source = row[6] } },
    }
  end
  return out
end

--- Whether `db` holds the shipped tables at all: a database built
--- before they existed answers no query here.
local function has_docs(db: Sqlite.Handle): boolean | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'docs'")
  if rows == nil then return nil, trouble end
  return #rows > 0, ""
end

--- `searched_docs` and `searched_examples` together. Each example is kept once
--- as itself; documentation rows retain their real symbol identity.
local function searched(db: Sqlite.Handle, public: boolean, query: string): {docs.Entry} | nil, string
  local fts = fts_query(query)
  if fts == "" then
    return {}
  end
  local from_docs, docs_trouble = searched_docs(db, public, fts, lead_word(query))
  if from_docs == nil then
    return nil, docs_trouble
  end
  local from_examples, examples_trouble = searched_examples(db, public, fts)
  if from_examples == nil then
    return nil, examples_trouble
  end
  local out: {docs.Entry} = {}
  for _, entry in ipairs(from_docs) do out[#out + 1] = entry end
  for _, entry in ipairs(from_examples) do out[#out + 1] = entry end
  return out
end

--- The places that refer to what `query` names, by the rule
--- `symbols.used_where` keeps.
local function uses_of(db: Sqlite.Handle, public: boolean, query: string): {docs.Use} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, from_module, from_file, line FROM uses u WHERE " ..
    symbols.used_where("u") .. " AND " ..
    symbols.public_only("module", public) .. " AND " ..
    symbols.public_only("from_module", public) ..
    " ORDER BY module, symbol, from_file, line", { text(query) })
  if rows == nil then
    return nil, trouble
  end
  local out: {docs.Use} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row[1], symbol = row[2], from_module = row[3],
      from_file = row[4], line = math.tointeger(tonumber(row[5])) or 0 }
  end
  return out
end

--- The databases a lookup reads, in order: the working directory's own
--- `o/cosmic.db` when there is one, then every database the store
--- searches. A module found in an earlier one hides the same module in
--- a later one, so a project's build answers for its own modules and
--- the binary answers for the standard library.
function docs.databases(): docs.Sources
  local out: {Sqlite.Handle} = {}
  local public: {boolean} = {}
  local own_exists, own_trouble = Fs.exists("o/cosmic.db")
  assert(own_exists ~= nil, own_trouble)
  if own_exists then
    -- The project's own build is best effort: one that cannot be opened
    -- or read (a directory, a file that is not a database, one a build
    -- is rewriting) is left out, so help and docs still answer from the
    -- binary's own databases rather than failing on a stale output.
    local own, _ = Sqlite.open("o/cosmic.db", false)
    if own ~= nil then
      local readable, _ = has_docs(own)
      if readable == nil then
        local _, _ = own:close()
      else
        out[#out + 1] = own
        public[#out] = false
      end
    end
  end
  -- Outside cosmic's own tree the store's databases are public sources:
  -- a project sees its own code and the standard library, never the
  -- build that made the binary.
  local root, root_trouble = Fs.absolute(".")
  assert(root ~= nil, root_trouble)
  local own_tree, tree_trouble = tree.is_own(root)
  assert(own_tree ~= nil, tree_trouble)
  local outside = not own_tree
  for _, db in ipairs(Store.databases()) do
    out[#out + 1] = db
    public[#out] = outside
  end
  return { handles = out, public = public }
end

--- One lookup over `databases`, in order, with a module answered by an
--- earlier database hiding it in every later one.
--- @param look what to read from each database
local function across<T>(view: docs.View,
                         look: function(Sqlite.Handle, boolean): {T} | nil, string,
                         module_of: function(T): string): {T} | nil, string
  local out: {T} = {}
  for index, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local found, trouble = look(db, view.public[index] == true)
      if found == nil then
        return nil, trouble
      end
      for _, item in ipairs(found) do
        local module = module_of(item)
        if view.owners[module] == index then
          out[#out + 1] = item
        end
      end
    end
  end
  return out
end

local function entry_module(entry: docs.Entry): string
  return entry.module
end

local function calling_module(use: docs.Use): string
  return use.from_module
end

local function use_key(module: string, symbol: string): string
  return module .. "\n" .. symbol
end

--- How many places refer to `module`/`symbol`, across `view.databases`.
--- A use counts only if the database is not a public source or both ends are
--- public modules, and only when that database owns the calling module; see
--- `across`. Each pair is computed once and cached on `view`, since both a
--- module listing and symbol rendering can request it in one command.
local function count_uses(view: docs.View, module: string,
                          symbol: string): integer | nil, string
  local key = use_key(module, symbol)
  local cached = view.use_counts[key]
  if cached ~= nil then
    return cached, ""
  end
  local seen: {string: boolean} = {}
  local total = 0
  for index, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT from_module, from_file, line FROM uses " ..
        "WHERE module = ?1 AND symbol = ?2",
        { text(module), text(symbol) })
      if rows == nil then
        return nil, trouble
      end
      for _, row in ipairs(rows) do
        local from_module = row[1]
        local counted = not view.public[index] or
          (symbols.is_public_module(module) and symbols.is_public_module(from_module))
        if counted and view.owners[from_module] == index then
          local position = module .. "\n" .. symbol .. "\n" .. from_module ..
            "\n" .. row[2] .. "\n" .. row[3]
          if not seen[position] then
            seen[position] = true
            total = total + 1
          end
        end
      end
    end
  end
  view.use_counts[key] = total
  return total, ""
end

local function effective_counts(view: docs.View, entries: {docs.Entry}): boolean, string
  for _, entry in ipairs(entries) do
    local uses, trouble = count_uses(view, entry.module, entry.symbol)
    if uses == nil then
      return false, trouble
    end
    entry.uses = uses
  end
  return true, ""
end

--- Resolves module ownership once for a docs command or direct caller.
--- Membership comes from `modules`, even when the owning database has
--- no documentation for that module, and from `decls` -- `cosmic.sys`
--- is only a declaration -- where it does: a database that copied a
--- declaration without its documentation must not hide the one that
--- documents it.
--- @param public which databases, by index, are public sources
function docs.view(databases: {Sqlite.Handle}, public?: {boolean}): docs.View | nil, string
  local scope: {integer: boolean} = {}
  for index, flag in ipairs(public or {}) do
    scope[index] = flag
  end
  local owners: {string: integer} = {}
  for index, db in ipairs(databases) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT path FROM modules UNION SELECT path FROM decls " ..
      "WHERE path IN (SELECT module FROM docs) ORDER BY path")
    if rows == nil then
      return nil, trouble
    end
    for _, row in ipairs(rows) do
      if owners[row[1]] == nil then
        owners[row[1]] = index
      end
    end
  end
  return { databases = databases, public = scope, owners = owners,
           use_counts = {} }
end

--- `entries` as a lookup's answer.
local function lookup(entries: {docs.Entry}, exact: boolean, count: integer): docs.Lookup
  local out: docs.Lookup = { exact = exact, named = count }
  for i, entry in ipairs(entries) do out[i] = entry end
  return out
end

--- The words `written` holds, lowercased, as FTS5's default tokenizer
--- splits it closely enough for a match: runs of letters and digits.
local function words_of(written: string): {string:boolean}
  local out: {string:boolean} = {}
  for word in written:lower():gmatch("%w+") do out[word] = true end
  return out
end

--- The verbs whose prose and options together carry every word of
--- `query`, as `Cli.<verb>` entries: the search reads doc comments, and
--- a verb's options are data (`Cli.options`), so what one does is
--- matched here instead, against the options of the binary answering.
--- A verb `found` already holds is not repeated.
local function by_options(view: docs.View, query: string,
                          found: {docs.Entry}): {docs.Entry} | nil, string
  local wanted: {string} = {}
  for quoted in (fts_query(query) .. " "):gmatch('"([^"]*)" ') do
    wanted[#wanted + 1] = quoted:lower()
  end
  if #wanted == 0 then
    return {}
  end
  local names: {string} = {}
  for verb in pairs(Cli.options) do names[#names + 1] = "Cli." .. verb end
  table.sort(names)
  local fields, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return named_all(db, public, names)
    end, entry_module)
  if fields == nil then
    return nil, trouble
  end
  local held: {string:boolean} = {}
  for _, entry in ipairs(found) do held[entry.module .. "\n" .. entry.symbol] = true end
  local out: {docs.Entry} = {}
  for _, entry in ipairs(fields) do
    local verb = entry.module == "cosmic.cli" and entry.symbol:match("^Cli%.(%w+)$") or nil
    if verb ~= nil and not held[entry.module .. "\n" .. entry.symbol] then
      local spoken = words_of(entry.text .. "\n" .. Flags.options(Cli.options[verb]))
      local all = true
      for _, word in ipairs(wanted) do
        if not spoken[word] then all = false end
      end
      if all then out[#out + 1] = entry end
    end
  end
  return out, ""
end

--- What `query` names, across `databases`: its exact matches when it
--- names a symbol or a module; for a qualified name that names nothing,
--- what its qualifier offers (see `scoped`); otherwise the
--- documentation that carries all its words, and the verbs whose
--- options do (see `by_options`).
function docs.lookup(view: docs.View, query: string): docs.Lookup | nil, string
  local exact, exact_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return named(db, public, query)
    end, entry_module)
  if exact == nil then
    return nil, exact_trouble
  end
  if #exact > 0 then
    local named_count = #exact
    -- A raw binding's name is also what its wrapper stands in for:
    -- "unlink" answers with sys.unlink and then Fs.remove.
    local raw = query:match("^[%w_]+$") ~= nil
    for _, entry in ipairs(exact) do
      if entry.module ~= "cosmic.sys" then
        raw = false
      end
    end
    if raw then
      local wrapping, wrapping_trouble = across(view,
        function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
          return stand_ins(db, public, query)
        end, entry_module)
      if wrapping == nil then
        return nil, wrapping_trouble
      end
      for _, entry in ipairs(wrapping) do
        exact[#exact + 1] = entry
      end
    end
    local counted, count_trouble = effective_counts(view, exact)
    if not counted then
      return nil, count_trouble
    end
    return lookup(exact, true, named_count), ""
  end
  local found: {docs.Entry} = {}
  local qualifier, name = query:match("^([%w_]+)[.:]([%w_]+)$")
  if qualifier ~= nil then
    local near, near_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return scoped(db, public, qualifier, name)
      end, entry_module)
    if near == nil then
      return nil, near_trouble
    end
    found = near
  end
  if #found == 0 then
    local searched_found, search_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return searched(db, public, query)
      end, entry_module)
    if searched_found == nil then
      return nil, search_trouble
    end
    found = searched_found
    local verbs, verbs_trouble = by_options(view, query, found)
    if verbs == nil then
      return nil, verbs_trouble
    end
    for _, entry in ipairs(verbs) do found[#found + 1] = entry end
  end
  local counted, count_trouble = effective_counts(view, found)
  if not counted then
    return nil, count_trouble
  end
  return lookup(found, false, 0), ""
end

--- The first sentence of `documented`'s first paragraph, on one line:
--- up to the first `.`, `?` or `!` that a space or the end follows,
--- outside backticks and not closing "e.g" or "i.e".
local function first_sentence(documented: string): string
  local trimmed = documented:match("^%s*(.-)%s*$")
  local paragraph = (trimmed:match("^(.-)\n%s*\n") or trimmed):gsub("%s+", " ")
  local quoted = false
  for at = 1, #paragraph do
    local char = paragraph:sub(at, at)
    if char == "`" then
      quoted = not quoted
    elseif not quoted and (char == "." or char == "?" or char == "!") and
        (at == #paragraph or paragraph:sub(at + 1, at + 1) == " ") then
      local before = paragraph:sub(math.max(1, at - 3), at - 1)
      if before ~= "e.g" and before ~= "i.e" then
        return paragraph:sub(1, at)
      end
    end
  end
  return paragraph
end

--- Whether `entry`'s comment opens its file: a record's, standing in
--- for the module's own row when a file's opening comment sits on it.
local function opens_its_file(entry: docs.Entry): boolean
  local _, breaks = entry.text:gsub("\n", "")
  return entry.line - (breaks + 1) == 1
end

--- Every module `view` holds, by name, with the first sentence of its
--- documentation ("" for one it does not document) -- no test or
--- example, which a reader never calls: what `cosmic docs` lists when
--- asked nothing.
function docs.index(view: docs.View): {docs.Summary} | nil, string
  local found, trouble = across(view, modules_of, entry_module)
  if found == nil then
    return nil, trouble
  end
  -- The module's own row when it has one, else the record its opening
  -- comment sits on.
  local said: {string: string} = {}
  for _, entry in ipairs(found) do
    if entry.symbol == "" or (said[entry.module] == nil and opens_its_file(entry)) then
      said[entry.module] = first_sentence(entry.text)
    end
  end
  local out: {docs.Summary} = {}
  for module, owner in pairs(view.owners) do
    local listed = module:sub(-5) ~= "_test" and module:sub(-8) ~= "_example" and
      (view.public[owner] ~= true or symbols.is_public_module(module))
    if listed then
      out[#out + 1] = { module = module, text = said[module] or "" }
    end
  end
  table.sort(out, function(a: docs.Summary, b: docs.Summary): boolean
    return a.module < b.module
  end)
  return out
end

--- Every one of `names` that names a symbol exactly, in one query per
--- database rather than one lookup per name -- built for a caller
--- that needs several known symbols in one command, such as `cosmic
--- help` listing every verb. `#names == 0` finds nothing without
--- querying. A name absent from the result was not found; this never
--- fails for that, only for real trouble reading a database.
function docs.named_all(view: docs.View, names: {string}): {docs.Entry} | nil, string
  if #names == 0 then
    return {}
  end
  local found, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
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

--- Every place across `databases` that refers to what `query` names.
function docs.uses(view: docs.View, query: string): {docs.Use} | nil, string
  local found, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Use} | nil, string
      return uses_of(db, public, query)
    end, calling_module)
  if found == nil then
    return nil, trouble
  end
  local out: {docs.Use} = {}
  local seen: {string: boolean} = {}
  for _, use in ipairs(found) do
    local key = use.module .. "\n" .. use.symbol .. "\n" .. use.from_module ..
      "\n" .. use.from_file .. "\n" .. use.line
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = use
    end
  end
  return out
end

--- One entry, as `cosmic docs` prints it: where it is, its signature,
--- its documentation indented under that, and how many places use it.
--- A module's row lists the symbols it declares instead of a signature.
--- Nil and why when a database cannot be read.
function docs.render(view: docs.View, entry: docs.Entry): {string} | nil, string
  local lines: {string} = {}
  if entry.kind == "example" then
    local ex = entry.related[1]
    lines[#lines + 1] = entry.module .. " example " .. ex.name .. " (" ..
      ex.file .. ":" .. ex.line .. ")"
    for line in (ex.text .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = #line > 0 and "  " .. line or ""
    end
    for line in (ex.source .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = #line > 0 and "    " .. line or ""
    end
    return lines, ""
  end
  if entry.symbol == "" then
    lines[#lines + 1] = entry.module .. " (" .. entry.file .. ")"
  else
    local at = entry.line > 0 and ":" .. entry.line or ""
    lines[#lines + 1] = entry.module .. " " .. entry.source_symbol .. " (" ..
      entry.file .. at .. ")"
    lines[#lines + 1] = "  " .. entry.signature
  end
  if #entry.related > 0 then
    lines[#lines + 1] = "  related search examples:"
    for _, ex in ipairs(entry.related) do
      lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
        ex.line .. "):"
      for line in (ex.text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = #line > 0 and "  " .. line or ""
      end
      for line in (ex.source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = #line > 0 and "    " .. line or ""
      end
    end
  end
  for line in (entry.text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = #line > 0 and "  " .. line or ""
  end
  -- A verb's options are data, `Cli.options`, not prose: shown under
  -- its field as `cosmic help` shows them, and searched by
  -- `by_options`.
  local verb = entry.module == "cosmic.cli" and entry.symbol:match("^Cli%.(%w+)$") or nil
  if verb ~= nil and Cli.options[verb] ~= nil then
    lines[#lines + 1] = "  options:"
    for line in (Flags.options(Cli.options[verb]) .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = "  " .. line
    end
  end
  if entry.symbol == "" then
    local declared, declared_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return declared_in(db, public, entry.module)
      end, entry_module)
    if declared == nil then
      return nil, declared_trouble
    end
    local counted, count_trouble = effective_counts(view, declared)
    if not counted then
      return nil, count_trouble
    end
    for _, item in ipairs(declared) do
      local marks: {string} = {}
      if item.uses > 0 then
        marks[#marks + 1] = item.uses .. " uses"
      end
      if item.examples > 0 then
        marks[#marks + 1] = item.examples .. " example" ..
          (item.examples == 1 and "" or "s")
      end
      lines[#lines + 1] = "  " .. item.kind .. " " .. item.source_symbol ..
        (#marks > 0 and " (" .. table.concat(marks, ", ") .. ")" or "")
    end
  else
    if entry.uses > 0 then
      lines[#lines + 1] = "  used in " .. entry.uses .. " place" ..
        (entry.uses == 1 and "" or "s") .. "; cosmic uses " .. entry.source_symbol
    end
    local examples, examples_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Example} | nil, string
        return examples_for(db, public, entry.module, entry.source_symbol)
      end, function(_: docs.Example): string return entry.module end)
    if examples == nil then
      return nil, examples_trouble
    end
    for _, ex in ipairs(examples) do
      lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
        ex.line .. "):"
      for line in (ex.text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = #line > 0 and "  " .. line or ""
      end
      for line in (ex.source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = #line > 0 and "    " .. line or ""
      end
    end
  end
  return lines, ""
end

--- `cosmic docs <query>`: prints what the query names and ends in a
--- verdict line; fails when nothing matches. With no query, lists
--- every module (`docs.index`).
function docs.run(argv: {integer:string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed == nil then
    log:complain("docs: " .. parse_trouble)
    return 2
  end
  local exit = reboot.stale_exit(argv)
  if exit ~= nil then
    return exit
  end
  local started = Time.monotonic_ns()
  local query = table.concat(parsed.words, " ")
  local sources = docs.databases()
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then
    log:complain("docs: " .. view_trouble)
    return 1
  end
  if query == "" then
    local index, index_trouble = docs.index(view)
    if index == nil then
      log:complain("docs: " .. index_trouble)
      return 1
    end
    local width = 0
    for _, summary in ipairs(index) do
      width = math.max(width, #summary.module)
    end
    for _, summary in ipairs(index) do
      local line = summary.module
      if summary.text ~= "" then
        line = line .. string.rep(" ", width - #line + 2) .. summary.text
      end
      log:say(line)
    end
    log:say("")
    log:say("`cosmic docs <module>` shows one, with what it offers; " ..
      "`cosmic docs <words>` searches them all.")
    log:verdict("docs", true, #index .. " modules, " .. #view.databases ..
      " databases, " .. clock.elapsed_ms(started) .. " ms")
    return 0
  end
  local found, trouble = docs.lookup(view, query)
  if found == nil then
    log:complain("docs: " .. trouble)
    return 1
  end
  if #found == 0 then
    log:verdict("docs", false, "nothing named or documented as '" .. query .. "', " ..
      clock.elapsed_ms(started) .. " ms")
    return 1
  end
  if not found.exact then
    log:say("No exact symbol match; showing related documentation:")
    log:say("")
  end
  for index, entry in ipairs(found) do
    if index > 1 then
      log:say("")
    end
    local lines, render_trouble = docs.render(view, entry)
    if lines == nil then
      log:complain("docs: " .. render_trouble)
      return 1
    end
    for _, line in ipairs(lines) do
      log:say(line)
    end
  end
  log:say("")
  local counted = found.exact and found.named .. " named" or #found .. " found"
  if found.exact and #found > found.named then
    counted = counted .. ", " .. (#found - found.named) .. " standing in"
  end
  log:verdict("docs", true, counted ..
    ", " .. #view.databases .. " databases, " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

--- `cosmic uses <symbol> [path...]`: every place that refers to the
--- symbol, one `file:line` per line -- only those in a file under one
--- of the paths, when there are any -- and a verdict line.
function docs.run_uses(argv: {integer:string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed == nil then
    log:complain("uses: " .. parse_trouble)
    return 2
  end
  local query = parsed.words[1] or ""
  if query == "" then
    log:complain("uses: which symbol? as declared (Fs.read) or by its last name (read)")
    return 2
  end
  local exit = reboot.stale_exit(argv)
  if exit ~= nil then
    return exit
  end
  local started = Time.monotonic_ns()
  local sources = docs.databases()
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then
    log:complain("uses: " .. view_trouble)
    return 1
  end
  local found, trouble = docs.uses(view, query)
  if found == nil then
    log:complain("uses: " .. trouble)
    return 1
  end
  local words: {string} = {}
  for slot = 2, #parsed.words do words[#words + 1] = parsed.words[slot] end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain("uses: " .. root_trouble)
    return 1
  end
  local paths = narrow.paths(root, words)
  local shown = 0
  for _, use in ipairs(found) do
    if narrow.holds(paths, use.from_file) then
      log:say(use.from_file .. ":" .. use.line .. ": " .. use.module .. " " .. use.symbol)
      shown = shown + 1
    end
  end
  if shown == 0 then
    local where = #paths > 0 and " under " .. table.concat(paths, ", ") or ""
    log:verdict("uses", false, "nothing" .. where .. " refers to '" .. query .. "', " ..
      clock.elapsed_ms(started) .. " ms")
    return 1
  end
  log:verdict("uses", true, shown .. " places, " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

return docs
