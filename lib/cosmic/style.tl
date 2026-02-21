--- Style checker for Teal and Lua files.
--- Checks line count (<= 500), column width (<= 90), and that assert-style
--- test functions are called immediately after their closing end.

--- A style diagnostic.
local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

--- Result from checking a file.
local record StyleResult
  ok: boolean
  diagnostics: {Diagnostic}
end

local MAX_LINES = 500
local MAX_COLS = 90

--- Check whether a filename looks like a test file.
local function is_test_file(path: string): boolean
  return path:match("_test%.tl$") ~= nil
    or path:match("_test%.lua$") ~= nil
end

--- Run all style checks on the given file content.
--- @param path string Path to the file (used in diagnostics and for test detection)
--- @param content string File content
--- @return StyleResult
local function check_content(
  path: string,
  content: string
): StyleResult
  local diagnostics: {Diagnostic} = {}

  -- Split into lines
  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  -- Remove trailing empty line added by the pattern above when content
  -- already ends with a newline.
  if lines[#lines] == "" and content:sub(-1) == "\n" then
    lines[#lines] = nil
  end

  -- Check 1: line count
  if #lines > MAX_LINES then
    diagnostics[#diagnostics + 1] = {
      file = path,
      line = MAX_LINES + 1,
      col = 1,
      rule = "line-count",
      message = string.format(
        "file has %d lines (max %d)", #lines, MAX_LINES
      ),
    }
  end

  -- Check 2: column width
  for i, line in ipairs(lines) do
    local len = #line
    if len > MAX_COLS then
      diagnostics[#diagnostics + 1] = {
        file = path,
        line = i,
        col = MAX_COLS + 1,
        rule = "line-length",
        message = string.format(
          "line is %d columns (max %d)", len, MAX_COLS
        ),
      }
    end
  end

  -- Check 3: test functions called immediately after end (test files only)
  if is_test_file(path) then
    local i = 1
    while i <= #lines do
      local fn_name = lines[i]:match("^local function (test_[%w_]+)%s*%(")
      if fn_name then
        -- Scan forward to find the closing "end"
        local j = i + 1
        while j <= #lines do
          -- Match bare "end" (possibly with trailing whitespace)
          if lines[j]:match("^end%s*$") then
            break
          end
          j = j + 1
        end
        -- j now points at closing "end" or past EOF
        -- Check the very next non-blank line for a call
        local k = j + 1
        while k <= #lines and lines[k]:match("^%s*$") do
          k = k + 1
        end
        local found_call = false
        -- A blank line between end and call is a violation (skip to end)
        -- Only accept an immediate call (no blank lines between end and call)
        if k == j + 1 then
          -- No blank lines between end and call site
          if lines[k] and lines[k]:match(
            "^" .. fn_name:gsub("_", "%%_") .. "%s*%("
          ) then
            found_call = true
          end
        end
        if not found_call then
          diagnostics[#diagnostics + 1] = {
            file = path,
            line = i,
            col = 1,
            rule = "test-not-called",
            message = string.format(
              "test function %s() is not called immediately after its end",
              fn_name
            ),
          }
        end
        i = j + 1
      else
        i = i + 1
      end
    end
  end

  return {
    ok = #diagnostics == 0,
    diagnostics = diagnostics,
  }
end

--- Check a file on disk.
--- @param path string Path to the file to check
--- @return StyleResult
local function check_file(path: string): StyleResult
  local f, open_err = io.open(path, "r")
  if not f then
    return {
      ok = false,
      diagnostics = {{
        file = path,
        line = 0,
        col = 0,
        rule = "io",
        message = "cannot open file: " .. (open_err or "unknown error"),
      }},
    }
  end
  local content = f:read("*a")
  f:close()
  return check_content(path, content)
end

--- Format diagnostics for human-readable output.
--- @param diagnostics {Diagnostic}
--- @return string
local function format_issues(diagnostics: {Diagnostic}): string
  local out: {string} = {}
  for _, d in ipairs(diagnostics) do
    out[#out + 1] = string.format(
      "%s:%d:%d: error: [%s] %s",
      d.file, d.line, d.col, d.rule, d.message
    )
  end
  return table.concat(out, "\n")
end

local record StyleModule
  check_file: function(path: string): StyleResult
  check_content: function(path: string, content: string): StyleResult
  format_issues: function(diagnostics: {Diagnostic}): string
  Diagnostic: Diagnostic
  StyleResult: StyleResult
end

local M: StyleModule = {
  check_file = check_file,
  check_content = check_content,
  format_issues = format_issues,
}

return M
