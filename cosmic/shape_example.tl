--- Worked examples for [`cosmic.shape`], shown by `cosmic docs` under the
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

--- `into` answers the first value that does not fit, in the order the
--- walk meets them: a record's fields in byte order, a list's elements
--- by index. A config whose author wants every mistake fixes that one
--- and runs again.
function Example.first_failure_only()
  local RELEASE <const> = Shape.record({
    tag = Shape.integer,
    draft = Shape.string,
    assets = Shape.list(Shape.integer),
  })
  local release, err: Release | nil, string = Shape.into(decoded(), RELEASE)
  assert(release == nil)
  print(err)
  assert(err == "$.assets[1]: expected integer, got string", err)
end

--- An enumeration: a level is one of a few strings, and anything else
--- is refused by name.
function Example.one_of()
  local LEVEL <const> = Shape.one_of("debug", "info", "warn")
  local _, err: string | nil, string = Shape.into("loud", LEVEL)
  print(err)
  assert(err == '$: expected one of "debug", "info", "warn", got "loud"', err)
end

--- A config file refuses a key its spec does not name, so a misspelled
--- one fails by name rather than leaving its field unset.
function Example.strict_record()
  local SERVER <const> = Shape.strict_record({
    host = Shape.string,
    port = Shape.optional(Shape.integer),
  })
  local _, err: {string: any} | nil, string =
    Shape.into(Json.decode('{"host": "localhost", "prot": 8080}'), SERVER)
  print(err)
  assert(err == "$.prot: unknown key", err)
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

--- A field that may be one string or a list of them: `any` takes the
--- value as it is, unchecked, and the caller tells the two forms apart,
--- checking a list with a second `into`.
function Example.any()
  local record Target
    names: any
    retries: integer
  end
  local TARGET <const> = Shape.record({
    names = Shape.any,
    retries = Shape.integer,
  })
  local NAMES <const> = Shape.list(Shape.string)
  local target, err: Target | nil, string =
    Shape.into(Json.decode('{"names": ["a", "b"], "retries": 3}'), TARGET)
  assert(target ~= nil, err)
  local names, why: {string} | nil, string = Shape.into(target.names, NAMES)
  assert(names ~= nil and #names == 2, why)
  local _, bad: {string} | nil, string = Shape.into({ "a", 3 }, NAMES)
  print(bad)
  assert(bad == "$[2]: expected string, got integer", bad)
end

return Example
