--- URL encoding and decoding utilities.
--- Wraps cosmo.EscapeParam for encoding; manual decode for percent-encoded strings.
local cosmo = require("cosmo")

--- Encode a string for use in URL query parameters.
--- Spaces become %20, special characters become %XX.
--- @param str string The string to encode
--- @return string The percent-encoded string
local function encode(str: string): string
  return cosmo.EscapeParam(str)
end

--- Decode a percent-encoded string.
--- Handles %XX sequences and + as space.
--- @param str string The percent-encoded string
--- @return string The decoded string, or nil on error
--- @return string? Error message if decoding failed
local function decode(str: string): string, string
  -- Replace + with space first
  local s = str:gsub("+", " ")
  -- Decode valid %XX sequences
  local result = s:gsub("%%(%x%x)", function(hex: string): string
    return string.char(tonumber(hex, 16) as integer)
  end)
  -- Check for remaining % characters (invalid sequences that weren't decoded)
  if result:match("%%") then
    return nil, "invalid percent-encoding"
  end
  return result, nil
end

local record UrlModule
  encode: function(str: string): string
  decode: function(str: string): string, string
end

local M: UrlModule = {
  encode = encode,
  decode = decode,
}

return M
