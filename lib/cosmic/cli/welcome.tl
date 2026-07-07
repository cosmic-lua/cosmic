-- Welcome message state tracking for first-run experience

local czip = require("cosmic.zip")
local fs = require("cosmic.fs")

local MARKER < const > = ".cosmic/welcome-shown"

--- Check if welcome has been shown.
--- @return boolean True if welcome was already shown (marker embedded in binary)
local function was_shown(): boolean
  return fs.read("/zip/" .. MARKER) ~= nil
end

--- Mark welcome as shown by embedding marker in binary.
local function mark_shown()
  local exe = arg[-1]
  if exe then
    local appender = czip.appender(exe)
    if appender then
      local a = appender as czip.Appender
      -- Ignore result; showing welcome again on failure is acceptable
      a:add(MARKER, "")
      a:close()
    end
  end
end

return {was_shown = was_shown, mark_shown = mark_shown}
