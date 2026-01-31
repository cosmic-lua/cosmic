--- Welcome message for first-time cosmic-lua users.
--- Shown once on first invocation to help users discover --docs and --help.

local unix = require("cosmo.unix")
local path = require("cosmo.path")

--- Get the path to the welcome marker file.
--- @return string The path to ~/.config/cosmic/.welcome-shown
local function get_marker_path(): string
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return path.join(home, ".config", "cosmic", ".welcome-shown")
end

--- Check if the welcome message has been shown before.
--- @return boolean True if welcome was already shown
local function was_shown(): boolean
  local marker_path = get_marker_path()
  local st = unix.stat(marker_path)
  return st ~= nil
end

--- Mark the welcome message as shown by creating the marker file.
local function mark_shown()
  local marker_path = get_marker_path()
  local dir = path.dirname(marker_path)
  unix.makedirs(dir, tonumber("755", 8))
  local f = io.open(marker_path, "w")
  if f then
    f:close()
  end
end

--- Generate the welcome message text.
--- @return string The welcome message
local function generate(): string
  local lines: {string} = {}
  table.insert(lines, "Welcome to cosmic-lua!")
  table.insert(lines, "")
  table.insert(lines, "Helpful commands:")
  table.insert(lines, "  cosmic --help         show usage and available modules")
  table.insert(lines, "  cosmic --docs <query> search documentation")
  table.insert(lines, "")
  table.insert(lines, "Set COSMIC_NO_WELCOME=1 to suppress this message.")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

return {
  was_shown = was_shown,
  mark_shown = mark_shown,
  generate = generate,
}
