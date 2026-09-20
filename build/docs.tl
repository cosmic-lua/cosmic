--- What the database says about a symbol: `cosmic docs` and `cosmic
--- uses`, read off the shipped `docs` and `uses` tables of every
--- database the store searches, and of a project's own `o/cosmic.db`
--- when the working directory holds one.
---
--- A query is a symbol first -- `Fs.read`, `read`, `cosmic.fs` -- and
--- words to search the documentation for when no symbol is called that.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")

local record docs
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
    use_counts: {string: integer}
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

  --- One row of `uses`.
  record Use
    module: string
    symbol: string
    from_module: string
    from_file: string
    line: integer
  end
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- A symbol as an `examples_fts` phrase: `Fs.read` and `Fs:read` alike
--- become `"Fs read"`, matching adjacent tokens in that order -- what
--- an example's own source reads as, tokenized, when it genuinely
--- calls the symbol it demonstrates. Looser than an exact join, and
--- deliberately so: this is what lets one example answer for every
--- symbol its code actually mentions, not only the one whose name it
--- happens to share.
---
--- On its own this over-matches: FTS5's tokenizer splits on `_`, so
--- `Fs.hex` and `Fs.hex_sha256` share the same first two tokens, and
--- `"Fs hex"` matches an example that only ever calls the second one.
--- `example_boundary` is the other half of every query this builds --
--- a phrase match narrows to candidates cheaply, the boundary check
--- on those few rows says whether the symbol is really there, whole.
local function example_phrase(symbol: string): string
  return '"' .. symbol:gsub("[%.:]", " ") .. '"'
end

--- A GLOB pattern matching `symbol` followed by a character that could
--- not continue the same identifier -- so `Fs.hex` matches `Fs.hex(`
--- but not `Fs.hex_sha256`. Checked against an example's own text and
--- source, space-joined so a match flush against the end of either
--- still has a boundary to land on.
local function example_boundary(symbol: string): string
  return "*" .. symbol .. "[^A-Za-z0-9_]*"
end

local EXAMPLE_BOUNDARY_SQL =
  "(e.text || ' ' || e.source || ' ') GLOB " ..
  "('*' || d.source_symbol || '[^A-Za-z0-9_]*')"

--- Whether a module is the public standard library's own: what a
--- public source answers for.
local function is_public_module(module: string): boolean
  return module:sub(1, 7) == "cosmic." and module:sub(1, 16) ~= "cosmic.internal." and
    module:sub(-5) ~= "_test"
end

--- The rows a public source answers with, as a condition on the
--- module `column` names; `1` when the source is not public.
local function public_only(column: string, public: boolean): string
  if not public then
    return "1"
  end
  return "(" .. column .. " LIKE 'cosmic.%' AND " .. column ..
    " NOT LIKE 'cosmic.internal.%' AND substr(" .. column .. ", -5) <> '_test')"
end

local columns =
  "d.module, d.symbol, d.source_symbol, d.exported, d.kind, d.signature, " ..
  "d.text, d.file, d.line, " ..
  "(SELECT count(*) FROM uses u WHERE u.module = d.module AND u.symbol = d.symbol), " ..
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
    "AND " .. public_only("e.module", public) .. " " ..
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
    "SELECT " .. columns .. " FROM docs d WHERE (d.symbol = ?1 " ..
    "OR d.source_symbol = ?1 " ..
    "OR substr(d.symbol, -length(?1) - 1) = '.' || ?1 " ..
    "OR substr(d.symbol, -length(?1) - 1) = ':' || ?1 " ..
    "OR (d.symbol = '' AND d.module = ?1)) AND " ..
    public_only("d.module", public) .. " ORDER BY d.module, d.id",
    { text(query) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- Every symbol a module declares at its top level, for the listing
--- under a module's own documentation.
local function declared_in(db: Sqlite.Handle, public: boolean, module: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 " ..
    "AND d.symbol <> '' AND d.kind NOT IN ('field', 'value') AND " ..
    public_only("d.module", public) .. " ORDER BY d.id",
    { text(module) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- `query`'s words as an FTS5 query every one of them must match, each
--- quoted so it reads as a literal rather than as FTS5 syntax.
local function fts_query(query: string): string
  local words: {string} = {}
  for word in query:gmatch("[%w_]+") do
    words[#words + 1] = '"' .. word .. '"'
  end
  return table.concat(words, " ")
end

--- The rows whose symbol, signature or documentation carries every
--- word of `query`, best match first.
local function searched_docs(db: Sqlite.Handle, public: boolean, fts: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
    "WHERE docs_fts MATCH ?1 AND " .. public_only("d.module", public) ..
    " ORDER BY bm25(docs_fts), d.module, d.id LIMIT 20",
    { text(fts) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- The module row of every module whose worked example carries every
--- word of `query`, best match first, for a module `searched_docs`
--- did not already find on a doc comment -- a `cosmic docs "sha256
--- hex"` that only an example's own code mentions still finds
--- `cosmic.fs`, whichever of its symbols the example turns out to be
--- for; the module's own listing shows each symbol's own example
--- count (`examples_for`, by name this time) to narrow from there.
local function searched_examples(db: Sqlite.Handle, public: boolean, fts: string): {docs.Entry} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. columns .. " FROM examples_fts " ..
    "JOIN examples e ON e.id = examples_fts.rowid " ..
    "JOIN docs d ON d.module = e.module AND d.symbol = '' " ..
    "WHERE examples_fts MATCH ?1 AND " .. public_only("d.module", public) ..
    " ORDER BY bm25(examples_fts), d.module, d.id LIMIT 20",
    { text(fts) })
  if rows == nil then
    return nil, trouble
  end
  return entries_of(rows)
end

--- `searched_docs` and `searched_examples` together, a symbol kept
--- once: a doc-comment match outranks an example-only one, since
--- `searched_docs`'s own rows come first and a later duplicate is
--- dropped.
local function searched(db: Sqlite.Handle, public: boolean, query: string): {docs.Entry} | nil, string
  local fts = fts_query(query)
  if fts == "" then
    return {}
  end
  local from_docs, docs_trouble = searched_docs(db, public, fts)
  if from_docs == nil then
    return nil, docs_trouble
  end
  local from_examples, examples_trouble = searched_examples(db, public, fts)
  if from_examples == nil then
    return nil, examples_trouble
  end
  local seen: {string: boolean} = {}
  local out: {docs.Entry} = {}
  for _, group in ipairs({ from_docs, from_examples }) do
    for _, entry in ipairs(group) do
      local key = entry.module .. "\n" .. entry.symbol
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = entry
      end
    end
  end
  return out
end

--- The places that refer to `symbol` as declared, or to any symbol
--- whose last name is `symbol`.
local function uses_of(db: Sqlite.Handle, public: boolean, query: string): {docs.Use} | nil, string
  local canonical = query:match("([^%.:]+)$") or query
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, from_module, from_file, line FROM uses " ..
    "WHERE (symbol = ?1 OR substr(symbol, -length(?1) - 1) = '.' || ?1 " ..
    "OR substr(symbol, -length(?1) - 1) = ':' || ?1 OR symbol = ?2) AND " ..
    public_only("module", public) .. " AND " .. public_only("from_module", public) ..
    " ORDER BY module, symbol, from_file, line", { text(query), text(canonical) })
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

--- Whether `db` holds the shipped tables at all: a database built
--- before they existed answers no query here.
local function has_docs(db: Sqlite.Handle): boolean
  local rows = Sqlite.text_rows(db,
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'docs'")
  return rows ~= nil and #rows > 0
end

--- The databases a lookup reads, in order: the working directory's own
--- `o/cosmic.db` when there is one, then every database the store
--- searches. A module found in an earlier one hides the same module in
--- a later one, so a project's build answers for its own modules and
--- the binary answers for the standard library.
function docs.databases(): {Sqlite.Handle}, {boolean}
  local out: {Sqlite.Handle} = {}
  local public: {boolean} = {}
  if Fs.exists("o/cosmic.db") then
    local own = Sqlite.open("o/cosmic.db", false)
    if own ~= nil then
      out[#out + 1] = own
      public[#out] = false
    end
  end
  -- Outside cosmic's own tree the store's databases are public sources:
  -- a project sees its own code and the standard library, never the
  -- build that made the binary.
  local root = Fs.absolute(".")
  local outside = root == nil or not importer.is_own_tree(root)
  for _, db in ipairs(Store.databases()) do
    out[#out + 1] = db
    public[#out] = outside
  end
  return out, public
end

--- One lookup over `databases`, in order, with a module answered by an
--- earlier database hiding it in every later one.
--- @param look what to read from each database
local function across<T>(view: docs.View,
                         look: function(Sqlite.Handle, boolean): {T} | nil, string,
                         module_of: function(T): string): {T} | nil, string
  local out: {T} = {}
  for index, db in ipairs(view.databases) do
    if has_docs(db) then
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

local function effective_counts(view: docs.View, entries: {docs.Entry})
  for _, entry in ipairs(entries) do
    entry.uses = view.use_counts[use_key(entry.module, entry.symbol)] or 0
  end
end

--- Resolves module ownership once for a docs command or direct caller.
--- Membership comes from `modules`, even when the owning database has
--- no documentation for that module.
--- @param public which databases, by index, are public sources
function docs.view(databases: {Sqlite.Handle}, public?: {boolean}): docs.View | nil, string
  local scope: {integer: boolean} = {}
  for index, flag in ipairs(public or {}) do
    scope[index] = flag
  end
  local owners: {string: integer} = {}
  for index, db in ipairs(databases) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT path FROM modules ORDER BY path")
    if rows == nil then
      return nil, trouble
    end
    for _, row in ipairs(rows) do
      if owners[row[1]] == nil then
        owners[row[1]] = index
      end
    end
  end
  local use_counts: {string: integer} = {}
  local seen: {string: boolean} = {}
  for index, db in ipairs(databases) do
    if has_docs(db) then
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT module, symbol, from_module, from_file, line FROM uses " ..
        "ORDER BY module, symbol, from_module, from_file, line")
      if rows == nil then
        return nil, trouble
      end
      for _, row in ipairs(rows) do
        local counted = not scope[index] or
          (is_public_module(row[1]) and is_public_module(row[3]))
        if counted and owners[row[3]] == index then
          local position = table.concat(row, "\n")
          if not seen[position] then
            seen[position] = true
            local key = use_key(row[1], row[2])
            use_counts[key] = (use_counts[key] or 0) + 1
          end
        end
      end
    end
  end
  return { databases = databases, public = scope, owners = owners,
           use_counts = use_counts }
end

--- What `query` names, across `databases`: its exact matches when it
--- names a symbol or a module, otherwise the documentation that
--- carries all its words.
function docs.lookup(view: docs.View, query: string): {docs.Entry} | nil, string, boolean
  local exact, exact_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return named(db, public, query)
    end, entry_module)
  if exact == nil then
    return nil, exact_trouble, false
  end
  if #exact > 0 then
    effective_counts(view, exact)
    return exact, "", true
  end
  local found, search_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
      return searched(db, public, query)
    end, entry_module)
  if found == nil then
    return nil, search_trouble, false
  end
  effective_counts(view, found)
  return found, "", false
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
function docs.render(view: docs.View, entry: docs.Entry): {string}
  local lines: {string} = {}
  if entry.symbol == "" then
    lines[#lines + 1] = entry.module .. " (" .. entry.file .. ")"
  else
    lines[#lines + 1] = entry.module .. " " .. entry.source_symbol .. " (" ..
      entry.file .. ":" .. entry.line .. ")"
    lines[#lines + 1] = "  " .. entry.signature
  end
  for line in (entry.text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = #line > 0 and "  " .. line or ""
  end
  if entry.symbol == "" then
    local declared = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Entry} | nil, string
        return declared_in(db, public, entry.module)
      end, entry_module)
    if declared ~= nil then
      effective_counts(view, declared)
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
    end
  else
    if entry.uses > 0 then
      lines[#lines + 1] = "  used in " .. entry.uses .. " place" ..
        (entry.uses == 1 and "" or "s") .. "; cosmic uses " .. entry.symbol
    end
    local examples = across(view,
      function(db: Sqlite.Handle, public: boolean): {docs.Example} | nil, string
        return examples_for(db, public, entry.module, entry.source_symbol)
      end, function(_: docs.Example): string return entry.module end)
    if examples ~= nil then
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
  end
  return lines
end

--- `cosmic docs <query>`: prints what the query names and ends in a
--- verdict line; fails when nothing matches.
function docs.run(argv: {integer:string}): integer
  local query = table.concat({ table.unpack(argv, 2) }, " ")
  if query == "" then
    complain("docs: what to look up? a symbol (Fs.read), a module " ..
      "(cosmic.fs), or words to search for")
    return 2
  end
  local handles, public = docs.databases()
  local view, view_trouble = docs.view(handles, public)
  if view == nil then
    complain("docs: " .. view_trouble)
    return 1
  end
  local found, trouble, exact = docs.lookup(view, query)
  if found == nil then
    complain("docs: " .. trouble)
    return 1
  end
  if #found == 0 then
    report("docs: FAIL (nothing named or documented as '" .. query .. "')")
    return 1
  end
  for index, entry in ipairs(found) do
    if index > 1 then
      report("")
    end
    for _, line in ipairs(docs.render(view, entry)) do
      report(line)
    end
  end
  report("")
  report("docs: PASS (" .. #found .. (exact and " named" or " found") ..
    ", " .. #view.databases .. " databases)")
  return 0
end

--- `cosmic uses <symbol>`: every place that refers to the symbol, one
--- `file:line` per line, and a verdict line.
function docs.run_uses(argv: {integer:string}): integer
  local query = argv[2] or ""
  if query == "" then
    complain("uses: which symbol? as declared (Fs.read) or by its last name (read)")
    return 2
  end
  local handles, public = docs.databases()
  local view, view_trouble = docs.view(handles, public)
  if view == nil then
    complain("uses: " .. view_trouble)
    return 1
  end
  local found, trouble = docs.uses(view, query)
  if found == nil then
    complain("uses: " .. trouble)
    return 1
  end
  for _, use in ipairs(found) do
    report(use.from_file .. ":" .. use.line .. ": " .. use.module .. " " .. use.symbol)
  end
  if #found == 0 then
    report("uses: FAIL (nothing refers to '" .. query .. "')")
    return 1
  end
  report("uses: PASS (" .. #found .. " places)")
  return 0
end

return docs
