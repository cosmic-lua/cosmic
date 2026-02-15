--- Code formatter for Teal and Lua files.
--- Produces deterministic, consistently-indented output while preserving
--- all information including comments. Uses the Teal lexer for tokenization
--- and parser for syntax validation.

local tl = require("tl")

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
local record Item
  y: integer -- source line
  x: integer -- source column
  tk: string -- text
  kind: string -- token kind (or "comment" for comments)
end

-- Block-opening keywords: indent after these.
local block_openers: {string: boolean} = {
  ["do"] = true,
  ["then"] = true,
  ["repeat"] = true,
  ["else"] = true,
}

-- Block-closing keywords: dedent before these.
local block_closers: {string: boolean} = {
  ["end"] = true,
  ["until"] = true,
}

-- Keywords that dedent then indent (same level as opening keyword).
local block_half_closers: {string: boolean} = {
  ["else"] = true,
  ["elseif"] = true,
}

-- Tokens that should NOT have a space before them.
local no_space_before: {string: boolean} = {
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
  [","] = true,
  [";"] = true,
  ["?"] = true,
}

-- Tokens that should NOT have a space after them.
local no_space_after: {string: boolean} = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  ["#"] = true,
}

-- Tokens after which `-` is unary (not binary subtraction).
local unary_minus_after: {string: boolean} = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  [","] = true,
  [";"] = true,
  ["="] = true,
  ["=="] = true,
  ["~="] = true,
  ["<"] = true,
  [">"] = true,
  ["<="] = true,
  [">="] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["//"] = true,
  ["%"] = true,
  ["^"] = true,
  [".."] = true,
  ["|"] = true,
  ["&"] = true,
  ["~"] = true,
  ["<<"] = true,
  [">>"] = true,
}

-- Keywords after which `-` is unary.
local unary_minus_after_kw: {string: boolean} = {
  ["return"] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["then"] = true,
  ["do"] = true,
  ["else"] = true,
  ["in"] = true,
}

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
    -- Emit attached comments before the token
    if token.comments then
      for _, raw_c in ipairs(token.comments) do
        local c = raw_c as {string: any}
        items[#items + 1] = {
          y = c["y"] as integer,
          x = c["x"] as integer,
          tk = c["text"] as string,
          kind = "comment",
        }
      end
    end

    -- Emit the token itself (skip EOF)
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

--- Check if an item is a block-opening keyword.
local function is_block_opener(item: Item): boolean
  if item.kind == "keyword" and block_openers[item.tk] then
    return true
  end
  -- Teal: record, enum, interface are identifiers that open blocks
  if item.kind == "identifier" and (item.tk == "record" or item.tk == "enum" or item.tk == "interface") then
    return true
  end
  return false
end

--- Check if an item is a block-closing keyword.
local function is_block_closer(item: Item): boolean
  return item.kind == "keyword" and (block_closers[item.tk] or false)
end

--- Check if an item is a half-closer (dedent then indent).
local function is_half_closer(item: Item): boolean
  return item.kind == "keyword" and (block_half_closers[item.tk] or false)
end

--- Check if a comment is a long comment.
local function is_long_comment(tk: string): boolean
  return tk:sub(1, 4) == "--[["
  or (tk:sub(1, 3) == "--[" and tk:sub(4, 4) == "=")
end

--- Check if a colon is in method-call position (vs type annotation).
--- Method call: prev is identifier/)/] and next is identifier (the method name).
--- Type annotation: everything else (field: Type, param: Type, etc.)
local function is_method_colon(prev: Item, next_item: Item): boolean
  if not prev or not next_item then
    return false
  end
  -- Method call pattern: <expr>:identifier(
  -- The colon follows an expression (identifier, ), ]) and precedes an identifier
  if next_item.kind == "identifier" then
    if prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]" or prev.kind == "string" then
      return true
    end
  end
  return false
end

--- Determine if we need a space between two adjacent items on the same line.
--- prev_prev is the item before prev (for unary minus detection), may be nil.
--- next_item is the item after cur (for lookahead on colon), may be nil.
local function needs_space(prev_prev: Item, prev: Item, cur: Item, next_item: Item): boolean
  -- Comments always get space before
  if cur.kind == "comment" then
    return true
  end
  -- After a comment, always space
  if prev.kind == "comment" then
    return true
  end
  -- No space after opening brackets/parens
  if no_space_after[prev.tk] then
    return false
  end
  -- No space before ( in function calls: identifier( or )( or ]( or function(
  if cur.tk == "(" then
    if prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]"
    or prev.kind == "string" or (prev.kind == "keyword" and prev.tk == "function") then
      return false
    end
  end
  -- No space before [ in indexing: identifier[ or )[ or ][
  if cur.tk == "[" then
    if prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]" then
      return false
    end
  end
  -- No space before closing brackets/parens, commas, semicolons, ?
  if no_space_before[cur.tk] then
    return false
  end
  -- Dot: no space around field access
  if prev.tk == "." or cur.tk == "." then
    return false
  end
  -- Label colons: no space around ::
  if prev.tk == "::" or cur.tk == "::" then
    return false
  end
  -- Colon handling: depends on whether it's a method call or type annotation
  if cur.tk == ":" then
    return false -- never space before colon
  end
  if prev.tk == ":" then
    -- Method call (obj:method): no space after colon
    -- Type annotation (x: Type): space after colon
    -- Distinguish by checking if what follows is identifier + "("
    if cur.kind == "identifier" and next_item and next_item.tk == "(" then
      return false -- method call: obj:method(
    end
    -- Default: space after colon (type annotation)
    return true
  end
  -- Note: for unary minus, we do NOT suppress space BEFORE the minus sign.
  -- The space before `-` is handled naturally (e.g., `= -1` has space after `=`).
  -- We only suppress space AFTER the minus sign (handled below).
  -- No space after unary minus: if prev is "-" and the item before it
  -- indicates unary context, suppress space between minus and operand
  if prev.tk == "-" and prev.kind == "op" then
    if prev_prev == nil then
      -- Minus at start of line is unary
      return false
    end
    if unary_minus_after[prev_prev.tk] or (prev_prev.kind == "keyword" and unary_minus_after_kw[prev_prev.tk]) then
      return false
    end
  end
  -- Generally, space between tokens
  return true
end

--- Determine if a `function` keyword on a line is a block-opening function
--- definition (which needs indentation for its body) vs a function TYPE
--- annotation (which does NOT open a block).
--- A function keyword is a type annotation when it appears after `:` in a
--- record field or parameter type position. We detect this by checking if
--- any prior token on the same line is `:` with no intervening block structure.
local function is_function_block_opener(line_items: {Item}, func_idx: integer): boolean
  -- Scan backwards from func_idx to find context
  for i = func_idx - 1, 1, -1 do
    local item = line_items[i]
    if item.kind == "comment" then
      -- skip
    elseif item.tk == ":" then
      -- function appears after colon: it's a type annotation
      return false
    elseif item.tk == "=" or item.tk == "(" or item.tk == "," then
      -- function after = or ( or , is a value/expression, it's a block opener
      return true
    elseif item.kind == "keyword" and (item.tk == "local" or item.tk == "return") then
      return true
    else
      -- Keep scanning
    end
  end
  -- At start of line or after only keywords: it's a block opener
  return true
end

--- Compute the net indent change for all items on a line.
--- Returns (pre_change, post_change) where:
---   pre_change: dedent to apply BEFORE emitting the line (for leading closers)
---   post_change: indent change to apply AFTER emitting the line
local function compute_indent_change(line_items: {Item}): integer, integer
  local pre_change = 0
  local post_change = 0

  -- Find first non-comment item
  local first_code: Item = nil
  for _, item in ipairs(line_items) do
    if item.kind ~= "comment" then
      first_code = item
      break
    end
  end

  -- Pre-change: dedent for leading closers
  if first_code then
    if is_block_closer(first_code) or is_half_closer(first_code) then
      pre_change = pre_change - 1
    end
    if first_code.tk == "}" or first_code.tk == ")" then
      pre_change = pre_change - 1
    end
  end

  -- Post-change: count all openers and non-leading closers
  local is_first_code = true
  for idx, item in ipairs(line_items) do
    if item.kind == "comment" then
      -- skip comments
    else
      if is_block_opener(item) then
        post_change = post_change + 1
      elseif item.tk == "{" or item.tk == "(" then
        post_change = post_change + 1
      elseif item.kind == "keyword" and item.tk == "function" then
        -- Only count as block opener if it's a function definition, not a type
        if is_function_block_opener(line_items, idx) then
          post_change = post_change + 1
        end
      end

      if not is_first_code then
        -- Non-leading closers: dedent
        if is_block_closer(item) or is_half_closer(item) then
          post_change = post_change - 1
        end
        if item.tk == "}" or item.tk == ")" then
          post_change = post_change - 1
        end
      end

      is_first_code = false
    end
  end

  return pre_change, post_change
end

--- Format source code.
--- Lexes and parses the input to validate it, then re-emits with
--- deterministic formatting.
--- @param input string The source code to format
--- @param filename string The filename (used for error messages and language detection)
--- @return FormatResult Result with ok status, formatted code, and any errors
local function format(input: string, filename: string): FormatResult
  filename = filename or "<input>"
  local lang = detect_lang(filename)

  -- Lex the input
  local tokens, lex_errs = tl.lex(input, filename)

  -- Check for lex errors
  if lex_errs and #lex_errs > 0 then
    local errors: {Issue} = {}
    for _, e in ipairs(lex_errs) do
      if e.msg then
        errors[#errors + 1] = {
          file = e.filename or filename,
          line = e.y as integer or 0,
          column = e.x as integer or 0,
          message = e.msg,
          severity = "error",
        }
      end
    end
    if #errors > 0 then
      return {ok = false, code = nil, errors = errors}
    end
  end

  -- Parse to validate syntax
  local parse_errs: {tl.Error} = {}
  tl.parse_program(tokens, parse_errs, filename, lang)

  if #parse_errs > 0 then
    local errors: {Issue} = {}
    for _, e in ipairs(parse_errs) do
      if e.msg then
        errors[#errors + 1] = {
          file = e.filename or filename,
          line = e.y as integer or 0,
          column = e.x as integer or 0,
          message = e.msg,
          severity = "error",
        }
      end
    end
    return {ok = false, code = nil, errors = errors}
  end

  -- Build flat item stream
  local items = build_items(tokens)
  if #items == 0 then
    return {ok = true, code = "", errors = {}}
  end

  local out: {string} = {}
  local indent = 0
  local indent_str = "  " -- 2-space indent

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

  for i = start_idx, #items do
    local item = items[i]
    if cur_line == nil or item.y ~= cur_line.y then
      cur_line = {items = {}, y = item.y}
      lines[#lines + 1] = cur_line
    end
    cur_line.items[#cur_line.items + 1] = item
  end

  -- Emit each line with proper indentation
  local prev_y = 0
  if start_idx == 2 and #items > 0 then
    prev_y = items[1].y
  end

  -- Track whether previous line ended with a long string (for Bug 4: ]]) splitting)
  local prev_line_ends_with_long_string = false

  for _, line in ipairs(lines) do
    -- Preserve blank lines (at most 1 blank line between code)
    -- But suppress blank line insertion when prev line ended with ]] and
    -- this line is just ) -- they belong together (e.g. func("arg", [[...]])  )
    local gap = line.y - prev_y
    if prev_y > 0 and gap > 1 then
      -- Check if this is a ]])  continuation (closing paren after long string)
      local suppress_blank = false
      if prev_line_ends_with_long_string then
        local first = line.items[1]
        if first and first.tk == ")" then
          suppress_blank = true
        end
      end
      if not suppress_blank then
        out[#out + 1] = "\n"
      end
    end

    -- Compute indent changes
    local pre_change, post_change = compute_indent_change(line.items)

    -- Apply pre-change (dedent for leading closers)
    indent = math.max(0, indent + pre_change)

    -- Emit indent
    if indent > 0 then
      out[#out + 1] = string.rep(indent_str, indent)
    end

    -- Emit items on this line with normalized spacing
    local prev_prev_item: Item = nil
    local prev_item: Item = nil
    for item_idx, item in ipairs(line.items) do
      if prev_item then
        local next_item: Item = nil
        if item_idx < #line.items then
          next_item = line.items[item_idx + 1]
        end
        if needs_space(prev_prev_item, prev_item, item, next_item) then
          out[#out + 1] = " "
        end
      end

      if item.kind == "comment" then
        if is_long_comment(item.tk) then
          -- Long comments: preserve internal newlines, re-indent each line
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
          -- Short comment: trim trailing whitespace
          out[#out + 1] = item.tk:match("^(.-)%s*$")
        end
      else
        out[#out + 1] = item.tk
      end

      prev_prev_item = prev_item
      prev_item = item
    end

    out[#out + 1] = "\n"

    -- Apply post-change (indent for openers, dedent for non-leading closers)
    indent = math.max(0, indent + post_change)

    -- Track whether this line ends with a long string (for ]] ) handling)
    local last_item = line.items[#line.items]
    prev_line_ends_with_long_string = false
    if last_item and last_item.kind == "string" then
      local tk = last_item.tk
      if tk:sub(1, 1) == "[" and tk:sub(-1) == "]" then
        prev_line_ends_with_long_string = true
      end
    end

    -- Track the last source line we emitted
    if last_item and last_item.kind == "comment" and is_long_comment(last_item.tk) then
      local newline_count = 0
      for _ in last_item.tk:gmatch("\n") do
        newline_count = newline_count + 1
      end
      prev_y = line.y + newline_count
    else
      prev_y = line.y
    end
  end

  return {ok = true, code = table.concat(out), errors = {}}
end

--- Format a file from disk.
--- Reads the file, formats it, and returns the result.
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
