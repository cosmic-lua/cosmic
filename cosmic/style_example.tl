--- Examples for the cosmic.style module.
--- The style checks behind `cosmic --check lint`: file length, column
--- width, and definition-before-use ordering. Each check returns a list
--- of Diagnostic records rather than printing or throwing, so a caller
--- decides how to report them — which is how `--make lint` reuses the
--- same functions the CLI runs.

-- Example_check_file_length demonstrates the file-length rule.
-- It takes the line count rather than the file, so a caller that has
-- already read the source does not read it twice.
local function Example_check_file_length()
  local style = require("cosmic.style")
  local ok = style.check_file_length("short.tl", 120, 500)
  local over = style.check_file_length("long.tl", 640, 500)
  print(#ok, #over)
  print(over[1].rule)
  -- Output:
  -- 0	1
  -- file-length
end

-- Example_defaults demonstrates the limits the CLI applies when a
-- caller does not name its own.
local function Example_defaults()
  local style = require("cosmic.style")
  print(style.DEFAULT_FILE_LINES)
  -- Output:
  -- 500
end

-- Suppress unused warnings for examples
local _ = {Example_check_file_length, Example_defaults}
