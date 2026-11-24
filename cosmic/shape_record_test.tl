--- [`Shape.record_of`] in modules the build compiled: the check the build wrote off a record returns the record, and the
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
  local home, deep_k = profile.by_key["home"], profile.inner.deep["k"]
  assert(home ~= nil and deep_k ~= nil, "the decoded profile holds a home and a deep k")
  assert(home.street == "Oak" and deep_k[2] == 2)
  assert((profile as {string: any}).unlisted == nil, "a key the record lacks was kept") -- checked: cast_refused
end

--- `into` returns a value of the record's own type: no annotation chooses it.
local function test_into_answers_the_records_type()
  local value, err = Json.decode(GOOD, { null_value = Json.null })
  assert(err == nil, err)
  local profile, why = PROFILE:into(value)
  assert(profile ~= nil, why)
  local age: integer = profile.age
  local street: string = profile.address.street
  assert(age == 36 and street == "Main")
end

local function test_a_value_that_breaks_the_record_is_refused_by_path()
  local record Broken
    json: string
    error: string
  end
  local cases: {Broken} = {
    { json = [[{"name": 1}]], error = "Profile: $.address: missing" },
    { json = [[{"address": {"street": "s", "floor": "two"}}]], error = "Profile: $.address.floor: want integer, got string" },
  }
  for _, case in ipairs(cases) do
    local profile, err = PROFILE:decode_into(case.json)
    assert(profile == nil, "accepted " .. case.json)
    assert(err == case.error, ("wanted %q, got %q"):format(case.error, err))
  end
  local value, _ = Json.decode(GOOD, { null_value = Json.null })
  local loud = (GOOD:gsub('"level": "info"', '"level": "loud"'))
  local broken, _ = Json.decode(loud, { null_value = Json.null })
  local _, level = PROFILE:into(broken)
  assert(level == 'Profile: $.level: want one of "debug", "info", "warn", got "loud"', level)
  local got1, why1 = Json.decode('{"deep": {"k": ["x"]}}')
  assert(got1 ~= nil, tostring(why1))
  local _, nested = INNER:into(got1)
  assert(nested == 'Profile.Inner: $.deep.k[0]: want integer, got string', nested)
  assert(PROFILE:into(value) ~= nil)
end

--- Only a shape failure starts with the record's name: text that is not
--- JSON is the decoder's own message.
local function test_a_syntax_error_does_not_carry_the_records_name()
  local profile, err = PROFILE:decode_into("{bad")
  assert(profile == nil and err ~= "" and not err:find("^Profile: "), err)
end

local record Reach
  path: string
  letters: string
end

local record Call
  calls: string
end

--- A list of records each told by a field it alone declares.
local record Granted
  grants: {Reach | Call}
end

local GRANTED <const> = Shape.record_of("Granted")

local function test_a_union_of_records_is_the_one_whose_own_field_the_value_holds()
  local granted, why = GRANTED:decode_into([[{"grants": [{"path": "/tmp", "letters": "r"}, {"calls": "fork"}]}]])
  assert(granted ~= nil, why)
  local first, second = granted.grants[1], granted.grants[2]
  assert(first is Reach and first.path == "/tmp" and first.letters == "r")
  assert(second is Call and second.calls == "fork")
  local _, none = GRANTED:decode_into([[{"grants": [{"letters": "r"}]}]])
  assert(none == 'Granted: $.grants[0]: want a record with one of the fields "calls", "path"', none)
  local _, missing = GRANTED:decode_into([[{"grants": [{"path": "/tmp"}]}]])
  assert(missing == "Granted: $.grants[0].letters: missing", missing)
  -- the fields of two records leave it none of them
  local _, both = GRANTED:decode_into([[{"grants": [{"path": "/tmp", "letters": "r", "calls": "fork"}]}]])
  assert(both == 'Granted: $.grants[0]: holds both "calls" and "path", which tell different records apart; keep one', both)
  -- strict, a record of the union refuses a key it does not name
  local _, extra = GRANTED:strict():decode_into([[{"grants": [{"calls": "fork", "letters": "r"}]}]])
  assert(extra == "Granted: $.grants[0].letters: unknown key", extra)
  local node = described(GRANTED.spec)
  local grants = assert(node.fields)["grants"]
  local union = assert(assert(grants).of)
  assert(union.kind == "union" and table.concat(assert(union.by), ",") == "calls,path", union.kind)
end
