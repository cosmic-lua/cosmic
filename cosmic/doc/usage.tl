--- The uses and links of a view's databases, counted and read of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local alias_members = require("cosmic.internal.alias_members")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local Examples = require("cosmic.doc.examples")
local Search = require("cosmic.doc.search")
local type Command = Types.Command
local type View = Types.View
local type Entry = Types.Entry
local type Use = Types.Use
local type Unused = Types.Unused
local entries_of = Examples.entries_of
local fts_query = Search.fts_query
local has_docs = Search.has_docs
local has_links = Search.has_links
local text = Examples.text

local record Usage
  type Command = Command
  type Entry = Entry
  type Use = Use
  type Unused = Unused
  type View = View
end

--- Whether `db` holds the `catalog` and the index over it: a database built before the codes of the checker were written to
--- it lacks them.
local function has_catalog(db: Sqlite.Handle): boolean?, string
  local rows, trouble = db:rows(
    "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('catalog', 'catalog_fts')")
  if rows == nil then return nil, tostring(trouble) end
  local held = false
  for _, row in ipairs(rows) do
    held = row:integer(1) == 2
  end
  return held, ""
end

--- The entries of the catalog rows of kind `code` ([`build.error_catalog`]) that `where` selects, from the first database
--- that holds any: the rule behind a code of the checker, its reason and its fix, in the text of the row. None in a
--- program's own view ([`Doc.program`]): its users are asked about the program, not the checker the tool documents,
--- so it finds no code, built or run from its source.
local function coded_entries(view: View, join: string, where: string, binds: {Sqlite.Value},
                             limit: integer): mut {Entry}?, string
  if view.program ~= nil then
    return {}, ""
  end
  for _, db in ipairs(view.databases) do
    local held, held_trouble = has_catalog(db)
    if held == nil then
      return nil, held_trouble
    end
    if held then
      local rows, trouble = db:rows(
        "SELECT c.module, ifnull(c.symbol, ''), ifnull(c.symbol, ''), 1, 'code', '', ifnull(c.text, ''), c.file, " ..
          "c.line, 0, 0 FROM catalog c " .. join ..
          " WHERE c.kind = 'code' AND " .. where .. " ORDER BY c.id LIMIT " .. tostring(limit),
        binds)
      if rows == nil then
        return nil, tostring(trouble)
      end
      if #rows > 0 then
        return entries_of(rows), ""
      end
    end
  end
  return {}, ""
end

--- The code `query` names exactly (`not_assignable`): its row of the catalog.
function Usage.coded(view: View, query: string): {Entry}?, string
  if query:match("^%l[%l%d_]*$") == nil then
    return {}, ""
  end
  return coded_entries(view, "", "c.symbol = ?1", { text(query) }, 1)
end

--- The rows of codes whose rule, reason or fix carries every word of `query`, best match first.
function Usage.coded_words(view: View, query: string): mut {Entry}?, string
  local fts = fts_query(query)
  if fts == "" then
    return {}, ""
  end
  return coded_entries(view, "JOIN catalog_fts ON catalog_fts.rowid = c.id", "catalog_fts MATCH ?1", { text(fts) }, 10)
end

--- The places that refer to what `query` names, by the rule
--- [`symbols.used_where`] keeps: the uses, then the links, which also
--- match a query that is a file's path from the root, alone or with
--- `#` and a heading's anchor (`doc/writing.md#every-example-runs`). A
--- path alone finds the links to its headings too, and a bare lowercase
--- name the links to each module it is the last name of, as
--- [`Doc.exact`] reads one (`fs` for [`cosmic.fs`]). A public source
--- has no link to a file of its own tree.
function Usage.uses_of(db: Sqlite.Handle, public: boolean, query: string): {Use}?, string
  local rows, trouble = db:rows(
    "SELECT module, symbol, from_module, from_file, line FROM uses u WHERE " ..
      symbols.used_where("u") .. " AND " ..
      symbols.public_only("module", public) .. " AND " ..
      symbols.public_only("from_module", public) ..
      " ORDER BY module, symbol, from_file, line", { text(query) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {Use} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row:text(1), symbol = row:text(2), from_module = row:text(3),
      from_file = row:text(4), line = row:integer(5),
      link = false, path = "", anchor = "" }
  end
  local linked, linked_trouble = has_links(db)
  if linked == nil then
    return nil, linked_trouble
  end
  if not linked then
    return out, ""
  end
  local path = query:gsub("^%./", ""):gsub("/$", "")
  local anchor: string? = nil
  local before, after = path:match("^([^#]*)#(.+)$")
  if before ~= nil and after ~= nil then
    path, anchor = before, after:lower()
  end
  local link_rows, link_trouble = db:rows(
    "SELECT module, symbol, from_module, from_file, line, path, anchor FROM links l WHERE " ..
      "((kind = 'symbol' AND (" .. symbols.used_where("l") .. " OR (l.symbol = '' AND " ..
      "l.module = ?1) OR (?5 = 1 AND " .. symbols.module_ending_where("l") .. ")) AND " ..
      symbols.public_only("l.module", public) .. ") OR " ..
      "(kind <> 'symbol' AND ?4 = 0 AND l.path = ?2 AND (?3 = '' OR lower(l.anchor) = ?3))) AND " ..
      symbols.public_only("l.from_module", public) ..
      " ORDER BY module, symbol, path, anchor, from_file, line, column",
    { text(query), text(path), text(anchor or ""),
      { integer = if public then 1 else 0 end },
      { integer = if query:match("^%l[%w_]*$") ~= nil then 1 else 0 end } })
  if link_rows == nil then
    return nil, tostring(link_trouble)
  end
  for _, row in ipairs(link_rows) do
    out[#out + 1] = { module = row:text(1), symbol = row:text(2), from_module = row:text(3),
      from_file = row:text(4), line = row:integer(5),
      link = true, path = row:text(6), anchor = row:text(7) }
  end
  return out, ""
end

--- The exported functions of `db`'s own modules that no code outside their file uses, a test's left out: a module
--- whose name ends in `_test`. A link is no use. None of a public source, whose callers are elsewhere.
function Usage.unused_of(db: Sqlite.Handle, public: boolean): {Unused}?, string
  if public then return {}, "" end
  local rows, trouble = db:rows(
    "SELECT d.module, d.source_symbol, d.file, d.line FROM docs d WHERE d.exported = 1 AND d.kind = 'function' " ..
      "AND d.module NOT GLOB '*_test' AND NOT EXISTS (SELECT 1 FROM uses u WHERE u.module = d.module AND " ..
      "u.symbol = d.symbol AND u.from_file <> d.file AND u.from_module NOT GLOB '*_test') " ..
      "ORDER BY d.file, d.line", {})
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {Unused} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row:text(1), symbol = row:text(2), file = row:text(3), line = row:integer(4) }
  end
  return out, ""
end

--- Whether the database at `index` of `view` covers `module`: the
--- first that holds it, or, for "" -- a Markdown, C or Zig file's link,
--- which names no module -- the first that is not
--- a public source, the tree's own projection, as only a tree's own
--- build indexes its files.
local function answers_for(view: View, index: integer, module: string): boolean
  if module == "" then
    for at = 1, #view.databases do
      if view.public[at] ~= true then return at == index end
    end
    return false
  end
  return view.owners[module] == index
end

--- One lookup over `databases`, in order, with a module found in an
--- earlier database hiding it in every later one.
--- @param look what to read from each database
function Usage.across<T>(view: View,
                         look: function(Sqlite.Handle, boolean): {T}?, string,
                         module_of: function(T): string): mut {T}?, string
  local out: mut {T} = {}
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
        if answers_for(view, index, module_of(item)) then
          out[#out + 1] = item
        end
      end
    end
  end
  return out, ""
end

function Usage.entry_module(entry: Entry): string
  return entry.module
end

function Usage.calling_module(use: Use): string
  return use.from_module
end

--- The database `owner` stands for: an owner is the index of a database
--- [`Doc.view`] listed, so it always has one.
function Usage.database_of(view: View, owner: integer): Sqlite.Handle
  return (assert(view.databases[owner], "an owner is the index of one of the view's databases"))
end
local database_of = Usage.database_of

--- Whether `module` is one the database that owns it records as public
--- ([`symbols.public_modules`]): what a public source covers. A
--- database that cannot say records none.
function Usage.is_public(view: View, module: string): boolean
  local owner = view.owners[module]
  if owner == nil then
    return false
  end
  local recorded = view.public_modules[owner]
  if recorded == nil then
    local read, _ = symbols.public_modules(database_of(view, owner))
    recorded = read or {}
    view.public_modules[owner] = recorded
  end
  return recorded[module] == true
end
local is_public = Usage.is_public

--- Whether `module` is the standard library's and public: one of the
--- `cosmic.*` namespace, which no project may define, that the database
--- that owns it records as public. A project's own public modules are
--- not the library's.
function Usage.is_library(view: View, module: string): boolean
  return symbols.is_library_module(module) and is_public(view, module)
end

--- The record `module`'s value is typed as when the module returns a
--- name that is not that record (`local module: Module`), as its own
--- row records it ([`alias_members.value_record`]); nil when it returns
--- its record by name, or has no row of its own.
function Usage.value_record(db: Sqlite.Handle, module: string): string?, string
  local rows, trouble = db:rows(
    "SELECT signature FROM docs WHERE module = ?1 AND symbol = '' AND kind = 'module' " ..
      "ORDER BY id LIMIT 1", { text(module) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  if #rows == 0 then
    return nil, ""
  end
  return alias_members.value_record(rows[1]:text(1)), ""
end
local value_record = Usage.value_record

--- The name `entry` is used by, as a use of it is recorded, when that
--- differs from its symbol: `order` for cosmic.cli's `Module.order`,
--- a member of the record the module's value is typed as. Nil when the
--- two are one, or nil and why when the owning database cannot be read.
function Usage.used_as(view: View, entry: Entry): string?, string
  local owner = view.owners[entry.module]
  if owner == nil or entry.symbol == "" then
    return nil, ""
  end
  local cached = view.value_records[entry.module]
  if cached == nil then
    local record, trouble = value_record(database_of(view, owner), entry.module)
    if record == nil and trouble ~= "" then
      return nil, trouble
    end
    cached = record or ""
    view.value_records[entry.module] = cached
  end
  local prefix = cached .. "."
  if cached ~= "" and String.starts_with(entry.source_symbol, prefix) then
    return (entry.source_symbol:sub(#prefix + 1):gsub(":", ".")), ""
  end
  return nil, ""
end
local used_as = Usage.used_as

local function use_key(module: string, symbol: string): string
  return module .. "\n" .. symbol
end

--- How many places refer to `module`/`symbol`, across `view.databases`.
--- A use counts only if the database is not a public source or both ends are
--- public modules, and only when that database owns the calling module; see
--- `across`. Each pair is computed once and cached on `view`, since both a
--- module listing and symbol rendering can request it in one command.
local function count_uses(view: View, module: string,
                          symbol: string): integer?, string
  local key = use_key(module, symbol)
  local cached = view.use_counts[key]
  if cached ~= nil then
    return cached, ""
  end
  local seen: mut {string: boolean} = {}
  local total = 0
  for index, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = db:rows(
        "SELECT from_module, from_file, line FROM uses " ..
          "WHERE module = ?1 AND symbol = ?2",
        { text(module), text(symbol) })
      if rows == nil then
        return nil, tostring(trouble)
      end
      for _, row in ipairs(rows) do
        local from_module = row:text(1)
        local counted = view.public[index] ~= true or
          (is_public(view, module) and is_public(view, from_module))
        if counted and view.owners[from_module] == index then
          local position = module .. "\n" .. symbol .. "\n" .. from_module ..
            "\n" .. row:text(2) .. "\n" .. tostring(row:integer(3))
          if seen[position] ~= true then
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

--- How many links name `module`/`symbol`, across `view.databases`,
--- counted as [`count_uses`] counts uses, and cached on `view` the same
--- way.
local function count_links(view: View, module: string,
                           symbol: string): integer?, string
  local key = use_key(module, symbol)
  local cached = view.link_counts[key]
  if cached ~= nil then
    return cached, ""
  end
  local seen: mut {string: boolean} = {}
  local total = 0
  for index, db in ipairs(view.databases) do
    local linked, linked_trouble = has_links(db)
    if linked == nil then
      return nil, linked_trouble
    end
    if linked then
      local rows, trouble = db:rows(
        "SELECT from_module, from_file, line FROM links " ..
          "WHERE kind = 'symbol' AND module = ?1 AND symbol = ?2",
        { text(module), text(symbol) })
      if rows == nil then
        return nil, tostring(trouble)
      end
      for _, row in ipairs(rows) do
        local from_module = row:text(1)
        local counted = view.public[index] ~= true or
          (is_public(view, module) and is_public(view, from_module))
        -- One place per line, as [`Doc.uses`] lists them.
        local position = row:text(2) .. "\n" .. tostring(row:integer(3))
        if counted and answers_for(view, index, from_module) and seen[position] ~= true then
          seen[position] = true
          total = total + 1
        end
      end
    end
  end
  view.link_counts[key] = total
  return total, ""
end

function Usage.effective_counts(view: View, entries: {Entry}): boolean, string
  for _, entry in ipairs(entries) do
    if view.program ~= nil then
      -- A program's user has no `uses` to follow a count with, so its pages give none.
      entry.uses, entry.links = 0, 0
    end
  end
  if view.program ~= nil then
    return true, ""
  end
  for _, entry in ipairs(entries) do
    local used, used_trouble = used_as(view, entry)
    if used == nil and used_trouble ~= "" then
      return false, used_trouble
    end
    local uses, trouble = count_uses(view, entry.module, used or entry.symbol)
    if uses == nil then
      return false, trouble
    end
    entry.uses = uses
    local linked, link_trouble = count_links(view, entry.module, entry.symbol)
    if linked == nil then
      return false, link_trouble
    end
    entry.links = linked
  end
  return true, ""
end

--- What a reader types to ask `view`'s documentation: the tool's `cosmic docs`, or the program's own.
function Usage.docs_command(view: View): string
  return (view.program or "cosmic") .. " docs"
end

--- The command of `view` that `entry` documents, or nil.
function Usage.command_of(view: View, entry: Entry): Command?
  for _, command in ipairs(view.commands) do
    if command.module == entry.module and command.symbol == entry.symbol then
      return command
    end
  end
  return nil
end

return Usage
