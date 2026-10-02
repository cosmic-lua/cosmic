--- The `docs` rows a link's name is looked up in, held in memory: what
--- `cosmic fix` ([`build.links`]) and the build's index of links
--- ([`build.link_index`]) answer a name in full with, one table lookup a
--- name rather than a scan of every row. The rule is [`docs.exact`]'s
--- for a name with a `.` -- a symbol as declared or by its last few
--- names, a module's own row, a module with no row of its own by its
--- first, or a member of a type an alias stands for
--- ([`Sqlite.Handle.exec`]) -- and, for a module's member written in full,
--- [`build.docs`]' `member_of`'s ([`cosmic.fs.read`],
--- [`cosmic.cli.order`]). A name alone never comes here:
--- it names a declaration of its own file ([`build.link_resolve`]).

local Sqlite = require("cosmic.sqlite")
local alias_members = require("build.alias_members")
local type link_resolve = require("build.link_resolve")

local record symbol_index
  --- One row of `docs` ([`build.schema`]), from the database `database`
  --- (an index into the caller's) at its row `id`.
  record Row is alias_members.Declared
    module: string
    symbol: string
    source_symbol: string
    kind: string
    signature: string
    exported: boolean
    file: string
    --- Whether a name may answer with it: `cosmic docs` shows it, from
    --- the database that owns its module. A row not shown is still a
    --- type an alias may stand for, as [`build.docs`] reads every row.
    shown: boolean
    database: integer
    id: integer
  end

  --- The rows, keyed by each way they are found: `exact` by symbol,
  --- source symbol and a module's own name; `named` by symbol and each
  --- of its last few names; `members` by module and dotted name; and
  --- each module's first row (`first`), and the record each module's
  --- value is typed as when its own row says so (`values`,
  --- [`alias_members.value_record`]); these only of rows shown. Of
  --- every row, a record, interface, enum or `type X = Y` by module and
  --- source symbol (`types`) and, exported, by module and symbol
  --- (`exported`), and a field or value by module and the source symbol
  --- it is declared under (`under`); and the module each module binds
  --- each name to, by module and name (`bound`, [`symbol_index.add_bound`]).
  record Index
    modules: {string: boolean}
    exact: {string: {Row}}
    named: {string: {Row}}
    members: {string: {Row}}
    first: {string: Row}
    values: {string: string}
    types: {string: Row}
    exported: {string: Row}
    under: {string: {Row}}
    bound: {string: string}
  end
end

--- An index of no rows.
function symbol_index.new(): symbol_index.Index
  return { modules = {}, exact = {}, named = {}, members = {}, first = {}, values = {},
    types = {}, exported = {}, under = {}, bound = {} }
end

--- Adds `row` to the list `map` keeps under `key`.
local function put(map: {string: {symbol_index.Row}}, key: string, row: symbol_index.Row)
  local list = map[key]
  if list == nil then
    list = {}
    map[key] = list
  end
  list[#list + 1] = row
end

--- Whether `a` was read before `b`: by database, then by row.
local function before(a: symbol_index.Row, b: symbol_index.Row): boolean
  if a.database ~= b.database then return a.database < b.database end
  return a.id < b.id
end

--- Keeps `row` under `key` in `map` unless a row read before it is there.
local function keep_first(map: {string: symbol_index.Row}, key: string, row: symbol_index.Row)
  local held = map[key]
  if held == nil or before(row, held) then map[key] = row end
end

--- Adds `module` to `index`'s modules, whether or not a row of it is
--- added.
function symbol_index.module(index: symbol_index.Index, module: string)
  index.modules[module] = true
end

--- Adds to `index` each name a module binds to another, the rows of
--- `bound` ([`build.schema`]) of the database `db` holds under
--- `qualifier` (`""` or `"out."`), where it holds that table: one
--- written before it existed binds none. The first database read that
--- binds a name answers for it, as [`build.docs`] reads them.
function symbol_index.add_bound(index: symbol_index.Index, db: Sqlite.Handle,
                                qualifier: string): boolean, string
  local held, held_trouble = Sqlite.text_rows(db, "SELECT 1 FROM " .. qualifier ..
    "sqlite_schema WHERE type = 'table' AND name = 'bound'")
  if held == nil then
    return false, held_trouble
  end
  if #held == 0 then
    return true, ""
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT path, name, requires FROM " .. qualifier .. "bound ORDER BY path, name")
  if rows == nil then
    return false, trouble
  end
  for _, row in ipairs(rows) do
    local key = row[1] .. "\n" .. row[2]
    if index.bound[key] == nil then index.bound[key] = row[3] end
  end
  return true, ""
end

--- Adds a row of `docs` to `index` (`symbol` `""` for the module's own
--- row). The first row shown of a module is its `first`.
function symbol_index.add(index: symbol_index.Index, row: symbol_index.Row)
  local module, symbol, source = row.module, row.symbol, row.source_symbol
  if row.kind == "record" or row.kind == "interface" or row.kind == "enum" or
      row.signature:match("^type .* = ") ~= nil then
    keep_first(index.types, module .. "\n" .. source, row)
    if row.exported then keep_first(index.exported, module .. "\n" .. symbol, row) end
  end
  local parent, last = source:match("^(.*)%.([^.]*)$")
  if parent ~= nil and (row.kind == "field" or row.kind == "value") and last:sub(1, 1) ~= "_" then
    put(index.under, module .. "\n" .. parent, row)
  end
  if not row.shown then
    return
  end
  index.modules[module] = true
  if index.first[module] == nil then index.first[module] = row end
  if symbol == "" and row.kind == "module" and index.values[module] == nil then
    index.values[module] = alias_members.value_record(row.signature)
  end
  put(index.exact, symbol, row)
  if source ~= symbol then put(index.exact, source, row) end
  if symbol == "" then
    put(index.exact, module, row)
    return
  end
  put(index.named, symbol, row)
  for at in symbol:gmatch("()[.:]") do put(index.named, symbol:sub(at + 1), row) end
  local dotted = symbol:gsub(":", ".")
  local dotted_source = source:gsub(":", ".")
  put(index.members, module .. "\n" .. dotted, row)
  if dotted_source ~= dotted then put(index.members, module .. "\n" .. dotted_source, row) end
end

--- The rows of `lists`, in order, each module and symbol once.
local function once_each(lists: {{symbol_index.Row}}): {symbol_index.Row}
  local out: {symbol_index.Row} = {}
  local seen: {string: boolean} = {}
  for _, list in ipairs(lists) do
    for _, row in ipairs(list) do
      local full = row.module .. "\n" .. row.symbol
      if not seen[full] then
        seen[full] = true
        out[#out + 1] = row
      end
    end
  end
  return out
end

--- `rows` as the symbols a link names.
local function symbols(rows: {symbol_index.Row}): {link_resolve.Symbol}
  local out: {link_resolve.Symbol} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { module = row.module, symbol = row.symbol, file = row.file }
  end
  return out
end

--- The fields and values declared directly under `target`, less any
--- named `_...`, as [`build.docs`] reads them: those of the first
--- database that declares any, in its order.
local function members_under(index: symbol_index.Index, target: symbol_index.Row): {symbol_index.Row}
  local rows = index.under[target.module .. "\n" .. target.source_symbol] or {}
  local first: integer = nil
  for _, row in ipairs(rows) do
    if first == nil or row.database < first then first = row.database end
  end
  local out: {symbol_index.Row} = {}
  for _, row in ipairs(rows) do
    if row.database == first then out[#out + 1] = row end
  end
  table.sort(out, before)
  return out
end

--- `index`'s rows, as [`build.alias_members`] follows a declaration
--- through them.
local function source_of(index: symbol_index.Index): alias_members.Source<symbol_index.Row>
  return {
    declared = function(module: string, name: string): symbol_index.Row | nil, string
      return index.types[module .. "\n" .. name]
    end,
    exported = function(module: string, name: string): symbol_index.Row | nil, string
      return index.exported[module .. "\n" .. name]
    end,
    bound = function(module: string, name: string): string | nil, string
      return index.bound[module .. "\n" .. name]
    end,
    under = function(target: symbol_index.Row): {symbol_index.Row} | nil, string
      return members_under(index, target)
    end,
    as_member = function(owner: symbol_index.Row, member: symbol_index.Row,
                         name: string): symbol_index.Row
      return { module = owner.module, symbol = owner.symbol .. "." .. name,
        source_symbol = owner.source_symbol .. "." .. name, kind = member.kind,
        signature = member.signature, exported = true, file = member.file, shown = true,
        database = member.database, id = member.id }
    end,
  }
end

--- The members named `name` of the types `owners` stand for.
local function through(index: symbol_index.Index, owners: {symbol_index.Row},
                       name: string): {symbol_index.Row}
  -- Rows held in memory are always read: no answer is nil.
  local found, _ = alias_members.named(source_of(index), owners, name)
  return once_each({ found or {} })
end

--- The rows of `module` named `name`, a method's `:` read as `.`; else
--- the exported member `name` of the record the module's value is typed
--- as (`Module.order` of a module that returns `local module: Module`);
--- else the member of a type an alias of the module stands for
--- (`Handle.close` of [`cosmic.sqlite`]): [`build.docs`]' `member_of`.
local function members_of(index: symbol_index.Index, module: string,
                          name: string): {symbol_index.Row}
  local dotted = name:gsub(":", ".")
  local found = once_each({ index.members[module .. "\n" .. dotted] or {} })
  local record = index.values[module]
  if #found == 0 and record ~= nil then
    for _, row in ipairs(index.members[module .. "\n" .. record .. "." .. dotted] or {}) do
      if row.exported and (row.source_symbol:gsub(":", ".")) == record .. "." .. dotted then
        found[#found + 1] = row
      end
    end
    found = once_each({ found })
  end
  local prefix, last = dotted:match("^(.+)%.([%w_]+)$")
  if #found > 0 or prefix == nil then
    return found
  end
  return through(index, members_of(index, module, prefix), last)
end

--- The members of `module` named `name`, a method's `:` read as `.`, as
--- [`members_of`] finds them.
function symbol_index.member(index: symbol_index.Index, module: string,
                             name: string): {link_resolve.Symbol}
  return symbols(members_of(index, module, name))
end

--- The rows `query` names as declared or by its last few names, or a
--- module's own row, as [`build.docs`]'s `named` finds them.
local function named_rows(index: symbol_index.Index, query: string): {{symbol_index.Row}}
  return { index.exact[query] or {}, index.named[query] or {},
    index.named[(query:gsub(":", "."))] or {} }
end

--- The symbols `query`, a name with a `.` or a `:`, names.
function symbol_index.named(index: symbol_index.Index, query: string): {link_resolve.Symbol}
  local lists = named_rows(index, query)
  if #once_each(lists) == 0 and index.modules[query] and index.first[query] ~= nil then
    lists[#lists + 1] = { index.first[query] }
  end
  local modules: {string} = {}
  local at = 1
  while true do
    local dot = query:find(".", at, true)
    if dot == nil then break end
    local module = query:sub(1, dot - 1)
    if index.modules[module] then
      modules[#modules + 1] = module
      lists[#lists + 1] = index.members[module .. "\n" .. (query:sub(dot + 1):gsub(":", "."))] or {}
    end
    at = dot + 1
  end
  local found = once_each(lists)
  if #found > 0 then
    return symbols(found)
  end
  -- Nothing is declared by that name: a member of a type an alias
  -- stands for, spelled from the alias ([`Sqlite.Handle.close`]) or from
  -- its module ([`cosmic.sqlite.Handle.close`]).
  local prefix, name = query:match("^([%w_]+%.[%w_%.]+)%.([%w_]+)$")
  if prefix ~= nil then
    lists[#lists + 1] = through(index, once_each(named_rows(index, prefix)), name)
  end
  for _, module in ipairs(modules) do
    lists[#lists + 1] = members_of(index, module, query:sub(#module + 2))
  end
  return symbols(once_each(lists))
end

return symbol_index
