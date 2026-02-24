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

local DEFAULT_COL_LIMIT <const> = 90

local function read_lines(path: string): {string}
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines: {string} = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  return lines
end

local function check_line_columns(
  file: string,
  lines: {string},
  limit: integer
): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if #line > limit then
      table.insert(diagnostics, {
        file = file,
        line = i,
        col = limit + 1,
        rule = "line-columns",
        message = string.format(
          "%s:%d: line has %d columns (limit: %d)",
          file, i, #line, limit
        ),
      })
    end
  end
  return diagnostics
end

local function check_assert_ordering(
  file: string,
  lines: {string}
): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local pending_name: string = nil
  local in_function = false
  local depth = 0

  for i, line in ipairs(lines) do
    local fn_name = line:match("^local function (test_[%w_]+)%s*%(")
    if fn_name then
      pending_name = fn_name
      in_function = true
      depth = 1
    elseif in_function then
      -- Track block depth for nested blocks (if/for/while/do/function)
      local opens = 0
      local closes = 0
      for _ in line:gmatch("%f[%w]if%f[%W]") do
        opens = opens + 1
      end
      for _ in line:gmatch("%f[%w]for%f[%W]") do
        opens = opens + 1
      end
      for _ in line:gmatch("%f[%w]while%f[%W]") do
        opens = opens + 1
      end
      for _ in line:gmatch("%f[%w]do%f[%W]") do
        opens = opens + 1
      end
      for _ in line:gmatch("%f[%w]function%f[%W]") do
        opens = opens + 1
      end
      for _ in line:gmatch("%f[%w]end%f[%W]") do
        closes = closes + 1
      end
      depth = depth + opens - closes
      if depth <= 0 then
        -- This line is the closing `end` of the function; next non-blank line
        -- should be the call.
        in_function = false
        depth = 0
        -- Look ahead for next non-blank, non-comment line
        for j = i + 1, math.min(i + 5, #lines) do
          local next_line = lines[j]
          if next_line:match("^%s*$") or next_line:match("^%s*%-%-") then
            -- skip blank / comment lines
          else
            -- Check if it's the call
            local call_pat = "^" .. pending_name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1") .. "%s*%(%s*%)"
            if not next_line:match(call_pat) then
              table.insert(diagnostics, {
                file = file,
                line = j,
                col = 1,
                rule = "assert-ordering",
                message = string.format(
                  "%s:%d: expected %s() call immediately after function definition",
                  file, j, pending_name
                ),
              })
            end
            break
          end
        end
        pending_name = nil
      end
    end
  end

  return diagnostics
end

local function check_style(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files
  if path:match("%.d%.tl$") then
    return {}
  end

  local lines = read_lines(path)
  if #lines == 0 then
    return {}
  end

  local diagnostics: {Diagnostic} = {}

  local length_diags = check_file_length(path, #lines, DEFAULT_FILE_LINES)
  for _, d in ipairs(length_diags) do
    table.insert(diagnostics, d)
  end

  local col_diags = check_line_columns(path, lines, DEFAULT_COL_LIMIT)
  for _, d in ipairs(col_diags) do
    table.insert(diagnostics, d)
  end

  local order_diags = check_assert_ordering(path, lines)
  for _, d in ipairs(order_diags) do
    table.insert(diagnostics, d)
  end

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
  check_line_columns = check_line_columns,
  check_assert_ordering = check_assert_ordering,
  check_style = check_style,
  lint_file = lint_file,
  main = main,
}
