--- A legible, derived display for a board item's id — never stored,
--- computed fresh on every render and every input.
---
--- Same-week KSUIDs share their LEADING characters (creation order is
--- lexicographic order), so the last 8 characters are what actually
--- distinguishes one item from its neighbors — and they are pure
--- entropy, and a literal substring of the id, so the rendered handle
--- greps item files, branch logs, and PR bodies directly. Measured
--- against the live board (`ls items/*.tl`), `id:sub(20)` is
--- collision-free across every item, exact and case-folded.
local item = require("_work.item")

--- Render an item's tail as two hyphenated 4-char chunks, wrapped in
--- guillemets so a reader can tell a handle from a word, a count, or
--- the `[full id]` bracket on sight.
--- @param id string A full item id (a 27-char KSUID)
--- @return string "«XXXX-XXXX»"
local function handle(id: string): string
  local t = id:sub(20)
  return "«" .. t:sub(1, 4) .. "-" .. t:sub(5, 8) .. "»"
end

--- Whether input has a tail's shape: 8 base62 characters, with at
--- most one hyphen, which — when present — sits right after the 4th
--- character, optionally wrapped in the guillemets a rendered handle
--- carries. So a caller can tell a tail attempt from an id prefix
--- before asking `resolve` to search.
--- @param input string Candidate input
--- @return boolean True when it has tail shape
local function is_tail_shape(input: string): boolean
  return input:match("^%w%w%w%w%-?%w%w%w%w$") ~= nil
  or input:match("^«%w%w%w%w%-?%w%w%w%w»$") ~= nil
end

--- Resolve a tail against every item's `id:sub(20)`. An exact match
--- is tried first; only when that finds none does a case-insensitive
--- match follow — retyping tolerance, safe because the folded space
--- is measured collision-free on the live board (see the module
--- doc). Refuses on zero matches or more than one AT EITHER STAGE,
--- naming the candidates' tails.
--- @param items {item.Item} Every item
--- @param input string What a session typed
--- @return string | nil The matching item's id
--- @return string Error message
local function resolve(items: {item.Item}, input: string): string | nil, string
  local normalized = (input:gsub("[«»%-]", ""))
  local exact_ids: {string} = {}
  local exact_tails: {string} = {}
  for _, it in ipairs(items) do
    if it.id:sub(20) == normalized then
      exact_ids[#exact_ids + 1] = it.id
      exact_tails[#exact_tails + 1] = it.id:sub(20)
    end
  end
  if #exact_ids == 1 then
    return exact_ids[1]
  end
  if #exact_ids > 1 then
    return nil, ("%s is ambiguous: %s"):format(input, table.concat(exact_tails, " "))
  end
  local folded = normalized:lower()
  local ci_ids: {string} = {}
  local ci_tails: {string} = {}
  for _, it in ipairs(items) do
    if it.id:sub(20):lower() == folded then
      ci_ids[#ci_ids + 1] = it.id
      ci_tails[#ci_tails + 1] = it.id:sub(20)
    end
  end
  if #ci_ids == 1 then
    return ci_ids[1]
  end
  if #ci_ids > 1 then
    return nil, ("%s is ambiguous: %s"):format(input, table.concat(ci_tails, " "))
  end
  return nil, ("no item matches tail %s"):format(input)
end

local record tail
  handle: function(id: string): string
  is_tail_shape: function(input: string): boolean
  resolve: function(items: {item.Item}, input: string): string | nil, string
end

local M: tail = {
  handle = handle,
  is_tail_shape = is_tail_shape,
  resolve = resolve,
}

return M
