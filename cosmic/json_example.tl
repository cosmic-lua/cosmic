--- Examples for the cosmic.json module.
--- Demonstrates JSON encoding and decoding.

-- Example_decode demonstrates JSON decoding
local function Example_decode()
  local json = require("cosmic.json")
  local result = json.decode('{"a":1}')
  -- result is now a Lua table
  print((json.encode(result)))
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

-- Example_decode_object demonstrates typed decoding of a JSON object
local function Example_decode_object()
  local json = require("cosmic.json")
  local obj = json.decode_object('{"name":"ada","age":36}')
  if obj is {string: any} then
    print(obj["name"])
  end
  -- Output:
  -- ada
end

-- Example_decode_array demonstrates typed decoding of a JSON array
local function Example_decode_array()
  local json = require("cosmic.json")
  local items = json.decode_array("[10,20,30]")
  if items is {any} then
    print(#items)
  end
  -- Output:
  -- 3
end

-- Example_decode_error demonstrates error handling for invalid JSON
local function Example_decode_error()
  local json = require("cosmic.json")
  local _, err = json.decode("{invalid}")
  if err then
    print("decode error: " .. err)
  end
  -- Output:
  -- decode error: illegal character
end

-- Example_encode_error demonstrates error handling for unencodable values
local function Example_encode_error()
  local json = require("cosmic.json")
  local _, err = json.encode(function() end)
  if err then
    print("encode error: " .. err)
  end
  -- Output:
  -- encode error: unsupported lua type
end

-- Suppress unused warnings for examples
local _ = {Example_decode, Example_encode, Example_decode_object,
  Example_decode_array, Example_decode_error, Example_encode_error}
