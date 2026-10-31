--- [`Shape.record_of`] in modules the build compiled: the spec it
--- reads off a record is what the same record's hand-written
--- [`Shape.raw`] `record` builds, and `into` checks against it. Which records
--- the build refuses is build/shape_specs_test.tl's.
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

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

local ADDRESS <const> = Shape.raw.record({
  street = Shape.raw.string,
  floor = Shape.raw.optional(Shape.raw.integer),
})

local HAND_WRITTEN <const> = Shape.raw.record({
  name = Shape.raw.string,
  age = Shape.raw.integer,
  score = Shape.raw.number,
  admin = Shape.raw.boolean,
  nickname = Shape.raw.optional(Shape.raw.string),
  address = ADDRESS,
  previous = Shape.raw.optional(ADDRESS),
  tags = Shape.raw.list(Shape.raw.string),
  scores = Shape.raw.list(Shape.raw.number),
  places = Shape.raw.list(ADDRESS),
  by_key = Shape.raw.map(ADDRESS),
  weights = Shape.raw.map(Shape.raw.number),
  level = Shape.raw.one_of("debug", "info", "warn"),
  anything = Shape.raw.optional(Shape.raw.any),
  inner = Shape.raw.record({ deep = Shape.raw.map(Shape.raw.list(Shape.raw.integer)) }),
})

--- `a` and `b` hold the same, whatever tables they are.
local function same(a: any, b: any, at: string)
  if a is {any: any} and b is {any: any} then
    for k, v in pairs(a) do same(v, b[k], at .. "." .. tostring(k)) end
    for k in pairs(b) do assert(a[k] ~= nil, at .. "." .. tostring(k) .. ": missing") end
  else
    assert(a == b, ("%s: %s is not %s"):format(at, tostring(a), tostring(b)))
  end
end

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

local function test_the_spec_is_the_hand_written_one()
  same(Shape.node_of(PROFILE.spec), HAND_WRITTEN, "$")
end

local function test_the_spec_checks_what_the_hand_written_one_does()
  local text = GOOD
  local profile, err = PROFILE:decode_into(text, { null_value = Json.null })
  assert(profile ~= nil, err)
  assert(profile.name == "Ada" and profile.address.floor == 2)
  assert(profile.nickname == nil and profile.previous == nil)
  assert(profile.by_key["home"].street == "Oak" and profile.inner.deep["k"][2] == 2)
  assert((profile as {string: any}).unlisted == nil, "a key the record lacks was kept")
  local decoded = Json.decode(text, { null_value = Json.null })
  local hand, hand_err = Shape.raw.check(decoded, HAND_WRITTEN)
  assert(hand ~= nil, hand_err)
  same(profile, hand, "$")
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

--- A call the build did not resolve has no spec to answer with.
local function test_an_unresolved_call_says_what_to_do()
  -- Named by an index, since the build refuses any mention of [`Shape.record_of`] that is not its call.
  local unresolved: function(string): Shape.Typed<Profile> = Shape["record_of"] as function(string): Shape.Typed<Profile>
  local ok, err = pcall(unresolved, "Profile")
  assert(not ok)
  local message = tostring(err)
  assert(message:find("record_of(\"Profile\") was not resolved", 1, true), message)
  assert(message:find("--standalone", 1, true) and message:find("aliased or computed", 1, true), message)
  assert(message:find("Shape.record_of(\"Name\")", 1, true) and message:find("Shape.record", 1, true), message)
end
