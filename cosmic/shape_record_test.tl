--- [`Shape.record_of`] in modules the build compiled: the check the build wrote off a record answers the record, and the
--- node it describes the fields with is what the binders read. Which records
--- the build refuses is build/shape_specs_test.tl's.
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

--- The node a record's spec describes.
local function described<T>(spec: Shape.Spec<T>): Shape.Node
  local describe = spec.describe
  assert(describe ~= nil, "a spec that describes nothing")
  return describe()
end

local enum Level
  "debug"
  "info"
  "warn"
end

local record Address
  street: string
  floor: integer?
end

--- One field of every kind a spec can be read off.
local record Profile
  name: string
  age: integer
  score: number
  admin: boolean
  nickname: string?
  address: Address
  previous: Address?
  tags: {string}
  scores: {number}
  places: {Address}
  by_key: {string: Address}
  weights: {string: number}
  level: Level
  anything: any
  record Inner
    deep: {string: {integer}}
  end
  inner: Inner
end

local PROFILE <const> = Shape.record_of("Profile")
local INNER <const> = Shape.record_of("Profile.Inner")

local GOOD <const> = [[{
  "name": "Ada", "age": 36, "score": 4.5, "admin": false,
  "nickname": null,
  "address": {"street": "Main", "floor": 2},
  "previous": null,
  "tags": ["a", "b"], "scores": [1, 2.5],
  "places": [{"street": "Elm"}],
  "by_key": {"home": {"street": "Oak", "floor": null}},
  "weights": {"a": 1},
  "level": "info",
  "anything": [1, "x"],
  "inner": {"deep": {"k": [1, 2]}},
  "unlisted": true
}]]

local function test_the_node_describes_the_fields()
  local node = described(PROFILE.spec)
  assert(node.kind == "record" and not node.optional)
  local fields = assert(node.fields)
  local names: mut {string} = {}
  for name in pairs(fields) do names[#names + 1] = name end
  assert(#names == 15, tostring(#names))
  assert(assert(fields["address"]).kind == "record" and not assert(fields["address"]).optional)
  assert(assert(fields["previous"]).kind == "record" and assert(fields["previous"]).optional)
  assert(assert(fields["nickname"]).kind == "string" and assert(fields["nickname"]).optional)
  assert(assert(fields["anything"]).kind == "any" and assert(fields["anything"]).optional)
  assert(assert(fields["places"]).kind == "list" and assert(assert(fields["places"]).of).kind == "record")
  assert(assert(fields["by_key"]).kind == "map" and assert(fields["weights"]).kind == "map")
  local level = assert(fields["level"])
  local values: mut {string} = {}
  for _, value in ipairs(assert(level.values)) do values[#values + 1] = tostring(value) end
  assert(level.kind == "one_of" and table.concat(values, ",") == "debug,info,warn")
  local strict = described(PROFILE:strict().spec)
  assert(strict.strict == true and assert(assert(strict.fields)["address"]).strict == true)
end

local function test_the_check_answers_the_record_and_drops_what_it_does_not_name()
  local text = GOOD
  local profile, err = PROFILE:decode_into(text, { null_value = Json.null })
  assert(profile ~= nil, err)
  assert(profile.name == "Ada" and profile.address.floor == 2)
  assert(profile.nickname == nil and profile.previous == nil)
  assert(profile.by_key["home"].street == "Oak" and profile.inner.deep["k"][2] == 2)
  assert((profile as {string: any}).unlisted == nil, "a key the record lacks was kept")
end

--- `into` answers the record's own type: no annotation chooses it.
local function test_into_answers_the_records_type()
  local value, err = Json.decode(GOOD, { null_value = Json.null })
  assert(err == "", err)
  local profile, why = PROFILE:into(value)
  assert(profile ~= nil, why)
  local age: integer = profile.age
  local street: string = profile.address.street
  assert(age == 36 and street == "Main")
end

local function test_a_value_that_breaks_the_record_is_refused_by_path()
  local cases: {{string}} = {
    { [[{"name": 1}]], "Profile: $.address: missing" },
    { [[{"address": {"street": "s", "floor": "two"}}]], "Profile: $.address.floor: want integer, got string" },
  }
  for _, case in ipairs(cases) do
    local profile, err = PROFILE:decode_into(case[1])
    assert(profile == nil, "accepted " .. case[1])
    assert(err == case[2], ("wanted %q, got %q"):format(case[2], err))
  end
  local value = Json.decode(GOOD, { null_value = Json.null })
  local loud = (GOOD:gsub('"level": "info"', '"level": "loud"'))
  local broken = Json.decode(loud, { null_value = Json.null })
  local _, level = PROFILE:into(broken)
  assert(level == 'Profile: $.level: want one of "debug", "info", "warn", got "loud"', level)
  local _, nested = INNER:into((Json.decode('{"deep": {"k": ["x"]}}')))
  assert(nested == 'Profile.Inner: $.deep.k[0]: want integer, got string', nested)
  assert(PROFILE:into(value) ~= nil)
end

--- Only a shape failure starts with the record's name: text that is not
--- JSON is the decoder's own message.
local function test_a_syntax_error_does_not_carry_the_records_name()
  local profile, err = PROFILE:decode_into("{bad")
  assert(profile == nil and err ~= "" and not err:find("^Profile: "), err)
end
