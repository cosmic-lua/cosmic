-- Welcome message state tracking for first-run experience

local cosmo = require("cosmo")
local zip = require("cosmo.zip")

local record Appender
  add: function(self: Appender, name: string, content: string): boolean | nil, string | nil
  close: function(self: Appender)
end

local MARKER <const> = ".cosmic/welcome-shown"

--- Check if welcome has been shown.
--- @return boolean True if welcome was already shown (marker embedded in binary)
local function was_shown(): boolean
  return cosmo.Slurp("/zip/" .. MARKER) ~= nil
end

--- Mark welcome as shown by embedding marker in binary.
local function mark_shown()
  local exe = arg[-1]
  if exe then
    local appender = zip.open(exe, "a") as Appender
    if appender then
      appender:add(MARKER, "")
      appender:close()
    end
  end
end

return { was_shown = was_shown, mark_shown = mark_shown }
