#!/usr/bin/env lua

local proc = require("cosmic.proc")

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

local DEFAULT_FILE_LINES < const > = 500
local DEFAULT_COL_LIMIT < const > = 90

local function read_lines(path: string): {string}
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines: {string} = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

local function count_lines(path: string): integer
  local lines = read_lines(path)
  return #lines
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

--- Check that no line exceeds the column limit.
--- @param file string Path to the file (for diagnostics)
--- @param lines {string} File lines
--- @param limit integer Column limit (default: DEFAULT_COL_LIMIT)
--- @return {Diagnostic}
local function check_line_width(file: string, lines: {string}, limit: integer): {Diagnostic}
  limit = limit or DEFAULT_COL_LIMIT
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if #line > limit then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = i,
        col = limit + 1,
        rule = "col-limit",
        message = string.format(
          "%s:%d: line has %d columns (limit: %d)",
          file, i, #line, limit
        ),
      }
    end
  end
  return diagnostics
end

--- Check that assert-style test functions are called immediately after definition.
--- Matches pattern: local function test_NAME() ... test_NAME()
--- The call must be the very next non-blank, non-comment line after the closing end.
--- @param file string Path to the file (for diagnostics)
--- @param lines {string} File lines
--- @return {Diagnostic}
local function check_assert_order(file: string, lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^local function (test_[%w_]+)%s*%(")
    if name then
      local def_line = i
      -- find the closing `end` for this function by scanning forward
      local depth = 1
      local j = i + 1
      while j <= #lines and depth > 0 do
        local l = lines[j]
        -- count block openers (function, if, for, while, do, repeat)
        -- count end/until closers
        for _ in l:gmatch("%f[%a]function%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]if%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]for%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]while%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]do%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]repeat%f[%A]") do depth = depth + 1 end
        for _ in l:gmatch("%f[%a]end%f[%A]") do depth = depth - 1 end
        for _ in l:gmatch("%f[%a]until%f[%A]") do depth = depth - 1 end
        j = j + 1
      end
      -- j - 1 is now the line with the final `end`
      -- find the next non-blank, non-comment line
      local k = j
      while k <= #lines do
        local next_line = lines[k]
        if next_line:match("^%s*$") or next_line:match("^%s*%-%-") then
          k = k + 1
        else
          break
        end
      end
      -- check if that line is a call to name()
      if k > #lines or not lines[k]:match("^" .. name .. "%s*%(") then
        diagnostics[#diagnostics + 1] = {
          file = file,
          line = def_line,
          col = 1,
          rule = "assert-order",
          message = string.format(
            "%s:%d: test function '%s' is not called immediately after definition",
            file, def_line, name
          ),
        }
      end
      i = j
    else
      i = i + 1
    end
  end
  return diagnostics
end

local function lint_file(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files — they describe C binding interfaces
  -- and cannot be split due to Teal's record system.
  if path:match("%.d%.tl$") then
    return {}
  end

  local lines = read_lines(path)
  if #lines == 0 then
    return {} -- missing or empty file
  end

  local diagnostics: {Diagnostic} = {}

  local file_diags = check_file_length(path, #lines, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    diagnostics[#diagnostics + 1] = d
  end

  local width_diags = check_line_width(path, lines, DEFAULT_COL_LIMIT)
  for _, d in ipairs(width_diags) do
    diagnostics[#diagnostics + 1] = d
  end

  local order_diags = check_assert_order(path, lines)
  for _, d in ipairs(order_diags) do
    diagnostics[#diagnostics + 1] = d
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
      all_diagnostics[#all_diagnostics + 1] = d
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
  read_lines = read_lines,
  count_lines = count_lines,
  check_file_length = check_file_length,
  check_line_width = check_line_width,
  check_assert_order = check_assert_order,
  lint_file = lint_file,
  main = main,
}
