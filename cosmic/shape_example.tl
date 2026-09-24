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

--- An enumeration: a level is one of a few strings, and anything else
--- is refused by name.
function Example.one_of()
  local LEVEL <const> = Shape.one_of("debug", "info", "warn")
  local _, err: string | nil, string = Shape.into("loud", LEVEL)
  print(err)
  assert(err == '$: expected one of "debug", "info", "warn", got "loud"', err)
end

return Example
