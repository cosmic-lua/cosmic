-- Welcome message state tracking for first-run experience

local cosmo = require("cosmo")
local path = require("cosmo.path")
local unix = require("cosmo.unix")
local zip = require("cosmo.zip")

local record Appender
  add: function(self: Appender, name: string, content: string): boolean | nil, string | nil
  close: function(self: Appender)
end

local MARKER <const> = ".cosmic/welcome-shown"

local function get_xdg_marker(): string
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local base = (xdg and xdg ~= "") and xdg or path.join(os.getenv("HOME") or "", ".config")
  return path.join(base, "cosmic", ".welcome-shown")
end

--- Check if welcome has been shown.
--- @return boolean True if welcome was already shown
local function was_shown(): boolean
  -- Check embedded marker first
  if cosmo.Slurp("/zip/" .. MARKER) then
    return true
  end
  -- Check XDG fallback
  local xdg_marker = get_xdg_marker()
  return unix.stat(xdg_marker) ~= nil
end

--- Mark welcome as shown.
--- Tries to embed marker in binary first, falls back to XDG config.
local function mark_shown()
  -- Try to embed in binary first
  local exe = arg[-1]
  if exe then
    local appender = zip.open(exe, "a") as Appender
    if appender then
      local ok = appender:add(MARKER, "")
      appender:close()
      if ok then
        return
      end
    end
  end

  -- Fall back to XDG
  local xdg_marker = get_xdg_marker()
  local dir = path.dirname(xdg_marker)
  unix.makedirs(dir, tonumber("755", 8))
  local fd = unix.open(xdg_marker, unix.O_CREAT | unix.O_WRONLY, tonumber("644", 8))
  if fd then unix.close(fd) end
end

return { was_shown = was_shown, mark_shown = mark_shown }
