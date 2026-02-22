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
  count_lines = count_lines,
  check_file_length = check_file_length,
  lint_file = lint_file,
  main = main,
}
