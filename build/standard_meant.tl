--- What a `require` of a `cosmic.*` name that the binary has no module of may have meant, from the binary's docs: so
--- a refusal names the module to require, and the next try needs no lookup. A program run with `cosmic file.tl` and a
--- snippet of `cosmic agent` are both checked by [`build.pipeline`], which asks it ([`StandardMeant.wrap`]).
---
---     for _, m in ipairs(StandardMeant.of("cosmic.base64")) do print(m) end -- `cosmic.codec` (has `base64`)

local type Doc = require("cosmic.doc")
local NearNames = require("lang.near_names")
local plural = require("build.plural")

local record StandardMeant
  --- What [`StandardMeant.of`] reads of the docs: the summary of each module, and the rows a word names
  --- ([`Doc.exact`]).
  record Docs
    index: {Doc.Summary}
    --- The module and the symbol of each function the word names.
    exact: function(word: string): {{string}}
    --- The module and the symbol of each exported function with a parameter of the word's name (`Fs.basename(path)`).
    takes: function(word: string): {{string}}
  end

  --- What a `require` of `name` in the file `file` that names no module may have meant, as the driver asks it.
  type Meant = function(name: string, file: string): {string}
end

-- The modules that are the tools' own, never a program's guess: those [`Host.modules`] leaves out too.
local TOOLING <const>: {string: boolean} = {
  ["cosmic.agent"] = true, ["cosmic.cli"] = true, ["cosmic.coverage"] = true, ["cosmic.doc"] = true,
  ["cosmic.entrypoint"] = true, ["cosmic.layout"] = true, ["cosmic.project"] = true, ["cosmic.removed"] = true,
  ["cosmic.store"] = true, ["cosmic.test"] = true,
}

-- At most this many modules are named.
local MOST <const> = 8

-- A module's words in a candidate are cut to this many bytes.
local ABOUT <const> = 70

-- A module is named for its functions that take a parameter of the word's name where it has at least this many, and at
-- most this many such modules are named, with this many of the functions each.
local TAKERS <const> = 3
local TAKING <const> = 3
local SHOWN <const> = 4

-- The query of the exported functions with a parameter named ?1, as a declaration's signature writes one.
local TAKES <const> = "SELECT module, symbol FROM docs WHERE kind = 'function' AND exported = 1 AND (" ..
  "instr(signature, '(' || ?1 || ':') > 0 OR instr(signature, '(' || ?1 || '?:') > 0 OR " ..
  "instr(signature, ', ' || ?1 || ':') > 0 OR instr(signature, ', ' || ?1 || '?:') > 0)"

--- `text` on one line, cut to [`ABOUT`] bytes.
local function about(text: string): string
  return NearNames.cut((text:gsub("%s+", " "):gsub("^ ", "")), ABOUT)
end

--- The binary's docs, read once a process, at the first refusal that asks.
local record Read
  mut done: boolean
  mut docs?: StandardMeant.Docs
end
local read: Read = { done = false }

--- The binary's docs, or nil where they cannot be read: a store that withholds them (a test's) raises, and is taken
--- for none.
local function binary_docs(): StandardMeant.Docs?
  if read.done then return read.docs end
  read.done = true
  local ok, held = pcall(function(): StandardMeant.Docs?
    local Docs = require("cosmic.doc")
    local Store = require("cosmic.store")
    local view, _ = Docs.view(Store.databases())
    if view == nil then return nil end
    local index, _ = Docs.index(view)
    if index == nil then return nil end
    return { index = index, exact = function(w: string): {{string}}
      local found, _ = Docs.exact(view, w)
      local rows: mut {{string}} = {}
      for _, e in ipairs(found or {}) do
        if e.kind == "function" then rows[#rows + 1] = { e.module, e.symbol } end
      end
      return rows
    end, takes = function(w: string): {{string}}
      local rows: mut {{string}} = {}
      for _, db in ipairs(view.databases) do
        local found, _ = db:rows(TAKES, { w })
        for _, row in ipairs(found or {}) do rows[#rows + 1] = { row:text(1), row:text(2) } end
      end
      return rows
    end }
  end)
  if ok then read.docs = held end
  return read.docs
end

--- The modules `name` (`cosmic.<words>`) may have meant, each as "`cosmic.m` (why)", best first: those whose name, or
--- last part, is an edit or two from the name's, those with the most functions that take a parameter named its last part,
--- those that export a function named it, then those whose summary holds it. None where `name` is not `cosmic.*` or the docs cannot be read. `docs` stands in for
--- the binary's, for a test.
function StandardMeant.of(name: string, docs?: StandardMeant.Docs): {string}
  local out: mut {string} = {}
  local asked = name:match("^cosmic%.([%w_.]+)$")
  if asked == nil then return out end
  local rest = asked:lower()
  local last = rest:match("[%w_]+$") or rest
  local held = docs or binary_docs()
  if held == nil then return out end
  local named: mut {string: boolean} = {}
  local function put(module: string, why: string)
    if named[module] == nil and #out < MOST then
      named[module] = true
      out[#out + 1] = "`" .. module .. "` (" .. why .. ")"
    end
  end
  local summaries: mut {string: string} = {}
  local modules: mut {string} = {}
  for _, s in ipairs(held.index) do
    if s.module:match("^cosmic%.[%w_.]+$") ~= nil and s.closed == "" and TOOLING[s.module] == nil then
      summaries[s.module] = s.text
      modules[#modules + 1] = s.module
    end
  end
  table.sort(modules)
  local function limit(word: string): integer
    return if #word <= 4 then 1 else 2 end
  end
  for _, module in ipairs(modules) do
    local own = module:sub(8)
    local own_last = own:match("[%w_]+$") or own
    if NearNames.distance(rest, own, limit(rest)) <= limit(rest) or
        (own ~= own_last and NearNames.distance(last, own_last, limit(last)) <= limit(last)) then
      put(module, about(summaries[module] or ""))
    end
  end
  -- The modules most of whose functions take a parameter of the name (`cosmic.path`: `Fs.basename(path)`).
  local taking: mut {string: mut {string}} = {}
  local seen: mut {string: boolean} = {}
  for _, row in ipairs(held.takes(last)) do
    local module, symbol = row[1] or "", row[2] or ""
    local short = symbol:match("[%w_]+$") or symbol
    if summaries[module] ~= nil and seen[module .. " " .. short] == nil then
      seen[module .. " " .. short] = true
      local list = taking[module] or {}
      list[#list + 1] = short
      taking[module] = list
    end
  end
  local takers: mut {string} = {}
  for module, list in pairs(taking) do
    if #list >= TAKERS then takers[#takers + 1] = module end
  end
  table.sort(takers, function(a: string, b: string): boolean
    local na, nb = #(taking[a] or {}), #(taking[b] or {})
    if na ~= nb then return na > nb end
    return a < b
  end)
  for i, module in ipairs(takers) do
    if i <= TAKING then
      local list = taking[module] or {}
      table.sort(list)
      local shown: mut {string} = {}
      for j = 1, math.min(#list, SHOWN) do shown[#shown + 1] = list[j] end
      put(module, plural.count(#list, "function") .. " take a `" .. last .. "`: " .. table.concat(shown, ", ") ..
          (if #list > SHOWN then ", ..." else "" end))
    end
  end
  for _, row in ipairs(held.exact(last)) do
    local module, symbol = row[1] or "", row[2] or ""
    if summaries[module] ~= nil and symbol == last then put(module, "has `" .. symbol .. "`") end
  end
  for _, module in ipairs(modules) do
    local text = summaries[module] or ""
    if (" " .. text:lower() .. " "):find("[^%w_]" .. last .. "[^%w_]") ~= nil then
      put(module, about(text))
    end
  end
  return out
end

--- Has [`StandardMeant.of`] read `docs` in this process from now on, in place of the binary's: for a test, whose store
--- withholds them.
function StandardMeant.read_from(docs: StandardMeant.Docs)
  read.done = true
  read.docs = docs
end

--- `meant`, and where it names nothing for a `cosmic.*` name, [`StandardMeant.of`] it, read from `docs` where given.
function StandardMeant.wrap(meant: StandardMeant.Meant, docs?: StandardMeant.Docs): StandardMeant.Meant
  return function(name: string, file: string): {string}
    local found = meant(name, file)
    if #found > 0 then return found end
    return StandardMeant.of(name, docs)
  end
end

return StandardMeant
