--- JavaScript string-literal escaping.
local cosmo = require("cosmo")

--- The `\uXXXX` targets for the five bytes cosmo.EscapeLiteral passes
--- through raw or under-escapes: backtick, `$`, `{` and `}` never
--- appear escaped in its output (its table passes them through), and
--- `"` only ever appears as the two-byte sequence `\"` (never bare).
--- Keyed by the bare target byte — the gsub below strips off any
--- backslash marker before consulting this table.
local ESCAPES: {string: string} = {
  ["`"] = "\\u0060",
  ["$"] = "\\u0024",
  ["{"] = "\\u007b",
  ["}"] = "\\u007d",
  ['"'] = "\\u0022",
}

--- Escape str for use as the CONTENT of a `'`- or `"`-quoted
--- JavaScript string literal inside a `<script>` block — the caller
--- writes the surrounding quotes. Canonicalizes the input's UTF-8,
--- emits `\uXXXX` sequences for every non-ASCII code point (the
--- output is therefore plain ASCII), and also encodes the
--- HTML-sensitive characters (`<`, `>`, `&`, …) plus backtick, `$`,
--- `{`, `}` and `"` as `\uXXXX` — including when one of them is
--- immediately preceded by a literal backslash in the input — so a
--- literal built with this needs no separate `cosmic.html.escape`
--- even inside a `<script>` block, and cannot be used to open a
--- template literal or its `${...}` interpolation if it ever ends up
--- between backticks instead. Not for template literals, not for
--- `on*=` attributes (the HTML tokenizer does not honor JavaScript's
--- backslash escapes), and not for a bare, unquoted expression slot.
--- An input sequence this cannot decode as UTF-8 is treated as
--- ISO-8859-1; an int with no UTF-16 representation becomes the
--- `\xFFFD` replacement character.
--- @param str string The string to escape
--- @return string The literal-safe string
local function escape_literal(str: string): string
  local escaped = cosmo.EscapeLiteral(str)
  -- cosmo.EscapeLiteral doubles every literal backslash to `\\` and,
  -- independently, escapes every literal quote to `\"` — so a run of
  -- N backslashes immediately before one of the five targets below is
  -- always N/2 pass-through backslash pairs (N even) EXCEPT right
  -- before a quote, where the doubling of any preceding literal
  -- backslashes is followed by the quote's own escaping backslash,
  -- making the run odd and its trailing backslash the quote's marker,
  -- not part of a pair. Matching the whole run and checking its
  -- parity (rather than assuming at most one leading backslash) is
  -- what keeps an unrelated `\\` pair from being misread as adjacent
  -- to the target: only a quote with an ODD run sheds its last
  -- backslash; every other run, target, and parity passes through
  -- untouched and the target is escaped on top of it.
  return (escaped:gsub('(\\*)(["`${}])', function(backslashes: string, target: string): string
        if target == '"' and #backslashes % 2 == 1 then
          return backslashes:sub(1, #backslashes - 1) .. ESCAPES[target]
        end
        return backslashes .. ESCAPES[target]
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
