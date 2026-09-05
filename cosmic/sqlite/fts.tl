--- Internal helper for cosmic.sqlite: FTS5 MATCH-expression builders
--- for free-typed text. Pure string functions — no `sqlite.Database`
--- dependency, so a caller can build a query string without a live
--- connection, or even an FTS5-enabled build, at all. Lives in its
--- own file so cosmic/sqlite/init.tl stays under the 500-line cap.

--- Quote one token for FTS5's query syntax, doubling an interior
--- quote: a bare token containing `AND`, `-`, `*`, `(`, `)`, `:`, or
--- `^` means something to FTS5's own parser, but a QUOTED token is
--- always a literal string match, whatever punctuation it holds.
--- @param tok string One whitespace-free token
--- @return string The quoted token
local function escape_token(tok: string): string
  return "\"" .. tok:gsub("\"", "\"\"") .. "\""
end

--- A free-typed query as an FTS5 MATCH expression requiring EVERY
--- token: quoted, space-joined — FTS5 ANDs space-separated terms by
--- default, so this reads "every word appears somewhere", never a
--- syntax error on a session's stray punctuation.
--- @param text string The typed query
--- @return string The MATCH expression; "" when text has no tokens
local function match_all(text: string): string
  local parts: {string} = {}
  for tok in (text or ""):gmatch("%S+") do
    parts[#parts + 1] = escape_token(tok)
  end
  return table.concat(parts, " ")
end

--- A free-typed query as an FTS5 MATCH expression requiring ANY
--- token: quoted, OR-joined — for a near-duplicate or fuzzy match
--- where every row sharing at least one word should surface, leaving
--- the actual discrimination to the caller's own ranking (e.g. bm25).
--- @param text string The candidate text
--- @return string The MATCH expression; "" when text has no tokens
local function match_any(text: string): string
  local parts: {string} = {}
  for tok in (text or ""):gmatch("%S+") do
    parts[#parts + 1] = escape_token(tok)
  end
  return table.concat(parts, " OR ")
end

local record fts
  escape_token: function(tok: string): string
  match_all: function(text: string): string
  match_any: function(text: string): string
end

local M: fts = {
  escape_token = escape_token,
  match_all = match_all,
  match_any = match_any,
}

return M
