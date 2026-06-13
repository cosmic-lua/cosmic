--- Script execution helpers for the cosmic CLI.
--- Provides require-hint augmentation for compile-time errors and
--- user-facing traceback trimming for runtime errors.

--- Augment a Teal compile-time error message with require hints.
--- When Teal reports "module not found: 'x'", appends the same Did-you-mean
--- suggestions produced by the runtime hint engine so users see them
--- regardless of whether the error is detected at compile or run time.
--- Returns the original message unchanged when hints are disabled or
--- no suggestion is available.
--- @param err string Compile error message (may be multi-line)
--- @return string Possibly augmented error message
local function augment_module_errors(err: string): string
  if os.getenv("COSMIC_NO_REQUIRE_HINTS") then
    return err
  end
  local mod_name = err:match("module not found: '([^']+)'")
  if not mod_name then
    return err
  end
  local req_mod = require("cosmic.require")
  local hint = req_mod.format_error(mod_name)
  -- hint starts with "module 'x' not found\n\n..." — skip the first two lines
  -- and append the Did-you-mean block.
  local hint_lines: {string} = {}
  local line_idx = 0
  for line in (hint .. "\n"):gmatch("([^\n]*)\n") do
    line_idx = line_idx + 1
    if line_idx > 2 then
      hint_lines[#hint_lines + 1] = line
    end
  end
  if #hint_lines == 0 then
    return err
  end
  while #hint_lines > 0 and hint_lines[#hint_lines] == "" do
    hint_lines[#hint_lines] = nil
  end
  return err .. "\n" .. table.concat(hint_lines, "\n")
end

--- Build a traceback for user-visible errors, trimming internal frames.
--- Strips frames at and below the cosmic entry point (/zip/main.lua) so users
--- see only their own stack. Set COSMIC_FULL_TRACEBACK=1 to disable trimming.
--- @param err any The error value
--- @return string Trimmed traceback string
local function trim_traceback(err: any): string
  local tb = debug.traceback(tostring(err), 2)
  if os.getenv("COSMIC_FULL_TRACEBACK") then
    return tb
  end
  local lines: {string} = {}
  local trimmed = false
  for line in (tb .. "\n"):gmatch("([^\n]*)\n") do
    if not trimmed and line:match("\t/zip/main%.lua:") then
      trimmed = true
    end
    if not trimmed then
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

local record RunModule
  augment_module_errors: function(err: string): string
  trim_traceback: function(err: any): string
end

local M: RunModule = {
  augment_module_errors = augment_module_errors,
  trim_traceback = trim_traceback,
}

return M
