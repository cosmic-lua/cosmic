#!/usr/bin/env cosmic
local repl = require("cosmic.repl")

local function test_module_loads()
  assert(repl ~= nil, "repl module should not be nil")
  assert(repl.run ~= nil, "repl.run should not be nil")
  assert(type(repl.run) == "function", "repl.run should be a function")
  assert(repl.inspect ~= nil, "repl.inspect should not be nil")
  assert(type(repl.inspect) == "function", "repl.inspect should be a function")
end
test_module_loads()

local function test_inspect_nil()
  local result = repl.inspect(nil, 3)
  assert(result == "nil", "inspect(nil) should return 'nil', got: " .. tostring(result))
end
test_inspect_nil()

local function test_inspect_boolean()
  assert(repl.inspect(true, 3) == "true", "inspect(true) should return 'true'")
  assert(repl.inspect(false, 3) == "false", "inspect(false) should return 'false'")
end
test_inspect_boolean()

local function test_inspect_number()
  assert(repl.inspect(42, 3) == "42", "inspect(42) should return '42'")
  assert(repl.inspect(3.14, 3) == "3.14", "inspect(3.14) should return '3.14'")
  assert(repl.inspect(0, 3) == "0", "inspect(0) should return '0'")
end
test_inspect_number()

local function test_inspect_string()
  assert(repl.inspect("hello", 3) == '"hello"', "inspect('hello') should return quoted string")
  assert(repl.inspect("", 3) == '""', "inspect('') should return empty quoted string")
  -- Test string with special characters
  local result = repl.inspect('hello\nworld', 3)
  assert(result:find("hello"), "inspect should preserve string content")
end
test_inspect_string()

local function test_inspect_function()
  local f = function() end
  assert(repl.inspect(f, 3) == "<function>", "inspect(function) should return '<function>'")
end
test_inspect_function()

local function test_inspect_empty_table()
  local result = repl.inspect({}, 3)
  assert(result == "{}", "inspect({}) should return '{}'")
end
test_inspect_empty_table()

local function test_inspect_array()
  local arr = {1, 2, 3}
  local result = repl.inspect(arr, 3)
  assert(result == "{1, 2, 3}", "inspect([1,2,3]) should return '{1, 2, 3}', got: " .. result)
end
test_inspect_array()

local function test_inspect_dict()
  local dict = {a = 1, b = 2}
  local result = repl.inspect(dict, 3)
  -- Order is not guaranteed, so check both possible orderings
  local valid = result == "{a = 1, b = 2}" or result == "{b = 2, a = 1}"
  assert(valid, "inspect({a=1, b=2}) should contain both key-value pairs, got: " .. result)
end
test_inspect_dict()

local function test_inspect_nested_table()
  local nested = {x = {y = 1}}
  local result = repl.inspect(nested, 3)
  assert(result:find("x"), "inspect should show nested table structure")
  assert(result:find("y"), "inspect should show nested table keys")
end
test_inspect_nested_table()

local function test_inspect_depth_limit()
  -- Create deeply nested table
  local deep = {a = {b = {c = {d = {e = 1}}}}}
  local result = repl.inspect(deep, 2)
  assert(result:find("%.%.%."), "inspect should use '...' for depth-limited content")
end
test_inspect_depth_limit()

local function test_inspect_array_length_limit()
  -- Create array with many items
  local long_array: {number} = {}
  for i = 1, 25 do
    long_array[i] = i
  end
  local result = repl.inspect(long_array, 3)
  assert(result:find("%.%.%."), "inspect should truncate long arrays with '...'")
end
test_inspect_array_length_limit()

local function test_inspect_mixed_table()
  local mixed = {1, 2, 3, x = "value"}
  local result = repl.inspect(mixed, 3)
  -- Mixed tables should be treated as dictionaries
  assert(result:find("x") or result:find("1"), "inspect should handle mixed tables")
end
test_inspect_mixed_table()

print("All REPL tests passed")
