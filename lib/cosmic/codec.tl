--- Encoding and decoding utilities for various formats.
--- Provides hex and Lua serialization codecs with consistent error handling.
local cosmo = require("cosmo")

--- Encode a string as hexadecimal.
--- Each byte becomes two lowercase hex characters.
--- @param data string The binary data to encode
--- @return string The hexadecimal representation
local function encode_hex(data: string): string
  return cosmo.EncodeHex(data)
end

--- Decode a hexadecimal string to binary data.
--- Accepts both uppercase and lowercase hex characters.
--- @param hex string The hexadecimal string to decode
--- @return string The decoded binary data, or nil on error
--- @return string? Error message if decoding failed
local function decode_hex(hex: string): string, string
  -- Validate length is even
  if #hex % 2 ~= 0 then
    return nil, "hex string must have even length"
  end
  -- Validate characters are valid hex
  if hex:match("[^0-9a-fA-F]") then
    return nil, "invalid hex character"
  end
  -- Decode pairs of hex digits
  local result = hex:gsub("(%x%x)", function(pair: string): string
    return string.char(tonumber(pair, 16) as integer)
  end)
  return result, nil
end

--- Encode a Lua value as Lua source code.
--- The output can be loaded with decode_lua to reconstruct the value.
--- @param value any The Lua value to encode (table, string, number, boolean, or nil)
--- @param opts {string:any}? Optional encoding options
--- @return string The Lua source code representation
local function encode_lua(value: any, opts?: {string:any}): string
  return cosmo.EncodeLua(value, opts)
end

--- Decode Lua source code to a value.
--- Only loads the code, does not execute arbitrary functions.
--- WARNING: This executes Lua code. Only use with trusted input.
--- @param code string The Lua source code to decode
--- @return any The decoded Lua value, or nil on error
--- @return string? Error message if decoding failed
local function decode_lua(code: string): any, string
  local chunk, err = load("return " .. code)
  if not chunk then
    return nil, err as string
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, result as string
  end
  return result, nil
end

--- Encode binary data as base64.
--- Uses standard base64 encoding (RFC 4648).
--- @param data string The binary data to encode
--- @return string The base64 encoded string
local function encode_base64(data: string): string
  return cosmo.EncodeBase64(data)
end

--- Decode a base64 string to binary data.
--- Accepts standard base64 encoding with or without padding.
--- @param str string The base64 string to decode
--- @return string The decoded binary data
local function decode_base64(str: string): string
  return cosmo.DecodeBase64(str)
end

--- Encode binary data as base32.
--- Uses z-base-32 encoding (lowercase alphabet).
--- @param data string The binary data to encode
--- @return string The base32 encoded string
local function encode_base32(data: string): string
  return cosmo.EncodeBase32(data)
end

--- Decode a base32 string to binary data.
--- Accepts z-base-32 encoding.
--- @param str string The base32 string to decode
--- @return string The decoded binary data
local function decode_base32(str: string): string
  return cosmo.DecodeBase32(str)
end

--- Encode a UTF-8 string as Latin-1 (ISO-8859-1).
--- Characters outside the Latin-1 range will cause an error.
--- @param str string The UTF-8 string to encode
--- @return string The Latin-1 encoded bytes, or nil on error
--- @return string? Error message if encoding failed
local function encode_latin1(str: string): string, string
  local ok, result = pcall(cosmo.EncodeLatin1, str)
  if not ok then
    return nil, "cannot encode to Latin-1: character out of range"
  end
  return result, nil
end

--- Decode Latin-1 (ISO-8859-1) bytes to a UTF-8 string.
--- @param data string The Latin-1 bytes to decode
--- @return string The UTF-8 string
local function decode_latin1(data: string): string
  return cosmo.DecodeLatin1(data)
end

local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string, string
  encode_lua: function(value: any, opts?: {string:any}): string
  decode_lua: function(code: string): any, string
  encode_base64: function(data: string): string
  decode_base64: function(str: string): string
  encode_base32: function(data: string): string
  decode_base32: function(str: string): string
  encode_latin1: function(str: string): string, string
  decode_latin1: function(data: string): string
end

local M: CodecModule = {
  encode_hex = encode_hex,
  decode_hex = decode_hex,
  encode_lua = encode_lua,
  decode_lua = decode_lua,
  encode_base64 = encode_base64,
  decode_base64 = decode_base64,
  encode_base32 = encode_base32,
  decode_base32 = decode_base32,
  encode_latin1 = encode_latin1,
  decode_latin1 = decode_latin1,
}

return M
