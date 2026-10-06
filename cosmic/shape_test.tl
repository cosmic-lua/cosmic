local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local record Server
  host: string
  port: integer
  tls: boolean
end

local SERVER <const> = Shape.record({
  host = Shape.string,
  port = Shape.integer,
  tls = Shape.optional(Shape.boolean),
})

local function must<T>(v: T | nil, err: string): T
  assert(err == "", err)
  return v as T
end

local function fails(value: any, spec: Shape.Spec, want: string)
  local v, err: any, string = Shape.into(value, spec)
  assert(v == nil, "expected a failure: " .. want)
  assert(err == want, ("wanted %q, got %q"):format(want, err))
end

local function test_a_record_answers_a_copy_of_the_fields_it_names()
  local decoded: {string: any} = { host = "localhost", port = 8080, extra = { 1, 2 } }
  local s: Server = must(Shape.into(decoded, SERVER))
  assert(s.host == "localhost" and s.port == 8080 and s.tls == nil)
  assert((s as {string: any}).extra == nil, "a field the spec does not name was kept")
  assert(not rawequal(s, decoded), "into answered the table it was given")
  assert(decoded.extra ~= nil, "into wrote to its input")
end

local function test_a_mismatch_names_its_path()
  fails({ host = "h", port = "8080" }, SERVER, "pointer \"/port\": expected integer, got string")
  fails({ port = 1 }, SERVER, "pointer \"/host\": expected string, got nothing")
  fails("text", SERVER, "pointer \"\": expected record, got string")
  local rows = Shape.list(Shape.record({ id = Shape.string }))
  fails({ { id = "a" }, { id = 2 } }, rows, "pointer \"/1/id\": expected string, got integer")
  local by_key = Shape.map(Shape.record({ n = Shape.number }))
  fails({ ["a key"] = { n = true } }, by_key, 'pointer "/a key/n": expected number, got boolean')
end

-- Fields are checked in byte order, so two failing fields always
-- report the same one, whatever order the table was built in.
local function test_the_first_failure_is_the_same_every_run()
  local spec = Shape.record({ b = Shape.string, a = Shape.string, c = Shape.string })
  for _ = 1, 10 do
    fails({ c = 1, b = 1 }, spec, "pointer \"/a\": expected string, got nothing")
  end
end

-- A map's values, and a list's elements, go in key order too: a map
-- reports its least failing key, whichever `next` meets first. Forty
-- keys, built in two orders, leave `next` little chance of meeting
-- the least first in both.
local function test_a_map_reports_its_least_failing_key()
  local spec = Shape.map(Shape.string)
  local forward: {string: integer} = {}
  local backward: {string: integer} = {}
  for i = 1, 40 do forward["k" .. string.format("%02d", i)] = i end
  for i = 40, 1, -1 do backward["k" .. string.format("%02d", i)] = i end
  fails(forward, spec, "pointer \"/k01\": expected string, got integer")
  fails(backward, spec, "pointer \"/k01\": expected string, got integer")
end

local function test_a_list_reports_its_first_miss_in_index_order()
  local spec = Shape.list(Shape.string)
  fails({ [1] = 1, [3] = "c" }, spec, "pointer \"/0\": expected string, got integer")
  fails({ [1] = "a", [3] = 3 }, spec, "pointer \"/1\": expected string, got nothing")
end

local function test_integer_takes_a_whole_float_and_nothing_else()
  local v: integer = must(Shape.into(8080.0, Shape.integer))
  assert(math.type(v) == "integer" and v == 8080)
  fails(1.5, Shape.integer, "pointer \"\": expected integer, got 1.5")
  fails(2.0 ^ 63, Shape.integer, "pointer \"\": expected integer, got " .. tostring(2.0 ^ 63))
  fails(0 / 0, Shape.integer, "pointer \"\": expected integer, got " .. tostring(0 / 0))
  fails("1", Shape.integer, "pointer \"\": expected integer, got string")
  fails("1", Shape.number, "pointer \"\": expected number, got string")
  local f: number = must(Shape.into(1.5, Shape.number))
  assert(f == 1.5)
end

local function test_a_list_is_keyed_from_one()
  local l: {string} = must(Shape.into({ "a", "b" }, Shape.list(Shape.string)))
  assert(#l == 2 and l[2] == "b")
  local empty: {string} = must(Shape.into({}, Shape.list(Shape.string)))
  assert(#empty == 0)
  fails({ [1] = "a", [3] = "c" }, Shape.list(Shape.string), "pointer \"/1\": expected string, got nothing")
  fails({ [2] = "b" }, Shape.list(Shape.string), "pointer \"/0\": expected string, got nothing")
  fails({ x = "a" }, Shape.list(Shape.string), 'pointer "": expected list, got the string key "x"')
  fails({ [0] = "a" }, Shape.list(Shape.string), "pointer \"\": expected list, got the integer key 0")
  fails({ [1.5] = "a" }, Shape.list(Shape.string), "pointer \"\": expected list, got the float key 1.5")
end

-- A list answers a JSON array, so an empty one encodes back as `[]`,
-- whether it came from JSON or was built in Lua.
local function test_a_list_answers_a_json_array()
  local from_json: {integer} = must(Shape.into(must(Json.decode("[]")), Shape.list(Shape.integer)))
  assert(Json.is_array(from_json))
  assert(must(Json.encode(from_json)) == "[]")
  local from_lua: {integer} = must(Shape.into({}, Shape.list(Shape.integer)))
  assert(must(Json.encode(from_lua)) == "[]")
end

-- A JSON array is not an object, even an empty one.
local function test_a_map_or_record_refuses_a_json_array()
  local empty = must(Json.decode("[]"))
  fails(empty, Shape.map(Shape.string), "pointer \"\": expected map, got array")
  fails(empty, Shape.record({ a = Shape.optional(Shape.string) }), "pointer \"\": expected record, got array")
  fails(must(Json.decode('{"a": [1]}')), Shape.record({ a = Shape.string }), "pointer \"/a\": expected string, got array")
end

-- A strict record names the first key it does not know, before the
-- field that key was probably meant to be, and whatever its value.
local function test_a_strict_record_refuses_a_key_it_does_not_name()
  local strict = Shape.strict_record({
    host = Shape.string,
    port = Shape.integer,
    tls = Shape.optional(Shape.boolean),
  })
  local s: Server = must(Shape.into({ host = "h", port = 1, tls = Json.null }, strict))
  assert(s.host == "h" and s.port == 1 and s.tls == nil)
  fails({ host = "h", prot = 1 }, strict, "pointer \"/prot\": unknown key")
  fails({ host = "h", port = 1, zz = 1, ["a key"] = 1 }, strict, 'pointer "/a key": unknown key')
  fails({ host = "h", port = 1, tlss = Json.null }, strict, "pointer \"/tlss\": unknown key")
  fails({ host = "h", port = 1, [1] = "x" }, strict, "pointer \"\": expected record, got the integer key 1")
  fails(must(Json.decode("[]")), strict, "pointer \"\": expected record, got array")
  -- Nested, and optional, it is still strict.
  local outer = Shape.record({ server = Shape.optional(strict) })
  fails({ server = { host = "h", port = 1, extra = true } }, outer, "pointer \"/server/extra\": unknown key")
  local none: {string: any} = must(Shape.into({}, outer))
  assert(none.server == nil)
  local ok, err = pcall(Shape.strict_record, { a = "string" as Shape.Spec })
  assert(not ok and tostring(err):find('shape: strict_record\'s field "a" is not a Spec', 1, true), tostring(err))
end

local function test_a_map_refuses_a_key_that_is_not_a_string()
  local m: {string: integer} = must(Shape.into({ a = 1, b = 2.0 }, Shape.map(Shape.integer)))
  assert(m.a == 1 and math.type(m.b) == "integer")
  fails({ a = 1, [2] = 2 }, Shape.map(Shape.integer), "pointer \"\": expected map, got the integer key 2")
end

-- [`Json.null`] is a missing value: optional admits it and answers nil,
-- and a required field refuses it by name.
local function test_json_null_is_a_missing_value()
  local text = '{"host": "h", "port": 1, "tls": null}'
  local keep: Json.DecodeOptions = { null_value = Json.null }
  local s: Server = must(Shape.into(must(Json.decode(text, keep)), SERVER))
  assert(s.tls == nil)
  fails(must(Json.decode('{"host": null, "port": 1}', keep)), SERVER, "pointer \"/host\": expected string, got nothing")
  fails({ host = "h", port = Json.null }, Shape.record({ port = Shape.integer }),
    "pointer \"/port\": expected integer, got nothing")
  local l: {integer} = must(Shape.into(must(Json.decode("[1, null, 3]", keep)),
    Shape.list(Shape.optional(Shape.integer))))
  assert(l[1] == 1 and l[2] == nil and l[3] == 3)
  -- Decoded without a stand-in, the null leaves a hole, which is the
  -- same missing element.
  local holed: {integer} = must(Shape.into(must(Json.decode("[1, null, 3]")),
    Shape.list(Shape.optional(Shape.integer))))
  assert(holed[3] == 3)
  fails(must(Json.decode("[1, null, 3]")), Shape.list(Shape.integer), "pointer \"/1\": expected integer, got nothing")
  -- A sparse list of optional elements is walked by its keys, never by
  -- counting up to the highest one.
  local far: {integer} = must(Shape.into({ [1 << 40] = 7 }, Shape.list(Shape.optional(Shape.integer))))
  assert(far[1 << 40] == 7)
end

-- A whole number another encoder wrote as a float reads as an integer,
-- and a number too big for one, kept as its digits, is refused by name.
local function test_json_numbers_meet_integer()
  local port: integer = must(Shape.into(must(Json.decode("8080.0")), Shape.integer))
  assert(math.type(port) == "integer" and port == 8080)
  local big = must(Json.decode("18446744073709551615", { big_numbers_as_strings = true }))
  fails(big, Shape.integer, "pointer \"\": expected integer, got string")
end

-- Decode, check, re-encode: the answer holds only what the spec names,
-- so a field the payload grew does not reach the output.
local function test_a_checked_payload_re_encodes_without_its_extras()
  local text = '{"port": 8080, "host": "h", "debug": {"x": 1}}'
  local s: Server = must(Shape.into(must(Json.decode(text)), SERVER))
  assert(must(Json.encode(s)) == '{"host":"h","port":8080}')
end

local function test_one_of_admits_only_its_values()
  local level = Shape.one_of("debug", "info")
  local v: string = must(Shape.into("info", level))
  assert(v == "info")
  fails("warn", level, 'pointer "": expected one of "debug", "info", got "warn"')
  fails({}, level, 'pointer "": expected one of "debug", "info", got table')
  assert(not pcall(Shape.one_of))
end

local function test_any_passes_the_value_through()
  local t = {}
  local v: any = must(Shape.into({ x = t }, Shape.record({ x = Shape.any })))
  assert((v as {string: any}).x == t)
  fails({}, Shape.record({ x = Shape.any }), "pointer \"/x\": expected any, got nothing")
end

local function test_a_message_quotes_an_odd_key_as_json_does()
  local spec = Shape.record({ ['a"b\n'] = Shape.string })
  fails({}, spec, 'pointer "/a\\"b\\u000a": expected string, got nothing')
end

-- A cycle cannot run away: the walk goes only as deep as the spec does.
local function test_a_cyclic_value_is_walked_as_deep_as_the_spec()
  local t: {string: any} = { name = "loop" }
  t.self = t
  local spec = Shape.record({ name = Shape.string, self = Shape.record({ name = Shape.string }) })
  local v: {string: any} = must(Shape.into(t, spec))
  assert(((v.self) as {string: any}).name == "loop")
end

local function test_a_spec_not_built_here_raises()
  assert(not pcall(Shape.into, {}, {} as Shape.Spec))
  assert(not pcall(Shape.list, "string" as Shape.Spec))
  assert(not pcall(Shape.record, { a = { kind = "strig" } as any as Shape.Spec }))
end

-- `into` answers one failure and not the others: a config with several
-- mistakes reports the first in the walk's order, a record's fields in
-- byte order and a list's elements by index.
local function test_into_answers_only_the_first_of_several_failures()
  local spec = Shape.record({
    host = Shape.string,
    port = Shape.integer,
    level = Shape.one_of("debug", "info"),
    rows = Shape.list(Shape.record({ id = Shape.string })),
    tags = Shape.map(Shape.boolean),
  })
  local value: {string: any} = {
    port = "8080", level = "warn",
    rows = { { id = 1 }, { id = "b" }, { id = true } },
    tags = { b = 1, a = "x", c = true },
  }
  fails(value, spec, "pointer \"/host\": expected string, got nothing")
  value.host = "h"
  fails(value, spec, 'pointer "/level": expected one of "debug", "info", got "warn"')
  value.level = "info"
  fails(value, spec, "pointer \"/port\": expected integer, got string")
  value.port = 8080
  fails(value, spec, "pointer \"/rows/0/id\": expected string, got integer")
  value.rows = { { id = "a" } }
  fails(value, spec, "pointer \"/tags/a\": expected boolean, got string")
end

-- A key a list, map or record refuses fails it where it stands, whatever
-- its values, and the least such key in an order no address decides is
-- the one named.
local function test_a_refused_key_is_named_before_any_value_is_looked_at()
  local bad: {any: any} = { a = 1, [{}] = true, [print] = true, [true] = 1, [10] = 1, [2] = 1, [1.5] = 1 }
  fails(bad, Shape.map(Shape.string), "pointer \"\": expected map, got the float key 1.5")
  fails({ a = 1, [10] = 1, [2] = 1 }, Shape.map(Shape.string), "pointer \"\": expected map, got the integer key 2")
  local scalar_and_function: {any: any} = { [true] = 1, [print] = 1, a = 1 }
  fails(scalar_and_function, Shape.map(Shape.string), "pointer \"\": expected map, got the boolean key true")
  local function_only: {any: any} = { [print] = 1, a = 1 }
  fails(function_only, Shape.map(Shape.string), "pointer \"\": expected map, got a function key")
  fails({ [{}] = 1 }, Shape.map(Shape.string), "pointer \"\": expected map, got a table key")
  fails({ "a", x = 1, [0] = 2 }, Shape.list(Shape.integer), "pointer \"\": expected list, got the integer key 0")
  fails({ "a", x = 1 }, Shape.list(Shape.integer), 'pointer "": expected list, got the string key "x"')
  local strict = Shape.strict_record({ host = Shape.string, port = Shape.integer })
  fails({ prot = 1, hots = "h", port = "x", zone = true }, strict, "pointer \"/hots\": unknown key")
  fails({ prot = 1, [2] = true, [1] = true }, strict, "pointer \"\": expected record, got the integer key 1")
  fails({ nested = { prot = 1, a = 2 } },
    Shape.record({ nested = Shape.strict_record({ port = Shape.optional(Shape.integer) }) }),
    "pointer \"/nested/a\": unknown key")
end

-- A hole is a missing element however the table came by it: a marked
-- array that dropped a null, an unmarked table with a gap, and a table
-- whose length is a border short of its highest index.
local function test_a_hole_is_a_missing_element_in_every_table_that_has_one()
  local optional = Shape.list(Shape.optional(Shape.integer))
  local required = Shape.list(Shape.integer)
  local decoded = must(Json.decode("[1, null, null, 4, null]"))
  local l: {integer} = must(Shape.into(decoded, optional))
  assert(l[1] == 1 and l[2] == nil and l[4] == 4 and #l ~= 5)
  fails(decoded, required, "pointer \"/1\": expected integer, got nothing")
  -- Keys 1, 3 and 5, with 3 a border of the table.
  local gappy: {any: any} = { 1, 2, 3 }
  gappy[2] = nil
  gappy[5] = 5
  fails(gappy, required, "pointer \"/1\": expected integer, got nothing")
  local g: {integer} = must(Shape.into(gappy, optional))
  assert(g[1] == 1 and g[3] == 3 and g[5] == 5)
  -- A marked array with one far index is walked by its keys.
  local far: {integer} = must(Shape.into(Json.array({ [1 << 40] = 7 } as {any}), optional))
  assert(far[1 << 40] == 7)
  fails(Json.array({ [1 << 40] = 7 } as {any}), required, "pointer \"/0\": expected integer, got nothing")
end

-- A marked array holding a key that is no positive index is refused as
-- an unmarked table is, and nothing it holds is dropped silently.
local function test_a_marked_array_with_a_stray_key_is_refused()
  local optional = Shape.list(Shape.optional(Shape.integer))
  local function marked(key: any): {any: any}
    local t: {any: any} = Json.array({ 1 }) as {any: any}
    t[key] = 2
    return t
  end
  fails(marked("x"), optional, 'pointer "": expected list, got the string key "x"')
  fails(marked(0), optional, "pointer \"\": expected list, got the integer key 0")
  fails(marked(-3), optional, "pointer \"\": expected list, got the integer key -3")
  fails(marked(1.5), optional, "pointer \"\": expected list, got the float key 1.5")
  fails(marked(true), optional, "pointer \"\": expected list, got the boolean key true")
end

-- A Spec the module did not build raises, wherever the walk meets it.
local function test_a_nested_spec_of_unknown_kind_raises_when_met()
  local broken: {string: any} = { kind = "strig", optional = false }
  local nested: Shape.Spec = { kind = "list", optional = false, of = broken as Shape.Spec }
  local ok, err = pcall(Shape.into, { "a" }, nested)
  assert(not ok and tostring(err):find('a Spec of unknown kind "strig"', 1, true), tostring(err))
  assert(not pcall(Shape.into, {}, broken as Shape.Spec))
end

local function test_decode_into_answers_a_record_from_text()
  local s: Server = must(Shape.decode_into('{"host": "h", "port": 80, "extra": 1}', SERVER))
  assert(s.host == "h" and s.port == 80 and s.tls == nil)
end

local function test_decode_into_names_a_decode_error_as_json_does()
  local text = '{"host": '
  local _, want = Json.decode(text)
  local s, err: Server | nil, string = Shape.decode_into(text, SERVER)
  assert(s == nil and err ~= "" and err == want, err)
end

local function test_decode_into_names_the_path_of_a_shape_failure()
  local s, err: Server | nil, string = Shape.decode_into('{"host": "h", "port": "x"}', SERVER)
  assert(s == nil)
  assert(err == "pointer \"/port\": expected integer, got string", err)
end

local function test_decode_into_forwards_the_decode_options()
  local text = "{host: 'h', /* why */ port: 1,}"
  local plain, err: Server | nil, string = Shape.decode_into(text, SERVER)
  assert(plain == nil and err ~= "")
  local s: Server = must(Shape.decode_into(text, SERVER, { json5 = true }))
  assert(s.host == "h" and s.port == 1)
  -- null_value cannot tell: `into` treats the sentinel as missing too.
  local list = Shape.list(Shape.list(Shape.integer))
  local deep, derr: {{integer}} | nil, string = Shape.decode_into("[[1]]", list, { max_depth = 1 })
  assert(deep == nil and derr ~= "" and derr:sub(1, 8) ~= "pointer ", derr)
  local ok: {{integer}} = must(Shape.decode_into("[[1]]", list, { max_depth = 2 }))
  assert(ok[1][1] == 1)
end

local function test_decode_into_null_text_is_nothing_to_check()
  local s, err: Server | nil, string = Shape.decode_into("null", SERVER)
  assert(s == nil and err == "pointer \"\": expected record, got nothing", err)
  local o, oerr: Server | nil, string = Shape.decode_into("null", Shape.optional(SERVER))
  assert(o == nil and oerr == "", oerr)
end
