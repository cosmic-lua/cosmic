local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local record Server
  host: string
  port: integer
  tls: boolean?
end

local SERVER <const> = Shape.record_of("Server")

local record Item
  name: string
  tags: {string}
end

local record Doc
  items: {Item}
  by_id: {string: {integer}}
end

local record Row
  id: string
end

local enum Level
  "debug"
  "info"
end

local record Cfg
  host: string
  port: integer
  level: Level
  rows: {Row}
  tags: {string: boolean}
end

local record Pair
  b: string
  a: string
  c: string
end

local record Loose
  a: string?
end

local record Tagged
  any: any
end

local record Odd
  ["a b"]: string
  ["a-b"]: string
  ["1st"]: string
  _ok9: string
end

local record Inner
  name: string
end

local record Looping
  name: string
  self: Inner
end

local record Port
  port: integer
end

local record Nested
  nested: Port
end

local function must<T>(v: T?, err: string): T
  if v == nil then
    error(err)
  end
  return v
end

--- `value` checked against the spec is refused with `want`.
local function fails<T>(value: any, spec: Shape.Spec<T>, want: string)
  local v, err = Shape.into(value, spec)
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
  fails({ host = "h", port = "8080" }, SERVER.spec, "$.port: want integer, got string")
  fails({ port = 1 }, SERVER.spec, "$.host: missing")
  fails("text", SERVER.spec, "$: want record, got string")
  fails(must(Json.decode('[{"id": "a"}, {"id": 2}]')), Shape.list(Shape.record_of("Row").spec),
    "$[1].id: want string, got integer")
  local by_key: {string: {string: boolean}} = { ["a key"] = { id = true } }
  fails(by_key, Shape.map(Shape.record_of("Row").spec), '$["a key"].id: want string, got boolean')
end

local function test_the_first_failure_is_the_same_every_run()
  local spec = Shape.record_of("Pair").spec
  for _ = 1, 10 do
    fails({ c = 1, b = 1 }, spec, "$.a: missing")
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
  fails(forward, spec, "$.k01: want string, got integer")
  fails(backward, spec, "$.k01: want string, got integer")
end

local function test_a_list_reports_its_first_miss_in_index_order()
  local spec = Shape.list(Shape.string)
  fails({ [1] = 1, [3] = "c" }, spec, "$[0]: want string, got integer")
  fails({ [1] = "a", [3] = 3 }, spec, "$[1]: missing")
end

local function test_integer_takes_a_whole_float_and_nothing_else()
  local v = must(Shape.into(8080.0, Shape.integer))
  assert(math.type(v) == "integer" and v == 8080)
  fails(1.5, Shape.integer, "$: want integer, got 1.5")
  fails(2.0 ^ 63, Shape.integer, "$: want integer, got " .. tostring(2.0 ^ 63))
  fails(0 / 0, Shape.integer, "$: want integer, got " .. tostring(0 / 0))
  fails("1", Shape.integer, "$: want integer, got string")
  fails("1", Shape.number, "$: want number, got string")
  local f = must(Shape.into(1.5, Shape.number))
  assert(f == 1.5)
end

local function test_a_list_is_keyed_from_one()
  local strings = Shape.list(Shape.string)
  local l = must(Shape.into({ "a", "b" }, strings))
  assert(#l == 2 and l[2] == "b")
  local empty = must(Shape.into({}, strings))
  assert(#empty == 0)
  fails({ [1] = "a", [3] = "c" }, strings, "$[1]: missing")
  fails({ [2] = "b" }, strings, "$[0]: missing")
  fails({ x = "a" }, strings, '$: want list, got the string key "x"')
  fails({ [0] = "a" }, strings, "$: want list, got the integer key 0")
  fails({ [1.5] = "a" }, strings, "$: want list, got the float key 1.5")
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

local function test_a_map_or_record_refuses_a_json_array()
  local empty = must(Json.decode("[]"))
  fails(empty, Shape.map(Shape.string), "$: want map, got array")
  fails(empty, Shape.record_of("Loose").spec, "$: want record, got array")
  fails(must(Json.decode('{"a": [1]}')), Shape.record_of("Pair").spec, "$.a: want string, got array")
end

-- A strict record names the first key it does not know, before the
-- field that key was probably meant to be, and whatever its value.
local function test_a_strict_record_refuses_a_key_it_does_not_name()
  local strict = SERVER:strict()
  local s = must(Shape.into({ host = "h", port = 1, tls = Json.null }, strict.spec))
  assert(s.host == "h" and s.port == 1 and s.tls == nil)
  fails({ host = "h", prot = 1 }, strict.spec, "$.prot: unknown key")
  fails({ host = "h", port = 1, zz = 1, ["a key"] = 1 }, strict.spec, '$[\"a key\"]: unknown key')
  fails({ host = "h", port = 1, tlss = Json.null }, strict.spec, "$.tlss: unknown key")
  fails({ host = "h", port = 1, [1] = "x" }, strict.spec, "$: want record, got the integer key 1")
  fails(must(Json.decode("[]")), strict.spec, "$: want record, got array")
  -- A record the strict form is made of is made strict whatever it is nested in.
  local record Outer
    server: Server?
  end
  local OUTER <const> = Shape.record_of("Outer"):strict()
  fails({ server = { host = "h", port = 1, extra = true } }, OUTER.spec, "$.server.extra: unknown key")
end

local function test_a_map_refuses_a_key_that_is_not_a_string()
  local m = must(Shape.into({ a = 1, b = 2.0 }, Shape.map(Shape.integer)))
  assert(m.a == 1 and math.type(m.b) == "integer")
  fails({ a = 1, [2] = 2 }, Shape.map(Shape.integer), "$: want map, got the integer key 2")
end

-- [`Json.null`] is a missing value: optional admits it and answers nil,
-- and a required field refuses it by name.
local function test_json_null_is_a_missing_value()
  local text = '{"host": "h", "port": 1, "tls": null}'
  local keep: Json.DecodeOptions = { null_value = Json.null }
  local s = must(Shape.into(must(Json.decode(text, keep)), SERVER.spec))
  assert(s.tls == nil)
  fails(must(Json.decode('{"host": null, "port": 1}', keep)), SERVER.spec, "$.host: missing")
  fails({ host = "h", port = Json.null }, SERVER.spec, "$.port: missing")
  -- An array holds no hole, so a list whose elements may be missing is a map from the indexes that are there.
  local sparse = Shape.sparse_list(Shape.optional(Shape.integer))
  local l = must(Shape.into(must(Json.decode("[1, null, 3]", keep)), sparse))
  assert(l[1] == 1 and l[2] == nil and l[3] == 3)
  -- Decoded without a stand-in, the null leaves a hole, which is the
  -- same missing element.
  local holed = must(Shape.into(must(Json.decode("[1, null, 3]")), sparse))
  assert(holed[3] == 3)
  fails(must(Json.decode("[1, null, 3]")), Shape.list(Shape.integer), "$[1]: missing")
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
  fails(big, Shape.integer, "$: want integer, got string")
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
  fails("warn", level, '$: want one of "debug", "info", got "warn"')
  fails({}, level, '$: want one of "debug", "info", got table')
  local raised, _ = pcall(Shape.one_of)
  assert(not raised)
end

local function test_any_passes_the_value_through()
  local t = {}
  local v, err = Shape.into({ any = t }, Shape.record_of("Tagged").spec)
  assert(v ~= nil, err)
  -- a field of `any` may be missing, as `any` holds nil
  local missing, why = Shape.into({}, Shape.record_of("Tagged").spec)
  assert(missing ~= nil, why)
  local anything = must(Shape.into(t, Shape.any))
  assert(rawequal(anything, t))
  fails(nil, Shape.any, "$: missing")
end

local function test_a_failure_names_its_path_from_the_root()
  local spec = Shape.record_of("Doc").spec
  local function fails_on(text: string, want: string)
    fails(must(Json.decode(text)), spec, want)
  end
  local function items(fourth: string): string
    return '{"by_id": {}, "items": [' ..
      '{"name": "a", "tags": []}, {"name": "b", "tags": []}, {"name": "c", "tags": []}, ' .. fourth .. ']}'
  end
  local good, good_err = Shape.into(must(Json.decode(items('{"name": "d", "tags": []}'))), spec)
  assert(good ~= nil, good_err)
  fails_on(items('{"name": 4, "tags": []}'), "$.items[3].name: want string, got integer")
  fails_on(items('{"tags": []}'), "$.items[3].name: missing")
  fails_on(items('{"name": null, "tags": []}'), "$.items[3].name: missing")
  fails_on(items('{"name": "d", "tags": ["x", true]}'), "$.items[3].tags[1]: want string, got boolean")
  fails_on('{"items": [], "by_id": {"7": [1, "x"]}}', '$.by_id["7"][1]: want integer, got string')
  fails_on('"text"', "$: want record, got string")
  fails_on("[]", "$: want record, got array")
  fails(nil, spec, "$: missing")
end

-- [`Json.null`] is missing for every kind a field can have, an enum and a record among them.
local function test_json_null_is_missing_for_a_required_enum_or_record()
  local keep: Json.DecodeOptions = { null_value = Json.null }
  local cfg = Shape.record_of("Cfg").spec
  fails(must(Json.decode('{"host": "h", "port": 1, "level": null}', keep)), cfg, "$.level: missing")
  local looping = Shape.record_of("Looping").spec
  fails(must(Json.decode('{"name": "n", "self": null}', keep)), looping, "$.self: missing")
  fails(must(Json.decode('null', keep)), looping, "$: missing")
  fails(Json.null, Shape.one_of("a", "b"), "$: missing")
end

local function test_a_key_that_is_not_an_identifier_is_quoted_in_the_path()
  local spec = Shape.record_of("Odd").spec
  assert(select(2, Shape.into({}, spec)) == '$["1st"]: missing')
  local function bad(key: string, want: string)
    local text = '{"1st": "x", "_ok9": "x", "a b": "x", "a-b": "x"}'
    local escaped = key:gsub("%p", "%%%0")
    fails(must(Json.decode((text:gsub('"' .. escaped .. '": "x"', '"' .. key .. '": 1')))), spec, want)
  end
  bad("a b", '$["a b"]: want string, got integer')
  bad("a-b", '$["a-b"]: want string, got integer')
  bad("1st", '$["1st"]: want string, got integer')
  bad("_ok9", "$._ok9: want string, got integer")
end

local function test_a_cyclic_value_is_walked_as_deep_as_the_spec()
  local t: {string: any} = { name = "loop" }
  t.self = t
  local v, err = Shape.into(t, Shape.record_of("Looping").spec)
  assert(v ~= nil, err)
  assert(Json.encode_any(v) == '{"name":"loop","self":{"name":"loop"}}')
end

local function test_into_answers_only_the_first_of_several_failures()
  local spec = Shape.record_of("Cfg").spec
  local value: {string: any} = {
    port = "8080", level = "warn",
    rows = { { id = 1 }, { id = "b" }, { id = true } },
    tags = { b = 1, a = "x", c = true },
  }
  fails(value, spec, "$.host: missing")
  value.host = "h"
  fails(value, spec, '$.level: want one of "debug", "info", got "warn"')
  value.level = "info"
  fails(value, spec, "$.port: want integer, got string")
  value.port = 8080
  fails(value, spec, "$.rows[0].id: want string, got integer")
  value.rows = { { id = "a" } }
  fails(value, spec, "$.tags.a: want boolean, got string")
end

-- A key a list, map or record refuses fails it where it stands, whatever
-- its values, and the least such key in an order no address decides is
-- the one named.
local function test_a_refused_key_is_named_before_any_value_is_looked_at()
  local bad: {any: any} = { a = 1, [{}] = true, [print] = true, [true] = 1, [10] = 1, [2] = 1, [1.5] = 1 }
  fails(bad, Shape.map(Shape.string), "$: want map, got the float key 1.5")
  fails({ a = 1, [10] = 1, [2] = 1 }, Shape.map(Shape.string), "$: want map, got the integer key 2")
  local scalar_and_function: {any: any} = { [true] = 1, [print] = 1, a = 1 }
  fails(scalar_and_function, Shape.map(Shape.string), "$: want map, got the boolean key true")
  local function_only: {any: any} = { [print] = 1, a = 1 }
  fails(function_only, Shape.map(Shape.string), "$: want map, got a function key")
  fails({ [{}] = 1 }, Shape.map(Shape.string), "$: want map, got a table key")
  fails({ "a", x = 1, [0] = 2 }, Shape.list(Shape.integer), "$: want list, got the integer key 0")
  fails({ "a", x = 1 }, Shape.list(Shape.integer), '$: want list, got the string key "x"')
  local strict = Shape.record_of("Pair"):strict()
  fails(must(Json.decode('{"prot": 1, "hots": "h", "a": "x", "b": "x", "c": "x"}')), strict.spec, "$.hots: unknown key")
  fails({ prot = 1, [2] = true, [1] = true }, strict.spec, "$: want record, got the integer key 1")
  fails({ nested = { prot = 1, a = 2 } }, Shape.record_of("Nested"):strict().spec, "$.nested.a: unknown key")
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
  fails(decoded, required, "$[1]: missing")
  -- Keys 1, 3 and 5, with 3 a border of the table.
  local gappy: mut {any: any} = { 1, 2, 3 }
  gappy[2] = nil
  gappy[5] = 5
  fails(gappy, required, "$[1]: missing")
  local g = must(Shape.into(gappy, optional))
  assert(g[1] == 1 and g[3] == 3 and g[5] == 5)
  -- A marked array with one far index is walked by its keys.
  local far = must(Shape.into(Json.array({ [1 << 40] = 7 } as {any}), optional))
  assert(far[1 << 40] == 7)
  fails(Json.array({ [1 << 40] = 7 } as {any}), required, "$[0]: missing")
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
  fails(marked("x"), optional, '$: want list, got the string key "x"')
  fails(marked(0), optional, "$: want list, got the integer key 0")
  fails(marked(-3), optional, "$: want list, got the integer key -3")
  fails(marked(1.5), optional, "$: want list, got the float key 1.5")
  fails(marked(true), optional, "$: want list, got the boolean key true")
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
end

-- `any?` is `any` to the checker, so the type cannot tell a list of elements that may be missing from one that may not:
-- the list fails where an element is missing, whatever its element spec answers for it.
local function test_a_list_whose_element_may_be_missing_fails_even_where_the_type_cannot_say()
  fails(must(Json.decode("[1, null, 3]")), Shape.list(Shape.optional(Shape.any)), "$[1]: missing")
  fails({ [1] = 1, [3] = 3 }, Shape.list(Shape.optional(Shape.any)), "$[1]: missing")
end

-- `record_of` is completed by the build only where it is written `Shape.record_of("Name")`. A call written another way
-- gets no check, and raises when it runs; one that passes a check of its own passes a function the checker types
-- (lang/check_generics_test.tl), so no route names a `T` the check does not answer.
local function test_a_record_of_the_build_did_not_complete_raises_by_every_route()
  local alias = Shape
  local by_alias, why = pcall(function() local _: Shape.Typed<Row> = alias.record_of("Row") end)
  assert(not by_alias and tostring(why):find("was not resolved", 1, true) ~= nil, tostring(why))
  local inline, inline_why = pcall(function()
    local _: Shape.Typed<Row> = require("cosmic.shape").record_of("Row")
  end)
  assert(not inline and tostring(inline_why):find("was not resolved", 1, true) ~= nil, tostring(inline_why))
  local indexed, indexed_why = pcall(function()
    local _: Shape.Typed<Row> = Shape["record_of"]("Row")
  end)
  assert(not indexed and tostring(indexed_why):find("was not resolved", 1, true) ~= nil, tostring(indexed_why))
end

-- A `Spec<T>` is a check, and one written by hand is a function the checker types: it answers a `T` or it does not
-- compile (lang/check_generics_test.tl). So it composes as any other does, by its check; it only has no fields to
-- describe, which a strict record needs.
local function test_a_spec_written_by_hand_composes_by_its_check()
  local text: Shape.Spec<string> = {
    check = function(value: any, path: string): string?, string
      if value is string then return value, "" end
      return nil, path .. ": a string, by hand"
    end,
  }
  assert(Shape.into("x", text) == "x")
  local _, why = Shape.into(5, text)
  assert(why == "$: a string, by hand", why)
  local _, trouble = Shape.decode_into("5", text)
  assert(trouble == "$: a string, by hand", trouble)
  local list = must(Shape.into({ "a", "b" }, Shape.list(text)))
  assert(#list == 2 and list[2] == "b")
  fails(must(Json.decode("[\"a\", 2]")), Shape.list(text), "$[1]: a string, by hand")
  fails({ k = 1 }, Shape.map(text), "$.k: a string, by hand")
  assert(Shape.into(Json.null, Shape.optional(text)) == nil)
  fails({ [1] = "a", [3] = "c" }, Shape.list(text), "$[1]: missing")
  -- a check that answers nothing for a value it accepts is a hole, which a list fails
  local nothing: Shape.Spec<string> = { check = function(_value: any, _path: string): string?, string
    return nil, ""
  end }
  fails({ "a" }, Shape.list(nothing), "$[0]: missing")
  -- a record written by hand answers through a check written by hand, whatever it is named
  local honest: Shape.Spec<Server> = {
    check = function(_value: any, _path: string): Server?, string
      return nil, "no server is a Server here"
    end,
  }
  local forged: Shape.Typed<Server> = {
    name = "Server", spec = honest, make = function(_strict: boolean): Shape.Spec<Server>
      return honest
    end,
    node = { kind = "record", optional = false }, into = SERVER.into, decode_into = SERVER.decode_into,
    strict = SERVER.strict,
  }
  local _, said = forged:into({ host = "h" })
  assert(said == "Server: no server is a Server here", said)
  -- the specs the module makes are composed, strict ones included, and `strict` keeps its answer
  assert(SERVER:strict() == SERVER:strict() and SERVER:strict():strict() == SERVER:strict())
end
