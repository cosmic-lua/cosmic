--- Worked examples for `cosmic.shape`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local Example = {}

local record Release
  tag: string
  draft: boolean
  assets: {string}
end

--- A release as JSON decodes it: `any`, until a shape says otherwise.
--- `null_value` keeps the draft's null, which `optional` reads as nil.
local function decoded(): any
  local text = '{"tag": "v1", "draft": null, "assets": ["lua", "zip"], "author": "someone"}'
  local value, err = Json.decode(text, { null_value = Json.null })
  assert(err == "", err)
  return value
end

--- One call checks the value, and every read after it is a typed read.
--- The result's type comes from the annotation on the declaration.
function Example.into()
  local RELEASE <const> = Shape.record({
    tag = Shape.string,
    draft = Shape.optional(Shape.boolean),
    assets = Shape.list(Shape.string),
  })
  local release, err: Release | nil, string = Shape.into(decoded(), RELEASE)
  assert(release ~= nil, err)
  print(release.tag, #release.assets, release.draft)
  assert(release.tag == "v1" and release.assets[2] == "zip" and release.draft == nil)
  -- The answer holds what the spec names and nothing else.
  local text = Json.encode(release)
  print(text)
  assert(text == '{"assets":["lua","zip"],"tag":"v1"}', text)
end

--- A value that does not fit names the first place it went wrong.
function Example.into_failure()
  local RELEASE <const> = Shape.record({
    tag = Shape.string,
    assets = Shape.list(Shape.integer),
  })
  local _, err: Release | nil, string = Shape.into(decoded(), RELEASE)
  print(err)
  assert(err == "$.assets[1]: expected integer, got string", err)
end

--- A config file's author wants every mistake at once: `into_all`
--- lists each value that does not fit, by its path, in the order the
--- walk meets them.
function Example.into_all()
  local RELEASE <const> = Shape.record({
    tag = Shape.integer,
    draft = Shape.string,
    assets = Shape.list(Shape.integer),
  })
  local release, failures: Release | nil, {Shape.Failure} = Shape.into_all(decoded(), RELEASE)
  assert(release == nil)
  for _, f in ipairs(failures) do print(f.message) end
  assert(#failures == 4, "one per value that does not fit")
  assert(failures[1].message == "$.assets[1]: expected integer, got string", failures[1].message)
  assert(failures[2].path == "$.assets[2]" and failures[4].path == "$.tag")
end

--- An enumeration: a level is one of a few strings, and anything else
--- is refused by name.
function Example.one_of()
  local LEVEL <const> = Shape.one_of("debug", "info", "warn")
  local _, err: string | nil, string = Shape.into("loud", LEVEL)
  print(err)
  assert(err == '$: expected one of "debug", "info", "warn", got "loud"', err)
end

--- A map from names to numbers: `map` checks every value, and `number`
--- takes an integer and a float alike.
function Example.map()
  local WEIGHTS <const> = Shape.map(Shape.number)
  local weights, err: {string: number} | nil, string =
    Shape.into(Json.decode('{"lua": 2, "teal": 0.5}'), WEIGHTS)
  assert(weights ~= nil, err)
  print(weights.lua, weights.teal)
  assert(weights.lua == 2 and weights.teal == 0.5)
end

--- A field that may be one string or a list of them: `either` tries
--- each shape in turn. `any` takes a value as it is, unchecked.
function Example.either()
  local record Target
    names: string | {string}
    extra: any
  end
  local TARGET <const> = Shape.record({
    names = Shape.either(Shape.string, Shape.list(Shape.string)),
    extra = Shape.any,
  })
  local one, err: Target | nil, string =
    Shape.into(Json.decode('{"names": "a", "extra": [1, {}]}'), TARGET)
  assert(one ~= nil, err)
  assert(one.names == "a")
  local many, many_err: Target | nil, string =
    Shape.into(Json.decode('{"names": ["a", "b"], "extra": true}'), TARGET)
  assert(many ~= nil, many_err)
  local names = many.names
  assert(names is {string} and #names == 2)
  local _, why: Target | nil, string =
    Shape.into(Json.decode('{"names": 3, "extra": true}'), TARGET)
  print(why)
  assert(why ~= "")
end

return Example
