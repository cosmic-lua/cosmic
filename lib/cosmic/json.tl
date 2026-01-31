--- JSON encoding and decoding utilities.
--- Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.
local cosmo = require("cosmo")

--- Decode a JSON string into a Lua value.
--- Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
--- @param str string The JSON string to decode
--- @return any The decoded Lua value (table, string, number, boolean, or nil)
local function decode(str: string): any
  return cosmo.DecodeJson(str)
end

--- Encode a Lua value as a JSON string.
--- Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
--- @param value any The Lua value to encode
--- @return string The JSON string representation
local function encode(value: any): string
  return cosmo.EncodeJson(value)
end

local record JsonModule
  decode: function(str: string): any
  encode: function(value: any): string
end

local M: JsonModule = {
  decode = decode,
  encode = encode,
}

return M
