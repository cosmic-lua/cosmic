--- The format half of cosmic.literal: format and format_file mirror
--- literal's parse and parse_file. A flat `_literal_format` sibling for
--- the same reason `_teal_engine` is one: literal.tl sits at the
--- file-length cap. The public surface is cosmic.literal's.
local cosmo = require("cosmo")

--- Serialize a value as a literal file's SOURCE: `return { ... }`,
--- newline-terminated, so `literal.parse(literal.format(v))`
--- round-trips for every value in the literal domain (tables with
--- identifier or string keys holding strings, numbers, booleans, and
--- nested such tables). Values outside that domain — integer or mixed
--- keys, functions, userdata — still serialize when Lua can express
--- them, but only a loadstring can read them back; parse will refuse
--- what a pin could not carry.
--- @param value any The value to serialize
--- @return string | nil The literal source, or nil when the value cannot be serialized
--- @return string? Error message on failure
local function format(value: any): string | nil, string
  local body, err = cosmo.EncodeLua(value)
  if body == nil then
    return nil, err
  end
  return "return " .. body .. "\n"
end

--- Write a value as a literal file: format, then write to path.
--- The file variant of format (the `<verb>_file` convention), the
--- mirror of parse_file.
--- @param path string Where to write
--- @param value any The value to serialize
--- @return boolean True on success
--- @return string? Error message on failure
local function format_file(path: string, value: any): boolean, string
  local body, err = format(value)
  if not body then
    return false, err
  end
  local ok, werr = require("cosmic.fs").write(path, body)
  if not ok then
    return false, werr
  end
  return true
end

local record LiteralFormatModule
  format: function(value: any): string | nil, string
  format_file: function(path: string, value: any): boolean, string
end

local M: LiteralFormatModule = {
  format = format,
  format_file = format_file,
}

return M
