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

--- Escape str for the value of an HTML attribute — a stricter set
--- than escape(): every byte that is not an ASCII letter or digit
--- becomes a decimal numeric character reference (`&#DD;`), and every
--- byte 0x80 and above (a UTF-8 continuation or lead byte) passes
--- through unescaped, since it can never collide with an ASCII
--- delimiter. Allowlisting alphanumerics — rather than the five
--- entities escape() handles — is what keeps an attribute value safe
--- whether or not it ends up quoted: a bare space, `=`, or backtick
--- can break out of an UNQUOTED attribute the way `"` breaks out of a
--- quoted one, and escape() only covers the quoted case.
--- @param str string The string to escape
--- @return string The attribute-safe string
local function escape_attr(str: string): string
  local out: {string} = {}
  for i = 1, #str do
    local b = str:byte(i)
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
    or b >= 128 then
      out[#out + 1] = str:sub(i, i)
    else
      out[#out + 1] = "&#" .. tostring(b) .. ";"
    end
  end
  return table.concat(out)
end

--- Escaped HTML-attribute-value content, wrapped so a raw `string`
--- cannot reach an HTML-mode `{{attr ...}}` interpolation by accident.
--- A separate type from `SafeHtml`: an attribute value is safe under a
--- different rule than HTML text (escape_attr's wider allowlist, not
--- escape()'s five entities), so the two are not interchangeable —
--- piping `{{attr .x}}` through `html.safe` is a compile-time type
--- error, not a weaker escape silently accepted.
local record SafeAttr
  raw: string
end

--- Escape str with escape_attr and wrap it as SafeAttr.
--- @param str string The string to escape
--- @return SafeAttr The escaped, wrapped string
local function safe_attr(str: string): SafeAttr
  return {raw = escape_attr(str)}
end

--- Wrap str as SafeAttr WITHOUT escaping it.
--- @param str string An attribute value already known to be safe
--- @return SafeAttr The wrapped string, unescaped
local function trusted_attr(str: string): SafeAttr
  return {raw = str}
end

local record HtmlModule
  type SafeHtml = SafeHtml
  type SafeAttr = SafeAttr

  escape: function(str: string): string
  unescape: function(str: string): string
  safe: function(str: string): SafeHtml
  trusted: function(str: string): SafeHtml
  escape_attr: function(str: string): string
  safe_attr: function(str: string): SafeAttr
  trusted_attr: function(str: string): SafeAttr
end

local M: HtmlModule = {
  escape = escape,
  unescape = unescape,
  safe = safe,
  trusted = trusted,
  escape_attr = escape_attr,
  safe_attr = safe_attr,
  trusted_attr = trusted_attr,
}

return M
