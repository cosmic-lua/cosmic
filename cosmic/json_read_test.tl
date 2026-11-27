--- Proves Json.read and its narrowing kin read a JSON file in one call, reach a place inside it, and say which file
--- and which step failed; and that string_of, number_of, integer_of and boolean_of narrow a value by name.

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

--- A file in a fresh directory holding `text`, by its path.
local function written(text: string): string
  local dir = Fs.mkdtemp("json-read-")!
  local path = dir .. "/a.json"
  Fs.write(path, text)!
  return path
end

local function test_read_reaches_a_place()
  local path = written('{"legs": {"x": [1, 2]}, "name": "trip"}')
  local name, why = Json.read(path, { "name" })
  assert(Json.string_of(name) == "trip", tostring(why))
  local legs = Json.read_object(path, { "legs" })!
  assert(#(Json.array_of(legs["x"])!) == 2)
  local xs = Json.read_array(path, { "legs", "x" })!
  assert(Json.integer_of(xs[2]) == 2)
  local whole = Json.read_object(path)!
  assert(Json.string_of(whole["name"]) == "trip")
end

local function test_read_names_the_file_and_the_step()
  local path = written('{"legs": [1]}')
  local _, why = Json.read(path, { "legs", "x" })
  assert(why ~= nil and tostring(why):find(path, 1, true) ~= nil, tostring(why))
  assert(tostring(why):find("not an object", 1, true) ~= nil, tostring(why))
  local _, not_object = Json.read_object(path, { "legs" })
  assert(not_object ~= nil and not_object.kind == "mismatch", tostring(not_object))
  assert(tostring(not_object):find("expected a JSON object, got array", 1, true) ~= nil, tostring(not_object))
  local _, not_array = Json.read_array(path)
  assert(not_array ~= nil and tostring(not_array):find("got object", 1, true) ~= nil, tostring(not_array))
end

local function test_read_names_a_file_that_is_not_json()
  local path = written("{nope")
  local _, why = Json.read(path)
  assert(why ~= nil and tostring(why):find(path, 1, true) ~= nil, tostring(why))
  local _, missing = Json.read(path .. ".gone")
  assert(missing ~= nil and missing.kind == "system", tostring(missing))
end

local function test_narrowing_by_name()
  assert(Json.string_of("a") == "a" and Json.string_of(1) == nil and Json.string_of(nil) == nil)
  assert(Json.number_of(1.5) == 1.5 and Json.number_of("1") == nil)
  assert(Json.integer_of(3) == 3 and Json.integer_of(3.0) == 3 and Json.integer_of(3.5) == nil)
  assert(math.type(Json.integer_of(3.0)) == "integer")
  assert(Json.boolean_of(false) == false and Json.boolean_of(Json.null) == nil)
end
