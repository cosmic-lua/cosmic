--- The `docs` rows a link's name is looked up in, held in memory: what
--- `cosmic fix` ([`build.links`]) and the build's index of links
--- ([`build.link_index`]) answer a name in full with, one table lookup a
--- name rather than a scan of every row. The rule is [`docs.exact`]'s
--- for a name with a `.` -- a symbol as declared or by its last few
--- names, a module's own row, or a module with no row of its own by its
--- first -- and a module's member written in full ([`cosmic.fs.read`]).
--- A name alone never comes here: it names a declaration of its own
--- file ([`build.link_resolve`]). Neither does a member of a type an alias
--- stands for ([`Sqlite.Handle.exec`]), which [`build.docs`] resolves.

local type link_resolve = require("build.link_resolve")

local record symbol_index
  --- The rows, keyed by each way they are found: `exact` by symbol,
  --- source symbol and a module's own name; `named` by symbol and each
  --- of its last few names; `members` by module and dotted name; and
  --- each module's first row (`first`).
  record Index
    modules: {string: boolean}
    exact: {string: {link_resolve.Symbol}}
    named: {string: {link_resolve.Symbol}}
    members: {string: {link_resolve.Symbol}}
    first: {string: link_resolve.Symbol}
  end
end

--- An index of no rows.
function symbol_index.new(): symbol_index.Index
  return { modules = {}, exact = {}, named = {}, members = {}, first = {} }
end

--- Adds `symbol` to the list `map` keeps under `key`.
local function put(map: {string: {link_resolve.Symbol}}, key: string, symbol: link_resolve.Symbol)
  local list = map[key]
  if list == nil then
    list = {}
    map[key] = list
  end
  list[#list + 1] = symbol
end

--- Adds `module` to `index`'s modules, whether or not a row of it is
--- added.
function symbol_index.module(index: symbol_index.Index, module: string)
  index.modules[module] = true
end

--- Adds a row of `docs` to `index`: `symbol` of `module` (`""` for the
--- module's own row), as its source spells it (`source`), declared in
--- `file`. The first row added of a module is its `first`.
function symbol_index.add(index: symbol_index.Index, module: string, symbol: string, source: string,
                          file: string)
  local row: link_resolve.Symbol = { module = module, symbol = symbol, file = file }
  index.modules[module] = true
  if index.first[module] == nil then index.first[module] = row end
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

--- The symbols of `lists`, in order, each spelled once.
local function once_each(lists: {{link_resolve.Symbol}}): {link_resolve.Symbol}
  local out: {link_resolve.Symbol} = {}
  local seen: {string: boolean} = {}
  for _, list in ipairs(lists) do
    for _, symbol in ipairs(list) do
      local full = symbol.module .. "\n" .. symbol.symbol
      if not seen[full] then
        seen[full] = true
        out[#out + 1] = symbol
      end
    end
  end
  return out
end

--- The members of `module` named `name`, a method's `:` read as `.`.
function symbol_index.member(index: symbol_index.Index, module: string,
                             name: string): {link_resolve.Symbol}
  return once_each({ index.members[module .. "\n" .. (name:gsub(":", "."))] or {} })
end

--- The symbols `query`, a name with a `.` or a `:`, names.
function symbol_index.named(index: symbol_index.Index, query: string): {link_resolve.Symbol}
  local dotted = query:gsub(":", ".")
  local lists: {{link_resolve.Symbol}} = { index.exact[query] or {}, index.named[query] or {},
    index.named[dotted] or {} }
  if #once_each(lists) == 0 and index.modules[query] and index.first[query] ~= nil then
    lists[#lists + 1] = { index.first[query] }
  end
  local at = 1
  while true do
    local dot = query:find(".", at, true)
    if dot == nil then break end
    local module = query:sub(1, dot - 1)
    if index.modules[module] then
      lists[#lists + 1] = symbol_index.member(index, module, query:sub(dot + 1))
    end
    at = dot + 1
  end
  return once_each(lists)
end

return symbol_index
