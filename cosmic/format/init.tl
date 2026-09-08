--- Code formatter for Teal and Lua files.
--- Produces deterministic house-style layout while preserving the parsed
--- token stream, comments, and literal spellings.

local source = require("cosmic.ast.source")
local snapshot_format = require("cosmic.format_snapshot")
local teal = require("cosmic.teal")

local type Issue = teal.Issue
local type FormatResult = snapshot_format.FormatResult
local type Snapshot = source.Snapshot
local type ParseResult = source.ParseResult

local function detect_lang(filename: string): string
  if filename and filename:match("%.tl$") then return "tl" end
  return "lua"
end

local function source_errors(result: ParseResult, filename: string): FormatResult
  local errors: {Issue} = {}
  for _, issue in ipairs(result.issues) do
    errors[#errors + 1] = {
      file = filename,
      line = issue.line,
      column = issue.column,
      message = issue.message,
      severity = "error",
    }
  end
  return {ok = false, code = nil, errors = errors}
end

--- Format an already parsed source snapshot without parsing its input again.
--- The second return is the validated output snapshot on success.
local format_snapshot = snapshot_format.format_snapshot

--- Format source code.
--- @param input string The source code to format
--- @param filename string The filename (for error messages and language detection)
--- @return FormatResult Result with ok status, formatted code, and any errors
local function format(input: string, filename: string): FormatResult
  filename = filename or "<input>"
  local parsed = source.inspect(input, filename, detect_lang(filename))
  if not parsed.snapshot then return source_errors(parsed, filename) end
  local result = format_snapshot(parsed.snapshot)
  return result
end

--- Format a file from disk.
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

local format_issues = teal.format_issues

local record FormatModule
  type Issue = Issue
  type FormatResult = FormatResult
  type Snapshot = Snapshot
  format: function(input: string, filename: string): FormatResult
  format_snapshot: function(snapshot: Snapshot): FormatResult, Snapshot | nil
  format_file: function(input_path: string): FormatResult
  format_issues: function(issues: {Issue}): string
end

local M: FormatModule = {
  format = format,
  format_snapshot = format_snapshot,
  format_file = format_file,
  format_issues = format_issues,
}

return M
