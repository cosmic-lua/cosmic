-- Welcome message state tracking for first-run experience

local cio = require("cosmic.io")
local czip = require("cosmic.zip")

local record Appender
  add: function(self: Appender, name: string, content: string): boolean | nil, string | nil
  close: function(self: Appender)
end

local MARKER < const > = ".cosmic/welcome-shown"

--- Check if welcome has been shown.
--- @return boolean True if welcome was already shown (marker embedded in binary)
local function was_shown(): boolean
  return cio.slurp("/zip/" .. MARKER) ~= nil
end

--- Mark welcome as shown by embedding marker in binary.
local function mark_shown()
  local exe = arg[-1]
  if exe then
    local appender = czip.open(exe, "a") as Appender
    if appender then
      -- Ignore result; showing welcome again on failure is acceptable
      appender:add(MARKER, "")
      appender:close()
    end
  end
end

return {was_shown = was_shown, mark_shown = mark_shown}
