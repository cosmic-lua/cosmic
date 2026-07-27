--- Code formatter for Teal and Lua files.
--- Produces deterministic, consistently-indented output while preserving
--- all information including comments. Uses the Teal lexer for tokenization
--- and parser for syntax validation.

local tl = require("tl")

local rules = require("cosmic.format.rules")

--- A formatting issue (syntax error preventing formatting).
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string
end

--- Result from formatting a file.
local record FormatResult
  ok: boolean
  code: string
  errors: {Issue}
end

-- An item in the output stream: either a token or a comment.
local record Item is rules.Item
  -- y/x/tk/kind come from the rules.Item interface.
  _newlines: integer -- cached newline count for multiline tokens
  _tight_before: boolean -- render with no space before (type-param lists)
end

--- Mark type-parameter lists (`function<T>(`, `function name<K, V>(`) so
--- the spacing pass renders them tightly; needs_space alone cannot tell
--- `f<T>(` from a `<` comparison in its four-token window.
local function mark_type_params(items: {Item})
  for i, item in ipairs(items) do
    if item.kind == "keyword" and item.tk == "function" then
      local j = i + 1
      if items[j] and items[j].kind == "identifier" then j = j + 1 end
      if items[j] and items[j].tk == "<" then
        local k = j + 1
        local depth = 1
        while items[k] and depth > 0 do
          if items[k].tk == "<" then
            depth = depth + 1
          elseif items[k].tk == ">" then
            depth = depth - 1
          end
          k = k + 1
        end
        if depth == 0 and items[k] and items[k].tk == "(" then
          for m = j, k do
            local it = items[m]
            if m == j or it.tk == ">" or m == k
            or (items[m - 1] and items[m - 1].tk == "<") then
              it._tight_before = true
            end
          end
        end
      end
    end
  end
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

--- Determine the language mode from a filename.
local function detect_lang(filename: string): string
  if filename and filename:match("%.tl$") then
    return "tl"
  end
  return "lua"
end

--- Build a flat, position-sorted list of items from the token stream.
--- Extracts comments from tokens and interleaves them by position.
local function build_items(tokens: {tl.Token}): {Item}
  local items: {Item} = {}

  for _, token in ipairs(tokens) do
    if token.comments then
      for _, raw_c in ipairs(token.comments) do
        local c = raw_c as {string: any} -- cast: from any
        items[#items + 1] = {
          y = c["y"] as integer, -- cast: from any
          x = c["x"] as integer, -- cast: from any
          tk = c["text"] as string, -- cast: from any
          kind = "comment",
        }
      end
    end

    if token.kind ~= "$EOF$" then
      items[#items + 1] = {
        y = token.y,
        x = token.x,
        tk = token.tk,
        kind = token.kind,
      }
    end
  end

  return items
end

--- Format source code.
--- @param input string The source code to format
--- @param filename string The filename (for error messages and language detection)
--- @return FormatResult Result with ok status, formatted code, and any errors
local function format(input: string, filename: string): FormatResult
  filename = filename or "<input>"
  local lang = detect_lang(filename)

  local tokens, lex_errs = tl.lex(input, filename)

  if lex_errs and #lex_errs > 0 then
    local errors: {Issue} = {}
    for _, e in ipairs(lex_errs) do
      if e.msg then
        errors[#errors + 1] = {
          file = e.filename or filename,
          line = e.y as integer or 0, -- cast: tl declares number
          column = e.x as integer or 0, -- cast: tl declares number
          message = e.msg,
          severity = "error",
        }
      end
    end
    if #errors > 0 then
      return {ok = false, code = nil, errors = errors}
    end
  end

  local parse_errs: {tl.Error} = {}
  tl.parse_program(tokens, parse_errs, filename, lang)

  if #parse_errs > 0 then
    local errors: {Issue} = {}
    for _, e in ipairs(parse_errs) do
      if e.msg then
        errors[#errors + 1] = {
          file = e.filename or filename,
          line = e.y as integer or 0, -- cast: tl declares number
          column = e.x as integer or 0, -- cast: tl declares number
          message = e.msg,
          severity = "error",
        }
      end
    end
    return {ok = false, code = nil, errors = errors}
  end

  local items = build_items(tokens)
  if #items == 0 then
    return {ok = true, code = "", errors = {}}
  end

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

  -- Whether the previous line left this one in type position (`as` or
  -- `:` last), which is the only cross-line fact the indent rules need.
  local continues_type = false

  for _, line in ipairs(lines) do
    local gap = line.y - prev_y
    if prev_y > 0 and gap > 1 then
      out[#out + 1] = "\n"
    end

    local pre_change, post_change =
    rules.compute_indent_change(line.items, continues_type)
    continues_type = rules.opens_type_position(line.items)

    indent = math.max(0, indent + pre_change)

    if indent > 0 then
      out[#out + 1] = string.rep(indent_str, indent)
    end

    mark_type_params(line.items)

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
          out[#out + 1] = " "
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
              out[#out + 1] = "\n"
              if indent > 0 then
                out[#out + 1] = string.rep(indent_str, indent)
              end
              out[#out + 1] = cl:match("^%s*(.*)$")
            else
              out[#out + 1] = cl
            end
          end
        else
          out[#out + 1] = item.tk:match("^(.-)%s*$")
        end
      else
        out[#out + 1] = item.tk
      end

      prev_prev_item = prev_item
      prev_item = item
    end

    out[#out + 1] = "\n"

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

  return {ok = true, code = table.concat(out), errors = {}}
end

--- Format a file from disk.
--- @param input_path string Path to the file to format
--- @return FormatResult Result with ok status, formatted code, and any errors
local function format_file(input_path: string): FormatResult
  local f, open_err = io.open(input_path, "r")
  if not f then
    return {
      ok = false,
      code = nil,
      errors = {{
          file = input_path,
          line = 0,
          column = 0,
          message = "cannot open file: " .. (open_err or "unknown error"),
          severity = "error",
        }},
    }
  end
  local content = f:read("*a")
  f:close()

  return format(content, input_path)
end

--- Format issues for human-readable output.
local function format_issues(issues: {Issue}): string
  local out: {string} = {}
  for _, issue in ipairs(issues) do
    out[#out + 1] = string.format("%s:%d:%d: %s: %s",
      issue.file,
      issue.line,
      issue.column,
      issue.severity,
      issue.message)
  end
  return table.concat(out, "\n")
end

local record FormatModule
  format: function(input: string, filename: string): FormatResult
  format_file: function(input_path: string): FormatResult
  format_issues: function(issues: {Issue}): string
end

local M: FormatModule = {
  format = format,
  format_file = format_file,
  format_issues = format_issues,
}

return M
