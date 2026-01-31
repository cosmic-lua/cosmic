--- Examples for the cosmic.json module.
--- Demonstrates JSON encoding and decoding.

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

return {}
