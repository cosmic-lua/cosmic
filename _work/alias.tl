--- A legible, derived display for a board item's id — never stored,
--- computed fresh on every render and every input.
---
--- Same-week KSUIDs share their LEADING characters (creation order is
--- lexicographic order: live-board evidence has three items reading
--- 3IVLEO8M, 3IVUGuv6, 3IVRNCFB side by side), and base62's l/1/I and
--- O/0 lookalikes make even the distinguishing tail hard to read back.
--- The alias sidesteps both: Crockford base32 (no I, L, O, U — nothing
--- reads as anything else) over the first 40 bits of the id's SHA-256
--- hash, unrelated to the id's own characters, chunked into two groups
--- of four. `resolve` accepts it back with the usual Crockford
--- folding, so a session can read one off a render and retype it.
local hash = require("cosmic.hash")
local item = require("_work.item")

local ALPHABET < const > = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local VALUE_OF: {string: integer} = {}
for i = 1, #ALPHABET do
  VALUE_OF[ALPHABET:sub(i, i)] = i - 1
end

--- Render an 8-character code as two hyphenated 4-char chunks — the
--- one shape both the alias and a chunked id8 render share.
--- @param s string Exactly 8 characters
--- @return string "XXXX-XXXX"
local function chunk(s: string): string
  return s:sub(1, 4) .. "-" .. s:sub(5, 8)
end

--- The alias: Crockford base32 over the first 5 bytes (40 bits) of
--- sha256(id), chunked. Pure and deterministic, so it is safe to
--- derive on every render and every input instead of storing it.
--- @param id string An item id
--- @return string The chunked alias, e.g. "Q4TX-9GMD"
local function of(id: string): string
  local digest = hash.sha256_hex(id)
  local n = 0
  for i = 1, 9, 2 do
    local byte = math.tointeger(tonumber(digest:sub(i, i + 1), 16)) or 0
    n = (n << 8) | byte
  end
  local out: {string} = {}
  for shift = 35, 0, -5 do
    local idx = (n >> shift) & 0x1f
    out[#out + 1] = ALPHABET:sub(idx + 1, idx + 1)
  end
  return chunk(table.concat(out))
end

--- Fold input the way Crockford decoding does: case-insensitive,
--- hyphens ignored, the visually-ambiguous letters read as the digits
--- they are mistaken for.
--- @param input string What a session typed
--- @return string The folded, hyphen-free form
local function fold(input: string): string
  return (input:upper():gsub("%-", ""):gsub("[IL]", "1"):gsub("O", "0"))
end

--- Whether input has an alias's shape: 8 Crockford characters (after
--- folding), one optional hyphen — so a caller can tell an alias
--- attempt from an id prefix before asking `resolve` to search.
--- @param input string Candidate input
--- @return boolean True when it has alias shape
local function is_alias_shape(input: string): boolean
  local s = fold(input)
  if #s ~= 8 then
    return false
  end
  for i = 1, #s do
    if VALUE_OF[s:sub(i, i)] == nil then
      return false
    end
  end
  return true
end

--- Resolve an alias against every item's derived alias, folded and
--- compared case-insensitively. Refuses on zero matches and — astro-
--- nomically unlikely, checked anyway — on more than one, naming the
--- colliding ids.
--- @param all {item.Item} Every item
--- @param input string What a session typed
--- @return string | nil The matching item's id
--- @return string Error message
local function resolve(all: {item.Item}, input: string): string | nil, string
  local folded = fold(input)
  local matches: {string} = {}
  for _, it in ipairs(all) do
    if fold(of(it.id)) == folded then
      matches[#matches + 1] = it.id
    end
  end
  if #matches == 0 then
    return nil, ("no item matches alias %s"):format(input)
  end
  if #matches > 1 then
    return nil, ("%s is ambiguous: %s"):format(input, table.concat(matches, " "))
  end
  return matches[1]
end

local record alias
  of: function(id: string): string
  chunk: function(s: string): string
  is_alias_shape: function(input: string): boolean
  resolve: function(all: {item.Item}, input: string): string | nil, string
end

local M: alias = {
  of = of,
  chunk = chunk,
  is_alias_shape = is_alias_shape,
  resolve = resolve,
}

return M
