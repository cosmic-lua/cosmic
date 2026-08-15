--- HTML utilities.
local cosmo = require("cosmo")

--- Escape HTML special characters.
--- Converts <, >, &, ", and ' to their HTML entity equivalents.
--- @param str string The string to escape
--- @return string The HTML-safe string
local function escape(str: string): string
  return cosmo.EscapeHtml(str)
end

--- The named entities unescape() decodes: exactly escape()'s output
--- set plus the aliases browsers emit for the same characters.
local ENTITIES < const >: {string: string} = {
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&quot;"] = '"',
  ["&#34;"] = '"',
  ["&#39;"] = "'",
  ["&apos;"] = "'",
}

--- Unescape HTML entities: the inverse of escape() — a pair ships
--- both halves. Decodes the five entities escape() produces
--- (&amp; &lt; &gt; &quot; &#39;) plus their common aliases (&apos;,
--- &#34;). Unknown entities pass through unchanged; this is not a
--- general HTML parser.
--- @param str string The string holding HTML entities
--- @return string The decoded string
local function unescape(str: string): string
  -- &amp; last, so "&amp;lt;" decodes to the literal text "&lt;"
  -- instead of "<" — decoding must not cascade.
  local out = str:gsub("&%#?%w+;", function(ent: string): string
      return ENTITIES[ent]
    end)
  return (out:gsub("&amp;", "&"))
end

local record HtmlModule
  escape: function(str: string): string
  unescape: function(str: string): string
end

local M: HtmlModule = {
  escape = escape,
  unescape = unescape,
}

return M
