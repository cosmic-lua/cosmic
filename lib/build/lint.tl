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

local FILE_LINES: {string: integer} = {
  ["lib/types/cosmo/unix.d.tl"] = 2352,
  ["lib/cosmic/fs.tl"] = 1273,
  ["lib/cosmic/docs.tl"] = 1090,
  ["lib/types/gentype.tl"] = 1081,
  ["lib/cosmic/fs_test.tl"] = 1077,
  ["lib/cosmic/doc.tl"] = 962,
  ["lib/cosmic/main.tl"] = 765,
  ["lib/cosmic/format.tl"] = 723,
  ["lib/cosmic/sqlite_test.tl"] = 678,
  ["lib/cosmic/net.tl"] = 618,
  ["lib/cosmic/embed_test.tl"] = 511,
}

local function count_lines(path: string): integer, string
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local n = 0
  for _ in f:lines() do
    n = n + 1
  end
  f:close()
  return n
end

local function check_file_length(file: string, n: integer, limit: integer): Diagnostic
  if n > limit then
    return {
      file = file,
      line = limit + 1,
      col = 1,
      rule = "file-length",
      message = string.format("%s has %d lines (limit: %d)", file, n, limit),
    }
  end
  return nil
end

local function normalize_path(path: string): string
  -- strip leading o/ or output dir prefix to match FILE_LINES keys
  return path:gsub("^o/", "")
end

local function lint_file(path: string): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local n, err = count_lines(path)
  if not n then
    table.insert(diagnostics, {
      file = path,
      line = 0,
      col = 0,
      rule = "file-length",
      message = "could not read file: " .. (err or "unknown error"),
    })
    return diagnostics
  end

  local key = normalize_path(path)
  local limit = FILE_LINES[key] or DEFAULT_FILE_LINES
  local diag = check_file_length(key, n, limit)
  if diag then
    table.insert(diagnostics, diag)
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
    print("pass: lint")
    return 0
  end

  for _, d in ipairs(all_diagnostics) do
    io.stderr:write(string.format("%s:%d:%d: %s: %s\n", d.file, d.line, d.col, d.rule, d.message))
  end
  print(string.format("fail: %d issues", #all_diagnostics))
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

return {
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  FILE_LINES = FILE_LINES,
  count_lines = count_lines,
  check_file_length = check_file_length,
  normalize_path = normalize_path,
  lint_file = lint_file,
  main = main,
}
