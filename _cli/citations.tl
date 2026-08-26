--- Documentation that cites the tree by `file:line` must cite a line
--- that is really there.
---
--- The design documents under `docs/design/` carry their value in
--- quoted citations: the prototype that measured a census is thrown
--- away by construction, so a reader's only check on a class count is
--- the two or three sites the document quotes. A quote that has drifted
--- off its line, or a path that was renamed away, silently turns that
--- evidence into fiction.
---
--- Two shapes are checked, each at the strength it admits. An INLINE
--- reference is a whole backticked span that is nothing but
--- `<path>:<line>` (or a `<line>-<line>` range); it pins a position, so
--- the position is what is checked. A FENCED reference is a
--- `-- <path>:<line>` comment as a code block's first line, followed by
--- the quoted source; that one also pins TEXT, so the text is compared
--- too.
---
--- A citation is a claim about the working tree unless its document
--- says otherwise. A document that opens with a `Measured against
--- `<sha>`` line is a SNAPSHOT of that commit: its positions describe a
--- tree this check cannot read — there is no `git` in the lint gate, by
--- the same rule that makes `lint_sources` the model's file set rather
--- than `git ls-files`' — so they are left unjudged. Its PATHS are
--- still checked, because a file renamed away is a citation no reader
--- can follow whichever commit it was measured at.

local fs = require("cosmic.fs")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Citations into the build output directory are skipped: those files
--- are generated, legitimately absent from a checkout, and every one of
--- them in the tree today is correct as written. Nothing else is
--- skipped — failing open on an unresolvable path would miss exactly
--- the rename this check exists to catch.
local GENERATED_PREFIX < const > = "o/"

--- A citation's path and the line span it names.
local record Citation
  path: string
  first: integer
  last: integer
  --- The whole text as the document wrote it, for the diagnostic.
  text: string
end

--- `s` without leading or trailing whitespace.
--- @param s string The raw text
--- @return string The trimmed text
local function trim(s: string): string
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- A `%d+` capture as an integer. The pattern that produced `s` admits
--- nothing else, so the fallbacks are unreachable and exist only to
--- keep the result a plain `integer`.
--- @param s string The captured digits
--- @return integer The value
local function to_int(s: string): integer
  return math.tointeger(tonumber(s) or 0) or 0
end

--- The fence marker a line opens or closes a code block with.
---
--- Infallible on purpose: "" means the line is not a fence, which keeps
--- this a plain tuple rather than a fallible return with an unused
--- error slot.
--- @param line string The document line
--- @return string The fence character, or "" when this is not a fence
--- @return integer How many of it, 0 when this is not a fence
local function fence_marker(line: string): string, integer
  local ticks = line:match("^%s*(`+)")
  if ticks and #ticks >= 3 then
    return "`", #ticks
  end
  local tildes = line:match("^%s*(~+)")
  if tildes and #tildes >= 3 then
    return "~", #tildes
  end
  return "", 0
end

--- The citation a whole backticked span is, or nil when it is not one.
---
--- The span must be a citation ENTIRELY. A span that merely contains a
--- path — a shell command, a grep pattern — is prose, and matching
--- inside it would flag text no reader reads as a citation.
--- @param span string The text between two backticks
--- @return Citation|nil The citation, or nil when the span is not one
local function inline_citation(span: string): Citation | nil
  local path, first, last = span:match("^([%w_%-%./]+%.[%w_%-]+):(%d+)%-(%d+)$")
  if not path then
    path, first = span:match("^([%w_%-%./]+%.[%w_%-]+):(%d+)$")
    last = first
  end
  if not path then
    return nil
  end
  return {
    path = path,
    first = to_int(first),
    last = to_int(last),
    text = span,
  }
end

--- The citation a fenced block's header comment is, or nil.
--- @param line string The block's first content line
--- @return Citation|nil The citation, or nil when the line is not one
local function fenced_citation(line: string): Citation | nil
  local path, at = line:match("^%-%- ([%w_%-%./]+):(%d+)$")
  if not path then
    return nil
  end
  local n = to_int(at)
  return {path = path, first = n, last = n, text = path .. ":" .. at}
end

--- The lines of a cited source file, read at most once per path.
--- @param path string The cited path
--- @param cache {string: {string}} Per-call memo, keyed by path
--- @return {string} The file's lines; empty when it cannot be read
local function source_lines(path: string, cache: {string: {string}}): {string}
  local hit = cache[path]
  if hit then
    return hit
  end
  local out: {string} = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      out[#out + 1] = line
    end
    f:close()
  end
  cache[path] = out
  return out
end

--- Build one diagnostic.
--- @param file string The citing document
--- @param line integer Its line, 1-based
--- @param col integer Its column, 1-based
--- @param message string The body, already formatted
--- @return Diagnostic
local function finding(file: string, line: integer, col: integer,
    message: string): Diagnostic
  return {file = file, line = line, col = col, rule = "doc-citation",
    message = message}
end

--- Check one citation's path, and — for a document that is not a
--- snapshot — that its line span is within that path.
--- @param file string The citing document
--- @param at integer The document line the citation is on
--- @param col integer The column it starts at
--- @param cite Citation The citation
--- @param snapshot boolean Whether the document pins a past commit
--- @param cache {string: {string}} Per-call source memo
--- @param out {Diagnostic} Findings, appended to
--- @return boolean True when the citation resolved and may be quoted
local function check_one(file: string, at: integer, col: integer,
    cite: Citation, snapshot: boolean, cache: {string: {string}},
    out: {Diagnostic}): boolean
  if cite.path:sub(1, #GENERATED_PREFIX) == GENERATED_PREFIX then
    return false
  end
  if not fs.is_file(cite.path) then
    out[#out + 1] = finding(file, at, col, string.format(
        "%s:%d: citation `%s` names no file — a path that was renamed or"
        .. " deleted leaves the reader nothing to follow", file, at,
        cite.text))
    return false
  end
  if snapshot then
    return false
  end
  local lines = source_lines(cite.path, cache)
  if cite.last > #lines then
    out[#out + 1] = finding(file, at, col, string.format(
        "%s:%d: citation `%s` is past end of file (%s has %d lines)",
        file, at, cite.text, cite.path, #lines))
    return false
  end
  return true
end

--- Compare a fenced block's quote against the line it cites.
--- @param file string The citing document
--- @param at integer The document line the quote is on
--- @param cite Citation The block's header citation
--- @param quote string The quoted line, as the document wrote it
--- @param cache {string: {string}} Per-call source memo
--- @param out {Diagnostic} Findings, appended to
local function check_quote(file: string, at: integer, cite: Citation,
    quote: string, cache: {string: {string}}, out: {Diagnostic})
  local lines = source_lines(cite.path, cache)
  local want = trim(lines[cite.first] or "")
  local got = trim(quote)
  if want == got then
    return
  end
  out[#out + 1] = finding(file, at, 1, string.format(
      "%s:%d: the quoted line is not %s — document has `%s`, source has"
      .. " `%s`. Repoint the citation, or, if this document is a snapshot"
      .. " of a past commit, say so with a `Measured against ` line",
      file, at, cite.text, got, want))
end

--- Every `file:line` citation in one markdown document.
---
--- One pass over the lines, tracking fenced-block state, because all
--- three things this needs — whether a line is inside a block, whether
--- it is a block's first line, and whether the `Measured against`
--- sentence is prose or a quoted example — are answers only that state
--- can give.
--- @param file string Path, for the diagnostics
--- @param lines {string} The document's lines
--- @return {Diagnostic} One per unresolvable or mismatched citation
local function check_citations(file: string, lines: {string}): {Diagnostic}
  local snapshot = false
  local open_char, open_len = "", 0
  for _, line in ipairs(lines) do
    local char, len = fence_marker(line)
    if open_char ~= "" then
      if char == open_char and len >= open_len then
        open_char, open_len = "", 0
      end
    elseif char ~= "" then
      open_char, open_len = char, len
    elseif line:match("^Measured against `%x%x%x%x%x%x%x+`") then
      snapshot = true
    end
  end

  local out: {Diagnostic} = {}
  local cache: {string: {string}} = {}
  open_char, open_len = "", 0
  -- Set on the line after an opening fence, cleared once that line has
  -- been read: only a block's FIRST line can be a header comment.
  local at_block_start = false
  -- The header citation whose quote is still to come, and nil once it
  -- has been compared or the block has ended without one.
  local pending: Citation | nil = nil
  for i, line in ipairs(lines) do
    local char, len = fence_marker(line)
    if open_char ~= "" then
      if char == open_char and len >= open_len then
        open_char, open_len = "", 0
        at_block_start = false
        pending = nil
      elseif at_block_start then
        at_block_start = false
        local cite = fenced_citation(line)
        if cite and check_one(file, i, 1, cite, snapshot, cache, out) then
          pending = cite
        end
      elseif pending and trim(line) ~= "" then
        check_quote(file, i, pending, line, cache, out)
        pending = nil
      end
    elseif char ~= "" then
      open_char, open_len = char, len
      at_block_start = true
    else
      for span in line:gmatch("`([^`]+)`") do
        local cite = inline_citation(span)
        if cite then
          local col = line:find(span, 1, true) or 1
          check_one(file, i, col, cite, snapshot, cache, out)
        end
      end
    end
  end
  return out
end

local record CitationsModule
  check_citations: function(file: string, lines: {string}): {Diagnostic}
end

local M: CitationsModule = {
  check_citations = check_citations,
}

return M
