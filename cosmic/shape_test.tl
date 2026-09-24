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

local function fails(value: any, spec: Shape.Spec, want: string, opts?: Shape.Options)
  local v, err: any, string = Shape.into(value, spec, opts)
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
  fails({ host = "h", port = "8080" }, SERVER, "$.port: expected integer, got string")
  fails({ port = 1 }, SERVER, "$.host: expected string, got nothing")
  fails("text", SERVER, "$: expected record, got string")
  local rows = Shape.list(Shape.record({ id = Shape.string }))
  fails({ { id = "a" }, { id = 2 } }, rows, "$[2].id: expected string, got integer")
  local by_key = Shape.map(Shape.record({ n = Shape.number }))
  fails({ ["a key"] = { n = true } }, by_key, '$["a key"].n: expected number, got boolean')
end

-- Fields are checked in byte order, so two failing fields always
-- report the same one, whatever order the table was built in.
local function test_the_first_failure_is_the_same_every_run()
  local spec = Shape.record({ b = Shape.string, a = Shape.string, c = Shape.string })
  for _ = 1, 10 do
    fails({ c = 1, b = 1 }, spec, "$.a: expected string, got nothing")
  end
end

local function test_integer_takes_a_whole_float_and_nothing_else()
  local v: integer = must(Shape.into(8080.0, Shape.integer))
  assert(math.type(v) == "integer" and v == 8080)
  fails(1.5, Shape.integer, "$: expected integer, got 1.5")
  fails(2.0 ^ 63, Shape.integer, "$: expected integer, got " .. tostring(2.0 ^ 63))
  fails(0 / 0, Shape.integer, "$: expected integer, got " .. tostring(0 / 0))
  fails("1", Shape.integer, "$: expected integer, got string")
  fails("1", Shape.number, "$: expected number, got string")
  local f: number = must(Shape.into(1.5, Shape.number))
  assert(f == 1.5)
end

local function test_a_list_is_keyed_from_one()
  local l: {string} = must(Shape.into({ "a", "b" }, Shape.list(Shape.string)))
  assert(#l == 2 and l[2] == "b")
  local empty: {string} = must(Shape.into({}, Shape.list(Shape.string)))
  assert(#empty == 0)
  fails({ [1] = "a", [3] = "c" }, Shape.list(Shape.string), "$[2]: expected string, got nothing")
  fails({ [2] = "b" }, Shape.list(Shape.string), "$[1]: expected string, got nothing")
  fails({ x = "a" }, Shape.list(Shape.string), '$: expected list, got the string key "x"')
  fails({ [0] = "a" }, Shape.list(Shape.string), "$: expected list, got the integer key 0")
  fails({ [1.5] = "a" }, Shape.list(Shape.string), "$: expected list, got the float key 1.5")
end

-- A decoded JSON array carries a mark in its metatable so that an empty
-- one encodes back as `[]`; the copy keeps it.
local function test_a_list_keeps_its_array_mark()
  local marked: {integer} = setmetatable({}, { __name = "array" })
  local l: {integer} = must(Shape.into(marked, Shape.list(Shape.integer)))
  assert(getmetatable(l) == getmetatable(marked))
end

local function test_a_map_refuses_a_key_that_is_not_a_string()
  local m: {string: integer} = must(Shape.into({ a = 1, b = 2.0 }, Shape.map(Shape.integer)))
  assert(m.a == 1 and math.type(m.b) == "integer")
  fails({ a = 1, [2] = 2 }, Shape.map(Shape.integer), "$: expected map, got the integer key 2")
end

-- A stand-in for null, like `Json.null`, is a missing value: optional
-- admits it and answers nil, and a required field refuses it.
local function test_the_null_stand_in_is_a_missing_value()
  local null = {}
  local opts: Shape.Options = { null = null }
  local s: Server = must(Shape.into({ host = "h", port = 1, tls = null }, SERVER, opts))
  assert(s.tls == nil)
  fails({ host = null, port = 1 }, SERVER, "$.host: expected string, got nothing", opts)
  local l: {integer} = must(Shape.into({ 1, null, 3 }, Shape.list(Shape.optional(Shape.integer)), opts))
  assert(l[1] == 1 and l[2] == nil and l[3] == 3)
  -- A sparse list of optional elements is walked by its keys, never by
  -- counting up to the highest one.
  local far: {integer} = must(Shape.into({ [1 << 40] = 7 }, Shape.list(Shape.optional(Shape.integer))))
  assert(far[1 << 40] == 7)
  fails({ host = "h", port = 1, tls = null }, SERVER, "$.tls: expected boolean, got table")
end

local function test_one_of_admits_only_its_values()
  local level = Shape.one_of("debug", "info")
  local v: string = must(Shape.into("info", level))
  assert(v == "info")
  fails("warn", level, '$: expected one of "debug", "info", got "warn"')
  fails({}, level, '$: expected one of "debug", "info", got table')
  assert(not pcall(Shape.one_of))
end

local function test_either_takes_the_first_choice_that_fits()
  local names = Shape.either(Shape.string, Shape.list(Shape.string))
  local one: string = must(Shape.into("a", names))
  assert(one == "a")
  local many: {string} = must(Shape.into({ "a", "b" }, names))
  assert(many[2] == "b")
  fails(true, names, "$: expected string or list, got boolean")
  -- A choice that failed inside the value says more than the union does.
  fails({ "a", 2 }, names, "$[2]: expected string, got integer")
end

local function test_any_passes_the_value_through()
  local t = {}
  local v: any = must(Shape.into({ x = t }, Shape.record({ x = Shape.any })))
  assert((v as {string: any}).x == t)
  fails({}, Shape.record({ x = Shape.any }), "$.x: expected any, got nothing")
end

local function test_a_message_quotes_an_odd_key_as_json_does()
  local spec = Shape.record({ ['a"b\n'] = Shape.string })
  fails({}, spec, '$["a\\"b\\u000a"]: expected string, got nothing')
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
  assert(not pcall(Shape.record, { a = { kind = "strig" } as Shape.Spec }))
  assert(not pcall(Shape.either))
end
