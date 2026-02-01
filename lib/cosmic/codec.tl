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

local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string, string
  encode_lua: function(value: any, opts?: {string:any}): string
  decode_lua: function(code: string): any, string
end

local M: CodecModule = {
  encode_hex = encode_hex,
  decode_hex = decode_hex,
  encode_lua = encode_lua,
  decode_lua = decode_lua,
}

return M
