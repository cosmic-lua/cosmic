--- HTML utilities.
local cosmo = require("cosmo")

--- Escape HTML special characters.
--- Converts <, >, &, ", and ' to their HTML entity equivalents.
--- @param str string The string to escape
--- @return string The HTML-safe string
local function escape(str: string): string
  return cosmo.EscapeHtml(str)
end

local record HtmlModule
  escape: function(str: string): string
end

local M: HtmlModule = {
  escape = escape,
}

return M
