--- JavaScript string-literal escaping.
local cosmo = require("cosmo")

--- The `\uXXXX` targets for the five bytes cosmo.EscapeLiteral passes
--- through raw or under-escapes: backtick, `$`, `{` and `}` never
--- appear escaped in its output (its table passes them through), and
--- `"` only ever appears as the two-byte sequence `\"` (never bare) —
--- so a single gsub pass over the escaped string, keyed by exactly
--- these matches, is exact.
local ESCAPES: {string: string} = {
  ["`"] = "\\u0060",
  ["$"] = "\\u0024",
  ["{"] = "\\u007b",
  ["}"] = "\\u007d",
  ['\\"'] = "\\u0022",
}

--- Escape str for use as the CONTENT of a `'`- or `"`-quoted
--- JavaScript string literal inside a `<script>` block — the caller
--- writes the surrounding quotes. Canonicalizes the input's UTF-8,
--- emits `\uXXXX` sequences for every non-ASCII code point (the
--- output is therefore plain ASCII), and also encodes the
--- HTML-sensitive characters (`<`, `>`, `&`, …) plus backtick, `$`,
--- `{`, `}` and `"` as `\uXXXX`, so a literal built with this needs no
--- separate `cosmic.html.escape` even inside a `<script>` block, and
--- cannot be used to open a template literal or its `${...}`
--- interpolation if it ever ends up between backticks instead — a
--- side effect of the encoding, not a documented context. Not for
--- template literals, not for `on*=` attributes (the HTML tokenizer
--- does not honor JavaScript's backslash escapes), and not for a
--- bare, unquoted expression slot. An input sequence this cannot
--- decode as UTF-8 is treated as ISO-8859-1; an int with no UTF-16
--- representation becomes the `\xFFFD` replacement character.
--- @param str string The string to escape
--- @return string The literal-safe string
local function escape_literal(str: string): string
  local escaped = cosmo.EscapeLiteral(str)
  -- the optional leading backslash only ever matches immediately
  -- before a quote: a \uXXXX sequence's own backslash is followed by
  -- 'u' and hex digits, never one of these five characters, so it
  -- never gets swept into this pass.
  return (escaped:gsub('\\?["`${}]', function(match: string): string
        return ESCAPES[match]
      end))
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
