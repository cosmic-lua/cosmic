--- Saying where a failure happened.
---
--- A failure travels as a value: `T | nil, string` for a value and
--- `boolean, string` for an effect. This is for the place that reports
--- one to a person, where the message alone is not enough.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local errors = require("cosmic.internal.errors")

local record Errors
end

--- Words too common to mean anything on their own: sharing one proves
--- nothing about two messages being related ("Not a directory" shares
--- "not" with anything that says "is not available"). Deliberately
--- short: the English function words cosmic's own messages use, not a
--- general-purpose list.
local stopwords: {string:boolean} = {}
for _, word in ipairs({
  "a", "an", "the", "is", "are", "was", "were", "be",
  "to", "of", "in", "on", "at", "for", "and", "or",
  "not", "no", "this", "that", "it", "its", "as", "by",
  "with", "from", "own",
}) do
  stopwords[word] = true
end

--- The significant words of `text`, in order: its runs of ASCII letters
--- and digits, lowercased, less `stopwords`.
local function significant(text: string): {string}
  local found: {string} = {}
  for word in text:gmatch("[%w]+") do
    local lower = word:lower()
    if not stopwords[lower] then
      found[#found + 1] = lower
    end
  end
  return found
end

--- `message`'s significant words as an FTS5 query on the `message` column
--- matching a catalog row that shares any of them, each word quoted so
--- it reads as a string, not syntax; nil when it has none. The column
--- matters: `catalog_fts` also indexes the guidance prose, where an
--- ordinary word would match rows about something else. A catalog row's
--- message is a literal prefix of a real one, so it is the message's
--- words that are sought in the row's, and `bm25` ranks a row sharing
--- more, or rarer, words first. At most sixteen words, and 1024 bytes.
local function catalog_query(message: string): string | nil
  local terms: {string} = {}
  local used = #"message: ()"
  for _, word in ipairs(significant(message)) do
    if #terms == 16 then
      break
    end
    local term = '"' .. word .. '"'
    local needed = #term + (#terms > 0 and 4 or 0)
    if used + needed >= 1024 then
      break
    end
    terms[#terms + 1] = term
    used = used + needed
  end
  if #terms == 0 then
    return nil
  end
  return "message: (" .. table.concat(terms, " OR ") .. ")"
end

--- How many distinct significant words of `message` are whole words of
--- `candidate`, case aside: the check on the one row the query ranked
--- first, since bm25 alone does not tell a real match from one shared
--- ordinary word ("files", found by hand). Distinct and whole, because a
--- word said three times is one word, and "os" is not in "cosmic".
local function shared_words(message: string, candidate: string): integer
  local present: {string:boolean} = {}
  for word in candidate:gmatch("[%w]+") do
    present[word:lower()] = true
  end
  local counted: {string:boolean} = {}
  local shared = 0
  for _, word in ipairs(significant(message)) do
    if present[word] and not counted[word] then
      counted[word] = true
      shared = shared + 1
    end
  end
  return shared
end

--- The lines printed for a catalog row's guidance `text`: the first
--- opening with `head`, which says where the words come from, and every
--- `@param`/`@return` line left out, since those describe the signature,
--- not the failure.
local function guidance_lines(head: string, text: string): string
  local lines: {string} = {}
  local at = 1
  while at <= #text do
    local newline = text:find("\n", at, true)
    local line = text:sub(at, (newline or #text + 1) - 1)
    if line:sub(1, 1) ~= "@" then
      if #lines == 0 then
        lines[1] = "cosmic: " .. head .. ": " .. line
      else
        lines[#lines + 1] = "cosmic:   " .. line
      end
    end
    if newline == nil then
      break
    end
    at = newline + 1
  end
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The best catalog row of `handle` for `message`, as the lines that
--- print its guidance, or nil when it has none: no catalog, no row
--- sharing two or more significant words with it, or no guidance on the
--- row it shares them with.
local function guidance_in(handle: Sqlite.Handle, message: string): string | nil
  local query = catalog_query(message)
  if query == nil then
    return nil
  end
  local rows, _ = Sqlite.text_rows(handle,
    "SELECT coalesce(catalog.text, (SELECT d.text FROM main.docs d " ..
    "WHERE d.module = catalog.module AND " ..
    "d.source_symbol = catalog.symbol)), " ..
    "catalog.message, catalog.symbol, catalog.file, catalog.line " ..
    "FROM main.catalog_fts JOIN main.catalog " ..
    "ON catalog.id = catalog_fts.rowid " ..
    "WHERE catalog_fts MATCH ?1 ORDER BY bm25(catalog_fts) LIMIT 1",
    { { text = query } })
  if rows == nil or #rows == 0 then
    return nil
  end
  local row = rows[1]
  local text, candidate, symbol, file = row[1], row[2], row[3], row[4]
  if text == "" or shared_words(message, candidate) < 2 then
    return nil
  end
  local line = math.tointeger(tonumber(row[5])) or 0
  local head: string
  if line > 0 then
    head = symbol .. " (" .. file .. ":" .. tostring(line) .. ")"
  else
    head = symbol .. " (" .. file .. ")"
  end
  return guidance_lines(head, text)
end

--- What cosmic says beneath an uncaught error's `message`, one
--- `cosmic: ` line per line: the guidance the first database in search
--- order (a project's own ahead of the binary's) holds for the error it
--- matches, the doc comment of the function the message came from, or
--- nil when none matches it. The core prints it for an error nothing
--- caught.
function Errors.guidance(message: string): string | nil
  for _, handle in ipairs(Store.databases()) do
    local found = guidance_in(handle, message)
    if found ~= nil then
      return found
    end
  end
  return nil
end

--- The call stack as text, with `message` at the top when one is given.
--- `level` says how many frames to skip; 1, the default, is the caller.
function Errors.trace(message?: string, level?: integer): string
  return errors.trace(message, level or 1)
end

return Errors
