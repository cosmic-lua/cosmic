--- JavaScript string-literal escaping.
local cosmo = require("cosmo")

--- Escape str for use as the CONTENT of a JavaScript string literal —
--- the caller still supplies the surrounding quotes. Canonicalizes the
--- input's UTF-8, emits `\uXXXX` sequences for every non-ASCII code
--- point (the output is therefore plain ASCII), and also encodes the
--- HTML-sensitive characters (`<`, `>`, `&`, …), so a literal built
--- with this needs no separate `cosmic.html.escape` even when it ends
--- up inside a `<script>` block. An input sequence this cannot decode
--- as UTF-8 is treated as ISO-8859-1; an int with no UTF-16
--- representation becomes the `\xFFFD` replacement character.
--- @param str string The string to escape
--- @return string The literal-safe string
local function escape_literal(str: string): string
  return cosmo.EscapeLiteral(str)
end

--- Escaped JavaScript string-literal content, wrapped so a raw
--- `string` cannot reach a `{{js ...}}` interpolation by accident. The
--- only two ways to get one are safe() (escapes, then wraps) and
--- trusted() (wraps without escaping — the explicit hatch for a
--- literal that is already known to be safe, such as a numeric
--- literal formatted by hand).
local record SafeJs
  raw: string
end

--- Escape str with escape_literal and wrap it as SafeJs.
--- @param str string The string to escape
--- @return SafeJs The escaped, wrapped string
local function safe(str: string): SafeJs
  return {raw = escape_literal(str)}
end

--- Wrap str as SafeJs WITHOUT escaping it.
--- @param str string A JavaScript string-literal body already known to be safe
--- @return SafeJs The wrapped string, unescaped
local function trusted(str: string): SafeJs
  return {raw = str}
end

local record JsModule
  type SafeJs = SafeJs

  escape_literal: function(str: string): string
  safe: function(str: string): SafeJs
  trusted: function(str: string): SafeJs
end

local M: JsModule = {
  escape_literal = escape_literal,
  safe = safe,
  trusted = trusted,
}

return M
