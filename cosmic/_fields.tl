--- The one field grammar for structured `key=value` lines.
--- cosmic.log and cosmic.instrument both render field values with it,
--- so a line from either is readable by instrument's parser: an
--- encoded value never contains a space or a line terminator, fields
--- are read back with a non-space (`%S+`) pattern and then decoded.
--- Internal to cosmic/ (leading underscore) — the public surfaces are
--- log.format and instrument.format_line/parse_line.

--- Encode one field value: literal "%" first (so decoding is
--- unambiguous), then the space delimiter and the line terminators.
--- @param s string Raw field value
--- @return string Value safe to place between spaces on one line
local function encode(s: string): string
  return (s:gsub("%%", "%%25"):gsub(" ", "%%20"):gsub("\n", "%%0A"):gsub("\r", "%%0D"))
end

--- Reverse encode, in the opposite order it applied.
--- @param s string An encoded field value read off a line
--- @return string The original value
local function decode(s: string): string
  return (s:gsub("%%0D", "\r"):gsub("%%0A", "\n"):gsub("%%20", " "):gsub("%%25", "%%"))
end

--- Render any value as an encoded field value: strings encode as
--- themselves, everything else through tostring.
--- @param v any The value to render
--- @return string The encoded field value
local function render(v: any): string
  if v is string then
    return encode(v)
  end
  return encode(tostring(v))
end

local record FieldsModule
  encode: function(s: string): string
  decode: function(s: string): string
  render: function(v: any): string
end

local M: FieldsModule = {
  encode = encode,
  decode = decode,
  render = render,
}

return M
