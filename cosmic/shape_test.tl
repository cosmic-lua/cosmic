local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local record Server
  host: string
  port: integer
  tls: boolean?
end

local SERVER <const> = Shape.record_of("Server")

local R <const> = Shape.raw

local function must<T>(v: T?, err: string): T
  if v == nil then
    error(err)
  end
  return v
end

--- `value` checked against the untyped `node` is refused with `want`.
local function fails(value: any, node: Shape.Node, want: string)
  local v, err = R.check(value, node)
  assert(v == nil, "expected a failure: " .. want)
  assert(err == want, ("wanted %q, got %q"):format(want, err))
end

local function test_a_record_answers_a_copy_of_the_fields_it_names()
  local decoded: {string: any} = { host = "localhost", port = 8080, extra = { 1, 2 } }
  local s = must(Shape.into(decoded, SERVER.spec))
  assert(s.host == "localhost" and s.port == 8080 and s.tls == nil)
  assert(Json.encode_any(s) == '{"host":"localhost","port":8080}', "a field the spec does not name was kept")
  assert(not rawequal(s, decoded), "into answered the table it was given")
  assert(decoded.extra ~= nil, "into wrote to its input")
end

local function test_a_mismatch_names_its_path()
  fails({ host = "h", port = "8080" }, SERVER.spec.node, "$.port: want integer, got string")
  fails({ port = 1 }, SERVER.spec.node, "$.host: missing")
  fails("text", SERVER.spec.node, "$: want record, got string")
  fails(must(Json.decode('[{"id": "a"}, {"id": 2}]')), R.list(R.record({ id = R.string })),
    "$[1].id: want string, got integer")
  local by_key: {string: {string: boolean}} = { ["a key"] = { n = true } }
  fails(by_key, R.map(R.record({ n = R.number })), '$["a key"].n: want number, got boolean')
end

-- Fields are checked in byte order, so two failing fields always
-- report the same one, whatever order the table was built in.
local function test_the_first_failure_is_the_same_every_run()
  local node = R.record({ b = R.string, a = R.string, c = R.string })
  for _ = 1, 10 do
    fails({ c = 1, b = 1 }, node, "$.a: missing")
  end
end

-- A map's values, and a list's elements, go in key order too: a map
-- reports its least failing key, whichever `next` meets first. Forty
-- keys, built in two orders, leave `next` little chance of meeting
-- the least first in both.
local function test_a_map_reports_its_least_failing_key()
  local spec = Shape.map(Shape.string)
  local forward: mut {string: integer} = {}
  local backward: mut {string: integer} = {}
  for i = 1, 40 do forward["k" .. string.format("%02d", i)] = i end
  for i = 40, 1, -1 do backward["k" .. string.format("%02d", i)] = i end
  fails(forward, spec.node, "$.k01: want string, got integer")
  fails(backward, spec.node, "$.k01: want string, got integer")
end

local function test_a_list_reports_its_first_miss_in_index_order()
  local spec = Shape.list(Shape.string)
  fails({ [1] = 1, [3] = "c" }, spec.node, "$[0]: want string, got integer")
  fails({ [1] = "a", [3] = 3 }, spec.node, "$[1]: missing")
end

local function test_integer_takes_a_whole_float_and_nothing_else()
  local v = must(Shape.into(8080.0, Shape.integer))
  assert(math.type(v) == "integer" and v == 8080)
  fails(1.5, Shape.integer.node, "$: want integer, got 1.5")
  fails(2.0 ^ 63, Shape.integer.node, "$: want integer, got " .. tostring(2.0 ^ 63))
  fails(0 / 0, Shape.integer.node, "$: want integer, got " .. tostring(0 / 0))
  fails("1", Shape.integer.node, "$: want integer, got string")
  fails("1", Shape.number.node, "$: want number, got string")
  local f = must(Shape.into(1.5, Shape.number))
  assert(f == 1.5)
end

local function test_a_list_is_keyed_from_one()
  local strings = Shape.list(Shape.string)
  local l = must(Shape.into({ "a", "b" }, strings))
  assert(#l == 2 and l[2] == "b")
  local empty = must(Shape.into({}, strings))
  assert(#empty == 0)
  fails({ [1] = "a", [3] = "c" }, strings.node, "$[1]: missing")
  fails({ [2] = "b" }, strings.node, "$[0]: missing")
  fails({ x = "a" }, strings.node, '$: want list, got the string key "x"')
  fails({ [0] = "a" }, strings.node, "$: want list, got the integer key 0")
  fails({ [1.5] = "a" }, strings.node, "$: want list, got the float key 1.5")
end

-- A list answers a JSON array, so an empty one encodes back as `[]`,
-- whether it came from JSON or was built in Lua.
local function test_a_list_answers_a_json_array()
  local integers = Shape.list(Shape.integer)
  local from_json = must(Shape.into(must(Json.decode("[]")), integers))
  assert(Json.is_array(from_json))
  assert(must(Json.encode(from_json)) == "[]")
  local from_lua = must(Shape.into({}, integers))
  assert(must(Json.encode(from_lua)) == "[]")
end

-- A JSON array is not an object, even an empty one.
local function test_a_map_or_record_refuses_a_json_array()
  local empty = must(Json.decode("[]"))
  fails(empty, R.map(R.string), "$: want map, got array")
  fails(empty, R.record({ a = R.optional(R.string) }), "$: want record, got array")
  fails(must(Json.decode('{"a": [1]}')), R.record({ a = R.string }), "$.a: want string, got array")
end

-- A strict record names the first key it does not know, before the
-- field that key was probably meant to be, and whatever its value.
local function test_a_strict_record_refuses_a_key_it_does_not_name()
  local strict = SERVER:strict()
  local s = must(Shape.into({ host = "h", port = 1, tls = Json.null }, strict.spec))
  assert(s.host == "h" and s.port == 1 and s.tls == nil)
  fails({ host = "h", prot = 1 }, strict.spec.node, "$.prot: unknown key")
  fails({ host = "h", port = 1, zz = 1, ["a key"] = 1 }, strict.spec.node, '$[\"a key\"]: unknown key')
  fails({ host = "h", port = 1, tlss = Json.null }, strict.spec.node, "$.tlss: unknown key")
  fails({ host = "h", port = 1, [1] = "x" }, strict.spec.node, "$: want record, got the integer key 1")
  fails(must(Json.decode("[]")), strict.spec.node, "$: want record, got array")
  -- Nested, and optional, it is still strict.
  local node = R.strict_record({ host = R.string, port = R.integer, tls = R.optional(R.boolean) })
  local outer = R.record({ server = R.optional(node) })
  fails({ server = { host = "h", port = 1, extra = true } }, outer, "$.server.extra: unknown key")
  local none, err = R.check({}, outer)
  assert(none ~= nil, err)
  -- A record the strict form is made of is made strict whatever it is nested in.
  local record Outer
    server: Server?
  end
  local OUTER <const> = Shape.record_of("Outer"):strict()
  fails({ server = { host = "h", port = 1, extra = true } }, OUTER.spec.node, "$.server.extra: unknown key")
  local raised, _ = pcall(R.strict_record, { a = "string" as Shape.Node })
  assert(not raised)
end

local function test_a_map_refuses_a_key_that_is_not_a_string()
  local m = must(Shape.into({ a = 1, b = 2.0 }, Shape.map(Shape.integer)))
  assert(m.a == 1 and math.type(m.b) == "integer")
  fails({ a = 1, [2] = 2 }, Shape.map(Shape.integer).node, "$: want map, got the integer key 2")
end

-- [`Json.null`] is a missing value: optional admits it and answers nil,
-- and a required field refuses it by name.
local function test_json_null_is_a_missing_value()
  local text = '{"host": "h", "port": 1, "tls": null}'
  local keep: Json.DecodeOptions = { null_value = Json.null }
  local s = must(Shape.into(must(Json.decode(text, keep)), SERVER.spec))
  assert(s.tls == nil)
  fails(must(Json.decode('{"host": null, "port": 1}', keep)), SERVER.spec.node, "$.host: missing")
  fails({ host = "h", port = Json.null }, R.record({ port = R.integer }), "$.port: missing")
  -- An array holds no hole, so a list whose elements may be missing is a map from the indexes that are there.
  local sparse = Shape.sparse_list(Shape.optional(Shape.integer))
  local l = must(Shape.into(must(Json.decode("[1, null, 3]", keep)), sparse))
  assert(l[1] == 1 and l[2] == nil and l[3] == 3)
  -- Decoded without a stand-in, the null leaves a hole, which is the
  -- same missing element.
  local holed = must(Shape.into(must(Json.decode("[1, null, 3]")), sparse))
  assert(holed[3] == 3)
  fails(must(Json.decode("[1, null, 3]")), Shape.list(Shape.integer).node, "$[1]: missing")
  -- A sparse list of optional elements is walked by its keys, never by
  -- counting up to the highest one.
  local far = must(Shape.into({ [1 << 40] = 7 }, sparse))
  assert(far[1 << 40] == 7)
end

-- A whole number another encoder wrote as a float reads as an integer,
-- and a number too big for one, kept as its digits, is refused by name.
local function test_json_numbers_meet_integer()
  local port = must(Shape.into(must(Json.decode("8080.0")), Shape.integer))
  assert(math.type(port) == "integer" and port == 8080)
  local big = must(Json.decode("18446744073709551615", { big_numbers_as_strings = true }))
  fails(big, Shape.integer.node, "$: want integer, got string")
end

-- Decode, check, re-encode: the answer holds only what the spec names,
-- so a field the payload grew does not reach the output.
local function test_a_checked_payload_re_encodes_without_its_extras()
  local text = '{"port": 8080, "host": "h", "debug": {"x": 1}}'
  local s = must(Shape.into(must(Json.decode(text)), SERVER.spec))
  assert(must(Json.encode_any(s)) == '{"host":"h","port":8080}')
end

local function test_one_of_admits_only_its_values()
  local level = Shape.one_of("debug", "info")
  local v = must(Shape.into("info", level))
  assert(v == "info")
  fails("warn", level.node, '$: want one of "debug", "info", got "warn"')
  fails({}, level.node, '$: want one of "debug", "info", got table')
  local raised, _ = pcall(R.one_of)
  assert(not raised)
end

local function test_any_passes_the_value_through()
  local t = {}
  local v, err = R.check({ x = t }, R.record({ x = R.any }))
  assert(v ~= nil, err)
  fails({}, R.record({ x = R.any }), "$.x: missing")
  local anything = must(Shape.into(t, Shape.any))
  assert(rawequal(anything, t))
end

local function test_a_message_quotes_an_odd_key_as_json_does()
  fails({}, R.record({ ['a"b\n'] = R.string }), '$["a\\"b\\u000a"]: missing')
end

local function test_a_failure_names_its_path_from_the_root()
  local item = R.record({ name = R.string, tags = R.list(R.string) })
  local node = R.record({
    items = R.list(item),
    by_id = R.map(R.list(R.integer)),
  })
  local function fails_on(text: string, want: string)
    fails(must(Json.decode(text)), node, want)
  end
  local function items(fourth: string): string
    return '{"by_id": {}, "items": [' ..
      '{"name": "a", "tags": []}, {"name": "b", "tags": []}, {"name": "c", "tags": []}, ' .. fourth .. ']}'
  end
  local good, good_err = R.check(must(Json.decode(items('{"name": "d", "tags": []}'))), node)
  assert(good ~= nil, good_err)
  fails_on(items('{"name": 4, "tags": []}'), "$.items[3].name: want string, got integer")
  fails_on(items('{"tags": []}'), "$.items[3].name: missing")
  fails_on(items('{"name": null, "tags": []}'), "$.items[3].name: missing")
  fails_on(items('{"name": "d", "tags": ["x", true]}'), "$.items[3].tags[1]: want string, got boolean")
  fails_on('{"items": [], "by_id": {"7": [1, "x"]}}', '$.by_id["7"][1]: want integer, got string')
  fails_on('"text"', "$: want record, got string")
  fails_on("[]", "$: want record, got array")
  fails(nil, node, "$: missing")
end

local function test_a_key_that_is_not_an_identifier_is_quoted_in_the_path()
  local function at(key: string, want: string)
    local text = assert(Json.encode({ [key] = 1 }))
    fails(must(Json.decode(text)), R.record({ [key] = R.string }), want)
  end
  at("a b", '$["a b"]: want string, got integer')
  at("a.b", '$["a.b"]: want string, got integer')
  at("1st", '$["1st"]: want string, got integer')
  at("", '$[""]: want string, got integer')
  at("_ok9", "$._ok9: want string, got integer")
  at("na\u{ef}ve", '$["na\u{ef}ve"]: want string, got integer')
end

-- A cycle cannot run away: the walk goes only as deep as the spec does.
local function test_a_cyclic_value_is_walked_as_deep_as_the_spec()
  local t: {string: any} = { name = "loop" }
  t.self = t
  local node = R.record({ name = R.string, self = R.record({ name = R.string }) })
  local v, err = R.check(t, node)
  assert(v ~= nil, err)
  assert(Json.encode_any(v) == '{"name":"loop","self":{"name":"loop"}}')
end

local function test_a_spec_not_built_here_raises()
  local raised, _ = pcall(Shape.into, {}, {} as Shape.Spec<string>)
  assert(not raised)
  raised, _ = pcall(R.record, { a = { kind = "strig" } as any as Shape.Node })
  assert(not raised)
end

-- `into` answers one failure and not the others: a config with several
-- mistakes reports the first in the walk's order, a record's fields in
-- byte order and a list's elements by index.
local function test_into_answers_only_the_first_of_several_failures()
  local node = R.record({
    host = R.string,
    port = R.integer,
    level = R.one_of("debug", "info"),
    rows = R.list(R.record({ id = R.string })),
    tags = R.map(R.boolean),
  })
  local value: {string: any} = {
    port = "8080", level = "warn",
    rows = { { id = 1 }, { id = "b" }, { id = true } },
    tags = { b = 1, a = "x", c = true },
  }
  fails(value, node, "$.host: missing")
  value.host = "h"
  fails(value, node, '$.level: want one of "debug", "info", got "warn"')
  value.level = "info"
  fails(value, node, "$.port: want integer, got string")
  value.port = 8080
  fails(value, node, "$.rows[0].id: want string, got integer")
  value.rows = { { id = "a" } }
  fails(value, node, "$.tags.a: want boolean, got string")
end

-- A key a list, map or record refuses fails it where it stands, whatever
-- its values, and the least such key in an order no address decides is
-- the one named.
local function test_a_refused_key_is_named_before_any_value_is_looked_at()
  local bad: {any: any} = { a = 1, [{}] = true, [print] = true, [true] = 1, [10] = 1, [2] = 1, [1.5] = 1 }
  fails(bad, R.map(R.string), "$: want map, got the float key 1.5")
  fails({ a = 1, [10] = 1, [2] = 1 }, R.map(R.string), "$: want map, got the integer key 2")
  local scalar_and_function: {any: any} = { [true] = 1, [print] = 1, a = 1 }
  fails(scalar_and_function, R.map(R.string), "$: want map, got the boolean key true")
  local function_only: {any: any} = { [print] = 1, a = 1 }
  fails(function_only, R.map(R.string), "$: want map, got a function key")
  fails({ [{}] = 1 }, R.map(R.string), "$: want map, got a table key")
  fails({ "a", x = 1, [0] = 2 }, R.list(R.integer), "$: want list, got the integer key 0")
  fails({ "a", x = 1 }, R.list(R.integer), '$: want list, got the string key "x"')
  local strict = R.strict_record({ host = R.string, port = R.integer })
  fails({ prot = 1, hots = "h", port = "x", zone = true }, strict, "$.hots: unknown key")
  fails({ prot = 1, [2] = true, [1] = true }, strict, "$: want record, got the integer key 1")
  fails({ nested = { prot = 1, a = 2 } },
    R.record({ nested = R.strict_record({ port = R.optional(R.integer) }) }),
    "$.nested.a: unknown key")
end

-- A dense list stays an ordinary array: shrinking it shortens what it
-- encodes as, and a key added past its end is refused, as for any array
-- with a hole. A sparse list writes null where it has a hole.
local function test_a_dense_list_stays_a_plain_array_and_a_sparse_list_writes_null()
  -- A chunk of Lua, because the checker would not let a test change what [`Shape.into`] answers.
  local chunk = assert(load([[
    local Json, Shape = ...
    local r = assert(Shape.into({ 1, 2, 3 }, Shape.list(Shape.integer)))
    r[#r] = nil
    local shrunk = Json.encode_any(r)
    r[5] = 5
    local grown, why = Json.encode_any(r)
    local holed = assert(Shape.into({ [1] = 1, [3] = 3 }, Shape.sparse_list(Shape.optional(Shape.integer))))
    return shrunk, grown, why, Json.encode_any(holed)
  ]]))
  local shrunk, grown, why, holed: any, any, any, any = chunk(Json, Shape)
  assert(shrunk == "[1,2]", "the last element is gone, not written as null")
  assert(grown == nil and why == "json: cannot encode an array with a hole (index 3 is nil)", why)
  assert(holed == "[1,null,3]")
end

-- A hole is a missing element however the table came by it: a marked
-- array that dropped a null, an unmarked table with a gap, and a table
-- whose length is a border short of its highest index.
local function test_a_hole_is_a_missing_element_in_every_table_that_has_one()
  local optional = Shape.sparse_list(Shape.optional(Shape.integer))
  local required = Shape.list(Shape.integer)
  local decoded = must(Json.decode("[1, null, null, 4, null]"))
  local l = must(Shape.into(decoded, optional))
  assert(l[1] == 1 and l[2] == nil and l[4] == 4)
  fails(decoded, required.node, "$[1]: missing")
  -- Keys 1, 3 and 5, with 3 a border of the table.
  local gappy: mut {any: any} = { 1, 2, 3 }
  gappy[2] = nil
  gappy[5] = 5
  fails(gappy, required.node, "$[1]: missing")
  local g = must(Shape.into(gappy, optional))
  assert(g[1] == 1 and g[3] == 3 and g[5] == 5)
  -- A marked array with one far index is walked by its keys.
  local far = must(Shape.into(Json.array({ [1 << 40] = 7 } as {any}), optional))
  assert(far[1 << 40] == 7)
  fails(Json.array({ [1 << 40] = 7 } as {any}), required.node, "$[0]: missing")
end

-- A marked array holding a key that is no positive index is refused as
-- an unmarked table is, and nothing it holds is dropped silently.
local function test_a_marked_array_with_a_stray_key_is_refused()
  local optional = Shape.sparse_list(Shape.optional(Shape.integer))
  local function marked(key: any): {any: any}
    local t: mut {any: any} = Json.array({ 1 }) as {any: any}
    t[key] = 2
    return t
  end
  fails(marked("x"), optional.node, '$: want list, got the string key "x"')
  fails(marked(0), optional.node, "$: want list, got the integer key 0")
  fails(marked(-3), optional.node, "$: want list, got the integer key -3")
  fails(marked(1.5), optional.node, "$: want list, got the float key 1.5")
  fails(marked(true), optional.node, "$: want list, got the boolean key true")
end

-- A node the module did not build raises, wherever the walk meets it.
local function test_a_nested_node_of_unknown_kind_raises_when_met()
  local broken: {string: any} = { kind = "strig", optional = false }
  local nested: Shape.Node = { kind = "list", optional = false, of = broken as Shape.Node }
  local ok, err = pcall(R.check, { "a" }, nested)
  assert(not ok and tostring(err):find('a node of unknown kind "strig"', 1, true), tostring(err))
  local raised, _ = pcall(R.check, {}, broken as Shape.Node)
  assert(not raised)
end

local function test_decode_into_answers_a_record_from_text()
  local s = must(Shape.decode_into('{"host": "h", "port": 80, "extra": 1}', SERVER.spec))
  assert(s.host == "h" and s.port == 80 and s.tls == nil)
end

local function test_decode_into_names_a_decode_error_as_json_does()
  local text = '{"host": '
  local _, want = Json.decode(text)
  local s, err = Shape.decode_into(text, SERVER.spec)
  assert(s == nil and err ~= "" and err == want, err)
end

local function test_decode_into_names_the_path_of_a_shape_failure()
  local s, err = Shape.decode_into('{"host": "h", "port": "x"}', SERVER.spec)
  assert(s == nil)
  assert(err == "$.port: want integer, got string", err)
end

local function test_decode_into_forwards_the_decode_options()
  local text = "{host: 'h', /* why */ port: 1,}"
  local plain, err = Shape.decode_into(text, SERVER.spec)
  assert(plain == nil and err ~= "")
  local s = must(Shape.decode_into(text, SERVER.spec, { json5 = true }))
  assert(s.host == "h" and s.port == 1)
  -- null_value cannot tell: `into` treats the sentinel as missing too.
  local list = Shape.list(Shape.list(Shape.integer))
  local deep, derr = Shape.decode_into("[[1]]", list, { max_depth = 1 })
  assert(deep == nil and derr ~= "" and derr:sub(1, 1) ~= "$", derr)
  local ok = must(Shape.decode_into("[[1]]", list, { max_depth = 2 }))
  assert(assert(ok[1])[1] == 1)
end

local function test_decode_into_null_text_is_nothing_to_check()
  local s, err = Shape.decode_into("null", SERVER.spec)
  assert(s == nil and err == "$: missing", err)
  local o, oerr = Shape.decode_into("null", Shape.optional(SERVER.spec))
  assert(o == nil and oerr == "", oerr)
end

-- What the types refuse: a list whose elements may be missing is no array, and a spec says the type of its answer.
local function test_a_list_of_optional_elements_is_a_map_in_the_type()
  local slots = must(Shape.into({ 1, 2 }, Shape.sparse_list(Shape.optional(Shape.integer))))
  local first: integer? = slots[1]
  assert(first == 1)
  local raised, _ = pcall(Shape.sparse_list, Shape.integer as Shape.Spec<integer?>)
  assert(raised == false)
end

-- `any?` is `any` to the checker, so the type cannot tell a list of elements that may be missing from one that may not.
local function test_a_list_whose_element_may_be_missing_is_refused_even_where_the_type_cannot_say()
  local raised, why = pcall(Shape.list, Shape.optional(Shape.any))
  assert(not raised and tostring(why):find("use `Shape.sparse_list`", 1, true) ~= nil, tostring(why))
end

--- What `run` raises, or nil where it returns.
local function raised(run: function()): string?
  local ok, why = pcall(run)
  if ok then
    return nil
  end
  return tostring(why)
end

--- Whether `run` raises that a spec of the caller's was not made by cosmic.shape.
local function refuses_a_forgery(run: function()): boolean
  local why = raised(run)
  return why ~= nil and why:find("did not make", 1, true) ~= nil
end

-- `table_of` makes a spec of a table of untrusted values from a record or map node, and no other.
local function test_table_of_takes_a_record_or_a_map_and_no_other()
  local spec = R.table_of(R.record({ a = R.string }))
  local ok = must(Shape.into(must(Json.decode('{"a": "x"}')), spec))
  assert(ok["a"] == "x")
  assert(raised(function() local _ = R.table_of(R.string) end) ~= nil)
  assert(raised(function() local _ = R.table_of(R.list(R.string)) end) ~= nil)
end

-- A `Spec<T>` is a table anyone can write, and what ties its `T` to its check is that cosmic.shape made it: a spec written
-- by hand is refused wherever it is used, as the answer's type would be the writer's claim.
local function test_a_spec_written_by_hand_is_refused_wherever_it_is_used()
  local dense: Shape.Spec<{integer}> = { node = R.list(R.optional(R.integer)) }
  local holey = must(Json.decode("[1, null, 3]"))
  assert(refuses_a_forgery(function() local _ = Shape.into(holey, dense) end))
  local text: Shape.Spec<string> = { node = R.any }
  assert(refuses_a_forgery(function() local _ = Shape.into(5, text) end))
  assert(refuses_a_forgery(function() local _ = Shape.decode_into("5", text) end))
  -- a made spec's own node is its alone: the leaves of `Raw` are shared, and a spec of one is still hand-written
  local shared: Shape.Spec<string> = { node = R.string }
  assert(refuses_a_forgery(function() local _ = Shape.into("a", shared) end))
  -- nor does a constructor build on one
  assert(refuses_a_forgery(function() local _ = Shape.list(text) end))
  assert(refuses_a_forgery(function() local _ = Shape.optional(text) end))
  assert(refuses_a_forgery(function() local _ = Shape.map(text) end))
  local optional: Shape.Spec<integer?> = { node = R.optional(R.integer) }
  assert(refuses_a_forgery(function() local _ = Shape.sparse_list(optional) end))
  -- a record written by hand answers through a spec written by hand
  local forged: Shape.Typed<Server> = {
    name = "Server", spec = { node = R.record({ host = R.string }) },
    into = SERVER.into, decode_into = SERVER.decode_into, strict = SERVER.strict,
  }
  assert(refuses_a_forgery(function() local _ = forged:into({ host = "h" }) end))
  assert(refuses_a_forgery(function() local _ = forged:strict() end))
  -- the specs the module makes are taken, strict ones included, and `strict` keeps its answer
  assert(Shape.into("x", Shape.string) == "x")
  assert(SERVER:strict() == SERVER:strict() and SERVER:strict():strict() == SERVER:strict())
end
