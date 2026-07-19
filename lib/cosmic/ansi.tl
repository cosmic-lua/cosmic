--- ANSI terminal styling.
--- Wraps text in SGR escape sequences for colors and attributes, with
--- helpers to strip styling and to decide whether a stream should be
--- colored at all. All styling functions are pure and infallible:
--- they return the wrapped string and never inspect the terminal —
--- gate output with enabled() at the call site.
---
--- Example usage:
---   local ansi = require("cosmic.ansi")
---   if ansi.enabled(1) then
---     print(ansi.bold(ansi.red("error:")) .. " something broke")
---   end
---
--- Styles close with their specific off-code (39 for foreground, 49
--- for background, 24 for underline, ...) rather than a full reset,
--- so wrapped styles compose: bold(red("x")) renders bold red.
--- Caveat: bold and dim share off-code 22, so nesting one inside the
--- other ends both at the inner close.
---
--- Reserved names: rgb / color256 (24-bit and 256-color output),
--- cursor (movement/erase sequences), and hyperlink (OSC 8) are
--- reserved for a post-stable battery. Do not reuse these names.
local env = require("cosmic.env")
local tty = require("cosmic.tty")

local ESC < const > = string.char(27)
local CSI < const > = ESC .. "["

--- Foreground and background color names. The bright_* variants use
--- the high-intensity SGR range (90-97 / 100-107).
local enum Color
  "black"
  "red"
  "green"
  "yellow"
  "blue"
  "magenta"
  "cyan"
  "white"
  "bright_black"
  "bright_red"
  "bright_green"
  "bright_yellow"
  "bright_blue"
  "bright_magenta"
  "bright_cyan"
  "bright_white"
end

--- Text attributes.
local enum Attr
  "bold"
  "dim"
  "italic"
  "underline"
  "reverse"
  "strikethrough"
end

-- SGR foreground codes; backgrounds are these plus 10. Total over
-- Color so the checker proves every name has a code.
local fg_code < total >: {Color: number} = {
  black = 30,
  red = 31,
  green = 32,
  yellow = 33,
  blue = 34,
  magenta = 35,
  cyan = 36,
  white = 37,
  bright_black = 90,
  bright_red = 91,
  bright_green = 92,
  bright_yellow = 93,
  bright_blue = 94,
  bright_magenta = 95,
  bright_cyan = 96,
  bright_white = 97,
}

local attr_open < total >: {Attr: number} = {
  bold = 1,
  dim = 2,
  italic = 3,
  underline = 4,
  reverse = 7,
  strikethrough = 9,
}

local attr_close < total >: {Attr: number} = {
  bold = 22,
  dim = 22,
  italic = 23,
  underline = 24,
  reverse = 27,
  strikethrough = 29,
}

local function wrap(text: string, open: number, close: number): string
  return CSI .. tostring(open) .. "m" .. text .. CSI .. tostring(close) .. "m"
end

--- Color text's foreground. Closes with code 39 (default foreground)
--- so surrounding styles survive.
--- @param text string The text to style
--- @param c Color The foreground color
--- @return string The wrapped text
local function color(text: string, c: Color): string
  return wrap(text, fg_code[c], 39)
end

--- Color text's background. Closes with code 49 (default background).
--- @param text string The text to style
--- @param c Color The background color
--- @return string The wrapped text
local function bg(text: string, c: Color): string
  return wrap(text, fg_code[c] + 10, 49)
end

--- Apply a text attribute. Closes with the attribute's own off-code
--- (see the module header for the bold/dim caveat).
--- @param text string The text to style
--- @param a Attr The attribute to apply
--- @return string The wrapped text
local function attr(text: string, a: Attr): string
  return wrap(text, attr_open[a], attr_close[a])
end

--- Style text red. Shorthand for color(text, "red").
--- @param text string The text to style
--- @return string The wrapped text
local function red(text: string): string
  return color(text, "red")
end

--- Style text green. Shorthand for color(text, "green").
--- @param text string The text to style
--- @return string The wrapped text
local function green(text: string): string
  return color(text, "green")
end

--- Style text yellow. Shorthand for color(text, "yellow").
--- @param text string The text to style
--- @return string The wrapped text
local function yellow(text: string): string
  return color(text, "yellow")
end

--- Style text blue. Shorthand for color(text, "blue").
--- @param text string The text to style
--- @return string The wrapped text
local function blue(text: string): string
  return color(text, "blue")
end

--- Style text magenta. Shorthand for color(text, "magenta").
--- @param text string The text to style
--- @return string The wrapped text
local function magenta(text: string): string
  return color(text, "magenta")
end

--- Style text cyan. Shorthand for color(text, "cyan").
--- @param text string The text to style
--- @return string The wrapped text
local function cyan(text: string): string
  return color(text, "cyan")
end

--- Make text bold. Shorthand for attr(text, "bold").
--- @param text string The text to style
--- @return string The wrapped text
local function bold(text: string): string
  return attr(text, "bold")
end

--- Make text dim. Shorthand for attr(text, "dim").
--- @param text string The text to style
--- @return string The wrapped text
local function dim(text: string): string
  return attr(text, "dim")
end

--- Underline text. Shorthand for attr(text, "underline").
--- @param text string The text to style
--- @return string The wrapped text
local function underline(text: string): string
  return attr(text, "underline")
end

--- Remove all SGR escape sequences from text, returning the plain
--- string. Only styling sequences (CSI ... m) are removed; other
--- escape sequences pass through untouched.
--- @param text string The possibly-styled text
--- @return string The text with SGR sequences removed
local function strip(text: string): string
  return (text:gsub(CSI .. "[0-9;]*m", ""))
end

--- Decide whether styled output is appropriate for a stream, honoring
--- the NO_COLOR convention (https://no-color.org: set to any value,
--- including empty, disables color), TERM=dumb, and whether the fd is
--- a terminal.
--- @param fd integer? File descriptor to check (default 1, stdout)
--- @return boolean True when it is reasonable to emit styled output
local function enabled(fd?: integer): boolean
  if env.get("NO_COLOR") ~= nil then
    return false
  end
  if env.get("TERM") == "dumb" then
    return false
  end
  return tty.isatty(fd or 1)
end

local record AnsiModule
  type Color = Color
  type Attr = Attr

  --- Full reset sequence (SGR 0), for manual composition.
  reset: string

  color: function(text: string, c: Color): string
  bg: function(text: string, c: Color): string
  attr: function(text: string, a: Attr): string

  red: function(text: string): string
  green: function(text: string): string
  yellow: function(text: string): string
  blue: function(text: string): string
  magenta: function(text: string): string
  cyan: function(text: string): string
  bold: function(text: string): string
  dim: function(text: string): string
  underline: function(text: string): string

  strip: function(text: string): string
  enabled: function(fd?: integer): boolean
end

local M: AnsiModule = {
  reset = CSI .. "0m",

  color = color,
  bg = bg,
  attr = attr,

  red = red,
  green = green,
  yellow = yellow,
  blue = blue,
  magenta = magenta,
  cyan = cyan,
  bold = bold,
  dim = dim,
  underline = underline,

  strip = strip,
  enabled = enabled,
}

return M
