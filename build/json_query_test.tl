--- Proves what `cosmic json` prints beyond the value at a path: every
--- leaf of a value as a `path = value` line, its path a JSONPath query
--- in shorthand form, and a value's shape.

local Json = require("cosmic.json")
local json_query = require("build.json_query")

--- The value `text` decodes to, or a failed assertion naming why.
local function decoded(text: string, opts?: Json.DecodeOptions): any
  local value, err = Json.decode(text, opts)
  assert(err == "", "decode failed on " .. text .. ": " .. err)
  return value
end

local function encoded(value: any): string
  local text, err = Json.encode(value)
  assert(text ~= nil, "encode failed: " .. err)
  return text
end

local function test_describe_summarizes_nested_shapes_sorted()
  local doc = decoded('{"today": {"accounts": [{"id": "a", "balance": 1.5}, {"id": "b", "balance": 2}]},' ..
      ' "plans": [{"x": 1}, {"x": 2}, {"x": 3}], "ok": true, "name": "n"}')
  assert(json_query.describe(doc) == "{name: string, ok: boolean, plans: [3 x {x: number}]," ..
      " today: {accounts: [2 x {balance: number, id: string}]}}", json_query.describe(doc))
  assert(json_query.describe(doc, { max_depth = 2 }) == "{name: string, ok: boolean, plans: [3 x {...}]," ..
      " today: {accounts: [2 x ...]}}", json_query.describe(doc, { max_depth = 2 }))
  assert(json_query.describe(doc, { max_depth = 0 }) == "{...}")
end

local function test_describe_merges_heterogeneous_elements()
  assert(json_query.describe(decoded('[1, "a", 2, null, true]', { null_value = Json.null })) == "[5 x boolean|null|number|string]")
  assert(json_query.describe(decoded('[{"a": 1}, {"a": 2, "b": "x"}, {"a": "s"}]')) ==
      "[3 x {a: number|string, b?: string}]")
  assert(json_query.describe(decoded('[[1, 2], [3], []]')) == "[3 x [0..2 x number]]")
  assert(json_query.describe(decoded('[{"a": 1}, 2]')) == "[2 x number|{a: number}]")
end

local function test_describe_scalars_empties_and_null()
  assert(json_query.describe(nil) == "null")
  assert(json_query.describe(Json.null) == "null")
  assert(json_query.describe("s") == "string")
  assert(json_query.describe(1) == "number" and json_query.describe(1.5) == "number")
  assert(json_query.describe(decoded("[]")) == "[0]")
  assert(json_query.describe(decoded("{}")) == "{}")
  assert(json_query.describe(decoded('{"a": {}, "b": [], "c": null}', { null_value = Json.null })) ==
      "{a: {}, b: [0], c: null}")
  assert(json_query.describe(decoded('{"odd key": 1}')) == '{"odd key": number}', json_query.describe(decoded('{"odd key": 1}')))
  assert(not pcall(json_query.describe, {}, { max_depth = -1 }))
  local fraction: any = 1.5
  assert(not pcall(json_query.describe, {}, { max_depth = fraction as integer }))
end

--- `?` and a depth cut, objects merged across nested arrays, holes.
local function test_describe_optional_keys_cuts_and_holes()
  assert(json_query.describe(decoded('[{"a": {"x": 1}}, {"b": 1}]'), { max_depth = 2 }) ==
      "[2 x {a?: {...}, b?: number}]")
  assert(json_query.describe(decoded('[[{"a": 1}], [{"b": 1}]]')) == "[2 x [1 x {a?: number, b?: number}]]")
  local holed = decoded('[1, null, 3]', { null_value = Json.null })
  assert(json_query.describe(holed) == "[3 x null|number]")
  local plain = json_query.describe(decoded('[1, null, 3]'))
  assert(plain:find("^%[%d x number") ~= nil, plain)
end

local function test_describe_a_long_array_is_one_merged_shape()
  local items = Json.array()
  for i = 1, 5000 do items[i] = { id = i, tag = "t" } end
  assert(json_query.describe(items) == "[5000 x {id: number, tag: string}]")
  local cycle: {any:any} = {}
  cycle.self = cycle
  assert(json_query.describe(cycle, { max_depth = 3 }) == "{self: {self: {self: {...}}}}")
end

local function flat_lines(value: any, opts?: json_query.FlattenOptions): {string}
  local leaves, err = json_query.flatten(value, opts)
  assert(leaves ~= nil, err)
  assert(err == "")
  local lines: {string} = {}
  for i, leaf in ipairs(leaves) do
    local line, why = json_query.flat_line(leaf.steps, leaf.value)
    assert(line ~= nil, why)
    lines[i] = line
  end
  return lines
end

local function assert_lines(got_lines: {string}, want: {string})
  assert(table.concat(got_lines, "\n") == table.concat(want, "\n"),
    "got:\n" .. table.concat(got_lines, "\n") .. "\nwant:\n" .. table.concat(want, "\n"))
end

local function test_flatten_lists_every_leaf_in_a_fixed_order()
  local doc = decoded('{"n": null, "c": "s", "b": [10, {"z": 1, "a": []}], "a": {}, "f": 1200.5, "t": true}',
    { null_value = Json.null })
  assert_lines(flat_lines(doc), {
    "$.a = {}", "$.b[0] = 10", "$.b[1].a = []", "$.b[1].z = 1", "$.c = \"s\"",
    "$.f = 1200.5", "$.n = null", "$.t = true",
  })
end

local function test_flat_line_spells_a_word_with_a_dot_and_any_other_name_quoted()
  local doc = decoded('{"k k": [{"a.b": 1}], "": 2, "it\'s": 3, "q\\"": 4}')
  assert_lines(flat_lines(doc), { '$[""] = 2', '$["it\'s"] = 3', '$["k k"][0]["a.b"] = 1', '$["q\\""] = 4' })
end

local function test_flatten_of_a_scalar_or_an_empty_container_is_that_one_leaf()
  assert_lines(flat_lines(3), { "$ = 3" })
  assert_lines(flat_lines("x"), { '$ = "x"' })
  assert_lines(flat_lines(decoded("{}")), { "$ = {}" })
  assert_lines(flat_lines(decoded("[]")), { "$ = []" })
  assert_lines(flat_lines(Json.array()), { "$ = []" })
  assert_lines(flat_lines(decoded("null", { null_value = Json.null })), { "$ = null" })
  assert_lines(flat_lines(decoded('[[], [[]], {}]')), { "$[0] = []", "$[1][0] = []", "$[2] = {}" })
end

local function test_flatten_skips_holes_and_keeps_the_neighbours_positions()
  local holey: {integer:string} = { [1] = "a", [3] = "c", [7] = "g" }
  assert_lines(flat_lines(holey), { '$[0] = "a"', '$[2] = "c"', '$[6] = "g"' })
  -- Nulls decoded to nothing leave an object member absent, and an object of only those is empty.
  assert_lines(flat_lines(decoded('{"a": null, "b": 1}')), { "$.b = 1" })
  assert_lines(flat_lines(decoded('{"a": null}')), { "$ = {}" })
end

local function test_a_decoded_array_with_holes_keeps_the_elements_past_them()
  assert_lines(flat_lines(decoded("[null, 2, 3]")), { "$[1] = 2", "$[2] = 3" })
  assert_lines(flat_lines(decoded("[1, null, 3]")), { "$[0] = 1", "$[2] = 3" })
  assert_lines(flat_lines(decoded("[1, null, null]")), { "$[0] = 1" })
  assert_lines(flat_lines(decoded('{"a": [null, {"b": 1}, null, [4]]}')), { "$.a[1].b = 1", "$.a[3][0] = 4" })
  assert_lines(flat_lines(decoded("[null, null]")), { "$ = []" })
end

local function test_flatten_root_spells_the_value_where_it_was_found()
  local doc = decoded('{"users": [{"id": 1}]}')
  local user = assert(Json.get(doc, { "users", 1 }))
  assert_lines(flat_lines(user, { root = { "users", 1 } }), { "$.users[0].id = 1" })
end

local function test_flatten_stops_at_max_depth_naming_the_pointer()
  local doc = decoded('{"a": {"b": [1]}}')
  local leaves, err = json_query.flatten(doc, { max_depth = 2 })
  assert(leaves == nil and err == 'the value at pointer "/a/b" nests deeper than max_depth 2', err)
  assert_lines(flat_lines(doc, { max_depth = 3 }), { "$.a.b[0] = 1" })
  -- An empty container still nests: it is a container.
  local _, empty_err = json_query.flatten(decoded('[[[]]]'), { max_depth = 2 })
  assert(empty_err:find('pointer "/0/0"', 1, true), empty_err)
  local deep: any = 1
  for _ = 1, 100 do deep = { deep } end
  local _, default_err = json_query.flatten(deep)
  assert(default_err:find("max_depth 64", 1, true), default_err)
  assert(json_query.flatten(deep, { max_depth = 200 }) ~= nil)
end

local function test_flatten_fails_on_a_cycle_and_on_mixed_keys()
  local loop: {string:any} = { name = "x" }
  loop.self = loop
  local leaves, err = json_query.flatten(loop)
  assert(leaves == nil and err == 'the value at pointer "/self" contains itself', err)
  local mixed: {any:any} = { a = 1, [1] = 2 }
  local m, mixed_err = json_query.flatten({ rows = mixed })
  assert(m == nil and mixed_err == 'the value at pointer "/rows" is a table with mixed keys', mixed_err)
  -- The same table twice is no cycle.
  local shared = { 1 }
  assert_lines(flat_lines({ a = shared, b = shared }), { "$.a[0] = 1", "$.b[0] = 1" })
end

local function test_flat_line_prints_the_compact_value()
  assert(json_query.flat_line({ "a", 1, "b" }, 1200.5) == "$.a[0].b = 1200.5")
  assert(json_query.flat_line({}, Json.null) == "$ = null")
  assert(json_query.flat_line({ "s" }, 'a "q" = b\n') == "$.s = \"a \\\"q\\\" = b\\n\"")
  local line, err = json_query.flat_line({ "f" }, function() end)
  assert(line == nil and err:find('the value at pointer "/f": ', 1, true), err)
  local zero, why = json_query.flat_line({ 0 }, 1)
  assert(zero == nil and why:find("step 1 is 0", 1, true), why)
end

local function test_every_flat_path_reads_back_to_its_leaf()
  local doc = decoded('{"a b": [1, {"c\\"d": [true, null, {}], "e": "s"}], "": {"": 0}, "$": 1.5}',
    { null_value = Json.null })
  local leaves = assert(json_query.flatten(doc))
  assert(#leaves == 7, #leaves)
  for _, leaf in ipairs(leaves) do
    local line = assert(json_query.flat_line(leaf.steps, leaf.value))
    local path = line:sub(1, #line - #encoded(leaf.value) - 3)
    local value = assert(Json.get(doc, (assert(Json.from_path(path)))))
    assert(encoded(value) == encoded(leaf.value), path)
  end
end

--- `value` with every table replaced by an empty one that answers for it,
--- and counts in `counter[1]` each time it is walked by `pairs`: one for
--- every container a walk lays out, so a test can bound the work a walk
--- does by what it counted, not by how long it took.
local function counted(value: any, counter: {integer}): any
  if not (value is {any:any}) then return value end
  local copy: {any:any} = {}
  for key, member in pairs(value) do copy[key] = counted(member, counter) end
  local walk_copy: function(): any, any, any = function(): any, any, any
    counter[1] = counter[1] + 1
    return next, copy, nil
  end
  return setmetatable({}, { __index = copy, __pairs = walk_copy })
end

local function test_flatten_of_a_large_document_lays_out_each_container_once()
  local rows: {any} = {}
  for i = 1, 25000 do rows[i] = { id = i, tags = { "a", "b" }, ["in"] = { id = -i } } end
  local counter = { 0 }
  local leaves = assert(json_query.flatten(counted({ rows = Json.array(rows) }, counter)))
  assert(#leaves == 100000, #leaves)
  assert(json_query.flat_line(leaves[1].steps, 1) == "$.rows[0].id = 1" and
      json_query.flat_line(leaves[4].steps, 1) == "$.rows[0].tags[1] = 1")
  assert(counter[1] == 75002, "laid out " .. counter[1] .. " containers")
end

--- A depth outside what a walk takes raises, naming the caller, for
--- `flatten` and `describe` alike.
local function test_a_max_depth_out_of_range_raises_naming_the_caller()
  local doc = decoded('{"a": [1]}')
  local function flatten_with(depth: any): any
    -- Not a tail call, which would leave no frame here to name.
    local leaves = json_query.flatten(doc, { max_depth = depth as integer })
    return leaves
  end
  local function describe_with(depth: any): any
    local text = json_query.describe(doc, { max_depth = depth as integer })
    return text
  end
  local walks = "json: max_depth must be an integer from 1 to " .. Json.depth_limit
  for _, bad in ipairs({ 0, Json.depth_limit + 1, 1.5, "2" } as {any}) do
    local ok, message = pcall(flatten_with, bad)
    assert(not ok and tostring(message):find(walks, 1, true), tostring(message))
    assert(tostring(message):find("json_query_test", 1, true), "named where it was called: " .. tostring(message))
  end
  for _, bad in ipairs({ -1, 1.5, "2" } as {any}) do
    local ok, message = pcall(describe_with, bad)
    assert(not ok and tostring(message):find("json: max_depth must be an integer of at least 0", 1, true),
      tostring(message))
    assert(tostring(message):find("json_query_test", 1, true), "named where it was called: " .. tostring(message))
  end
  assert(json_query.describe(doc, { max_depth = 0 }) == "{...}", "0 is a depth for describe")
  assert(json_query.flatten(doc, { max_depth = Json.depth_limit }) ~= nil, "the limit itself is allowed")
end
