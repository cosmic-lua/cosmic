local check = require("cosmic.check")
local json = require("cosmic.json")
local shape = require("cosmic.shape")

local record Meta
  name: string
  count: integer
  ok: boolean
  note: string
end

local META < const > = shape.record({
    name = shape.string,
    count = shape.integer,
    ok = shape.boolean,
    note = shape.optional(shape.string),
  })

local function test_valid_flat_record()
  local raw = check.must(json.decode_object('{"name":"a","count":2,"ok":true}'))
  local m: Meta = check.must(shape.into(raw, META))
  assert(m.name == "a", "name: " .. tostring(m.name))
  assert(m.count == 2, "count: " .. tostring(m.count))
  assert(m.ok == true, "ok: " .. tostring(m.ok))
  assert(m.note == nil, "an absent optional stays nil")
end
test_valid_flat_record()

local function test_wrong_typed_field_names_its_path()
  local raw = check.must(json.decode_object('{"name":1,"count":2,"ok":true}'))
  local m, err: Meta | nil, string = shape.into(raw, META)
  assert(m == nil, "a wrong-typed field must not validate")
  assert(err == "name: expected string, got number", "got: " .. tostring(err))
end
test_wrong_typed_field_names_its_path()

local function test_missing_required_field()
  local raw = check.must(json.decode_object('{"name":"a","ok":true}'))
  local m, err: Meta | nil, string = shape.into(raw, META)
  assert(m == nil, "a missing required field must not validate")
  assert(err == "count: missing", "got: " .. tostring(err))
end
test_missing_required_field()

-- A JSON null decodes to nil, so an absent key and a null-valued one
-- reach `into` as the same thing and optional admits both.
local function test_optional_admits_absent_and_null()
  local absent = check.must(json.decode_object('{"name":"a","count":1,"ok":false}'))
  local m1: Meta = check.must(shape.into(absent, META))
  assert(m1.note == nil, "absent optional: " .. tostring(m1.note))
  local nulled = check.must(
    json.decode_object('{"name":"a","count":1,"ok":false,"note":null}'))
  local m2: Meta = check.must(shape.into(nulled, META))
  assert(m2.note == nil, "null optional: " .. tostring(m2.note))
end
test_optional_admits_absent_and_null()

-- A payload that grows a field must not start failing, so keys the
-- Spec does not name are ignored rather than refused.
local function test_extra_key_is_ignored()
  local raw = check.must(
    json.decode_object('{"name":"a","count":1,"ok":true,"added_later":[1,2]}'))
  local m: Meta = check.must(shape.into(raw, META))
  assert(m.name == "a", "the declared fields still read")
end
test_extra_key_is_ignored()

local record Counted
  n: integer
end

local COUNTED < const > = shape.record({n = shape.integer})

local function test_integer_accepts_whole_float_and_rejects_fraction()
  local whole: {string: any} = {n = 3.0}
  local m: Counted = check.must(shape.into(whole, COUNTED))
  assert(m.n == 3, "value: " .. tostring(m.n))
  assert(math.type(m.n) == "integer", "normalized in place, got " .. tostring(math.type(m.n)))
  local fraction: {string: any} = {n = 3.5}
  local bad, err: Counted | nil, string = shape.into(fraction, COUNTED)
  assert(bad == nil, "a fractional number is not an integer")
  assert(err == "n: expected integer, got a fractional number", "got: " .. tostring(err))
end
test_integer_accepts_whole_float_and_rejects_fraction()

local COUNTS < const > = shape.list(shape.integer)

local function test_list_rejects_a_non_list_and_names_a_bad_index()
  local ok, oerr: {integer} | nil, string = shape.into({1, 2, 3}, COUNTS)
  assert(ok ~= nil and #ok == 3, "a real list validates: " .. tostring(oerr))
  local not_a_list: {string: any} = {a = 1}
  local m, err: {integer} | nil, string = shape.into(not_a_list, COUNTS)
  assert(m == nil, "an object is not a list")
  assert(err == "value: expected list, got a table with non-list keys",
    "got: " .. tostring(err))
  local bad, berr: {integer} | nil, string = shape.into({1, "two", 3}, COUNTS)
  assert(bad == nil, "a bad element fails the list")
  assert(berr == "[2]: expected integer, got string", "got: " .. tostring(berr))
end
test_list_rejects_a_non_list_and_names_a_bad_index()

local SHAS < const > = shape.map(shape.string)

local function test_map_checks_every_value()
  local raw = check.must(json.decode_object('{"linux":"aa","mac":"bb"}'))
  local m: {string: string} = check.must(shape.into(raw, SHAS))
  assert(m.linux == "aa" and m.mac == "bb", "both values read as strings")
  local mixed = check.must(json.decode_object('{"linux":"aa","mac":7}'))
  local bad, err: {string: string} | nil, string = shape.into(mixed, SHAS)
  assert(bad == nil, "a wrong-typed map value fails")
  assert(err == "mac: expected string, got number", "got: " .. tostring(err))
end
test_map_checks_every_value()

local record Holder
  payload: any
end

local HOLDER < const > = shape.record({payload = shape.any})

local function test_any_accepts_a_value_and_refuses_nil()
  local held: {string: any} = {payload = {1, 2}}
  local m: Holder = check.must(shape.into(held, HOLDER))
  assert(m.payload ~= nil, "any takes a table")
  local empty: {string: any} = {}
  local bad, err: Holder | nil, string = shape.into(empty, HOLDER)
  assert(bad == nil, "any is still required unless wrapped in optional")
  assert(err == "payload: missing", "got: " .. tostring(err))
end
test_any_accepts_a_value_and_refuses_nil()

local record Row
  id: string
end

local record Report
  rows: {Row}
end

local REPORT < const > = shape.record({
    rows = shape.list(shape.record({id = shape.string})),
  })

local function test_nested_mismatch_carries_the_full_path()
  local raw = check.must(json.decode_object('{"rows":[{"id":"a"},{"id":9}]}'))
  local m, err: Report | nil, string = shape.into(raw, REPORT)
  assert(m == nil, "a nested mismatch fails the whole value")
  assert(err == "rows[2].id: expected string, got number", "got: " .. tostring(err))
  local good = check.must(json.decode_object('{"rows":[{"id":"a"}]}'))
  local r: Report = check.must(shape.into(good, REPORT))
  assert(r.rows[1].id == "a", "the nested field reads without a cast")
end
test_nested_mismatch_carries_the_full_path()

-- The returned table is the same table, not a copy: callers that
-- already hold the decoded value keep holding it.
local function test_into_returns_the_same_table()
  local raw: {string: any} = {name = "a", count = 1, ok = true}
  local m: Meta = check.must(shape.into(raw, META))
  raw.name = "b"
  assert(m.name == "b", "into returns the same table, got: " .. tostring(m.name))
end
test_into_returns_the_same_table()
