--- Format a parsed source snapshot with parser-owned syntax roles.
--- The emitter retains Cosmic house style and validates the emitted lexical
--- stream before returning the parsed output snapshot.

local tl = require("tl")

local source = require("cosmic.ast.source")
local rules = require("cosmic.format.rules")
local preserve = require("cosmic.format.preserve")
local structure = require("cosmic.format.structure")

--- A formatting issue (syntax error preventing formatting).
-- One Issue record and one renderer for the whole toolchain: the
-- checker's (cosmic.teal), which this module reuses instead of keeping
-- a nominally-incompatible twin.
local teal = require("cosmic.teal")

local type Issue = teal.Issue
local type Snapshot = source.Snapshot
local type ParseResult = source.ParseResult

--- Result from formatting a file.
local record FormatResult
  ok: boolean
  --- nil when ok is false — the type admits it.
  code: string | nil
  errors: {Issue}
end

-- An item in the output stream: either a token or a comment.
local record Item is rules.Item
  -- y/x/tk/kind come from the rules.Item interface.
  _newlines: integer -- cached newline count for multiline tokens
  _tight_before: boolean -- render with no space before (type-param lists)
end

--- Count newlines in a string using plain find (faster than gmatch for counting).
local function count_newlines(s: string): integer
  local count = 0
  local pos = 1
  while true do
    local found, _ = s:find("\n", pos, true)
    if not found then break end
    count = count + 1
    pos = found + 1
  end
  return count
end

--- Return true if item is a long bracket string (e.g. [[...]] or [=[...]=]).
local function is_long_string(item: Item): boolean
  return item.kind == "string" and item.tk:sub(1, 1) == "[" and item.tk:sub(-1) == "]"
end

--- Build the ordered token/comment items consumed by the emitter.
local function build_items(tokens: {tl.Token}): {Item}
  local items: {Item} = {}

  for _, token in ipairs(tokens) do
    if token.comments then
      for _, c in ipairs(token.comments) do
        items[#items + 1] = {
          y = c.y,
          x = c.x,
          tk = c.text,
          kind = "comment",
        }
      end
    end

    if token.kind ~= "$EOF$" then
      items[#items + 1] = {y = token.y, x = token.x, tk = token.tk, kind = token.kind}
    end
  end

  return items
end

--- Convert structured snapshot parse issues to the formatter's issue type.
local function source_errors(result: ParseResult, filename: string,
    prefix?: string): FormatResult
  local errors: {Issue} = {}
  for _, e in ipairs(result.issues) do
    errors[#errors + 1] = {
      file = filename,
      line = e.line,
      column = e.column,
      message = (prefix or "") .. e.message,
      severity = "error",
    }
  end
  return {ok = false, code = nil, errors = errors}
end

--- Format an already parsed source snapshot without parsing its input again.
--- Output validation still lexes and parses the emitted candidate.
local function format_snapshot(snapshot: Snapshot): FormatResult, Snapshot | nil
  local filename = snapshot.name
  local lang = snapshot.lang
  local tokens = snapshot.tokens

  if #snapshot.issues > 0 then
    local errors: {Issue} = {}
    for _, e in ipairs(snapshot.issues) do
      errors[#errors + 1] = {
        file = filename,
        line = e.line,
        column = e.column,
        message = e.message,
        severity = "error",
      }
    end
    return {ok = false, code = nil, errors = errors}, nil
  end

  local items = build_items(tokens)
  if #items == 0 then
    return {ok = true, code = "", errors = {}}, snapshot
  end
  structure.annotate(snapshot, items)

  local out: {string} = {}
  local indent = 0
  local indent_str = "  "

  -- Preserve shebang
  local start_idx = 1
  if #items > 0 and items[1].kind == "hashbang" then
    out[#out + 1] = items[1].tk
    if not items[1].tk:match("\n$") then
      out[#out + 1] = "\n"
    end
    start_idx = 2
  end

  -- Group items by source line
  local record Line
    items: {Item}
    y: integer
  end

  local lines: {Line} = {}
  local cur_line: Line = nil
  local cur_line_end_y: integer = 0

  for i = start_idx, #items do
    local item = items[i]
    if cur_line == nil or (item.y ~= cur_line.y and item.y ~= cur_line_end_y) then
      cur_line = {items = {}, y = item.y}
      cur_line_end_y = item.y
      lines[#lines + 1] = cur_line
    end
    cur_line.items[#cur_line.items + 1] = item

    if is_long_string(item) then
      item._newlines = count_newlines(item.tk)
      if item._newlines > 0 then
        cur_line_end_y = item.y + item._newlines
      end
    end
  end

  -- Merge pass: absorb lines starting with closing punctuation or
  -- continuation operators after a long string.
  local merged: {Line} = {}
  for _, line in ipairs(lines) do
    local prev = merged[#merged]
    if prev then
      local last_prev = prev.items[#prev.items]
      local first_cur = line.items[1]
      if last_prev and first_cur
      and is_long_string(last_prev)
      and (first_cur.tk == ")" or first_cur.tk == "]" or first_cur.tk == "}"
        or first_cur.tk == "," or first_cur.tk == "..") then
        for _, item in ipairs(line.items) do
          prev.items[#prev.items + 1] = item
        end
      else
        merged[#merged + 1] = line
      end
    else
      merged[#merged + 1] = line
    end
  end
  lines = merged

  -- Emit each line with proper indentation
  local prev_y = 0
  if start_idx == 2 and #items > 0 then
    prev_y = items[1].y
  end

  -- One line's fragments, buffered and concatenated once per line, so
  -- `out` grows with lines rather than with tokens. The table is reused
  -- across lines and only `bn` resets: the concat below is bounded by
  -- `bn`, so entries left over from a longer previous line are never
  -- read.
  local buf: {string} = {}
  local bn = 0

  for _, line in ipairs(lines) do
    local gap = line.y - prev_y
    if prev_y > 0 and gap > 1 then
      out[#out + 1] = "\n"
    end
    bn = 0

    local pre_change, post_change = rules.compute_indent_change(line.items)

    indent = math.max(0, indent + pre_change)

    if indent > 0 then
      bn = bn + 1
      buf[bn] = string.rep(indent_str, indent)
    end

    local prev_prev_item: Item = nil
    local prev_item: Item = nil
    for item_idx, item in ipairs(line.items) do
      if prev_item then
        local next_item: Item = nil
        if item_idx < #line.items then
          next_item = line.items[item_idx + 1]
        end
        if not item._tight_before
        and rules.needs_space(prev_prev_item, prev_item, item, next_item) then
          bn = bn + 1
          buf[bn] = " "
        end
      end

      if item.kind == "comment" then
        if rules.is_long_comment(item.tk) then
          local comment_lines: {string} = {}
          for cl in item.tk:gmatch("[^\n]*") do
            comment_lines[#comment_lines + 1] = cl
          end
          for ci, cl in ipairs(comment_lines) do
            if ci > 1 then
              bn = bn + 1
              buf[bn] = "\n"
              if indent > 0 then
                bn = bn + 1
                buf[bn] = string.rep(indent_str, indent)
              end
              bn = bn + 1
              buf[bn] = cl:match("^%s*(.*)$")
            else
              bn = bn + 1
              buf[bn] = cl
            end
          end
        else
          bn = bn + 1
          buf[bn] = item.tk:match("^(.-)%s*$")
        end
      else
        bn = bn + 1
        buf[bn] = item.tk
      end

      prev_prev_item = prev_item
      prev_item = item
    end

    bn = bn + 1
    buf[bn] = "\n"

    out[#out + 1] = table.concat(buf, "", 1, bn)

    indent = math.max(0, indent + post_change)

    local effective_end_y = line.y
    for _, item in ipairs(line.items) do
      local end_y = item.y
      if item.kind == "comment" and rules.is_long_comment(item.tk) then
        if not item._newlines then
          item._newlines = count_newlines(item.tk)
        end
        end_y = item.y + item._newlines
      elseif is_long_string(item) then
        end_y = item.y + (item._newlines or 0)
      end
      if end_y > effective_end_y then
        effective_end_y = end_y
      end
    end
    prev_y = effective_end_y
  end

  local code = table.concat(out)

  -- Validate what was emitted, not only what was accepted as input. A
  -- spacing decision can form a different token (`- -1` used to become
  -- the comment `--1`) and valid-but-different output can still parse.
  local output = source.inspect(code, filename, lang)
  if not output.snapshot then
    return source_errors(output, filename, "formatter emitted invalid source: "), nil
  end
  local output_snapshot = output.snapshot

  local same, why = preserve.equivalent(tokens, output_snapshot.tokens)
  if not same then
    return {
      ok = false,
      code = nil,
      errors = {{
          file = filename,
          line = 0,
          column = 0,
          message = "formatter changed the lexical stream: " .. why,
          severity = "error",
        }},
    }, nil
  end

  return {ok = true, code = code, errors = {}}, output_snapshot
end

local record FormatSnapshotModule
  type Issue = Issue
  type FormatResult = FormatResult
  type Snapshot = Snapshot
  format_snapshot: function(snapshot: Snapshot): FormatResult, Snapshot | nil
end

local M: FormatSnapshotModule = {
  format_snapshot = format_snapshot,
}

return M
