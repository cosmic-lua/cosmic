--- Worked examples for [`cosmic.shape`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local Example = {}

--- A release as JSON decodes it: `any`, until a shape says otherwise.
--- `null_value` keeps the draft's null, which `optional` reads as nil.
local function decoded(): any
  local text = '{"tag": "v1", "draft": null, "assets": ["lua", "zip"], "author": "someone"}'
  local value, err = Json.decode(text, { null_value = Json.null })
  assert(err == "", err)
  return value
end

--- One call checks the value, and every read after it is a typed read.
--- The result's type is the spec's: [`record_of`] reads the declaration of
--- `Release` where the module is built, so a field added to the record is
--- checked from then on and no annotation can disagree. `draft` is
--- `boolean | nil`, so a null reads as missing.
function Example.into()
  local record Release
    tag: string
    draft: boolean?
    assets: {string}
  end
  local RELEASE <const> = Shape.record_of("Release")
  local release, err = Shape.into(decoded(), RELEASE.spec)
  assert(release ~= nil, err)
  print(release.tag, #release.assets, release.draft)
  assert(release.tag == "v1" and release.assets[2] == "zip" and release.draft == nil)
  -- The answer holds what the spec names and nothing else.
  local text = Json.encode_any(release)
  print(text)
  assert(text == '{"assets":["lua","zip"],"tag":"v1"}', text)
end

--- The spec's methods answer the record without naming it, and a failure
--- starts with the record's name.
function Example.record_of()
  local record Entry
    tag: string
    draft: boolean?
    assets: {string}
  end
  local RELEASE <const> = Shape.record_of("Entry")
  local release, err = RELEASE:into(decoded())
  assert(release ~= nil, err)
  print(release.tag, #release.assets, release.draft)
  assert(release.tag == "v1" and release.assets[2] == "zip" and release.draft == nil)
  local wrong = Json.decode('{"tag": "v2", "assets": [1]}')
  local _, why = RELEASE:into(wrong)
  print(why)
  assert(why == "Entry: $.assets[0]: want string, got integer", why)
end

--- Text that is JSON is decoded and checked in one call: the answer is a
--- `Release`, or the reason the text is not one, whether it is not JSON
--- or is JSON of another shape.
function Example.decode_into()
  local record Release
    tag: string
    assets: {string}
  end
  local RELEASE <const> = Shape.record_of("Release")
  local release, err = Shape.decode_into('{"tag": "v1", "assets": ["lua"]}', RELEASE.spec)
  assert(release ~= nil, err)
  print(release.tag, #release.assets)
  assert(release.tag == "v1" and release.assets[1] == "lua")
  local _, shape = Shape.decode_into('{"tag": 1, "assets": []}', RELEASE.spec)
  print(shape)
  assert(shape == "$.tag: want string, got integer", shape)
end

--- A value that does not fit names the first place it went wrong.
function Example.into_failure()
  local record Release
    tag: string
    assets: {integer}
  end
  local RELEASE <const> = Shape.record_of("Release")
  local _, err = Shape.into(decoded(), RELEASE.spec)
  print(err)
  assert(err == "$.assets[0]: want integer, got string", err)
end

--- `into` answers the first value that does not fit, in the order the
--- walk meets them: a record's fields in byte order, a list's elements
--- by index. A config whose author wants every mistake fixes that one
--- and runs again.
function Example.first_failure_only()
  local record Release
    tag: integer
    draft: string
    assets: {integer}
  end
  local RELEASE <const> = Shape.record_of("Release")
  local release, err = Shape.into(decoded(), RELEASE.spec)
  assert(release == nil)
  print(err)
  assert(err == "$.assets[0]: want integer, got string", err)
end

--- An enumeration: a level is one of a few strings, and anything else
--- is refused by name.
function Example.one_of()
  local LEVEL <const> = Shape.one_of("debug", "info", "warn")
  local _, err = Shape.into("loud", LEVEL)
  print(err)
  assert(err == '$: want one of "debug", "info", "warn", got "loud"', err)
end

--- A config file refuses a key its record does not name, so a misspelled
--- one fails by name rather than leaving its field unset.
function Example.strict()
  local record Server
    host: string
    port: integer?
  end
  local SERVER <const> = Shape.record_of("Server"):strict()
  local _, err = SERVER:into((Json.decode('{"host": "localhost", "prot": 8080}')))
  print(err)
  assert(err == "Server: $.prot: unknown key", err)
end

--- A map from names to numbers: `map` checks every value, and `number`
--- takes an integer and a float alike.
function Example.map()
  local WEIGHTS <const> = Shape.map(Shape.number)
  local weights, err = Shape.into(Json.decode('{"lua": 2, "teal": 0.5}'), WEIGHTS)
  assert(weights ~= nil, err)
  print(weights["lua"], weights["teal"])
  assert(weights["lua"] == 2 and weights["teal"] == 0.5)
end

--- A list whose elements may be missing is not an array, which holds no
--- hole: [`sparse_list`] answers a map from the indexes that are there, and
--- `list(optional(...))` does not compile.
function Example.sparse_list()
  local SLOTS <const> = Shape.sparse_list(Shape.optional(Shape.integer))
  local slots, err = Shape.into(Json.decode('[1, null, 3]', { null_value = Json.null }), SLOTS)
  assert(slots ~= nil, err)
  print(slots[1], slots[2], slots[3])
  assert(slots[1] == 1 and slots[2] == nil and slots[3] == 3)
end

--- A field that may be one string or a list of them: `any` takes the
--- value as it is, unchecked, and the caller tells the two forms apart,
--- checking a list with a second `into`.
function Example.any()
  local record Target
    names: any
    retries: integer
  end
  local TARGET <const> = Shape.record_of("Target")
  local NAMES <const> = Shape.list(Shape.string)
  local target, err = Shape.into(Json.decode('{"names": ["a", "b"], "retries": 3}'), TARGET.spec)
  assert(target ~= nil, err)
  local names, why = Shape.into(target.names, NAMES)
  assert(names ~= nil and #names == 2, why)
  local mixed = Json.decode('["a", 3]')
  local _, bad = Shape.into(mixed, NAMES)
  print(bad)
  assert(bad == "$[1]: want string, got integer", bad)
end

return Example
