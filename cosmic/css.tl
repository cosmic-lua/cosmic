--- CSS value escaping. No `cosmo.*` binding does this — unlike HTML,
--- URL, and JavaScript, cosmopolitan carries no CSS escaper, so this
--- module implements the escape itself rather than wrapping one.

--- Escape str for interpolation into a CSS value or string literal
--- (a `content: "…"` string, a `style="…"` attribute's value). Every
--- byte that is not an ASCII letter or digit becomes a CSS hex escape
--- `\XX ` — a backslash, the byte's value in lowercase hex, and a
--- trailing space that terminates the escape per the CSS syntax rules
--- (consumed as the terminator, not rendered) — and every byte 0x80
--- and above passes through unescaped, since a UTF-8 continuation or
--- lead byte can never collide with an ASCII delimiter. Allowlisting
--- alphanumerics is what makes this safe without parsing CSS: none of
--- those bytes can open a string, a comment, a `url(…)`, or an
--- `expression(…)`.
--- @param str string The string to escape
--- @return string The CSS-safe string
local function escape(str: string): string
  local out: {string} = {}
  for i = 1, #str do
    local b = str:byte(i)
    if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
    or b >= 128 then
      out[#out + 1] = str:sub(i, i)
    else
      out[#out + 1] = string.format("\\%x ", b)
    end
  end
  return table.concat(out)
end

--- Escaped CSS content, wrapped so a raw `string` cannot reach a
--- `{{css ...}}` interpolation by accident. The only two ways to get
--- one are safe() (escapes, then wraps) and trusted() (wraps without
--- escaping — the explicit hatch for a value already known to be
--- safe, such as a fixed color keyword).
local record SafeCss
  raw: string
end

--- Escape str with escape and wrap it as SafeCss.
--- @param str string The string to escape
--- @return SafeCss The escaped, wrapped string
local function safe(str: string): SafeCss
  return {raw = escape(str)}
end

--- Wrap str as SafeCss WITHOUT escaping it.
--- @param str string A CSS value already known to be safe
--- @return SafeCss The wrapped string, unescaped
local function trusted(str: string): SafeCss
  return {raw = str}
end

local record CssModule
  type SafeCss = SafeCss

  escape: function(str: string): string
  safe: function(str: string): SafeCss
  trusted: function(str: string): SafeCss
end

local M: CssModule = {
  escape = escape,
  safe = safe,
  trusted = trusted,
}

return M
