--- The search over a database's docs: names, words, guides and their sections of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local link_text = require("cosmic.internal.link_text")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local Examples = require("cosmic.doc.examples")
local type Example = Types.Example
local type Entry = Types.Entry
local calls_of = Examples.calls_of
local columns = Examples.columns
local entries_of = Examples.entries_of
local example_body = Examples.example_body
local text = Examples.text

--- What [`ranked_examples`] orders an example by, each field lower first.
local record Rank
  named: integer
  calls: integer
  first: integer
  size: integer
end

--- A guide's `##` sections: each heading's text, its anchor (as
--- GitHub spells one) and the lines under it, up to the next heading.
--- What comes before the first heading is not a section, since the
--- guide's own row says it. A `#` line inside a fence is code, not a heading.
local record Section
  heading: string
  anchor: string
  body: string
end

local record Scored
  entry: Entry
  score: integer
end

local record Search
  type Entry = Entry
  type Example = Example
  type Rank = Rank
  type Section = Section
  type Scored = Scored
  STOP_WORDS: {string:boolean}
  CLOSEST: integer
  NOTE_LIMIT: integer
end

--- `found` in the order a reader wants them: an example named for the
--- symbol (`Example.read` for [`Fs.read`]) first, then the one that
--- calls it most, then the one that calls it soonest, then the shorter,
--- then by file and line. An example is attached to a symbol by what
--- it calls, so one built around `truncate` also matches [`Fs.read`] and
--- must not lead its page.
function Search.ranked_examples(found: {Example}, symbol: string): {Example}
  local last = symbol:match("([%w_]+)$") or symbol
  local keys: mut {Example: Rank} = {}
  for _, ex in ipairs(found) do
    local body = example_body(ex.source)
    local calls, first = calls_of(body, symbol)
    keys[ex] = { named = if ex.name == last then 0 else 1 end, calls = -calls, first = first, size = #body }
  end
  local out: mut {Example} = {}
  for _, ex in ipairs(found) do out[#out + 1] = ex end
  table.sort(out, function(a: Example, b: Example): boolean
    local ka = assert(keys[a], "every example sorted was ranked")
    local kb = assert(keys[b], "every example sorted was ranked")
    if ka.named ~= kb.named then return ka.named < kb.named end
    if ka.calls ~= kb.calls then return ka.calls < kb.calls end
    if ka.first ~= kb.first then return ka.first < kb.first end
    if ka.size ~= kb.size then return ka.size < kb.size end
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
--- never one, whatever database is read, as in [`Doc.index`], so a bare
--- name means what a user of a library means by it.
function Search.modules_ending(db: Sqlite.Handle, query: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE " .. symbols.module_ending_where("d") ..
      " ORDER BY d.module LIKE 'cosmic.%', d.module, d.id",
    { text(query) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- What a lookup of its name finds for a module with no documentation
--- row of its own: the symbol it hands out, which carries the module's
--- comment (a `cmd/<name>/main.tl` that returns a function has no
--- record to hold it). `module` is the module's whole name.
function Search.module_symbol(db: Sqlite.Handle, public: boolean,
                              module: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.exported DESC, d.id LIMIT 1",
    { text(module) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- The rows named `query` exactly: a symbol as declared ([`Fs.read`]), a
--- symbol's last name alone (`read`, matching every `X.read` and
--- `X:read`), or a module's own row ([`cosmic.fs`]).
function Search.named(db: Sqlite.Handle, public: boolean, query: string): {Entry}?, string
  -- TODO: a function a record declares as a field and its file defines has two rows of one source symbol (`years` and
  -- `RunDb.years`), so `cosmic docs` shows it twice. Fix: the build writes one row for it, and this
  -- returns it once, as a link to it resolves once; nothing blocks it.
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE " .. symbols.named_where("d") ..
      " AND " .. symbols.shown_in(db, "d", public) .. " ORDER BY d.module, d.id",
    { text(query) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- The rows named exactly by one of `names` (`d.symbol IN (...)`), and
--- the own row of each module one of them names in full, in one query.
--- Unlike `named`, it matches only the symbol as declared, never a last
--- name: a caller passing several names already knows what each one is.
function Search.named_all(db: Sqlite.Handle, public: boolean,
                          names: {string}): {Entry}?, string
  local placeholders: mut {string} = {}
  local args: mut {Sqlite.Value} = {}
  for index, name in ipairs(names) do
    placeholders[index] = "?" .. tostring(index)
    args[index] = text(name)
  end
  local listed = table.concat(placeholders, ", ")
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE (d.symbol IN (" .. listed .. ") OR (d.symbol = '' AND d.module IN (" ..
      listed .. "))) AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.module, d.id",
    args)
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- The symbols a module offers, for the listing under a module's own
--- documentation: everything its returned value reaches, and every type
--- it declares, since those are the names its signatures are written
--- in. A private helper function is left out -- a reader scanning the
--- module wants what they can call -- but `cosmic docs <name>` still
--- finds it.
--- A `local` declaration is left out too, whichever source is read: it
--- is not the module's surface, though `cosmic docs <name>` finds it in
--- a source that covers the module's internals.
--- A call the module's own record declares as a field of function type
--- (`lstat: function(...)` in [`cosmic.sys`]'s syscall table) is listed
--- too, as a function; a record's plain data field, and any field of a
--- nested record (its symbol is dotted), is not. Nor is a field typed
--- `function` without parentheses, a generic one (`function<T>(...)`),
--- or an alias of a function type: only the literal `name: function(`
--- form is. A `metamethod` of the module's own record (`__call` of a
--- module that is itself callable) is listed too, by its signature; one
--- of a nested record (its `__close`) is that record's, as its other
--- fields are.
function Search.declared_in(db: Sqlite.Handle, public: boolean, module: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 " ..
      "AND d.symbol <> '' AND (d.kind NOT IN ('field', 'value', 'metamethod') OR " ..
      "(d.kind = 'metamethod' AND d.symbol NOT LIKE '%.%') OR " ..
      "(d.kind = 'field' AND d.symbol NOT LIKE '%.%' AND " ..
      "d.signature GLOB d.symbol || ': function(*')) AND " ..
      "(d.exported = 1 OR d.kind NOT IN ('function', 'method')) AND " ..
      "NOT " .. symbols.local_declaration("d") .. " AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.id",
    { text(module) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- The fields of every record and interface in `module`, and the values
--- of every enum, in declaration order: what a page lists under each.
--- A field of a `local` record, or one named `_...`, is left out of a
--- public source, as it is from every other view of it.
function Search.members_of(db: Sqlite.Handle, public: boolean,
                           module: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
      "d.kind IN ('field', 'value') AND " .. symbols.shown_in(db, "d", public) ..
      " ORDER BY d.id",
    { text(module) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- Every module's own documentation row, and every documented record
--- a module declares at its top: one of them says what a module is for
--- when its opening comment sits on it rather than above it.
function Search.modules_of(db: Sqlite.Handle, public: boolean): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE (d.symbol = '' OR " ..
      "(d.kind = 'record' AND d.symbol NOT LIKE '%.%' AND d.text <> '')) AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.module, d.line",
    {})
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
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

--- Words a search never requires: they join the words that name
--- something and match nearly every sentence of prose.
local STOP_WORDS: {string:boolean} = {
  a = true, an = true, the = true, to = true, of = true, ["for"] = true,
  ["in"] = true, on = true, with = true, ["and"] = true, ["or"] = true,
  from = true, how = true, ["do"] = true,
}
Search.STOP_WORDS = STOP_WORDS

--- The words of `query` a search matches. A word of one letter is left
--- out when there are others: it is almost always a flag ("cp -r",
--- "rm -f") that no documentation spells alone, and requiring it would
--- find nothing. A stop word is left out the same way, so "read from the
--- file" searches for "read" and "file".
function Search.query_words(query: string): {string}
  local words: mut {string} = {}
  local short: mut {string} = {}
  local stop: mut {string} = {}
  for word in query:gmatch("[%w_]+") do
    if STOP_WORDS[word:lower()] == true then
      stop[#stop + 1] = word
    elseif #word > 1 then
      words[#words + 1] = word
    else
      short[#short + 1] = word
    end
  end
  -- A query of nothing else ("x", "the") still searches for what it has.
  if #words > 0 then
    return words
  end
  return if #short > 0 then short else stop end
end
local query_words = Search.query_words

--- The first word of `query` a search keeps (see [`query_words`]).
local function lead_word(query: string): string
  return query_words(query)[1] or ""
end

--- `query`'s words as an FTS5 query every one of them must match, each
--- quoted so it reads as a literal rather than as FTS5 syntax.
function Search.fts_query(query: string): string
  local quoted: mut {string} = {}
  for _, word in ipairs(query_words(query)) do
    quoted[#quoted + 1] = '"' .. word .. '"'
  end
  return table.concat(quoted, " ")
end
local fts_query = Search.fts_query

--- The functions outside [`cosmic.sys`] whose documentation spells
--- `name` as code: what a reader who looked up a raw binding
--- ("unlink", "getpid") most likely wanted instead.
function Search.stand_ins(db: Sqlite.Handle, public: boolean,
                          name: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.module <> 'cosmic.sys' " ..
      "AND d.kind IN ('function', 'method') AND d.exported = 1 AND lower(d.text) GLOB ?1 AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.module, d.id LIMIT 20",
    { text(spelled_as_code(name)) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- For a qualified name that names nothing (`Proc.which`), what its
--- qualifier offers: the members whose documentation carries the last
--- name's words, best match first, or, when none does, every exported
--- function it declares. A reader who guessed the module right but the
--- name wrong sees the name they wanted among its neighbours, rather
--- than whatever elsewhere happens to use the word.
function Search.scoped(db: Sqlite.Handle, public: boolean, qualifier: string,
                       name: string): {Entry}?, string
  -- The build keeps a member's own name in `symbol` (`find`) and the
  -- name it was written as in `source_symbol` ([`Proc.find`]).
  local member = qualifier .. "[.:]*"
  local fts = fts_query(name)
  if fts ~= "" then
    local rows, trouble = db:rows(
      "SELECT " .. columns .. " FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
        "WHERE docs_fts MATCH ?1 AND d.source_symbol GLOB ?4 AND d.exported = 1 AND " ..
        symbols.shown_in(db, "d", public) ..
        " ORDER BY " .. STANDS_IN_SQL .. " DESC, bm25(docs_fts), d.module, d.id LIMIT 20",
      { text(fts), text(spelled_as_code(lead_word(name))), text(lead_word(name):lower()),
        text(member) })
    if rows == nil then
      return nil, tostring(trouble)
    end
    if #rows > 0 then
      return entries_of(rows), ""
    end
  end
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.source_symbol GLOB ?1 " ..
      "AND d.kind IN ('function', 'method') AND d.exported = 1 AND " ..
      symbols.shown_in(db, "d", public) .. " ORDER BY d.module, d.id",
    { text(member) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- How the columns of `docs_fts` count toward relevance: a word in a
--- symbol's name says far more than one in its signature, and that more
--- than one somewhere in its prose, which is the longest by far.
local DOCS_WEIGHTS = "10.0, 3.0, 1.0"

--- The most rows a search offers, and the most it offers of what
--- carries only some of the words.
local LIMIT = 20

local CLOSEST = 5
Search.CLOSEST = CLOSEST

--- The most guide sections a search offers, and how many rows of
--- documentation come before them.
local SECTIONS = 3

local AHEAD = 3

--- How many of `count` words a row must carry to be offered when none
--- carries all: half of them, and at least two, so a query with one word
--- nothing knows never finds the rows of the other.
local function bar(count: integer): integer
  return math.max(2, (count + 1) // 2)
end

--- The rows whose symbol, signature or documentation carries at least
--- `bar(#words)` of `words`, at most `CLOSEST` of them, those carrying
--- more of the words first and, among equals, the better match by
--- relevance. Each row's last field is its id.
local function partly_searched(db: Sqlite.Handle, public: boolean,
                               words: {string}): Sqlite.Rows?, string
  local matched: mut {integer:integer} = {}
  local score: mut {integer:number} = {}
  for _, word in ipairs(words) do
    local rows, trouble = db:rows(
      "SELECT d.id, bm25(docs_fts, " .. DOCS_WEIGHTS .. ") FROM docs_fts " ..
        "JOIN docs d ON d.id = docs_fts.rowid WHERE docs_fts MATCH ?1 AND " ..
        symbols.shown_in(db, "d", public), { text('"' .. word .. '"') })
    if rows == nil then
      return nil, tostring(trouble)
    end
    for _, row in ipairs(rows) do
      local id = row:integer(1)
      matched[id] = (matched[id] or 0) + 1
      score[id] = (score[id] or 0) + row:number(2)
    end
  end
  local ids: mut {integer} = {}
  for id, count in pairs(matched) do
    if count >= bar(#words) then ids[#ids + 1] = id end
  end
  table.sort(ids, function(x: integer, y: integer): boolean
    -- Every id came from `matched`, and `score` is set wherever it is.
    local matched_x = assert(matched[x], "every id was counted")
    local matched_y = assert(matched[y], "every id was counted")
    if matched_x ~= matched_y then return matched_x > matched_y end
    local score_x = assert(score[x], "every counted id was scored")
    local score_y = assert(score[y], "every counted id was scored")
    if score_x ~= score_y then return score_x < score_y end
    return x < y
  end)
  while #ids > CLOSEST do ids[#ids] = nil end
  if #ids == 0 then
    return {}, ""
  end
  -- The ids are integers this function read, so they are safe to spell out.
  local rows, trouble = db:rows(
    "SELECT " .. columns .. ", d.id FROM docs d WHERE d.id IN (" ..
      table.concat(ids, ",") .. ")", {})
  if rows == nil then
    return nil, tostring(trouble)
  end
  local by_id: mut {integer:Sqlite.Row} = {}
  for _, row in ipairs(rows) do
    by_id[row:integer(row:count())] = row
  end
  local out: mut {Sqlite.Row} = {}
  for _, id in ipairs(ids) do
    local row = by_id[id]
    if row ~= nil then out[#out + 1] = row end
  end
  return out, ""
end

--- `word` in lowercase without an ending that makes it a longer form of
--- a name: "reading" is "read", "files" is "file". The index stems words
--- exactly; this only lets a member named `read` count as named by
--- "reading".
local function plain(word: string): string
  local lower = word:lower()
  for _, ending in ipairs({ "ing", "ed", "es", "s" }) do
    if #lower >= #ending + 3 and String.ends_with(lower, ending) then
      return lower:sub(1, -#ending - 1)
    end
  end
  return lower
end

--- The rows whose symbol, signature or documentation carries every
--- word of `query`, best match first: those that spell its first word
--- as code, where it is not a parameter of theirs, then by relevance,
--- weighing a word in the name above one in the prose.
local function searched_docs(db: Sqlite.Handle, public: boolean,
                             query: string): {Entry}?, string
  local lead = lead_word(query)
  local words = query_words(query)
  -- What a function stands in for is a question about one word: with
  -- several, the words together say more than the first does.
  local stands_in = ""
  local binds = { text(fts_query(query)) }
  if #words == 1 then
    stands_in = STANDS_IN_SQL .. " DESC, "
    local as_code = text(spelled_as_code(lead))
    local lowered = text(lead:lower())
    binds[#binds + 1] = as_code
    binds[#binds + 1] = lowered
  end
  -- A member named for one of the words comes before any that only
  -- carries it: [`Fs.read`] before `Unveil.reads` for "read a file".
  local hits: mut {string} = {}
  for _, word in ipairs(words) do
    for _, form in ipairs({ word:lower(), plain(word) }) do
      binds[#binds + 1] = text(form)
      hits[#hits + 1] = "?" .. tostring(#binds)
    end
  end
  -- Then a comment that says the words together, as typed, and then a
  -- member before a field: a field is a detail of a record, which is
  -- likelier to be what was sought. A module's row stands on its own
  -- relevance, as any row does: a module whose prose says the words
  -- comes before a member that only has them in a parameter's type.
  -- A row whose own name or prose carries every word comes before one
  -- that carries them only in a signature, where a handle's parameter
  -- (`db: Sqlite.Handle`) is the whole match: a module about databases
  -- before each function that takes one.
  binds[#binds + 1] = text("{symbol text}: (" .. fts_query(query) .. ")")
  local said = "d.id IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?" .. tostring(#binds) .. ") DESC, "
  -- With one word, which names a topic, the module about it comes before
  -- a member that says it in passing; with several, which ask for
  -- something to do, the member does.
  -- It leads only when the word is in the module's name or the first
  -- paragraph of its documentation, which says what the module is for: a
  -- long module that mentions the word somewhere is not about it.
  if #words == 1 then
    local like = text("%" .. lead:lower() .. "%")
    binds[#binds + 1] = like
    local at = "?" .. tostring(#binds)
    said = said .. "(d.symbol = '' AND (lower(d.module) LIKE " .. at ..
      " OR lower(substr(d.text, 1, instr(d.text || char(10) || char(10), char(10) || char(10)) - 1)) LIKE " ..
      at .. ")) DESC, "
  end
  local phrase = ""
  if #words > 1 then
    local typed: mut {string} = {}
    for word in query:gmatch("[%w_]+") do typed[#typed + 1] = word:lower() end
    binds[#binds + 1] = text(table.concat(typed, " "))
    phrase = "instr(replace(lower(d.text), char(10), ' '), ?" .. tostring(#binds) .. ") > 0 DESC, "
  end
  local rows, trouble = db:rows(
    "SELECT " .. columns .. ", d.id FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
      "WHERE docs_fts MATCH ?1 AND " .. symbols.shown_in(db, "d", public) ..
      " ORDER BY " .. stands_in .. "lower(d.symbol) IN (" .. table.concat(hits, ", ") ..
      ") DESC, " .. said .. phrase .. "d.kind = 'field', bm25(docs_fts, " .. DOCS_WEIGHTS ..
      "), d.module, d.id LIMIT " .. tostring(LIMIT),
    binds)
  if rows == nil then
    return nil, tostring(trouble)
  end
  return entries_of(rows), ""
end

--- The rows carrying some words of `query` when none carries them all,
--- at most `CLOSEST`; nothing when it has fewer than two words to carry.
function Search.closest(db: Sqlite.Handle, public: boolean,
                        query: string): {Entry}?, string
  local words = query_words(query)
  if #words < 2 then
    return {}, ""
  end
  local rows, trouble = partly_searched(db, public, words)
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows), ""
end

--- Every worked example whose own name, comment, or checked source carries
--- every word of `query`. An example is returned as itself, not as one of
--- the symbols it calls: its source cannot say which of several calls is
--- its subject.
local function searched_examples(db: Sqlite.Handle, public: boolean, fts: string): {Entry}?, string
  local rows, trouble = db:rows(
    "SELECT e.module, e.name, e.text, e.file, e.line, e.source FROM examples_fts " ..
      "JOIN examples e ON e.id = examples_fts.rowid " ..
      "WHERE examples_fts MATCH ?1 AND " .. symbols.public_only("e.module", public) ..
      -- Names and prose describe intent; source often mentions incidental APIs.
      " ORDER BY bm25(examples_fts, 3.0, 2.0, 0.2), e.module, e.file, e.line LIMIT 20",
    { text(fts) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {Entry} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row:text(1), symbol = "Example." .. row:text(2),
      source_symbol = "Example." .. row:text(2), exported = true, kind = "example",
      signature = "", text = row:text(3),
      file = row:text(4), line = row:integer(5),
      uses = 0, links = 0, examples = 0,
      related = { { name = row:text(2), text = row:text(3), file = row:text(4),
        line = row:integer(5), source = row:text(6) } },
    }
  end
  return out, ""
end

--- Raises where `db` is a test's pure store, which leaves the documentation out: every query would find
--- nothing, or fail on a table it lacks, and a test would pass on the first.
function Search.refuse_pure(db: Sqlite.Handle)
  local pure, _ = db:rows("SELECT 1 FROM meta WHERE key = 'pure_store'")
  if pure ~= nil and #pure > 0 then
    error("the `docs` of the store is withheld, so no documentation can be read from it: a test that looks " ..
        "documentation up declares `Test.policy { store_text = true }`", 0)
  end
end

--- Whether `db` holds the shipped tables at all: a database built
--- before they existed lacks them.
function Search.has_docs(db: Sqlite.Handle): boolean?, string
  local rows, trouble = db:rows(
    "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'docs'")
  if rows == nil then return nil, tostring(trouble) end
  return #rows > 0, ""
end
local has_docs = Search.has_docs

-- Doc.documented, its failure in words.
function Search.documented_text(db: Sqlite.Handle): boolean?, string
  return has_docs(db)
end

--- Whether `db` holds `links`: a database built before it existed has
--- no links to read.
function Search.has_links(db: Sqlite.Handle): boolean?, string
  local rows, trouble = db:rows(
    "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'links'")
  if rows == nil then return nil, tostring(trouble) end
  return #rows > 0, ""
end

--- The text of `word` a section is searched for: its stem, so "narrowing"
--- finds "narrows", but a short word whole.
local function stem(word: string): string
  if #word >= 4 then
    return plain(word)
  end
  return word:lower()
end

--- How many times `word` (see [`stem`]) occurs in the lowercase `written`:
--- anywhere when `whole` is false, else only as a word of its own, so "db"
--- is not found in "sandbox" and "sort" not in "sorted".
local function occurrences(written: string, word: string, whole: boolean): integer
  local pattern = word:gsub("%p", "%%%0")
  if whole or #word < 4 then
    pattern = "%f[%w_]" .. pattern .. "%f[^%w_]"
  end
  local _, count = written:gsub(pattern, "")
  return count
end

local function sections_of(guide: string): {Section}
  local out: mut {Section} = {}
  local heading = ""
  local lines: mut {string} = {}
  local started = false
  local fence = false
  -- A heading said again takes `-1`, `-2` after its anchor, as GitHub does.
  local made: mut {string: integer} = {}
  --- Adds the section being read, once it has a heading.
  local function close()
    if started then
      local base = heading:lower():gsub("[^%w_%- ]", ""):gsub(" ", "-")
      local slug = base
      local times = made[base] or 0
      if times > 0 then
        slug = base .. "-" .. tostring(times)
      end
      made[base] = times + 1
      local section: Section = { heading = heading, anchor = slug,
        body = String.trim(table.concat(lines, "\n")) }
      out[#out + 1] = section
    end
    lines = {}
  end
  for line in String.lines(guide) do
    if line:match("^%s*[`~][`~][`~]") ~= nil then fence = not fence end
    local title = if fence then nil else line:match("^##%s+(.-)%s*$") end
    if title ~= nil then
      close()
      heading = title
      started = true
    else
      lines[#lines + 1] = line
    end
  end
  close()
  return out
end

--- The sections of the guides whose text carries every word of `query`
--- in its heading (as its stem, so "narrowing" finds "narrowing a
--- value") or as a word of its own in the text, each as an entry of
--- kind `section` that names the guide and the heading, best first:
--- those with a word in the heading, then by how often the words occur.
--- Each guide is split here rather than indexed, since the index holds
--- one row for a whole page, which its length buries and a hit shows
--- only the opening of.
local function guide_sections(db: Sqlite.Handle, public: boolean, query: string): {Entry}?, string
  local words: mut {string} = {}
  for _, word in ipairs(query_words(query)) do
    words[#words + 1] = stem(word)
  end
  local guides = "d.module GLOB 'doc.guides.*'"
  if public then
    guides = symbols.guide_module("d.module")
  end
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE d.symbol = '' AND d.kind = 'module' AND " ..
      guides .. " ORDER BY d.module")
  if rows == nil then
    return nil, tostring(trouble)
  end
  local scored: mut {Scored} = {}
  for _, guide in ipairs(entries_of(rows)) do
    for _, section in ipairs(sections_of(guide.text)) do
      local titled = section.heading:lower()
      local said = section.body:lower()
      local score, headed = 0, false
      for _, word in ipairs(words) do
        local in_heading = occurrences(titled, word, false) > 0
        local count = occurrences(said, word, true)
        if not in_heading and count == 0 then
          score = -1
          break
        end
        headed = headed or in_heading
        score = score + math.min(count, 5)
      end
      if score >= 0 then
        if headed then score = score + 100 end
        local at = guide.module .. "#" .. section.anchor
        scored[#scored + 1] = { entry = { module = guide.module, symbol = "#" .. section.anchor,
          source_symbol = at, exported = true, kind = "section", signature = "## " .. section.heading,
          text = section.body, file = guide.file, line = 0, uses = 0, links = 0, examples = 0,
          related = {} }, score = score }
      end
    end
  end
  table.sort(scored, function(a: Scored, b: Scored): boolean
    if a.score ~= b.score then return a.score > b.score end
    return a.entry.source_symbol < b.entry.source_symbol
  end)
  local out: mut {Entry} = {}
  for index, item in ipairs(scored) do
    if index > SECTIONS then break end
    out[index] = item.entry
  end
  return out, ""
end

--- [`searched_docs`] and [`searched_examples`] together. Each example is kept once
--- as itself; documentation rows retain their real symbol identity.
function Search.searched(db: Sqlite.Handle, public: boolean, query: string): {Entry}?, string
  local fts = fts_query(query)
  if fts == "" then
    return {}, ""
  end
  local from_docs, docs_trouble = searched_docs(db, public, query)
  if from_docs == nil then
    return nil, docs_trouble
  end
  local from_examples, examples_trouble = searched_examples(db, public, fts)
  if from_examples == nil then
    return nil, examples_trouble
  end
  local from_guides, guides_trouble = guide_sections(db, public, query)
  if from_guides == nil then
    return nil, guides_trouble
  end
  -- A section shows the part of its guide that matches, so the guide's
  -- own row, which shows only its opening, is left out. The sections
  -- come after the first few rows, which keeps the member a reader
  -- named ahead of a guide that merely says the words.
  local sectioned: mut {string: boolean} = {}
  for _, entry in ipairs(from_guides) do
    sectioned[entry.module] = true
  end
  local out: mut {Entry} = {}
  local kept = 0
  local offered = false
  local function offer_sections()
    if not offered and (kept == AHEAD or kept == #from_docs) then
      offered = true
      for _, entry in ipairs(from_guides) do out[#out + 1] = entry end
    end
  end
  offer_sections()
  for _, entry in ipairs(from_docs) do
    if not (entry.symbol == "" and sectioned[entry.module] == true) then
      out[#out + 1] = entry
    end
    kept = kept + 1
    offer_sections()
  end
  for _, entry in ipairs(from_examples) do out[#out + 1] = entry end
  return out, ""
end

--- The first sentence of `documented`'s first paragraph, on one line:
--- up to the first `.`, `?` or `!` that a space or the end follows,
--- outside backticks and not closing "e.g" or "i.e".
function Search.first_sentence(documented: string): string
  -- The first paragraph is cut out before its links are read: a module's whole text costs many times as much, and
  -- what is past the paragraph is never shown.
  local whole = String.trim(documented)
  local head = String.trim(link_text.unlinked(whole:match("^(.-)\n%s*\n") or whole))
  local paragraph = (head:match("^(.-)\n%s*\n") or head):gsub("%s+", " ")
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
local first_sentence = Search.first_sentence

--- `note` cut to `limit` bytes at a word, marked as cut.
function Search.clipped(note: string, limit: integer): string
  if #note <= limit then
    return note
  end
  local cut = note:sub(1, limit):match("^(.*%S)%s+%S*$") or note:sub(1, limit)
  return (cut:gsub("[,;:%-]+$", "")) .. "…"
end
local clipped = Search.clipped

--- How long a field's note runs on a module's page, where a record's
--- fields are a glance; its own page keeps the whole sentence.
local NOTE_LIMIT <const> = 100
Search.NOTE_LIMIT = NOTE_LIMIT

--- Whether a declared symbol is a call: a function, method or
--- metamethod, or a function-typed field.
function Search.is_call(item: Entry): boolean
  return item.kind == "function" or item.kind == "method" or item.kind == "metamethod" or
    (item.kind == "field" and item.signature:match("^[%w_]+: function%(") ~= nil)
end
local is_call = Search.is_call

--- One declared symbol as a module's listing shows it: a function,
--- method or metamethod by its signature (a function-typed field as
--- `function` and its name, then the signature's parameters and
--- results) and the first sentence of what it says, anything else (a
--- record's signature spans lines, and its fields follow it) by kind
--- and name, then its uses and examples.
function Search.listed(item: Entry): string
  local marks: mut {string} = {}
  if item.uses > 0 then
    marks[#marks + 1] = String.counted(item.uses, "use")
  end
  if item.links > 0 then
    marks[#marks + 1] = String.counted(item.links, "link")
  end
  if item.examples > 0 then
    marks[#marks + 1] = String.counted(item.examples, "example")
  end
  local shown = item.kind .. " " .. item.source_symbol
  if (item.kind == "function" or item.kind == "method" or
      item.kind == "metamethod") and
      item.signature ~= "" and not item.signature:find("\n", 1, true) then
    shown = item.signature
  elseif item.kind == "field" then
    local rest = item.signature:match("^[%w_]+: function(%(.*)$")
    if rest ~= nil then
      shown = "function " .. item.source_symbol .. rest
    end
  end
  local note = if is_call(item) then clipped(first_sentence(item.text), NOTE_LIMIT) else "" end
  return shown .. (if note ~= "" then " -- " .. note else "" end) ..
    (if #marks > 0 then "  (" .. table.concat(marks, ", ") .. ")" else "" end)
end

--- The example an entry of kind "example" stands for.
function Search.example_of(entry: Entry): Example
  return (assert(entry.related[1], "an entry of kind example carries its example"))
end
local example_of = Search.example_of

--- An entry's first line as [`Doc.render`] prints it: what it is and
--- where.
function Search.heading(entry: Entry): string
  if entry.kind == "example" then
    local ex = example_of(entry)
    return entry.module .. " example " .. ex.name .. " (" .. ex.file .. ":" .. tostring(ex.line) .. ")"
  end
  if entry.kind == "removed" then
    return entry.module .. " " .. entry.source_symbol .. " (removed)"
  end
  if entry.kind == "code" then
    return entry.module .. " " .. entry.symbol .. " (" .. entry.file .. ")"
  end
  if entry.kind == "section" then
    return entry.source_symbol .. " (" .. entry.file .. ")"
  end
  if entry.symbol == "" then
    return entry.module .. " (" .. entry.file .. ")"
  end
  local at = if entry.line > 0 then ":" .. tostring(entry.line) else "" end
  return entry.module .. " " .. entry.source_symbol .. " (" .. entry.file .. at .. ")"
end

return Search
