#!/usr/bin/env lua

local proc = require("cosmic.proc")

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

local DEFAULT_FILE_LINES <const> = 500
local DEFAULT_LINE_COLS <const> = 90

local function count_lines(path: string): integer
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local n = 0
  for _ in f:lines() do
    n = n + 1
  end
  f:close()
  return n
end

local function check_file_length(file: string, n: integer, limit: integer): {Diagnostic}
  if n > limit then
    return {{
      file = file,
      line = limit + 1,
      col = 1,
      rule = "file-length",
      message = string.format("%s has %d lines (limit: %d)", file, n, limit),
    }}
  end
  return {}
end

local function check_line_columns(path: string, limit: integer): {Diagnostic}
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  local lineno = 0
  for line in f:lines() do
    lineno = lineno + 1
    -- Strip trailing newline chars for accurate length
    local stripped = line:gsub("[\r\n]+$", "")
    if #stripped > limit then
      table.insert(diagnostics, {
        file = path,
        line = lineno,
        col = limit + 1,
        rule = "line-columns",
        message = string.format(
          "%s:%d has %d columns (limit: %d)",
          path, lineno, #stripped, limit
        ),
      })
    end
  end
  f:close()
  return diagnostics
end

local function check_assert_ordering(path: string): {Diagnostic}
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  local pending_call: string = nil
  local defined_at: integer = nil
  local lineno = 0
  for line in f:lines() do
    lineno = lineno + 1
    -- Detect `local function test_NAME(`
    local fname = line:match("^local function (test_[%w_]+)%s*%(")
    if fname then
      -- If there was already a pending call, it was never called — emit diagnostic
      if pending_call then
        table.insert(diagnostics, {
          file = path,
          line = defined_at,
          col = 1,
          rule = "assert-ordering",
          message = string.format(
            "%s:%d: test function '%s' not called immediately after definition",
            path, defined_at, pending_call
          ),
        })
      end
      pending_call = fname
      defined_at = lineno
    elseif pending_call then
      -- Skip blank lines and comment-only lines
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not trimmed:match("^%-%-") then
        -- This is the next code line: must be `pending_call()`
        if not line:match("^" .. pending_call .. "%s*%(%)") then
          table.insert(diagnostics, {
            file = path,
            line = defined_at,
            col = 1,
            rule = "assert-ordering",
            message = string.format(
              "%s:%d: test function '%s' not called immediately after definition",
              path, defined_at, pending_call
            ),
          })
        end
        pending_call = nil
        defined_at = nil
      end
    end
  end
  -- Handle pending call at end of file
  if pending_call then
    table.insert(diagnostics, {
      file = path,
      line = defined_at,
      col = 1,
      rule = "assert-ordering",
      message = string.format(
        "%s:%d: test function '%s' not called immediately after definition",
        path, defined_at, pending_call
      ),
    })
  end
  f:close()
  return diagnostics
end

local function lint_file(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files — they describe C binding interfaces
  -- and cannot be split due to Teal's record system.
  if path:match("%.d%.tl$") then
    return {}
  end

  local diagnostics: {Diagnostic} = {}
  local n = count_lines(path)
  if n == 0 then
    return diagnostics  -- missing or empty file
  end

  local file_diags = check_file_length(path, n, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    table.insert(diagnostics, d)
  end

  return diagnostics
end

local function style_file(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files — they describe C binding interfaces
  -- and cannot be split due to Teal's record system.
  if path:match("%.d%.tl$") then
    return {}
  end

  local diagnostics: {Diagnostic} = {}
  local n = count_lines(path)
  if n == 0 then
    return diagnostics  -- missing or empty file
  end

  local file_diags = check_file_length(path, n, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    table.insert(diagnostics, d)
  end

  local col_diags = check_line_columns(path, DEFAULT_LINE_COLS)
  for _, d in ipairs(col_diags) do
    table.insert(diagnostics, d)
  end

  local order_diags = check_assert_ordering(path)
  for _, d in ipairs(order_diags) do
    table.insert(diagnostics, d)
  end

  return diagnostics
end

local function main(...: string): integer
  local files: {string} = {...}
  if #files == 0 then
    io.stderr:write("usage: lint.lua FILE...\n")
    return 1
  end

  local all_diagnostics: {Diagnostic} = {}
  for _, file in ipairs(files) do
    local diagnostics = lint_file(file)
    for _, d in ipairs(diagnostics) do
      table.insert(all_diagnostics, d)
    end
  end

  if #all_diagnostics == 0 then
    print("pass:")
    return 0
  end

  print(string.format("fail: %d issues", #all_diagnostics))
  print("")
  for _, d in ipairs(all_diagnostics) do
    print(string.format("%s:%d:%d: %s: %s", d.file, d.line, d.col, d.rule, d.message))
  end
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

return {
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  DEFAULT_LINE_COLS = DEFAULT_LINE_COLS,
  count_lines = count_lines,
  check_file_length = check_file_length,
  check_line_columns = check_line_columns,
  check_assert_ordering = check_assert_ordering,
  lint_file = lint_file,
  style_file = style_file,
  main = main,
}
