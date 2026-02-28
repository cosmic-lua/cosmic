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
local DEFAULT_COL_LIMIT <const> = 90

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

local function check_col_length(file: string, lines_tbl: {string}, limit: integer): {Diagnostic}
  local diags: {Diagnostic} = {}
  for i, line in ipairs(lines_tbl) do
    if #line > limit then
      table.insert(diags, {
        file = file,
        line = i,
        col = limit + 1,
        rule = "col-length",
        message = string.format("%s:%d column %d exceeds limit %d", file, i, #line, limit),
      })
    end
  end
  return diags
end

-- check_assert_test_ordering checks that each `local function test_NAME(` definition
-- is followed immediately (after the function body ends) by a call `test_NAME()`.
-- The algorithm finds the end of each test function by counting block keywords,
-- then inspects the next non-blank line.
local function check_assert_test_ordering(file: string, source: string): {Diagnostic}
  local diags: {Diagnostic} = {}
  local source_lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    source_lines[#source_lines + 1] = line
  end

  local i = 1
  while i <= #source_lines do
    local line = source_lines[i]
    local func_name = line:match("^%s*local%s+function%s+(test_%S-)%s*%(")
    if func_name then
      local def_line = i
      -- Find the end of the function by counting block openers/closers.
      local depth = 1
      local j = i + 1
      while j <= #source_lines and depth > 0 do
        local l = source_lines[j]
        -- Count block-opening keywords (function, if, for, while, do, repeat).
        -- Use word-boundary patterns to avoid false matches inside strings/comments.
        local opens = 0
        for _ in l:gmatch("%f[%a]function%f[%A]") do opens = opens + 1 end
        for _ in l:gmatch("%f[%a]if%f[%A]") do opens = opens + 1 end
        for _ in l:gmatch("%f[%a]for%f[%A]") do opens = opens + 1 end
        for _ in l:gmatch("%f[%a]while%f[%A]") do opens = opens + 1 end
        for _ in l:gmatch("%f[%a]do%f[%A]") do opens = opens + 1 end
        for _ in l:gmatch("%f[%a]repeat%f[%A]") do opens = opens + 1 end
        local closes = 0
        for _ in l:gmatch("%f[%a]end%f[%A]") do closes = closes + 1 end
        for _ in l:gmatch("%f[%a]until%f[%A]") do closes = closes + 1 end
        depth = depth + opens - closes
        j = j + 1
      end
      -- j-1 is the line with the closing `end`; next non-blank line should be the call.
      local call_line = j - 1 + 1  -- line after the closing end
      while call_line <= #source_lines and source_lines[call_line]:match("^%s*$") do
        call_line = call_line + 1
      end
      if call_line > #source_lines then
        table.insert(diags, {
          file = file,
          line = def_line,
          col = 1,
          rule = "test-call-order",
          message = string.format(
            "%s:%d: test function %s is not called after its definition",
            file, def_line, func_name),
        })
      else
        local next_line = source_lines[call_line]:match("^%s*(.-)%s*$")
        if next_line ~= func_name .. "()" then
          table.insert(diags, {
            file = file,
            line = def_line,
            col = 1,
            rule = "test-call-order",
            message = string.format(
              "%s:%d: test function %s is not called after its definition",
              file, def_line, func_name),
          })
        end
      end
      i = j
    else
      i = i + 1
    end
  end
  return diags
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

-- style_file runs all style checks: file-length, col-length, and test-call-order.
local function style_file(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files.
  if path:match("%.d%.tl$") then
    return {}
  end

  local diagnostics: {Diagnostic} = {}
  local f = io.open(path, "r")
  if not f then
    return diagnostics  -- missing file
  end

  local lines: {string} = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()

  if #lines == 0 then
    return diagnostics  -- empty file
  end

  local file_diags = check_file_length(path, #lines, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    table.insert(diagnostics, d)
  end

  local col_diags = check_col_length(path, lines, DEFAULT_COL_LIMIT)
  for _, d in ipairs(col_diags) do
    table.insert(diagnostics, d)
  end

  local source = table.concat(lines, "\n")
  local order_diags = check_assert_test_ordering(path, source)
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
  DEFAULT_COL_LIMIT = DEFAULT_COL_LIMIT,
  count_lines = count_lines,
  check_file_length = check_file_length,
  check_col_length = check_col_length,
  check_assert_test_ordering = check_assert_test_ordering,
  lint_file = lint_file,
  style_file = style_file,
  main = main,
}
