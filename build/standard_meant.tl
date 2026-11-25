--- What a `require` of a `cosmic.*` name that the binary has no module of may have meant, from the binary's docs: so
--- a refusal names the module to require, and the next try needs no lookup. The same words reach a program run with
--- `cosmic file.tl` and a snippet of `cosmic agent`, since both are checked by the one pipeline.
---
---     for _, m in ipairs(StandardMeant.of("cosmic.base64")) do print(m) end -- `cosmic.codec` (has `Codec.base64`)

local type Doc = require("cosmic.doc")

local record StandardMeant
  --- What [`StandardMeant.of`] reads of the docs: the summary of each module, and the rows a word names
  --- ([`Doc.exact`]).
  record Docs
    index: {Doc.Summary}
    --- The module and the symbol of each row the word names.
    exact: function(word: string): {{string}}
  end
end

-- The modules that are the tools' own, never a program's guess: those [`Host.modules`] leaves out too.
local TOOLING <const>: {string: boolean} = {
  ["cosmic.agent"] = true, ["cosmic.cli"] = true, ["cosmic.coverage"] = true, ["cosmic.doc"] = true,
  ["cosmic.entrypoint"] = true, ["cosmic.layout"] = true, ["cosmic.project"] = true, ["cosmic.removed"] = true,
  ["cosmic.store"] = true, ["cosmic.test"] = true,
}

-- At most this many modules are named.
local MOST <const> = 5

-- A module's words in a candidate are cut to this many bytes.
local ABOUT <const> = 70

--- How far apart `a` and `b` are by edits, up to `limit`: `limit + 1` for more.
local function distance(a: string, b: string, limit: integer): integer
  if math.abs(#a - #b) > limit then return limit + 1 end
  local previous: mut {integer} = {}
  for j = 0, #b do previous[#previous + 1] = j end
  for i = 1, #a do
    local row: mut {integer} = { i }
    for j = 1, #b do
      local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
      local best = math.min((previous[j] or 0) + cost, (previous[j + 1] or 0) + 1, (row[j] or 0) + 1)
      row[#row + 1] = best
    end
    previous = row
  end
  return previous[#b + 1] or (limit + 1)
end

--- `text` cut to [`ABOUT`] bytes at a space, `...` after it where it was longer.
local function about(text: string): string
  local one = text:gsub("%s+", " "):gsub("^ ", "")
  if #one <= ABOUT then return one end
  return (one:sub(1, ABOUT):gsub("%s%S*$", "")) .. "..."
end

--- The modules `name` (`cosmic.<word>`) may have meant, each as "`cosmic.m` (why)", best first: those whose own name is
--- an edit or two from the word, those that export a function or value named the word, then those whose summary holds
--- it. None where `name` is not `cosmic.*` or the docs cannot be read. `docs` stands in for the binary's, for a test.
function StandardMeant.of(name: string, docs?: StandardMeant.Docs): {string}
  local out: mut {string} = {}
  local word = name:match("^cosmic%.([%w_]+)$")
  if word == nil then return out end
  word = word:lower()
  if docs == nil then
    -- Read only on a refusal, so a program that is not refused loads no docs; a store that withholds them (a test's)
    -- raises, and names nothing.
    local read, held = pcall(function(): StandardMeant.Docs?
      local Docs = require("cosmic.doc")
      local Store = require("cosmic.store")
      local view, _ = Docs.view(Store.databases())
      if view == nil then return nil end
      local index, _ = Docs.index(view)
      if index == nil then return nil end
      return { index = index, exact = function(w: string): {{string}}
        local found, _ = Docs.exact(view, w)
        local rows: mut {{string}} = {}
        for _, e in ipairs(found or {}) do rows[#rows + 1] = { e.module, e.symbol } end
        return rows
      end }
    end)
    if not read or held == nil then return out end
    docs = held
  end
  local named: mut {string: boolean} = {}
  local function put(module: string, why: string)
    if named[module] == nil and #out < MOST then
      named[module] = true
      out[#out + 1] = "`" .. module .. "` (" .. why .. ")"
    end
  end
  local summaries: mut {string: string} = {}
  local modules: mut {string} = {}
  for _, s in ipairs(docs.index) do
    if s.module:match("^cosmic%.[%w_]+$") ~= nil and s.closed == "" and TOOLING[s.module] == nil then
      summaries[s.module] = s.text
      modules[#modules + 1] = s.module
    end
  end
  table.sort(modules)
  local limit = if #word <= 4 then 1 else 2 end
  for _, module in ipairs(modules) do
    if distance(word, module:sub(8), limit) <= limit then
      put(module, about(summaries[module] or ""))
    end
  end
  for _, row in ipairs(docs.exact(word)) do
    local module, symbol = row[1] or "", row[2] or ""
    if summaries[module] ~= nil and symbol == word then
      local short = module:match("[%w_]+$") or module
      put(module, "has `" .. short:sub(1, 1):upper() .. short:sub(2) .. "." .. symbol .. "`")
    end
  end
  for _, module in ipairs(modules) do
    local text = summaries[module] or ""
    if (" " .. text:lower() .. " "):find("[^%w_]" .. word .. "[^%w_]") ~= nil then
      put(module, about(text))
    end
  end
  return out
end

return StandardMeant
