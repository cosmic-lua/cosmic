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

--- Escaped HTML, wrapped so a raw `string` cannot reach an HTML-mode
--- `cosmic.template` render's output by accident. The only two ways to
--- get one are safe() (escapes, then wraps) and trusted() (wraps
--- without escaping — the explicit hatch for markup that is already
--- rendered, such as a nested template's output).
local record SafeHtml
  raw: string
end

--- Escape str and wrap it as SafeHtml.
--- @param str string The string to escape
--- @return SafeHtml The escaped, wrapped string
local function safe(str: string): SafeHtml
  return {raw = escape(str)}
end

--- Wrap str as SafeHtml WITHOUT escaping it.
--- @param str string Markup already known to be safe HTML
--- @return SafeHtml The wrapped string, unescaped
local function trusted(str: string): SafeHtml
  return {raw = str}
end

local record HtmlModule
  type SafeHtml = SafeHtml

  escape: function(str: string): string
  unescape: function(str: string): string
  safe: function(str: string): SafeHtml
  trusted: function(str: string): SafeHtml
end

local M: HtmlModule = {
  escape = escape,
  unescape = unescape,
  safe = safe,
  trusted = trusted,
}

return M
