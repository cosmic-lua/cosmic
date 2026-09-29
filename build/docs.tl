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
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local narrow = require("build.narrow")
local plural = require("build.plural")
local reboot = require("build.reboot")
local symbols = require("build.symbols")
local tree = require("build.tree")

local log = require("build.verdict").log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")

local record docs
  --- The verbs' registrations: see build/verb_spec.tl.
  spec: verb_spec.Spec
  uses_spec: verb_spec.Spec
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
--- become `"Fs read"`, which matches those adjacent tokens in that order
--- in an example's text or source. Looser than an exact join on purpose:
--- one example answers for every symbol its code mentions, not only the
--- one whose name it shares.
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
--- `example_phrase`. Several can match one symbol, and each is as
--- relevant as any other, so source order serves better than a
--- ranking. `""` finds nothing, since a module's own row has no code of
--- its own to match.
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
    "ORDER BY e.file, e.line",
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

--- How many worked examples a symbol's page shows in full; the rest are
--- named in one line after them.
local EXAMPLES_SHOWN <const> = 2

--- Whether `at` in `code` starts a name: nothing before it continues an
--- identifier, so `MyFs.read` is no `Fs.read`.
local function starts_name(code: string, at: integer): boolean
  return at == 1 or code:sub(at - 1, at - 1):match("[%w_]") == nil
end

--- How many times `code` calls `symbol`, and where the first call is.
--- A call is spelled with `.` or `:` before the last name; a method
--- (a symbol two records deep, `Sqlite.Handle.exec`, or one written
--- with `:`) is also called through any value, `db:exec(`.
local function calls_of(code: string, symbol: string): integer, integer
  local spellings = { symbol }
  local colon = symbol:gsub("%.([%w_]+)$", ":%1")
  if colon ~= symbol then spellings[2] = colon end
  local last = symbol:match("([%w_]+)$")
  local _, dots = symbol:gsub("%.", "")
  if last ~= nil and (symbol:find(":", 1, true) ~= nil or dots >= 2) then
    spellings[#spellings + 1] = ":" .. last
  end
  local count, first = 0, math.maxinteger
  for _, spelled in ipairs(spellings) do
    local from = 1
    while true do
      local at, to = code:find(spelled, from, true)
      if at == nil then break end
      local after = code:sub(to + 1, to + 1)
      if after:match("[%w_]") == nil and (spelled:sub(1, 1) == ":" or starts_name(code, at)) then
        count = count + 1
        first = math.min(first, at)
      end
      from = to + 1
    end
  end
  return count, first
end

--- The function of an example's source, without the `require` lines and
--- top-level calls the analyzer put above it.
local function example_body(source: string): string
  return source:match("function Example%..*$") or source
end

--- Whether `line` closes the statement above it rather than begins one.
local function closes(line: string): boolean
  return line:match("^[})%]]") ~= nil or line:match("^end%f[^%w_]") ~= nil
end

--- What the analyzer put above an example's function, cut into its
--- top-level pieces: a `require`, a helper (any other `local`) or a
--- call (`Test.needs{...}`), each with the comment lines above it. The
--- text is in the layout `cosmic fix` writes, so a piece begins at a
--- line in column one that does not close the one before. `code` is a
--- piece's first line that is not a comment.
local function pieces_of(head: string): {{string}}
  local out: {{string}} = {}
  local lines: {string} = {}
  local code = ""
  local function finish()
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    if #lines > 0 then out[#out + 1] = { table.concat(lines, "\n"), code } end
    lines = {}
    code = ""
  end
  for line in (head .. "\n"):gmatch("(.-)\n") do
    local comment = line:match("^%-%-") ~= nil
    if line ~= "" and line:match("^%s") == nil and not closes(line) then
      if code ~= "" or (comment and #lines > 0 and lines[#lines] == "") then
        finish()
      end
      if not comment then code = line end
    end
    lines[#lines + 1] = line
  end
  finish()
  return out
end

--- An example's source as its page for `symbol` shows it. The analyzer
--- puts above the function the `require` lines it needs, the short
--- helpers it uses (`local function`, `local record`, ...) and, for a
--- file's first example, the file's top-level calls (`Test.needs{...}`).
--- Those calls are shown only on the page of a symbol they call; any
--- other page gets the function, the helpers and the `require` lines
--- its body and helpers name.
local function shown_source(source: string, symbol: string): string
  local body = example_body(source)
  local head = source:sub(1, #source - #body)
  local requires: {string} = {}
  local helpers: {string} = {}
  local calls: {string} = {}
  for _, piece in ipairs(pieces_of(head)) do
    if piece[2]:match("^local [%w_]+ = require%(") ~= nil then
      requires[#requires + 1] = piece[1]
    elseif piece[2]:match("^local ") ~= nil then
      helpers[#helpers + 1] = piece[1]
    else
      calls[#calls + 1] = piece[1]
    end
  end
  if #calls == 0 then
    return source
  end
  local call_text = table.concat(calls, "\n")
  if calls_of(call_text, symbol) > 0 then
    return source
  end
  local wanted = body .. "\n" .. table.concat(helpers, "\n")
  local kept: {string} = {}
  for _, line in ipairs(requires) do
    local name = line:match("^local ([%w_]+)")
    local found = false
    local from = 1
    while name ~= nil and not found do
      local at, to = wanted:find(name, from, true)
      if at == nil then break end
      found = starts_name(wanted, at) and wanted:sub(to + 1, to + 1):match("[%w_]") == nil
      from = to + 1
    end
    if found then kept[#kept + 1] = line end
  end
  local out = ""
  if #kept > 0 then out = table.concat(kept, "\n") .. "\n\n" end
  if #helpers > 0 then out = out .. table.concat(helpers, "\n\n") .. "\n\n" end
  return out .. body
end

--- `found` in the order a reader wants them: an example named for the
--- symbol (`Example.read` for `Fs.read`) first, then the one that
--- calls it most, then the one that calls it soonest, then the shorter,
--- then by file and line. An example is attached to a symbol by what
--- it calls, so one built around `truncate` also matches `Fs.read` and
--- must not lead its page.
local function ranked_examples(found: {docs.Example}, symbol: string): {docs.Example}
  local last = symbol:match("([%w_]+)$") or symbol
  local keys: {docs.Example: {integer}} = {}
  for _, ex in ipairs(found) do
    local body = example_body(ex.source)
    local calls, first = calls_of(body, symbol)
    keys[ex] = { ex.name == last and 0 or 1, -calls, first, #body }
  end
  local out: {docs.Example} = {}
  for _, ex in ipairs(found) do out[#out + 1] = ex end
  table.sort(out, function(a: docs.Example, b: docs.Example): boolean
    local ka, kb = keys[a], keys[b]
    for i = 1, #ka do
      if ka[i] ~= kb[i] then return ka[i] < kb[i] end
    end
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  return out
end

--- The modules that document themselves whose last dotted name is
--- `query` (`json` for `cosmic.json`, `util` for a project's
--- `myproj.util`), as their own rows, a project's own ahead of the
--- standard library's. A module
--- under `cosmic.internal`, a test module and an example module are
--- never one, whatever database is read, as in `docs.index`, so a bare
--- name means what a user of a library means by it.
local function modules_ending(db: Sqlite.Handle, query: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.symbol = '' AND " ..
    "substr(d.module, -length(?1) - 1) = '.' || ?1 AND " ..
    "d.module NOT LIKE 'cosmic.internal.%' AND substr(d.module, -5) <> '_test' AND " ..
    "substr(d.module, -8) <> '_example' " ..
    "ORDER BY d.module LIKE 'cosmic.%', d.module, d.id",
    { text(query) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- What a module with no documentation row of its own answers for its
--- name: the symbol it hands out, which carries the module's comment
--- (a `cmd/<name>/main.tl` that returns a function has no record to
--- hold it). `module` is the module's whole name.
local function module_symbol(db: Sqlite.Handle, public: boolean,
                             module: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
    symbols.shown_docs("d", public) .. " ORDER BY d.exported DESC, d.id LIMIT 1",
    { text(module) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The rows named `query` exactly: a symbol as declared (`Fs.read`), a
--- symbol's last name alone (`read`, matching every `X.read` and
--- `X:read`), or a module's own row (`cosmic.fs`).
local function named(db: Sqlite.Handle, public: boolean, query: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE " .. symbols.named_where("d") ..
    " AND " .. symbols.shown_docs("d", public) .. " ORDER BY d.module, d.id",
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
    symbols.shown_docs("d", public) .. " ORDER BY d.module, d.id",
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
--- A `local` declaration is left out too, whichever source is read: it
--- is not the module's surface, though `cosmic docs <name>` finds it in
--- a source that answers for the module's internals.
--- A call the module's own record declares as a field of function type
--- (`lstat: function(...)` in `cosmic.sys`'s syscall table) is listed
--- too, as a function; a record's plain data field, and any field of a
--- nested record (its symbol is dotted), is not. Nor is a field typed
--- `function` without parentheses, a generic one (`function<T>(...)`),
--- or an alias of a function type: only the literal `name: function(`
--- form is. A `metamethod` of the module's own record (`__call` of a
--- module that is itself callable) is listed too, by its signature; one
--- of a nested record (its `__close`) is that record's, as its other
--- fields are.
local function declared_in(db: Sqlite.Handle, public: boolean, module: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 " ..
    "AND d.symbol <> '' AND (d.kind NOT IN ('field', 'value', 'metamethod') OR " ..
    "(d.kind = 'metamethod' AND d.symbol NOT LIKE '%.%') OR " ..
    "(d.kind = 'field' AND d.symbol NOT LIKE '%.%' AND " ..
    "d.signature GLOB d.symbol || ': function(*')) AND " ..
    "(d.exported = 1 OR d.kind NOT IN ('function', 'method')) AND " ..
    "NOT " .. symbols.local_declaration("d") .. " AND " ..
    symbols.shown_docs("d", public) .. " ORDER BY d.id",
    { text(module) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The fields of every record and interface in `module`, and the values
--- of every enum, in declaration order: what a page lists under each.
--- A field of a `local` record, or one named `_...`, is left out of a
--- public source, as it is from every other view of it.
local function members_of(db: Sqlite.Handle, public: boolean,
                          module: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
    "d.kind IN ('field', 'value') AND " .. symbols.shown_docs("d", public) ..
    " ORDER BY d.id",
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
    symbols.shown_docs("d", public) .. " ORDER BY d.module, d.line",
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
    symbols.shown_docs("d", public) .. " ORDER BY d.module, d.id LIMIT 20",
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
      symbols.shown_docs("d", public) ..
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
    symbols.shown_docs("d", public) .. " ORDER BY d.module, d.id",
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
    "WHERE docs_fts MATCH ?1 AND " .. symbols.shown_docs("d", public) ..
    " ORDER BY " .. STANDS_IN_SQL .. " DESC, bm25(docs_fts), d.module, d.id LIMIT 20",
    { text(fts), text(spelled_as_code(lead)), text(lead:lower()) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- Every worked example whose own name, comment, or checked source carries
--- every word of `query`. An example is returned as itself, not as one of
--- the symbols it calls: its source cannot say which of several calls is
--- its subject.
local function searched_examples(db: Sqlite.Handle, public: boolean, fts: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT e.module, e.name, e.text, e.file, e.line, e.source FROM examples_fts " ..
    "JOIN examples e ON e.id = examples_fts.rowid " ..
    "WHERE examples_fts MATCH ?1 AND " .. symbols.public_only("e.module", public) ..
    -- Names and prose describe intent; source often mentions incidental APIs.
    " ORDER BY bm25(examples_fts, 3.0, 2.0, 0.2), e.module, e.file, e.line LIMIT 20",
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
    "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'docs'")
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
--- @param store the store's databases, `Store.databases()` unless the
--- caller hands it others, as a test of databases of its own does
function docs.databases(store?: {Sqlite.Handle}): docs.Sources
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
  for _, db in ipairs(store or Store.databases()) do
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
      "WHERE path IN (SELECT module FROM docs) UNION SELECT module FROM docs " ..
      "WHERE symbol = '' AND module GLOB 'doc.guides.*' ORDER BY path")
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

--- `written` as FTS5's default tokenizer reads it, closely enough for a
--- match: lowercased, each run of anything but letters and digits (`_`
--- among them) one space, and a space at each end, so a phrase is found
--- as " phrase " and never inside a longer word.
local function tokens_of(written: string): string
  local spaced = written:lower():gsub("[^%w]+", " ")
  return " " .. spaced:match("^%s*(.-)%s*$") .. " "
end

--- The verbs whose symbol, prose and options together carry every word
--- of `query`, as `Cli.<verb>` entries: the search reads doc comments,
--- and a verb's options are data (`Cli.options`), so what one does is
--- matched here instead, against the options of the binary answering,
--- as `render` shows them. Each word is a phrase, as `fts_query` quotes
--- it: `COSMIC_TEST_TIMEOUT` must be those three tokens in a row. They
--- come after what the index found, as the lesser match: most of what a
--- verb's options say is said again, closer, by the code they drive. A
--- verb `found` already holds is not repeated.
local function by_options(view: docs.View, query: string,
                          found: {docs.Entry}): {docs.Entry} | nil, string
  local wanted: {string} = {}
  for quoted in (fts_query(query) .. " "):gmatch('"([^"]*)" ') do
    local phrase = tokens_of(quoted)
    if phrase ~= "  " then wanted[#wanted + 1] = phrase end
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
      local spoken = tokens_of(entry.source_symbol .. "\n" .. entry.signature .. "\n" ..
        entry.text .. "\n" .. Flags.options(Cli.options[verb]))
      local all = true
      for _, phrase in ipairs(wanted) do
        if not spoken:find(phrase, 1, true) then all = false end
      end
      if all then out[#out + 1] = entry end
    end
  end
  return out, ""
end

--- What a dotted query names through a type alias or an inherited
--- record: `Child.Options.fds`, `Sqlite.Handle.exec`. Defined with the
--- other member helpers, below `first_sentence`.
local through_alias: function(view: docs.View, query: string): {docs.Entry} | nil, string

--- What `query` names, across `databases`, by the first rule that
--- answers:
--- - the public module a bare lowercase name ends (`json`, `fs`), with
---   its verb first if it is one (`test`);
--- - its exact matches, when it names a symbol or a module;
--- - for a qualified name that names nothing, what its qualifier offers
---   (see `scoped`);
--- - the documentation that carries all its words, and the verbs whose
---   options do (see `by_options`).
function docs.lookup(view: docs.View, query: string): docs.Lookup | nil, string
  -- A bare lowercase name that ends a public module's name is that
  -- module (`json` is `cosmic.json`, not the internal record `json`);
  -- the symbols it names exactly follow the module (`string` is
  -- `cosmic.string`, then `Shape.string`).
  local modules: {docs.Entry} = {}
  if query:match("^%l[%w_]*$") ~= nil then
    local found_modules, modules_trouble = across(view,
      function(db: Sqlite.Handle, _: boolean): {docs.Entry} | nil, string
        return modules_ending(db, query)
      end, entry_module)
    if found_modules == nil then
      return nil, modules_trouble
    end
    modules = found_modules
  end
  local exact, exact_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return named(db, public, query)
    end, entry_module)
  if exact == nil then
    return nil, exact_trouble
  end
  if #modules > 0 then
    -- What only shares the module's name, an internal record (`json`),
    -- is not another answer.
    local seen: {string: boolean} = {}
    for _, entry in ipairs(modules) do
      seen[entry.module .. "\n" .. entry.symbol] = true
    end
    -- The verb `cosmic <query>` names answers first, as `cosmic docs
    -- test` says it does, then the modules, then the other symbols.
    local answers: {docs.Entry} = {}
    local rest: {docs.Entry} = {}
    for _, entry in ipairs(exact) do
      local internal = entry.module:sub(1, 16) == "cosmic.internal." and
        entry.symbol == query
      if entry.module == "cosmic.cli" and entry.symbol == "Cli." .. query then
        answers[#answers + 1] = entry
        seen[entry.module .. "\n" .. entry.symbol] = true
      elseif not internal and not seen[entry.module .. "\n" .. entry.symbol] then
        rest[#rest + 1] = entry
      end
    end
    for _, entry in ipairs(modules) do answers[#answers + 1] = entry end
    for _, entry in ipairs(rest) do answers[#answers + 1] = entry end
    local counted, count_trouble = effective_counts(view, answers)
    if not counted then
      return nil, count_trouble
    end
    return lookup(answers, true, #answers), ""
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
  -- A module the index lists is always answered, though it has no row
  -- of its own to name it.
  if view.owners[query] ~= nil then
    local owner = view.owners[query]
    local held, held_trouble = module_symbol(view.databases[owner], view.public[owner] == true, query)
    if held == nil then
      return nil, held_trouble
    end
    if #held > 0 then
      local counted, count_trouble = effective_counts(view, held)
      if not counted then
        return nil, count_trouble
      end
      return lookup(held, true, #held), ""
    end
  end
  local through, through_trouble = through_alias(view, query)
  if through == nil then
    return nil, through_trouble
  end
  if #through > 0 then
    return lookup(through, true, #through), ""
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

--- Every module `view` holds, by name, with the first sentence of its
--- documentation ("" for one it does not document) -- no test or
--- example, which a reader never calls: what `cosmic docs` lists when
--- asked nothing.
function docs.index(view: docs.View): {docs.Summary} | nil, string
  local found, trouble = across(view, modules_of, entry_module)
  if found == nil then
    return nil, trouble
  end
  local said: {string: string} = {}
  for _, entry in ipairs(found) do
    if entry.symbol == "" then
      said[entry.module] = first_sentence(entry.text)
    end
  end
  local out: {docs.Summary} = {}
  for module, owner in pairs(view.owners) do
    local listed = module:sub(-5) ~= "_test" and module:sub(-8) ~= "_example" and
      (view.public[owner] ~= true or symbols.is_public_module(module) or
        symbols.is_public_guide(module))
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

--- The declaring record or enum of a member's source symbol:
--- `Child.Options.fds` is under `Child.Options`.
local function parent_of(symbol: string): string
  return symbol:match("^(.*)%.[^.]*$") or ""
end

--- A record's field, or an enum's value, on one line: as declared, then
--- the first sentence of what it says.
local function member_line(member: docs.Entry, limit?: integer): string
  local note = first_sentence(member.text)
  if limit ~= nil and #note > limit then
    local cut = note:sub(1, limit):match("^(.*%S)%s+%S*$") or note:sub(1, limit)
    note = cut:gsub("[,;:%-]+$", "") .. "…"
  end
  return member.signature .. (note ~= "" and " -- " .. note or "")
end

--- How long a field's note runs on a module's page, where a record's
--- fields are a glance; its own page keeps the whole sentence.
local NOTE_LIMIT <const> = 100

--- One declared symbol as a module's listing shows it: a function,
--- method or metamethod by its signature (a function-typed field as
--- `function` and its name, then the signature's parameters and
--- results), anything else (a record's signature spans lines) by kind
--- and name, then its uses and examples.
local function listed(item: docs.Entry): string
  local marks: {string} = {}
  if item.uses > 0 then
    marks[#marks + 1] = plural.count(item.uses, "use")
  end
  if item.examples > 0 then
    marks[#marks + 1] = plural.count(item.examples, "example")
  end
  local shown = item.kind .. " " .. item.source_symbol
  if (item.kind == "function" or item.kind == "method"
      or item.kind == "metamethod") and
     item.signature ~= "" and not item.signature:find("\n", 1, true) then
    shown = item.signature
  elseif item.kind == "field" then
    local rest = item.signature:match("^[%w_]+: function(%(.*)$")
    if rest ~= nil then
      shown = "function " .. item.source_symbol .. rest
    end
  end
  return shown .. (#marks > 0 and "  (" .. table.concat(marks, ", ") .. ")" or "")
end

--- The types a declaration stands for: `type Handle = raw_sqlite.Handle`
--- is one, `record Options is raw_http.Options` another (a list, comma
--- separated, when it extends several). Each is spelled as the module
--- wrote it.
local function type_references(entry: docs.Entry): {string}
  local out: {string} = {}
  local alias = entry.signature:match("^type [%w_]+ = ([%w_%.]+)$")
  if alias ~= nil then
    out[1] = alias
    return out
  end
  local bases = entry.signature:match("^[%a ]*record [%w_]+ is ([%w_%.,%s]+)$") or
    entry.signature:match("^[%a ]*interface [%w_]+ is ([%w_%.,%s]+)$")
  if bases ~= nil then
    for base in bases:gmatch("[%w_%.]+") do out[#out + 1] = base end
  end
  return out
end

--- The first row `sql` finds in any of `view`'s databases: the databases
--- are read whole, whatever they are public for, because a name a public
--- page hands out (an alias, a base) stands for the record it points at
--- even when that record is not itself a public symbol.
local function first_declared(view: docs.View, sql: string,
                              args: {Sqlite.Value}): docs.Entry | nil, string
  for _, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = Sqlite.text_rows(db, sql, args)
      if rows == nil then
        return nil, trouble
      end
      if #rows > 0 then
        return entries_of(rows)[1]
      end
    end
  end
  return nil
end

--- The record, interface or enum that `reference`, written in `module`,
--- names: one the module declares, one of `cosmic.internal.<module>`
--- (`raw_sqlite.Handle` is `sqlite.Handle` there), or one that another
--- module's own alias (`Compress.Stream`) points on to. Nil when it
--- names none, or nil and why on a database that cannot be read.
local function resolved_type(view: docs.View, module: string, reference: string,
                             depth: integer): docs.Entry | nil, string
  local types = "d.kind IN ('record', 'interface', 'enum') "
  local same, same_trouble = first_declared(view,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND d.source_symbol = ?2 " ..
    "AND " .. types .. "ORDER BY d.id LIMIT 1",
    { text(module), text(reference) })
  if same == nil and same_trouble ~= nil then
    return nil, same_trouble
  end
  if same ~= nil then
    return same
  end
  local stem, rest = reference:match("^([%w_]+)%.([%w_%.]+)$")
  if stem == nil then
    return nil
  end
  local record = stem:gsub("^raw_", ""):lower()
  local internal, internal_trouble = first_declared(view,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND d.source_symbol = ?2 " ..
    "AND " .. types .. "ORDER BY d.id LIMIT 1",
    { text("cosmic.internal." .. record), text(record .. "." .. rest) })
  if internal == nil and internal_trouble ~= nil then
    return nil, internal_trouble
  end
  if internal ~= nil then
    return internal
  end
  if depth >= 4 then
    return nil
  end
  local alias, alias_trouble = first_declared(view,
    "SELECT " .. columns .. " FROM docs d WHERE d.source_symbol = ?1 " ..
    "AND d.signature GLOB 'type * = *' AND d.exported = 1 ORDER BY d.id LIMIT 1",
    { text(reference) })
  if alias == nil then
    return nil, alias_trouble
  end
  local onward = type_references(alias)[1]
  if onward == nil then
    return nil
  end
  return resolved_type(view, alias.module, onward, depth + 1)
end

--- The fields, methods or values declared directly under `target`, as
--- its own module documents them, less any named `_...`: what a type
--- alias or a base record hands to its users.
local function members_under(view: docs.View, target: docs.Entry): {docs.Entry} | nil, string
  local out: {docs.Entry} = {}
  for _, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
        "d.kind IN ('field', 'value') AND d.source_symbol GLOB ?2 ORDER BY d.id",
        { text(target.module), text(target.source_symbol .. ".*") })
      if rows == nil then
        return nil, trouble
      end
      for _, member in ipairs(entries_of(rows)) do
        local name = member.source_symbol:match("([^.]*)$")
        if parent_of(member.source_symbol) == target.source_symbol and
            name:sub(1, 1) ~= "_" then
          out[#out + 1] = member
        end
      end
      if #out > 0 then
        return out
      end
    end
  end
  return out
end

--- What a declaration that stands for another type adds to its page:
--- the target's fields (or values), and its methods, each with its
--- documentation. `Sqlite.Handle` and `Child.Options` are aliases, so
--- they list what their target does; `Http.Options` extends one, so it
--- lists what it inherits after its own. Empty for a declaration that
--- stands for nothing.
local function inherited_lines(view: docs.View, entry: docs.Entry): {string} | nil, string
  local lines: {string} = {}
  local references = entry.symbol ~= "" and type_references(entry) or {}
  if #references == 0 then
    return lines
  end
  local own: {string: boolean} = {}
  if entry.kind == "record" or entry.kind == "interface" then
    local mine, mine_trouble = members_under(view, entry)
    if mine == nil then
      return nil, mine_trouble
    end
    for _, member in ipairs(mine) do own[member.source_symbol:match("([^.]*)$")] = true end
  end
  local heading = (entry.kind == "record" or entry.kind == "interface") and "inherited " or ""
  local fields: {string} = {}
  local methods: {string} = {}
  local values: {string} = {}
  for _, reference in ipairs(references) do
    local target, target_trouble = resolved_type(view, entry.module, reference, 0)
    if target == nil and target_trouble ~= nil then
      return nil, target_trouble
    end
    if target ~= nil and target.source_symbol ~= entry.source_symbol then
      local members, members_trouble = members_under(view, target)
      if members == nil then
        return nil, members_trouble
      end
      local short = target.source_symbol:match("([^.]*)$")
      for _, member in ipairs(members) do
        local name = member.source_symbol:match("([^.]*)$")
        if not own[name] then
          local note = first_sentence(member.text)
          local tail = member.signature:match("^[%w_]+: function%(" .. short .. "(.*)$")
          if member.kind == "value" then
            values[#values + 1] = "    " .. member_line(member)
          elseif tail ~= nil then
            methods[#methods + 1] = "    " .. name .. "(" ..
              (tail:sub(1, 2) == ", " and tail:sub(3) or tail) ..
              (note ~= "" and " -- " .. note or "")
          else
            fields[#fields + 1] = "    " .. member_line(member)
          end
        end
      end
    end
  end
  local function emit(title: string, rows: {string})
    if #rows > 0 then
      if #lines > 0 then lines[#lines + 1] = "" end
      lines[#lines + 1] = "  " .. title
      for _, row in ipairs(rows) do lines[#lines + 1] = row end
    end
  end
  emit(heading .. "values:", values)
  emit(heading .. "fields:", fields)
  emit(heading .. "methods:", methods)
  return lines
end

through_alias = function(view: docs.View, query: string): {docs.Entry} | nil, string
  local prefix, name = query:match("^([%w_]+%.[%w_%.]+)%.([%w_]+)$")
  if prefix == nil then
    return {}
  end
  local out: {docs.Entry} = {}
  local owners, owners_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return named(db, public, prefix)
    end, entry_module)
  if owners == nil then
    return nil, owners_trouble
  end
  for _, owner in ipairs(owners) do
    for _, reference in ipairs(type_references(owner)) do
      local target, target_trouble = resolved_type(view, owner.module, reference, 0)
      if target == nil and target_trouble ~= nil then
        return nil, target_trouble
      end
      if target ~= nil then
        local members, members_trouble = members_under(view, target)
        if members == nil then
          return nil, members_trouble
        end
        for _, member in ipairs(members) do
          if member.source_symbol:match("([^.]*)$") == name then
            member.module = owner.module
            member.symbol = owner.symbol .. "." .. name
            member.source_symbol = owner.source_symbol .. "." .. name
            member.exported = true
            out[#out + 1] = member
          end
        end
      end
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
    for line in String.lines(ex.text) do
      lines[#lines + 1] = #line > 0 and "  " .. line or ""
    end
    for line in String.lines(ex.source) do
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
    -- `local` says only how the module spelled a declaration it hands
    -- out; a caller reads it as a record like any other.
    lines[#lines + 1] = "  " .. (entry.exported and entry.signature:gsub("^local ", "")
      or entry.signature)
  end
  if #entry.related > 0 then
    lines[#lines + 1] = "  related search examples:"
    for _, ex in ipairs(entry.related) do
      lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
        ex.line .. "):"
      for line in String.lines(ex.text) do
        lines[#lines + 1] = #line > 0 and "  " .. line or ""
      end
      for line in String.lines(ex.source) do
        lines[#lines + 1] = #line > 0 and "    " .. line or ""
      end
    end
  end
  -- A module's signatures come right after its opening paragraph, ahead
  -- of the long prose: a reader scanning for a call wants the shapes
  -- first, and the prose that follows explains their shared contract.
  local index: {string} = {}
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
    local members, members_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return members_of(db, public, entry.module)
      end, entry_module)
    if members == nil then
      return nil, members_trouble
    end
    local under: {string: {docs.Entry}} = {}
    for _, member in ipairs(members) do
      local parent = parent_of(member.source_symbol)
      under[parent] = under[parent] or {}
      table.insert(under[parent], member)
    end
    -- A call the module's own record declares is listed as a function
    -- already, so it is not a field under that record as well.
    local listed_symbols: {string: boolean} = {}
    for _, item in ipairs(declared) do
      listed_symbols[item.symbol] = true
    end
    for _, item in ipairs(declared) do
      index[#index + 1] = "  " .. listed(item)
      for _, member in ipairs(under[item.source_symbol] or {}) do
        if not listed_symbols[member.symbol] then
          index[#index + 1] = "    " .. member_line(member, NOTE_LIMIT)
        end
      end
    end
  end
  -- The listing goes after the first paragraph, or, when that ends in
  -- a colon, after the run of indented or fenced blocks it introduces
  -- (an example), or else the next block, so the two stay together.
  local text_lines: {string} = {}
  for line in String.lines(entry.text) do text_lines[#text_lines + 1] = line end
  local function code_at(from: integer): boolean
    for j = from, #text_lines do
      if text_lines[j] ~= "" then
        return text_lines[j]:match("^%s") ~= nil or text_lines[j]:sub(1, 3) == "```"
      end
    end
    return false
  end
  local placed = #index == 0
  local last = ""
  local hold = false
  local fence = false
  for at, line in ipairs(text_lines) do
    if line:sub(1, 3) == "```" then fence = not fence end
    if not placed and not fence and line == "" and last ~= "" then
      if last:sub(-1) == ":" then
        hold = true
      elseif not (hold and code_at(at + 1)) then
        lines[#lines + 1] = ""
        for _, row in ipairs(index) do lines[#lines + 1] = row end
        placed = true
      end
    end
    if line ~= "" then last = line end
    lines[#lines + 1] = #line > 0 and "  " .. line or ""
  end
  if not placed then
    if entry.text ~= "" then lines[#lines + 1] = "" end
    for _, row in ipairs(index) do lines[#lines + 1] = row end
  end
  if entry.symbol ~= "" and (entry.kind == "record" or entry.kind == "interface"
      or entry.kind == "enum") then
    local members, members_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return members_of(db, public, entry.module)
      end, entry_module)
    if members == nil then
      return nil, members_trouble
    end
    local first = true
    for _, member in ipairs(members) do
      if parent_of(member.source_symbol) == entry.source_symbol then
        if first then
          if lines[#lines] ~= "" then
            lines[#lines + 1] = ""
          end
          lines[#lines + 1] = "  " .. (entry.kind == "enum" and "values:" or "fields:")
          first = false
        end
        lines[#lines + 1] = "    " .. member_line(member)
      end
    end
  end
  local inherited, inherited_trouble = inherited_lines(view, entry)
  if inherited == nil then
    return nil, inherited_trouble
  end
  if #inherited > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
  for _, line in ipairs(inherited) do lines[#lines + 1] = line end
  -- A verb's options are data, `Cli.options`, not prose: shown under
  -- its field as `cosmic help <verb>` shows them, and searched by
  -- `by_options`.
  local verb = entry.module == "cosmic.cli" and entry.symbol:match("^Cli%.(%w+)$") or nil
  if verb ~= nil and Cli.options[verb] ~= nil then
    lines[#lines + 1] = "  options:"
    for line in String.lines(Flags.options(Cli.options[verb])) do
      lines[#lines + 1] = "  " .. line
    end
  end
  if entry.symbol ~= "" then
    if entry.uses > 0 then
      lines[#lines + 1] = "  used in " .. plural.count(entry.uses, "place") ..
        "; cosmic uses " .. entry.source_symbol
    end
    local examples, examples_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Example} | nil, string
        return examples_for(db, public, entry.module, entry.source_symbol)
      end, function(_: docs.Example): string return entry.module end)
    if examples == nil then
      return nil, examples_trouble
    end
    local more: {string} = {}
    for at, ex in ipairs(ranked_examples(examples, entry.source_symbol)) do
      if at > EXAMPLES_SHOWN then
        more[#more + 1] = ex.name .. " (" .. ex.file .. ":" .. ex.line .. ")"
      else
        lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
          ex.line .. "):"
        for line in String.lines(ex.text) do
          lines[#lines + 1] = #line > 0 and "  " .. line or ""
        end
        for line in String.lines(shown_source(ex.source, entry.source_symbol)) do
          lines[#lines + 1] = #line > 0 and "    " .. line or ""
        end
      end
    end
    if #more > 0 then
      lines[#lines + 1] = "  " .. plural.count(#more, "more example") .. ": " ..
        table.concat(more, ", ")
    end
  end
  return lines, ""
end

--- `cosmic docs <query>`: prints what the query names and ends in a
--- verdict line; fails when nothing matches. With no query, lists
--- every module (`docs.index`).
local function run(argv: {integer:string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 2, {})
  if parsed == nil then
    log:complain("docs: " .. parse_trouble)
    return 2
  end
  local exit = reboot.stale_exit(argv)
  if exit ~= nil then
    return exit
  end
  local built, build_trouble = require("build.rebuild").here("docs")
  if not built then
    log:complain("docs: not rebuilt, answering from the last build: " .. build_trouble)
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
    log:verdict("docs", true, plural.count(#index, "module") .. ", " ..
      plural.count(#view.databases, "database") .. ", " .. clock.took(started))
    return 0
  end
  local found, trouble = docs.lookup(view, query)
  if found == nil then
    log:complain("docs: " .. trouble)
    return 1
  end
  if #found == 0 then
    log:verdict("docs", false, "nothing named or documented as '" .. query .. "', " ..
      clock.took(started))
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
    ", " .. plural.count(#view.databases, "database") .. ", " .. clock.took(started))
  return 0
end

--- `cosmic uses <symbol> [path...]`: every place that refers to the
--- symbol, one `file:line` per line -- only those in a file under one
--- of the paths, when there are any -- and a verdict line.
local function run_uses(argv: {integer:string}): integer
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
  local built, build_trouble = require("build.rebuild").here("uses")
  if not built then
    log:complain("uses: not rebuilt, answering from the last build: " .. build_trouble)
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
      clock.took(started))
    return 1
  end
  log:verdict("uses", true, plural.count(shown, "place") .. ", " .. clock.took(started))
  return 0
end

--- The `docs` verb as `build/verb_list.tl` lists it.
docs.spec = {
  name = "docs",
  guide = "looking up a symbol and where it is used",
  tests = { "build.docs_test" },
  run = function(argv: {integer:string}): integer return run(argv) end,
  bare = false,
  takes = "words to search for",
}

--- The `uses` verb as `build/verb_list.tl` lists it.
docs.uses_spec = {
  name = "uses",
  guide = "looking up a symbol and where it is used",
  tests = { "build.docs_test" },
  run = run_uses,
  bare = false,
  takes = "paths after its symbol",
}

return docs
