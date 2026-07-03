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
local DEFAULT_COLUMN_WIDTH < const > = 90

local function count_lines(path: string): integer
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local n = 0
  local ok = pcall(function()
      for _ in f:lines() do
        n = n + 1
      end
    end)
  f:close()
  if not ok then
    return 0
  end
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

local function check_column_length(file: string, lines: {string}, limit: integer): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if #line > limit then
      table.insert(diagnostics, {
          file = file,
          line = i,
          col = limit + 1,
          rule = "column-length",
          message = string.format("%s:%d has %d columns (limit: %d)", file, i, #line, limit),
        })
    end
  end
  return diagnostics
end

--- Check that top-level `local function NAME(` is immediately called as `NAME()` on
--- the next non-blank line after its closing `end`. Heuristic: track depth of
--- `function`/`end` keywords; when depth returns to 0, check the next line.
local function check_call_after_define(file: string, lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- Match top-level local function definition
    local fname = line:match("^local function%s+([%w_]+)%s*%(")
    if fname then
      local def_line = i
      -- Track end depth to find the closing end
      local depth = 1
      i = i + 1
      while i <= #lines and depth > 0 do
        local l = lines[i]
        -- Count keywords that open a new block scope
        for _ in l:gmatch("%f[%w_]function%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]if%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]for%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]while%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]repeat%f[^%w_]") do
          depth = depth + 1
        end
        -- Count standalone `do` (not the `do` terminating a for/while header,
        -- which is already counted above via for/while). A `do` is standalone
        -- when the same line contains no `for` or `while` keyword.
        if l:match("%f[%w_]do%f[^%w_]") and
        not l:match("%f[%w_]for%f[^%w_]") and
        not l:match("%f[%w_]while%f[^%w_]") then
          depth = depth + 1
        end
        -- `until` closes a repeat block without an `end`
        for _ in l:gmatch("%f[%w_]until%f[^%w_]") do
          depth = depth - 1
        end
        -- Count end keywords
        for _ in l:gmatch("%f[%w_]end%f[^%w_]") do
          depth = depth - 1
        end
        i = i + 1
      end
      -- i is now one past the closing end line; skip blank lines
      while i <= #lines and lines[i]:match("^%s*$") do
        i = i + 1
      end
      if i <= #lines then
        local call_line = lines[i]
        -- Accept NAME() or NAME(...) as a valid call
        if not call_line:match("^" .. fname .. "%s*%(") then
          table.insert(diagnostics, {
              file = file,
              line = def_line,
              col = 1,
              rule = "call-after-define",
              message = string.format(
                "function '%s' must be called immediately after its definition "
                  .. "(test/example files call each test_* function right after defining it)",
                fname
              ),
            })
        end
      end
    else
      i = i + 1
    end
  end
  return diagnostics
end

--- Files exempt from lint: .d.tl type declaration files (they describe C
--- binding interfaces and cannot be split due to Teal's record system) and
--- vendored Lua under 3p/ (imported verbatim from upstream projects; kept
--- byte-identical to ease diffing until rewritten in Teal).
local function is_exempt(path: string): boolean
  return path:match("%.d%.tl$") ~= nil
    or path:match("^3p/.*%.lua$") ~= nil
end

local function lint_file(path: string): {Diagnostic}
  if is_exempt(path) then
    return {}
  end

  local diagnostics: {Diagnostic} = {}

  local f = io.open(path, "r")
  if not f then
    return diagnostics
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return diagnostics
  end

  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local n = #lines
  -- A trailing newline produces an empty last element; adjust count
  if n > 0 and lines[n] == "" then
    n = n - 1
  end

  local file_diags = check_file_length(path, n, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    table.insert(diagnostics, d)
  end

  -- Column-length and assert-order checks apply to Teal source files only
  if path:match("%.tl$") then
    local col_diags = check_column_length(path, lines, DEFAULT_COLUMN_WIDTH)
    for _, d in ipairs(col_diags) do
      table.insert(diagnostics, d)
    end

    local order_diags = check_call_after_define(path, lines)
    for _, d in ipairs(order_diags) do
      table.insert(diagnostics, d)
    end
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
    -- The standalone lint binary only enforces file-length (run on all tracked files).
    -- Column-length and assert-order are enforced via --check-style on .tl files.
    if not is_exempt(file) then
      local n = count_lines(file)
      local diags = check_file_length(file, n, DEFAULT_FILE_LINES)
      for _, d in ipairs(diags) do
        table.insert(all_diagnostics, d)
      end
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
  DEFAULT_COLUMN_WIDTH = DEFAULT_COLUMN_WIDTH,
  count_lines = count_lines,
  check_file_length = check_file_length,
  check_column_length = check_column_length,
  check_call_after_define = check_call_after_define,
  lint_file = lint_file,
  main = main,
}
