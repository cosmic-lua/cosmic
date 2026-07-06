--- JSON encoding and decoding utilities.
--- Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.
local cosmo = require("cosmo")

--- Decode a JSON string into a Lua value.
--- Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
--- @param str string The JSON string to decode
--- @return any The decoded Lua value (table, string, number, boolean, or nil)
--- @return string? Error message if decoding failed
local function decode(str: string): any, string
  local result, err = cosmo.DecodeJson(str)
  return result, err as string
end

--- Encode a Lua value as a JSON string.
--- Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
--- @param value any The Lua value to encode
--- @return string | nil The JSON string representation
--- @return string? Error message if encoding failed
local function encode(value: any): string | nil, string
  local result, err = cosmo.EncodeJson(value)
  return result as string, err as string
end

local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any): string | nil, string
end

local M: JsonModule = {
  decode = decode,
  encode = encode,
}

return M
