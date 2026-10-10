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
--- more, or rarer, words first. At most sixteen words, and under 1024 bytes.
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
--- ordinary word such as "files". Distinct and whole, because a word
--- said three times is one word, and "os" is not in "cosmic".
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

--- What the catalog of the one database `handle` says beneath an
--- uncaught error's `message`, in the lines [`Errors.guidance`] prints: the
--- best row's guidance, or nil when it has none -- no catalog, no row
--- sharing two or more significant words with the message, or no
--- guidance on the row it shares them with. [`Errors.guidance`] asks each
--- database the store holds in turn.
function Errors.guidance_in(handle: Sqlite.Handle, message: string): string | nil
  -- TODO: a message Lua itself wrote shares two ordinary words with some
  -- doc comment and is shown that one's guidance, which has nothing to do
  -- with the failure: `print(t.path .. "x")` with `t` a `{string:string}`
  -- (`attempt to concatenate a nil value (field 'path')`) is shown
  -- `next_record`, and `module 'x' not found: ... no module 'x' in the
  -- store` is shown `locate`. Return nil here for a message whose first line is one of
  -- Lua's own `attempt to ...` or `module '...' not found` and leave
  -- [`Errors.hint`] to answer those; the catalog is for the messages cosmic's
  -- own code raises.
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

--- What to do about a runtime error whose `message` Lua itself wrote,
--- read from the message alone, as one line: nil for any other. The
--- message's first line must end with Lua's words, so one that only
--- quotes them (`wrapped: x.tl:3: attempt ...: more`) earns nothing.
---
--- `attempt to call a nil value (method 'set')`, in a Teal program the
--- checker passed, calls a method the value's type declares and the
--- value lacks. Either the value was made as a table literal, which
--- reaches the record's own table, where `function R:set` puts the
--- method, only as its metatable's `__index`; or R declares `set`
--- (an interface's method, a function-typed field) and nothing defines
--- it. The message tells the two apart by nothing, so both are named.
function Errors.hint(message: string): string | nil
  local method = message:match("^[^\n]*attempt to call a nil value %(method '([%a_][%w_]*)'%)\n") or
    message:match("^[^\n]*attempt to call a nil value %(method '([%a_][%w_]*)'%)$")
  if method == nil then
    return nil
  end
  return "'" .. method .. "' is nil on that value: either it was made as a table literal, " ..
    "which gets none of R's methods (make it with `setmetatable({ ... }, { __index = R })`), " ..
    "or R declares '" .. method .. "' and nothing defines `function R:" .. method .. "`"
end

--- What cosmic says beneath an uncaught error's `message`, one
--- `cosmic: ` line per line: the [`hint`] a message Lua wrote earns,
--- ahead of the catalog, whose rows share only common words ("call",
--- "value") with such a message; else the guidance the first database
--- in search order (a project's own ahead of the binary's) holds for
--- the error it matches, the doc comment of the function the message
--- came from; or nil when none matches it. The core prints it for an
--- error nothing caught.
function Errors.guidance(message: string): string | nil
  local hint = Errors.hint(message)
  if hint ~= nil then
    return "cosmic: hint: " .. hint .. "\n"
  end
  for _, handle in ipairs(Store.databases()) do
    local found = Errors.guidance_in(handle, message)
    if found ~= nil then
      return found
    end
  end
  return nil
end

--- The call stack as text, with `message` at the top when one is given.
--- `level` says how many frames to skip; 1, the default, is the caller.
function Errors.trace(message?: string, level?: integer): string
  -- The binding counts this frame as level 1.
  return errors.trace(message, (level or 1) + 1)
end

--- The call stack of coroutine `co` as text, from its top, with
--- `message` at the top when one is given. For a coroutine that raised,
--- it is where it raised, which `coroutine.resume` does not say (it
--- answers only the error) and which stays until the coroutine is
--- closed. One that returned, or was closed, has no frames: the text is
--- just `stack traceback:`. For the running coroutine the first frame is
--- [`trace_of`] itself, the caller's next.
-- TODO: unlike [`trace`], which starts at its caller, this starts at the
-- wrapper for the running coroutine, as the binding's [`trace_of`] takes no
-- level. Once `surface_trace_of` in core/surface.c takes one, pass 2 here
-- for the running coroutine and say the caller's frame is the first.
function Errors.trace_of(co: thread, message?: string): string
  return errors.trace_of(co, message)
end

return Errors
