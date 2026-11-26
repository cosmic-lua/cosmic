--- The members of a module or record a page lists: in full, by last name, through an alias, and their uses of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local alias_members = require("cosmic.internal.alias_members")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local Examples = require("cosmic.doc.examples")
local Search = require("cosmic.doc.search")
local Usage = require("cosmic.doc.usage")
local Pages = require("cosmic.doc.pages")
local type View = Types.View
local type Entry = Types.Entry
local type Taking = Types.Taking
local type Use = Types.Use
local across = Usage.across
local calling_module = Usage.calling_module
local columns = Examples.columns
local database_of = Usage.database_of
local entries_of = Examples.entries_of
local entry_module = Usage.entry_module
local has_links = Search.has_links
local named = Search.named
local text = Examples.text
local type_source = Pages.type_source
local used_as = Usage.used_as
local uses_of = Usage.uses_of
local value_record = Usage.value_record

--- The lookups of a member that call one another and are called before they are defined, as functions of one
--- record declared first: what a dotted query names through a type alias, in full, or from a module's last name,
--- and what a removed name resolves to.
local record Members
  type Entry = Entry
  type Taking = Taking
  type Use = Use
  type View = View
end

--- What a dotted query names through a type alias, else as a module's
--- member written in full ([`cosmic.fs.read`], [`cosmic.cli.order`]),
--- as a link names one.
function Members.in_full(view: View, query: string): {Entry}?, string
  local through, through_trouble = Members.through_alias(view, query)
  if through == nil then
    return nil, through_trouble
  end
  if #through > 0 then
    return through, ""
  end
  local out: mut {Entry} = {}
  local at = 1
  while true do
    local dot = query:find(".", at, true)
    if dot == nil then break end
    local module = query:sub(1, dot - 1)
    if view.owners[module] ~= nil then
      local members, trouble = Members.member_of(view, module, query:sub(dot + 1))
      if members == nil then
        return nil, trouble
      end
      for _, entry in ipairs(members) do out[#out + 1] = entry end
    end
    at = dot + 1
  end
  return out, ""
end

--- What `Q.name` names when `Q` is the last name of a module, either
--- case (`Cli.order`, `fs.read`): that module's member `name`, as a
--- caller that requires it under that name reads it.
function Members.by_last_name(view: View, query: string): {Entry}?, string
  local out: mut {Entry} = {}
  local qualifier, name = query:match("^([%w_]+)%.(.+)$")
  if qualifier == nil or name == nil then
    return out, ""
  end
  local modules: mut {string} = {}
  for module in pairs(view.owners) do
    local tail = module:match("[^.]+$")
    if tail ~= nil and tail:lower() == qualifier:lower() and module ~= qualifier and
        module:sub(1, 16) ~= "cosmic.internal." and module:sub(-5) ~= "_test" and
        module:sub(-8) ~= "_example" then
      modules[#modules + 1] = module
    end
  end
  table.sort(modules)
  for _, module in ipairs(modules) do
    local members, trouble = Members.member_of(view, module, name)
    if members == nil then
      return nil, trouble
    end
    for _, entry in ipairs(members) do out[#out + 1] = entry end
  end
  return out, ""
end

--- What a name [`cosmic.removed`] lists as withheld resolves to: one entry of kind `removed` saying what to write
--- instead, for a field of a withheld global (`os.getenv`) or a withheld field of `package` (`package.path`), with
--- the words a refusal at run time raises with; none for any other name.
function Members.removed_by(query: string): Entry?
  local qualifier, name = query:match("^([%w_]+)%.([%w_]+)$")
  if qualifier == nil or (Removed.names[qualifier] == nil and Removed.replacements[query] == nil) then
    return nil
  end
  return {
    module = "cosmic.removed", symbol = query,
    source_symbol = query, exported = true, kind = "removed", signature = "",
    text = Removed.message(qualifier, name), file = "cosmic/removed.tl", line = 0,
    uses = 0, links = 0, examples = 0, related = {},
  }
end

--- The uses of `module`'s member recorded as `used`, and the links to
--- its row `symbol`, in `db`.
local function member_uses(db: Sqlite.Handle, public: boolean, module: string, symbol: string,
                           used: string): {Use}?, string
  local out: mut {Use} = {}
  local rows, trouble = db:rows(
    "SELECT from_module, from_file, line FROM uses WHERE module = ?1 AND symbol = ?2 AND " ..
      symbols.public_only("module", public) .. " AND " ..
      symbols.public_only("from_module", public), { text(module), text(used) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = module, symbol = used, from_module = row:text(1), from_file = row:text(2),
      line = row:integer(3), link = false, path = "", anchor = "" }
  end
  local linked, linked_trouble = has_links(db)
  if linked == nil then
    return nil, linked_trouble
  end
  if not linked then
    return out, ""
  end
  local links, links_trouble = db:rows(
    "SELECT from_module, from_file, line FROM links WHERE kind = 'symbol' AND module = ?1 " ..
      "AND symbol = ?2 AND " .. symbols.public_only("module", public) .. " AND " ..
      symbols.public_only("from_module", public) .. " ORDER BY from_file, line, column",
    { text(module), text(symbol) })
  if links == nil then
    return nil, tostring(links_trouble)
  end
  for _, row in ipairs(links) do
    out[#out + 1] = { module = module, symbol = symbol, from_module = row:text(1), from_file = row:text(2),
      line = row:integer(3), link = true, path = "", anchor = "" }
  end
  return out, ""
end

-- Doc.uses, its failure in words.
function Members.uses_text(view: View, query: string): {Use}?, string
  local found, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Use}?, string
      return uses_of(db, public, query)
    end, calling_module)
  if found == nil then
    return nil, trouble
  end
  local members: mut {Entry} = {}
  for _, look in ipairs({ Members.in_full, Members.by_last_name }) do
    local answered, answered_trouble = look(view, query)
    if answered == nil then
      return nil, answered_trouble
    end
    for _, entry in ipairs(answered) do members[#members + 1] = entry end
  end
  for _, entry in ipairs(members) do
    local used, used_trouble = used_as(view, entry)
    if used == nil and used_trouble ~= "" then
      return nil, used_trouble
    end
    local more, more_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Use}?, string
        return member_uses(db, public, entry.module, entry.symbol, used or entry.symbol)
      end, calling_module)
    if more == nil then
      return nil, more_trouble
    end
    for _, use in ipairs(more) do found[#found + 1] = use end
  end
  local out: mut {Use} = {}
  local seen: mut {string: boolean} = {}
  for _, use in ipairs(found) do
    local key = use.module .. "\n" .. use.symbol .. "\n" .. use.from_module ..
      "\n" .. use.from_file .. "\n" .. tostring(use.line) .. "\n" .. tostring(use.link) ..
      "\n" .. use.path .. "\n" .. use.anchor
    if seen[key] ~= true then
      seen[key] = true
      out[#out + 1] = use
    end
  end
  -- Uses and links together, by where they are; at one place, a use
  -- before a link.
  table.sort(out, function(a: Use, b: Use): boolean
    if a.from_file ~= b.from_file then return a.from_file < b.from_file end
    if a.line ~= b.line then return a.line < b.line end
    if a.link ~= b.link then return b.link end
    if a.module ~= b.module then return a.module < b.module end
    if a.symbol ~= b.symbol then return a.symbol < b.symbol end
    if a.path ~= b.path then return a.path < b.path end
    return a.anchor < b.anchor
  end)
  return out, ""
end

--- Whether the function `signature` writes has a parameter named `word` in its own list, not in a function type one of
--- its parameters has.
local function takes_name(signature: string, word: string): boolean
  local open = signature:find("(", 1, true)
  if open == nil then return false end
  local depth = 0
  local start = open + 1
  for i = open + 1, #signature do
    local c = signature:sub(i, i)
    if c == "(" or c == "{" or c == "<" then
      depth = depth + 1
    elseif depth > 0 and (c == ")" or c == "}" or c == ">") then
      depth = depth - 1
    elseif depth == 0 and (c == "," or c == ")") then
      local name = signature:sub(start, i - 1):match("^%s*([%w_]+)%??:")
      if name == word then return true end
      if c == ")" then return false end
      start = i + 1
    end
  end
  return false
end

--- The exported functions of `db` whose signature names a parameter `word` (`path` of `Fs.basename(path: string)`).
function Members.taking_of(db: Sqlite.Handle, public: boolean, word: string): {Taking}?, string
  local rows, trouble = db:rows(
    "SELECT module, symbol, signature FROM docs WHERE kind = 'function' AND exported = 1 AND " ..
      symbols.public_only("module", public) .. " AND (" ..
      "instr(signature, '(' || ?1 || ':') > 0 OR instr(signature, '(' || ?1 || '?:') > 0 OR " ..
      "instr(signature, ', ' || ?1 || ':') > 0 OR instr(signature, ', ' || ?1 || '?:') > 0) ORDER BY module, symbol",
    { text(word) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {Taking} = {}
  for _, row in ipairs(rows) do
    if takes_name(row:text(3), word) then
      out[#out + 1] = { module = row:text(1), symbol = row:text(2) }
    end
  end
  return out, ""
end

--- The members named `name` of the types `owners` stand for, each as
--- the owner's own member (`Handle.close` of [`cosmic.sqlite`] for the
--- `close` of the record its `Handle` aliases).
function Members.aliased_members(view: View, owners: {Entry},
                                 name: string): {Entry}?, string
  return alias_members.named(type_source(view), owners, name)
end

--- What a dotted query names through a type alias or an inherited
--- record: [`Child.Options.fds`], [`Sqlite.Handle.exec`].
function Members.through_alias(view: View, query: string): {Entry}?, string
  local prefix, name = query:match("^([%w_]+%.[%w_%.]+)%.([%w_]+)$")
  if prefix == nil or name == nil then
    return {}, ""
  end
  local owners, owners_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      return named(db, public, prefix)
    end, entry_module)
  if owners == nil then
    return nil, owners_trouble
  end
  return Members.aliased_members(view, owners, name)
end

--- The rows of `module` whose symbol is `name`, as the symbol column
--- reads (`read`, [`Writer.write`]) or as the source spells it
--- ([`Fs.read`]), a method's `:` read as `.`; else the exported member
--- `name` of the record the module's value is typed as (`Module.order`
--- of cosmic.cli, whose value is `local module: Module`); else, as
--- [`Doc.exact`] does, the member of a type an alias of the module
--- stands for (`Handle.close` of [`cosmic.sqlite`]). None when the view
--- holds no such module. The database that owns the module is read.
function Members.member_of(view: View, module: string, name: string): {Entry}?, string
  local owner = view.owners[module]
  if owner == nil then
    return {}, ""
  end
  local db = database_of(view, owner)
  local shown = symbols.shown_in(db, "d", view.public[owner] == true)
  local dotted = name:gsub(":", ".")
  local rows, trouble = db:rows(
    "SELECT " .. columns .. " FROM docs d WHERE " .. symbols.member_where("d") .. " AND " ..
      shown .. " ORDER BY d.id", { text(module), text(dotted) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local found = entries_of(rows)
  if #found > 0 then
    return found, ""
  end
  local record, record_trouble = value_record(db, module)
  if record == nil and record_trouble ~= "" then
    return nil, record_trouble
  end
  if record ~= nil then
    local typed, typed_trouble = db:rows(
      "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND d.exported = 1 AND " ..
        "replace(d.source_symbol, ':', '.') = ?2 AND " .. shown .. " ORDER BY d.id",
      { text(module), text(record .. "." .. dotted) })
    if typed == nil then
      return nil, tostring(typed_trouble)
    end
    found = entries_of(typed)
    if #found > 0 then
      return found, ""
    end
  end
  local prefix, last = dotted:match("^(.+)%.([%w_]+)$")
  if prefix == nil or last == nil then
    return found, ""
  end
  local owners, owners_trouble = Members.member_of(view, module, prefix)
  if owners == nil then
    return nil, owners_trouble
  end
  return Members.aliased_members(view, owners, last)
end

return Members
