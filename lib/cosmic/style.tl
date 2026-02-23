--- Style checker for cosmic source files.
--- Checks line/column limits and test function call ordering.

local proc = require("cosmic.proc")

--- Diagnostic record (matches build.lint.Diagnostic).
local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

local DEFAULT_FILE_LINES < const > = 500
local DEFAULT_COL_LIMIT < const > = 90

--- Check that a file does not exceed the line limit.
--- @param file string Path to file (for diagnostic output)
--- @param n integer Line count
--- @param limit integer Line limit
--- @return {Diagnostic}
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
--- @param file string Path to file (for diagnostic output)
--- @param lines {string} File lines
--- @param limit integer Column limit
--- @return {Diagnostic}
local function check_col_limit(
    file: string, lines: {string}, limit: integer
  ): {Diagnostic}
  local diags: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if #line > limit then
      diags[#diags + 1] = {
        file = file,
        line = i,
        col = limit + 1,
        rule = "col-limit",
        message = string.format(
          "%s:%d has %d columns (limit: %d)",
          file, i, #line, limit
        ),
      }
    end
  end
  return diags
end

--- Track a pending test function during test-order scanning.
local record PendingTest
  name: string
  def_line: integer
  depth_at_def: integer
  end_line: integer
end

--- Check that test functions in _test.tl files are called immediately after definition.
--- Only applies to files whose basename ends in _test.tl.
--- Rules enforced:
---   test-not-called  : test_NAME defined but never called
---   test-order       : test_NAME() call not immediately after its closing end
--- @param file string Path to file (for diagnostic output)
--- @param lines {string} File lines
--- @return {Diagnostic}
local function check_test_order(file: string, lines: {string}): {Diagnostic}
  -- Only applies to assert-style test files.
  if not file:match("_test%.tl$") then
    return {}
  end

  local diags: {Diagnostic} = {}

  -- Track nesting depth to find the matching `end` for each test function.
  local depth = 0
  -- Stack of pending test functions (one per nesting depth at definition site).
  local pending: {PendingTest} = {}
  -- Map test name -> call line (populated when we see bare test_NAME() calls).
  local call_lines: {string: integer} = {}

  for i, raw_line in ipairs(lines) do
    -- Strip inline comments for pattern matching purposes.
    local line = raw_line:gsub("%-%-.*", "")

    -- Check for `local function test_NAME(...)` definition.
    local fn_name = line:match("^%s*local%s+function%s+(test_%w+)%s*%(")
    if fn_name then
      depth = depth + 1
      pending[#pending + 1] = {
        name = fn_name,
        def_line = i,
        depth_at_def = depth,
        end_line = 0,
      }
    else
      -- Count other function/block openers.
      if line:match("function%s+%w") or line:match("=%s*function%s*%(") then
        depth = depth + 1
      elseif line:match("^%s*do%s*$") or line:match("^%s*do%s+%-%-") then
        depth = depth + 1
      elseif line:match("^%s*if%s") then
        depth = depth + 1
      elseif line:match("^%s*for%s") then
        depth = depth + 1
      elseif line:match("^%s*while%s") then
        depth = depth + 1
      elseif line:match("^%s*repeat%s*$") or line:match("^%s*repeat%s+%-%-") then
        depth = depth + 1
      end
    end

    -- Check for bare `test_NAME()` call (not a definition).
    local call_name = line:match("^%s*(test_%w+)%s*%(")
    if call_name and not line:match("local%s+function")
    and not line:match("function%s+test_") then
      if not call_lines[call_name] then
        call_lines[call_name] = i
      end
    end

    -- Check for `end` — close the innermost nesting level.
    if line:match("^%s*end%s*$") or line:match("^%s*end%s*%-%-")
    or line:match("^%s*end[,;%)]") then
      -- Check if this end closes a pending test function.
      if #pending > 0 then
        local top = pending[#pending]
        if top.end_line == 0 and depth == top.depth_at_def then
          top.end_line = i
        end
      end
      depth = depth - 1
      if depth < 0 then
        depth = 0
      end
    end

    -- `until` closes repeat.
    if line:match("^%s*until%s") then
      depth = depth - 1
      if depth < 0 then
        depth = 0
      end
    end
  end

  -- Validate each pending test function.
  for _, pt in ipairs(pending) do
    local call_line = call_lines[pt.name]
    if not call_line then
      diags[#diags + 1] = {
        file = file,
        line = pt.def_line,
        col = 1,
        rule = "test-not-called",
        message = string.format("%s: %s defined but never called", file, pt.name),
      }
    elseif pt.end_line > 0 and call_line ~= pt.end_line + 1 then
      diags[#diags + 1] = {
        file = file,
        line = call_line,
        col = 1,
        rule = "test-order",
        message = string.format(
          "%s: %s() call on line %d should be on line %d (immediately after end)",
          file, pt.name, call_line, pt.end_line + 1
        ),
      }
    end
  end

  return diags
end

--- Read all lines from a file.
--- @param path string
--- @return {string}, string
local function read_lines(path: string): {string}, string
  local f, err = io.open(path, "r")
  if not f then
    return nil, err or "cannot open file"
  end
  local lines: {string} = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

--- Check a file for style violations.
--- Skips .d.tl type declaration files.
--- @param path string Path to file
--- @return {Diagnostic}
local function check_style_file(path: string): {Diagnostic}
  -- Skip .d.tl type declaration files.
  if path:match("%.d%.tl$") then
    return {}
  end

  local lines, err = read_lines(path)
  if not lines then
    return {{
        file = path,
        line = 1,
        col = 1,
        rule = "file-read",
        message = string.format("%s: %s", path, err or "cannot read file"),
      }}
  end

  local diags: {Diagnostic} = {}

  -- Check file length.
  local len_diags = check_file_length(path, #lines, DEFAULT_FILE_LINES)
  for _, d in ipairs(len_diags) do
    diags[#diags + 1] = d
  end

  -- Check column limit.
  local col_diags = check_col_limit(path, lines, DEFAULT_COL_LIMIT)
  for _, d in ipairs(col_diags) do
    diags[#diags + 1] = d
  end

  -- Check test ordering (only for _test.tl files).
  local order_diags = check_test_order(path, lines)
  for _, d in ipairs(order_diags) do
    diags[#diags + 1] = d
  end

  return diags
end

--- CLI entry point.
local function main(...: string): integer
  local files: {string} = {...}
  if #files == 0 then
    io.stderr:write("usage: style.lua FILE\n")
    return 1
  end

  local all_diags: {Diagnostic} = {}
  for _, file in ipairs(files) do
    local diags = check_style_file(file)
    for _, d in ipairs(diags) do
      all_diags[#all_diags + 1] = d
    end
  end

  if #all_diags == 0 then
    io.write("Style check passed\n")
    return 0
  end

  for _, d in ipairs(all_diags) do
    io.stderr:write(string.format(
        "%s:%d:%d: %s: %s\n",
        d.file, d.line, d.col, d.rule, d.message
      ))
  end
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

return {
  DEFAULT_COL_LIMIT = DEFAULT_COL_LIMIT,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  check_col_limit = check_col_limit,
  check_test_order = check_test_order,
  check_style_file = check_style_file,
  main = main,
}
