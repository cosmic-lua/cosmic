--- Examples for the cosmic.ansi module.
--- Demonstrates styling text, gating on terminal support, and
--- stripping styles. Examples print stripped or boolean results so
--- their output stays deterministic across terminals.

-- Example_style demonstrates wrapping text in colors and attributes.
-- Styles close with their specific off-codes, so nesting composes.
local function Example_style()
  local ansi = require("cosmic.ansi")
  local styled = ansi.bold(ansi.red("error:") .. " disk full")
  -- print the plain text; the styled string carries the SGR codes
  print(ansi.strip(styled))
  print(#styled > #ansi.strip(styled))
  -- Output:
  -- error: disk full
  -- true
end

-- Example_enabled demonstrates gating styled output on the stream:
-- NO_COLOR (set to anything, even empty) always wins.
local function Example_enabled()
  local ansi = require("cosmic.ansi")
  local env = require("cosmic.env")
  assert(env.set("NO_COLOR", "1"))
  local message = "hello"
  if ansi.enabled(1) then
    message = ansi.green(message)
  end
  print(message)
  assert(env.unset("NO_COLOR"))
  -- Output:
  -- hello
end

-- Example_strip demonstrates removing styling, e.g. before writing
-- terminal output to a log file.
local function Example_strip()
  local ansi = require("cosmic.ansi")
  local line = ansi.dim("2026-01-01") .. " " .. ansi.yellow("warn") .. " low disk"
  print(ansi.strip(line))
  -- Output:
  -- 2026-01-01 warn low disk
end

-- Suppress unused warnings for examples
local _ = {Example_style, Example_enabled, Example_strip}
