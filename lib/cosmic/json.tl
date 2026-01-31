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

-- Example_decode demonstrates JSON decoding
local function Example_decode()
  local json = require("cosmic.json")
  local result = json.decode('{"a":1}')
  -- result is now a Lua table
  print(json.encode(result))
  -- Output:
  -- {"a":1}
end

-- Example_encode demonstrates JSON encoding
local function Example_encode()
  local json = require("cosmic.json")
  local result = json.encode({a = 1})
  print(result)
  -- Output:
  -- {"a":1}
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
