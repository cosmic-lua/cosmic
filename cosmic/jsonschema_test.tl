--- [`cosmic.jsonschema`]: what each keyword allows and refuses, where a failure points, and the schemas it will
--- not compile.

local Json = require("cosmic.json")
local JsonSchema = require("cosmic.jsonschema")

local function decoded(text: string): Json.Value
  local v, why = Json.decode(text, { null_value = Json.null })
  assert(v ~= nil, tostring(why))
  return v
end

local function schema_of(text: string): JsonSchema.Schema
  return assert(JsonSchema.compile(decoded(text)))
end

--- Holds `schema` to allowing each of `good` and refusing each of `bad`, all JSON text.
local function holds(schema: string, good: {string}, bad: {string})
  local s = schema_of(schema)
  for _, text in ipairs(good) do
    local ok, why = s:check(decoded(text))
    assert(ok, schema .. " refused " .. text .. ": " .. tostring(why))
  end
  for _, text in ipairs(bad) do
    local ok, _ = s:check(decoded(text))
    assert(not ok, schema .. " allowed " .. text)
  end
end

local function test_types_and_values()
  holds('{"type":"integer"}', { "1", "-3", "2.0" }, { "1.5", '"1"', "true", "null", "[]", "{}" })
  holds('{"type":"number"}', { "1", "1.5" }, { '"x"' })
  holds('{"type":["string","null"]}', { '"x"', "null" }, { "1" })
  holds('{"type":"array"}', { "[]", "[1]" }, { "{}" })
  holds('{"type":"object"}', { "{}", '{"a":1}' }, { "[]" })
  holds('{"enum":[1,"a",[2],{"b":null}]}', { "1", "1.0", '"a"', "[2]", '{"b":null}' }, { "2", '{"b":1}', "[2,2]" })
  holds('{"const":{"a":[1,2]}}', { '{"a":[1,2]}' }, { '{"a":[2,1]}', '{"a":[1,2],"b":1}' })
  holds("true", { "1", "null" }, {})
  holds("false", {}, { "1", "null" })
end

local function test_strings_numbers_and_arrays()
  holds('{"minLength":2,"maxLength":3}', { '"ab"', '"héé"', "5" }, { '"a"', '"abcd"' })
  holds('{"minimum":0,"exclusiveMaximum":10,"multipleOf":2}', { "0", "8", '"x"' }, { "-2", "10", "3" })
  holds('{"multipleOf":0.1}', { "0.3", "1", "0" }, { "0.35", "1e-12" })
  holds('{"multipleOf":1}', { "3", "2.0" }, { "1e-10", "0.5" })
  holds('{"multipleOf":3}', { "9", "-3" }, { "1e300", "4" })
  holds('{"const":null}', { "null" }, { "5", '"null"' })
  holds('{"type":"object","properties":{"x":{"type":"null"}},"required":["x"]}', { '{"x":null}' }, { '{"x":1}', "{}" })
  holds('{"items":{"type":"integer"},"minItems":1,"maxItems":2,"uniqueItems":true}', { "[1]", "[1,2]" },
    { "[]", "[1,2,3]", "[1,1]", '[1,"a"]' })
  holds('{"prefixItems":[{"type":"string"}],"items":{"type":"integer"}}', { '["a",1,2]', '["a"]' }, { '[1]', '["a","b"]' })
  holds('{"contains":{"type":"string"},"maxContains":1}', { '[1,"a"]' }, { "[1]", '["a","b"]' })
end

local function test_objects()
  local schema = '{"type":"object","properties":{"n":{"type":"integer"},"s":{"type":"string"}},' ..
    '"required":["n"],"additionalProperties":false}'
  holds(schema, { '{"n":1}', '{"n":1,"s":"x"}' }, { "{}", '{"n":"1"}', '{"n":1,"x":2}' })
  holds('{"additionalProperties":{"type":"boolean"}}', { '{"a":true}' }, { '{"a":1}' })
  holds('{"propertyNames":{"maxLength":2},"minProperties":1,"maxProperties":2}', { '{"ab":1}' },
    { "{}", '{"abc":1}', '{"a":1,"b":2,"c":3}' })
  holds('{"dependentRequired":{"a":["b"]}}', { "{}", '{"b":1}', '{"a":1,"b":1}' }, { '{"a":1}' })
end

local function test_combinators_and_refs()
  holds('{"anyOf":[{"type":"string"},{"type":"integer"}]}', { '"a"', "1" }, { "1.5" })
  holds('{"oneOf":[{"type":"integer"},{"minimum":0}]}', { "-1", "0.5" }, { "1" })
  holds('{"allOf":[{"minimum":0},{"maximum":1}]}', { "0", "1" }, { "2" })
  holds('{"not":{"type":"null"}}', { "1" }, { "null" })
  holds('{"if":{"type":"integer"},"then":{"minimum":0},"else":{"type":"string"}}', { "1", '"a"' }, { "-1", "true" })
  local tree = '{"$defs":{"node":{"type":"object","properties":{"kids":{"type":"array","items":{"$ref":"#/$defs/node"}},' ..
    '"v":{"type":"integer"}}}},"$ref":"#/$defs/node"}'
  holds(tree, { '{"v":1,"kids":[{"v":2,"kids":[]}]}' }, { '{"kids":[{"v":"x"}]}' })
  holds('{"type":"array","items":{"$ref":"#"}}', { "[]", "[[[]]]" }, { "[1]" })
end

local function test_a_failure_points_at_the_value()
  local s = schema_of('{"properties":{"a":{"items":{"properties":{"b~/c":{"type":"string"}}}}}}')
  local ok, failed = s:check(decoded('{"a":[{"b~/c":"x"},{"b~/c":1}]}'))
  local why = assert(failed)
  assert(not ok and why.path == "/a/1/b~0~1c" and why.message:find("is not string", 1, true) ~= nil,
    tostring(why.path) .. " " .. why.message)
  local closed = schema_of('{"properties":{"a":{}},"additionalProperties":false}')
  local _, extra_failed = closed:check(decoded('{"a":1,"zz":2}'))
  local extra = assert(extra_failed)
  assert(extra.path == "/zz" and extra.message:find("additionalProperties", 1, true) ~= nil, extra.message)
end

local function test_what_it_will_not_assert_is_refused()
  local function refused(text: string, says: string, at?: string)
    local s, why = JsonSchema.compile(decoded(text))
    assert(s == nil and why.message:find(says, 1, true) ~= nil, text .. ": " .. tostring(why and why.message))
    if at ~= nil then assert(why.path == at, tostring(why.path)) end
  end
  refused('{"pattern":"^a"}', '"pattern" is not one', "/pattern")
  refused('{"properties":{"a":{"patternProperties":{}}}}', '"patternProperties"', "/properties/a/patternProperties")
  refused('{"$ref":"https://example.com/s"}', "only a schema's own")
  refused('{"$ref":"#/$defs/missing"}', "does not hold")
  refused('{"$defs":{"bad":{"type":"thing"}}}', "is not a type", "/$defs/bad/type")
  refused('{"minimum":"0"}', "must be a number")
  refused('{"multipleOf":0}', "above 0")
  refused('{"allOf":[]}', "at least one")
  refused('{"properties":{"a":{"$id":"https://example.com/a"}}}', "only at the schema's root", "/properties/a/$id")
  refused('{"$anchor":"a"}', '"$anchor"')
  refused("1", "must be an object, true or false")
  assert(JsonSchema.compile(decoded('{"title":"t","description":"d","format":"email","x-mcp-header":"H",' ..
      '"default":1,"examples":[1],"$id":"https://example.com/s","$schema":"https://json-schema.org/draft/2020-12/schema"}')))
end

local function test_a_ref_that_reads_nothing_ends()
  local s = schema_of('{"$defs":{"a":{"$ref":"#/$defs/b"},"b":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}')
  local ok, failed = s:check(1)
  local why = assert(failed)
  assert(not ok and why.message:find("leads back to itself", 1, true) ~= nil, why.message)
end

--- A `definitions` entry is refused at its own pointer, and a name under both `$defs` and `definitions` is two
--- schemas, each reached by its own `$ref`.
local function test_definitions_and_defs_are_apart()
  local s, why = JsonSchema.compile(decoded('{"definitions":{"bad":{"type":"thing"}}}'))
  assert(s == nil and why.path == "/definitions/bad/type", tostring(why and why.path))
  holds('{"$defs":{"x":{"type":"string"}},"definitions":{"x":{"type":"integer"}},' ..
      '"properties":{"a":{"$ref":"#/$defs/x"},"b":{"$ref":"#/definitions/x"}}}',
    { '{"a":"s","b":1}' }, { '{"a":1}', '{"b":"s"}' })
  local _, missing = JsonSchema.compile(decoded('{"$defs":{"x":true},"$ref":"#/definitions/x"}'))
  assert(missing ~= nil and missing.message:find("does not hold", 1, true) ~= nil, tostring(missing))
  local _, bad = JsonSchema.compile(decoded('{"$defs":{"x":true},"definitions":{"x":{"minimum":"0"}}}'))
  assert(bad ~= nil and bad.path == "/definitions/x/minimum", tostring(bad and bad.path))
  local _, escaped = JsonSchema.compile(decoded('{"definitions":{"a/b~":{"type":"thing"}}}'))
  assert(escaped ~= nil and escaped.path == "/definitions/a~1b~0/type", tostring(escaped and escaped.path))
  holds('{"definitions":{"a/b":{"type":"string"}},"$ref":"#/definitions/a~1b"}', { '"s"' }, { '1' })
end

--- A schema whose branches double at each level ends with a failure, and so does one that leads back to itself
--- through anyOf.
local function test_a_check_that_branches_for_ever_ends()
  local defs: mut {string} = {}
  for i = 0, 39 do
    defs[#defs + 1] = ('"d%d":{"anyOf":[{"$ref":"#/$defs/d%d"},{"$ref":"#/$defs/d%d"}]}'):format(i, i + 1, i + 1)
  end
  defs[#defs + 1] = '"d40":false'
  local s = schema_of('{"$defs":{' .. table.concat(defs, ",") .. '},"$ref":"#/$defs/d0"}')
  local ok, failed = s:check(1)
  local why = assert(failed)
  assert(not ok and why.message:find("steps", 1, true) ~= nil, why.message)
  local loop = schema_of('{"anyOf":[{"$ref":"#"},{"$ref":"#"}]}')
  local looped, lfailed = loop:check(1)
  assert(not looped and assert(lfailed).message ~= "", "a loop through anyOf ends")
  local same: mut {Json.Value} = {}
  for _ = 1, 2000 do same[#same + 1] = decoded('{"a":[1,2,3]}') end
  local unique = schema_of('{"uniqueItems":true,"items":{"type":"object"}}')
  local _, dup = unique:check(Json.array(same))
  assert(assert(dup).message:find("are the same", 1, true) ~= nil)
end

local function test_a_value_nested_too_deep_fails()
  local v: Json.Value = 1
  for _ = 1, 70 do v = Json.array({ v }) end
  local ok, failed = schema_of('{"uniqueItems":true}'):check(Json.array({ v, v }))
  assert(not ok and assert(failed).message:find("nested past 64", 1, true) ~= nil)
end
