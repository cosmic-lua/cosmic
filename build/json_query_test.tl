--- Proves the queries `cosmic json` and `cosmic sql --at` make: a path or
--- a pattern read from text, the values a pattern matches, every leaf of
--- a value as a `path = value` line, and a value's shape.

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

--- The value at `path`, or a failed assertion naming why it is not there.
local function got(value: any, path: {string | integer}): any
  local v, err = Json.get(value, path)
  assert(err == "", err)
  return v
end

local function test_describe_summarizes_nested_shapes_sorted()
  local doc = decoded('{"today": {"accounts": [{"id": "a", "balance": 1.5}, {"id": "b", "balance": 2}]},'
    .. ' "plans": [{"x": 1}, {"x": 2}, {"x": 3}], "ok": true, "name": "n"}')
  assert(json_query.describe(doc) == "{name: string, ok: boolean, plans: [3 x {x: number}],"
    .. " today: {accounts: [2 x {balance: number, id: string}]}}", json_query.describe(doc))
  assert(json_query.describe(doc, { max_depth = 2 }) == "{name: string, ok: boolean, plans: [3 x {...}],"
    .. " today: {accounts: [2 x ...]}}", json_query.describe(doc, { max_depth = 2 }))
  assert(json_query.describe(doc, { max_depth = 0 }) == "{...}")
end

local function test_describe_merges_heterogeneous_elements()
  assert(json_query.describe(decoded('[1, "a", 2, null, true]', { null_value = Json.null })) == "[5 x boolean|null|number|string]")
  assert(json_query.describe(decoded('[{"a": 1}, {"a": 2, "b": "x"}, {"a": "s"}]'))
    == "[3 x {a: number|string, b?: string}]")
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
  assert(json_query.describe(decoded('{"a": {}, "b": [], "c": null}', { null_value = Json.null }))
    == "{a: {}, b: [0], c: null}")
  assert(json_query.describe(decoded('{"odd key": 1}')) == '{"odd key": number}', json_query.describe(decoded('{"odd key": 1}')))
  assert(not pcall(json_query.describe, {}, { max_depth = -1 }))
  local fraction: any = 1.5
  assert(not pcall(json_query.describe, {}, { max_depth = fraction as integer }))
end

--- `?` and a depth cut, objects merged across nested arrays, holes.
local function test_describe_optional_keys_cuts_and_holes()
  assert(json_query.describe(decoded('[{"a": {"x": 1}}, {"b": 1}]'), { max_depth = 2 })
    == "[2 x {a?: {...}, b?: number}]")
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

local function path_of(text: string): {string | integer}
  local steps, err = json_query.parse_path(text)
  assert(steps ~= nil, text .. ": " .. err)
  assert(err == "")
  return steps
end

local function assert_steps(text: string, want: {string | integer})
  local read = path_of(text)
  assert(#read == #want, text .. " read as " .. #read .. " steps")
  for i, step in ipairs(want) do
    assert(read[i] == step and math.type(read[i] as number) == math.type(step as number), text .. " step " .. i)
  end
end

local function refused_path(text: string, why: string)
  local steps, err = json_query.parse_path(text)
  assert(steps == nil, text .. " read")
  assert(err:find(why, 1, true), text .. ": " .. err)
end

local function test_parse_path_reads_the_forms_child_path_writes()
  assert_steps("$", {})
  assert_steps("$.a", { "a" })
  assert_steps("$.rows[2].name", { "rows", 2, "name" })
  assert_steps('$["a key"][1]', { "a key", 1 })
  assert_steps('$["\\"\\\\\\n\\u00e9\\ud83d\\ude00"]', { '"\\\né\u{1F600}' })
  assert_steps("$[-1]", { -1 })
end

local function test_parse_path_takes_a_bare_or_dotted_start()
  assert_steps("a.b", { "a", "b" })
  assert_steps(".a.b", { "a", "b" })
  assert_steps("[1]", { 1 })
  assert_steps('["a b"].c', { "a b", "c" })
  assert_steps("a[1].b", { "a", 1, "b" })
  assert_steps("$.foo-bar", { "foo-bar" })
end

local function test_parse_path_names_where_a_path_stops_being_one()
  refused_path("", "empty")
  refused_path("$.", "column 3: expected a key")
  refused_path("$..a", "column 2: `..`")
  refused_path("$a", "expected `.` or `[`")
  refused_path("$[", "expected an integer or a quoted key")
  refused_path("$[]", "expected an integer or a quoted key")
  refused_path("$[1.5]", "expected an integer or a quoted key")
  refused_path("$[ 1 ]", "expected an integer or a quoted key")
  refused_path('$["a', "unclosed [")
  refused_path('$["a"', "expected `]`")
  refused_path('$["a"]x', "expected `.` or `[`")
  refused_path('$["\\x"]', "no such escape")
  refused_path('$["\\ud83d"]', "lone surrogate")
  refused_path('$["\\ude00"]', "lone surrogate")
  refused_path('$["\\u12"]', "four hex digits")
  refused_path("$[9223372036854775808]", "does not fit an integer")
end

local function test_parse_path_refuses_wildcards_and_descent_pointing_at_patterns()
  refused_path("$.a..b", "`..` (recursive descent) is a pattern, not a path")
  refused_path("..balance", "is a pattern, not a path")
  refused_path("$..", "recursive descent")
  refused_path("$.*", "is a pattern, not a path")
  refused_path("$.a.*.b", "wildcard")
  refused_path("*", "wildcard")
  refused_path("$[*]", "is a pattern, not a path")
  refused_path("a[*]", "wildcard")
  refused_path("$..[1]", "recursive descent")
  -- A key named `*` is still reachable, quoted, and `*` inside a longer key is a key.
  assert_steps('$["*"]', { "*" })
  assert_steps("$.a*", { "a*" })
  assert_steps("$.*a", { "*a" })
  assert_steps(json_query.child_path("$", "*"), { "*" })
end

local function test_parse_path_round_trips_child_path()
  local keys = { "a", "a key", "", "a.b", '"', "\\", "\n", "\xff", "é", "[1]" }
  for _, key in ipairs(keys) do
    local text = json_query.child_path(json_query.child_path("$", key), 3)
    assert_steps(text, { key, 3 })
  end
end

local function flat_lines(value: any, opts?: json_query.WalkOptions): {string}
  local leaves, err = json_query.flatten(value, opts)
  assert(leaves ~= nil, err)
  assert(err == "")
  local lines: {string} = {}
  for i, leaf in ipairs(leaves) do
    local line, why = json_query.flat_line(leaf.path, leaf.value)
    assert(line ~= nil, why)
    lines[i] = line
  end
  return lines
end

local function assert_lines(got_lines: {string}, want: {string})
  assert(table.concat(got_lines, "\n") == table.concat(want, "\n"),
    "got:\n" .. table.concat(got_lines, "\n") .. "\nwant:\n" .. table.concat(want, "\n"))
end

local function pat(text: string): {json_query.Step}
  local steps, err = json_query.parse_pattern(text)
  assert(steps ~= nil, text .. ": " .. err)
  return steps
end

local function test_flatten_lists_every_leaf_in_a_fixed_order()
  local doc = decoded('{"n": null, "c": "s", "b": [10, {"z": 1, "a": []}], "a": {}, "f": 1200.5, "t": true}',
    { null_value = Json.null })
  assert_lines(flat_lines(doc), {
    "$.a = {}", "$.b[1] = 10", "$.b[2].a = []", "$.b[2].z = 1", "$.c = \"s\"",
    "$.f = 1200.5", "$.n = null", "$.t = true",
  })
end

local function test_flatten_spells_keys_as_child_path_does()
  local doc = decoded('{"k k": [{"a.b": 1}], "": 2, "q\\"": 3}')
  assert_lines(flat_lines(doc), { '$[""] = 2', '$["k k"][1]["a.b"] = 1', '$["q\\""] = 3' })
end

local function test_flatten_of_a_scalar_or_an_empty_container_is_that_one_leaf()
  assert_lines(flat_lines(3), { "$ = 3" })
  assert_lines(flat_lines("x"), { '$ = "x"' })
  assert_lines(flat_lines(decoded("{}")), { "$ = {}" })
  assert_lines(flat_lines(decoded("[]")), { "$ = []" })
  assert_lines(flat_lines(Json.array()), { "$ = []" })
  assert_lines(flat_lines(decoded("null", { null_value = Json.null })), { "$ = null" })
  assert_lines(flat_lines(decoded('[[], [[]], {}]')), { "$[1] = []", "$[2][1] = []", "$[3] = {}" })
end

local function test_flatten_skips_holes_and_keeps_the_neighbours_indexes()
  local holey: {integer:string} = { [1] = "a", [3] = "c", [7] = "g" }
  assert_lines(flat_lines(holey), { '$[1] = "a"', '$[3] = "c"', '$[7] = "g"' })
  -- Nulls decoded to nothing leave an object member absent, and an object of only those is empty.
  assert_lines(flat_lines(decoded('{"a": null, "b": 1}')), { "$.b = 1" })
  assert_lines(flat_lines(decoded('{"a": null}')), { "$ = {}" })
end

local function test_flatten_root_spells_the_value_where_it_was_found()
  local doc = decoded('{"users": [{"id": 1}]}')
  local user = got(doc, { "users", 1 })
  assert_lines(flat_lines(user, { root = "$.users[1]" }), { "$.users[1].id = 1" })
end

local function test_flatten_stops_at_max_depth_naming_the_path()
  local doc = decoded('{"a": {"b": [1]}}')
  local leaves, err = json_query.flatten(doc, { max_depth = 2 })
  assert(leaves == nil and err:find("$.a.b", 1, true) and err:find("max_depth 2", 1, true), err)
  assert_lines(flat_lines(doc, { max_depth = 3 }), { "$.a.b[1] = 1" })
  -- An empty container still nests: it is a container.
  local _, empty_err = json_query.flatten(decoded('[[[]]]'), { max_depth = 2 })
  assert(empty_err:find("$[1][1]", 1, true), empty_err)
  local deep: any = 1
  for _ = 1, 100 do deep = { deep } end
  local _, default_err = json_query.flatten(deep)
  assert(default_err:find("max_depth 64", 1, true), default_err)
  assert(json_query.flatten(deep, { max_depth = 200 }) ~= nil)
  assert(not pcall(json_query.flatten, doc, { max_depth = 0 }))
  assert(not pcall(json_query.flatten, doc, { max_depth = Json.depth_limit + 1 }))
end

local function test_flatten_fails_on_a_cycle_and_on_mixed_keys()
  local loop: {string:any} = { name = "x" }
  loop.self = loop
  local leaves, err = json_query.flatten(loop)
  assert(leaves == nil and err:find("$.self: the table contains itself", 1, true), err)
  local mixed: {any:any} = { a = 1, [1] = 2 }
  local m, mixed_err = json_query.flatten({ rows = mixed })
  assert(m == nil and mixed_err:find("$.rows: expected an object or an array, got table with mixed keys", 1, true), mixed_err)
  -- The same table twice is no cycle.
  local shared = { 1 }
  assert_lines(flat_lines({ a = shared, b = shared }), { "$.a[1] = 1", "$.b[1] = 1" })
end

local function test_flat_line_prints_the_compact_value()
  assert(json_query.flat_line("$.a[1].b", 1200.5) == "$.a[1].b = 1200.5")
  assert(json_query.flat_line("$", Json.null) == "$ = null")
  assert(json_query.flat_line("$.s", 'a "q" = b\n') == '$.s = "a \\"q\\" = b\\n"')
  local line, err = json_query.flat_line("$.f", function() end)
  assert(line == nil and err:find("$.f", 1, true), err)
end

local function test_every_flat_path_reads_back_to_its_leaf()
  local doc = decoded('{"a b": [1, {"c\\"d": [true, null, {}], "e": "s"}], "": {"": 0}, "$": 1.5}',
    { null_value = Json.null })
  local leaves = assert(json_query.flatten(doc))
  assert(#leaves == 7, #leaves)
  for _, leaf in ipairs(leaves) do
    local steps = path_of(leaf.path)
    local value = got(doc, steps)
    local expected = leaf.value
    if expected is {any:any} then
      assert(encoded(value) == encoded(expected), leaf.path)
    else
      assert(value == expected, leaf.path)
    end
  end
end

local record Kinds
  kind: json_query.StepKind
  key: string
  index: integer
end

local function assert_pattern(text: string, want: {Kinds})
  local steps, err = json_query.parse_pattern(text)
  assert(steps ~= nil, text .. ": " .. err)
  assert(err == "")
  assert(#steps == #want, text .. " read as " .. #steps .. " steps")
  for i, w in ipairs(want) do
    assert(steps[i].kind == w.kind and steps[i].key == w.key and steps[i].index == w.index,
      text .. " step " .. i .. " is " .. steps[i].kind)
  end
  assert(json_query.spell_pattern(steps) == json_query.spell_pattern(pat(json_query.spell_pattern(steps))))
end

local function refused_pattern(text: string, why: string)
  local steps, err = json_query.parse_pattern(text)
  assert(steps == nil, text .. " read")
  assert(err:find(why, 1, true), text .. ": " .. err)
end

local function test_parse_pattern_reads_wildcards_and_descent()
  assert_pattern("$", {})
  assert_pattern("$.a.*", { { kind = "key", key = "a" }, { kind = "any" } })
  assert_pattern("a[*].b", { { kind = "key", key = "a" }, { kind = "any" }, { kind = "key", key = "b" } })
  assert_pattern("*", { { kind = "any" } })
  assert_pattern("$..id", { { kind = "deep_key", key = "id" } })
  assert_pattern("..id", { { kind = "deep_key", key = "id" } })
  assert_pattern("$.a..[3]", { { kind = "key", key = "a" }, { kind = "deep_index", index = 3 } })
  assert_pattern('$..["a key"].x', { { kind = "deep_key", key = "a key" }, { kind = "key", key = "x" } })
  assert_pattern("$..*", { { kind = "deep_any" } })
  assert_pattern("$..[*]", { { kind = "deep_any" } })
  assert_pattern("$[-1]..a[2]", { { kind = "index", index = -1 }, { kind = "deep_key", key = "a" }, { kind = "index", index = 2 } })
  -- Quoted `*` and `..` are keys.
  assert_pattern('$["*"]["..x"]', { { kind = "key", key = "*" }, { kind = "key", key = "..x" } })
  assert_pattern("$.a*.*b", { { kind = "key", key = "a*" }, { kind = "key", key = "*b" } })
end

local function test_parse_pattern_refuses_what_parse_path_refuses()
  refused_pattern("", "empty")
  refused_pattern("$.", "column 3: expected a key")
  refused_pattern("$..", "column 4: expected a key after `..`")
  refused_pattern("$...a", "expected a key after `..`")
  refused_pattern("$.a..", "expected a key after `..`")
  refused_pattern("$[", "expected an integer or a quoted key")
  refused_pattern("$[**]", "expected an integer or a quoted key")
  refused_pattern("$..[", "expected an integer or a quoted key")
  refused_pattern("$..[1.5]", "expected an integer or a quoted key")
  refused_pattern('$.*["a', "unclosed [")
  refused_pattern("$.*x[1]y", "expected `.` or `[`")
end

local function test_parse_pattern_and_parse_path_agree_on_plain_text_and_split_on_the_rest()
  for _, text in ipairs({ "$", "$.a[2][\"b c\"]", "a.b", "[1]", '$["*"]' }) do
    local plain = path_of(text)
    local steps = pat(text)
    assert(#steps == #plain, text)
    for i, step in ipairs(steps) do
      local want: string | integer = plain[i]
      if want is string then
        assert(step.kind == "key" and step.key == want, text)
      else
        assert(step.kind == "index" and step.index == want, text)
      end
    end
  end
  for _, text in ipairs({ "$.*", "$.a[*]", "$..a", "$.a..[1]", "$..*" }) do
    refused_path(text, "is a pattern, not a path")
    assert(#pat(text) > 0, text)
  end
end

local function test_spell_pattern_reads_back_as_the_same_steps()
  for _, text in ipairs({ "$", "$.a.*", "$..id", '$..["a key"]', "$..[3]", "$..*", '$["*"]..["*"]', "$[-2]" }) do
    assert(json_query.spell_pattern(pat(text)) == text, text)
  end
  assert(json_query.spell_pattern(pat("a[*]..b")) == "$.a.*..b")
  assert(not pcall(json_query.spell_pattern, { { kind = "key" } }))
end

--- The paths [`json_query.select`] finds for `pattern` in `doc`, joined by spaces.
local function selected(doc: any, pattern: string): string
  local found, err = json_query.select(doc, pat(pattern))
  assert(found ~= nil, pattern .. ": " .. err)
  assert(err == "")
  local paths: {string} = {}
  for i, match in ipairs(found) do paths[i] = match.path end
  return table.concat(paths, " ")
end

local SELECT_DOC <const> = [=[
{"id": 0, "users": [{"id": 1, "name": "ann", "tags": ["x", "y"], "kin": {"id": 11}},
                    {"id": 2, "name": "bo", "tags": []}],
 "meta": {"id": 9, "n": null, "deep": {"deep": {"id": 10}}}, "k k": [[1, 2], [3]]}
]=]

local function test_select_a_plain_pattern_matches_what_get_finds()
  local doc = decoded(SELECT_DOC)
  assert(selected(doc, "$") == "$")
  assert(selected(doc, "$.users[2].name") == "$.users[2].name")
  assert(selected(doc, '$["k k"][2][1]') == '$["k k"][2][1]')
  assert(selected(doc, "$.nope") == "")
  assert(selected(doc, "$.users[3]") == "")
  assert(selected(doc, "$.id.x") == "")
end

local function test_select_wildcards_take_every_member_or_element()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$.users[*].name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$.users.*.name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$.meta.*") == "$.meta.deep $.meta.id $.meta.n")
  assert(selected(doc, "$.users[1].tags[*]") == "$.users[1].tags[1] $.users[1].tags[2]")
  assert(selected(doc, '$["k k"][*][*]') == '$["k k"][1][1] $["k k"][1][2] $["k k"][2][1]')
  assert(selected(doc, "$.users[*].tags[*]") == "$.users[1].tags[1] $.users[1].tags[2]")
  assert(selected(doc, "$.users[2].tags[*]") == "")
  -- A wildcard over a scalar or a null matches nothing, and is no error.
  assert(selected(doc, "$.id.*") == "")
  assert(selected(doc, "$.meta.n[*]") == "")
  assert(selected(doc, "$.users[*].nope") == "")
  assert(selected(doc, "$.id[*]") == "")
  assert(selected(doc, "$.tags[*]") == "")
end

local function test_select_a_wildcard_meeting_the_other_kind_of_container_matches_by_kind()
  local doc = decoded('{"o": {"1": "s"}, "a": ["t"]}')
  assert(selected(doc, "$.o[1]") == "")
  assert(selected(doc, "$.a.x") == "")
  assert(selected(doc, "$.o[*]") == '$.o["1"]')
  assert(selected(doc, "$.*[*]") == '$.a[1] $.o["1"]')
end

local function test_select_descent_finds_a_key_at_any_depth_root_level_included()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$..id") ==
    "$.id $.meta.deep.deep.id $.meta.id $.users[1].id $.users[1].kin.id $.users[2].id")
  -- At the root's own level and below, and a match before what is inside it.
  assert(selected(decoded('{"a": {"a": 1}, "b": {"a": 2}}'), "$..a") == "$.a $.a.a $.b.a")
  assert(selected(decoded('{"a": 1}'), "..a") == "$.a")
  assert(selected(doc, "$..deep") == "$.meta.deep $.meta.deep.deep")
  assert(selected(doc, "$.meta..deep.id") == "$.meta.deep.deep.id")
  assert(selected(doc, "$.users..name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$..nope") == "")
  assert(selected(decoded("5"), "$..a") == "")
end

local function test_select_descent_by_index_and_over_everything()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$..[1]") == '$["k k"][1] $["k k"][1][1] $["k k"][2][1] $.users[1] $.users[1].tags[1]')
  assert(selected(doc, "$.users[1].kin..*") == "$.users[1].kin.id")
  assert(selected(decoded('{"a": [1, [2]]}'), "$..*") == "$.a $.a[1] $.a[2] $.a[2][1]")
  assert(selected(decoded('{"a": [1, [2]]}'), "$..[*]") == "$.a $.a[1] $.a[2] $.a[2][1]")
end

local function test_select_lists_each_value_once_however_it_is_reached()
  local doc = decoded('{"a": {"a": {"a": {"b": 1}}}}')
  assert(selected(doc, "$..a..b") == "$.a.a.a.b")
  assert(selected(doc, "$..a.a.b") == "$.a.a.a.b")
  assert(selected(doc, "$..a..*") == "$.a.a $.a.a.a $.a.a.a.b")
  local paired = decoded('{"x": {"x": 1}}')
  assert(selected(paired, "$..x..x") == "$.x.x")
end

local function test_select_answers_the_values_with_the_paths()
  local doc = decoded('{"a": [{"n": 1}, {"n": 2.5}], "b": {"n": "s"}}')
  local found = assert(json_query.select(doc, pat("$..n")))
  assert(#found == 3)
  assert(found[1].path == "$.a[1].n" and found[1].value == 1)
  assert(found[2].path == "$.a[2].n" and found[2].value == 2.5)
  assert(found[3].path == "$.b.n" and found[3].value == "s")
  local whole = assert(json_query.select(doc, {}))
  assert(#whole == 1 and whole[1].path == "$" and rawequal(whole[1].value, doc))
  local container = assert(json_query.select(doc, pat("$.a[*]")))
  assert(rawequal(container[1].value, (got(doc, { "a", 1 }))))
  -- Each match's path reads back to it.
  for _, match in ipairs(found) do assert(got(doc, path_of(match.path)) == match.value) end
end

local function test_select_spells_paths_from_the_root_it_is_given()
  local doc = decoded('{"n": 1, "m": [2]}')
  local found = assert(json_query.select(doc, pat("$.*"), { root = "$.x" }))
  assert(#found == 2 and found[1].path == "$.x.m" and found[2].path == "$.x.n")
end

local function test_select_hole_matches_nothing_and_neighbours_keep_indexes()
  local holey: {any:any} = { [1] = "a", [3] = "c" }
  assert(selected(holey, "$[*]") == "$[1] $[3]")
  assert(selected(holey, "$[2]") == "")
  assert(selected(holey, "$[3]") == "$[3]")
  assert(selected(holey, "$..*") == "$[1] $[3]")
end

local function test_select_fails_like_flatten_on_depth_cycles_and_mixed_keys()
  local doc = decoded('{"a": {"b": {"c": 1}}}')
  local found, err = json_query.select(doc, pat("$..c"), { max_depth = 2 })
  assert(found == nil and err:find("$.a.b: nested deeper than max_depth 2", 1, true), err)
  assert(json_query.select(doc, pat("$..c"), { max_depth = 3 }) ~= nil)
  -- A pattern that never goes down that far does not meet the limit.
  assert(json_query.select(doc, pat("$.a"), { max_depth = 1 }) ~= nil)
  local loop: {string:any} = { name = "x" }
  loop.self = loop
  local _, cycle = json_query.select(loop, pat("$..zzz"))
  assert(cycle:find("contains itself", 1, true), cycle)
  local _, mixed = json_query.select({ a = 1, [1] = 2 }, pat("$.*"))
  assert(mixed:find("mixed keys", 1, true), mixed)
  assert(not pcall(json_query.select, doc, { { kind = "key" } }))
  assert(not pcall(json_query.select, doc, {}, { max_depth = 0 }))
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

local function test_select_descent_over_a_large_document_lays_out_each_container_once()
  local parts: {string} = {}
  for i = 1, 16000 do
    parts[i] = '{"id": ' .. i .. ', "tags": ["a", "b"], "in": {"id": -' .. i .. '}}'
  end
  -- 16000 records of 7 values each is over 100k values, of which 48002
  -- are containers: the root, rows, and per record the record, tags and
  -- in.
  local counter = { 0 }
  local doc = counted(decoded('{"rows": [' .. table.concat(parts, ",") .. ']}'), counter)
  local ids = assert(json_query.select(doc, pat("$..id")))
  assert(#ids == 32000, #ids)
  assert(ids[1].path == "$.rows[1].id" and ids[2].path == "$.rows[1].in.id")
  assert(counter[1] == 48002, "laid out " .. counter[1] .. " containers")
  -- Nor does a second descent, or a wildcard, walk anything twice.
  counter[1] = 0
  assert(#assert(json_query.select(doc, pat("$..in..id"))) == 16000)
  assert(counter[1] == 48002, "laid out " .. counter[1] .. " containers")
end

local function test_select_chained_descents_are_linear_not_a_product()
  -- Every `a` is inside every earlier `a`: a walk that restarts at each
  -- match meets the innermost ones once per way of reaching them, over
  -- 100 million times here, and lists them that often.
  local chain: any = { leaf = 1 }
  for _ = 1, 900 do chain = { a = chain } end
  local counter = { 0 }
  local found = assert(json_query.select(counted(chain, counter), pat("$..a..a..a"), { max_depth = 1000 }))
  assert(#found == 898, #found)
  assert(found[1].path == "$.a.a.a" and found[898].path:sub(-6) == ".a.a.a")
  assert(counter[1] == 901, "laid out " .. counter[1] .. " containers")
end

local function test_select_spells_each_path_from_the_one_before_it()
  -- 900 matches at depths 1 to 900: spelling each from `$` would be
  -- 400k steps; the paths have to come out right all the same.
  local chain: any = { leaf = 1 }
  for _ = 1, 900 do chain = { a = chain } end
  local found = assert(json_query.select(chain, pat("$..a"), { max_depth = 1000 }))
  assert(#found == 900, #found)
  local text = "$"
  for i = 1, 900 do
    text = text .. ".a"
    assert(found[i].path == text, i)
  end
end

local function test_flatten_of_a_large_document_lays_out_each_container_once()
  local rows: {any} = {}
  for i = 1, 25000 do rows[i] = { id = i, tags = { "a", "b" }, ["in"] = { id = -i } } end
  local counter = { 0 }
  local leaves = assert(json_query.flatten(counted({ rows = Json.array(rows) }, counter)))
  assert(#leaves == 100000, #leaves)
  assert(leaves[1].path == "$.rows[1].id" and leaves[4].path == "$.rows[1].tags[2]")
  assert(counter[1] == 75002, "laid out " .. counter[1] .. " containers")
end

local function test_a_decoded_array_with_holes_keeps_the_elements_past_them()
  assert_lines(flat_lines(decoded("[null, 2, 3]")), { "$[2] = 2", "$[3] = 3" })
  assert_lines(flat_lines(decoded("[1, null, 3]")), { "$[1] = 1", "$[3] = 3" })
  assert_lines(flat_lines(decoded("[1, null, null]")), { "$[1] = 1" })
  assert_lines(flat_lines(decoded('{"a": [null, {"b": 1}, null, [4]]}')), { "$.a[2].b = 1", "$.a[4][1] = 4" })
  assert_lines(flat_lines(decoded("[null, null]")), { "$ = []" })
  assert(selected(decoded("[null, 2, 3]"), "$[*]") == "$[2] $[3]")
  assert(selected(decoded("[1, null, 3]"), "$[*]") == "$[1] $[3]")
  assert(selected(decoded("[1, null, 3]"), "$[3]") == "$[3]")
  assert(selected(decoded("[1, null, 3]"), "$[2]") == "")
  assert(selected(decoded('{"a": [null, {"b": 1}, [null, 5]]}'), "$..*") == "$.a $.a[2] $.a[2].b $.a[3] $.a[3][2]")
  assert(selected(decoded('[null, {"id": 1}, null, {"id": 2}]'), "$..id") == "$[2].id $[4].id")
end

local function test_select_refuses_a_pattern_of_more_than_62_steps()
  local steps: {json_query.Step} = {}
  for i = 1, 62 do steps[i] = { kind = "any" } end
  local deep: any = 1
  for _ = 1, 62 do deep = { deep } end
  local found = assert(json_query.select(deep, steps, { max_depth = 100 }))
  assert(#found == 1 and found[1].path:sub(1, 6) == "$[1][1")
  steps[63] = { kind = "any" }
  local none, err = json_query.select(deep, steps)
  assert(none == nil and err:find("at most 62 steps, not 63", 1, true), err)
end

local function test_select_a_plain_step_meets_mixed_keys_as_a_wildcard_does()
  local mixed: {any:any} = { a = 1, [1] = 2 }
  for _, text in ipairs({ "$.x.a", "$.x[1]", "$.x.*", "$.x..a" }) do
    local found, err = json_query.select({ x = mixed }, pat(text))
    assert(found == nil and err:find("$.x: expected an object or an array, got table with mixed keys", 1, true), text .. ": " .. tostring(err))
  end
end

local function test_child_path_spells_a_key_and_an_index()
  assert(json_query.child_path("$", "rows") == "$.rows")
  assert(json_query.child_path("$.rows", 2) == "$.rows[2]")
  assert(json_query.child_path("$", "a key") == '$["a key"]')
  assert(json_query.child_path("$", "") == '$[""]')
  assert(json_query.child_path("$", 'q"\n') == '$["q\\"\\u000a"]')
end

--- A depth outside what a walk takes raises, naming the caller, and one
--- check says so for `flatten`, `select` and `describe` alike.
local function test_a_max_depth_out_of_range_raises_naming_the_caller()
  local doc = decoded('{"a": [1]}')
  local function flatten_with(depth: any): any
    -- Not a tail call, which would leave no frame here to name.
    local leaves = json_query.flatten(doc, { max_depth = depth as integer })
    return leaves
  end
  local function select_with(depth: any): any
    local found = json_query.select(doc, {}, { max_depth = depth as integer })
    return found
  end
  local function describe_with(depth: any): any
    local text = json_query.describe(doc, { max_depth = depth as integer })
    return text
  end
  local walks = "json: max_depth must be an integer from 1 to " .. Json.depth_limit
  for _, bad in ipairs({ 0, Json.depth_limit + 1, 1.5, "2" } as {any}) do
    for _, call in ipairs({ flatten_with, select_with } as {function(any): any}) do
      local ok, message = pcall(call, bad)
      assert(not ok and tostring(message):find(walks, 1, true), tostring(message))
      assert(tostring(message):find("json_query_test", 1, true), "named where it was called: " .. tostring(message))
    end
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

--- Explore a document whose shape is not known: `describe` shows it at a
--- glance, `get` reaches one value, and `entries` and `items` narrow an
--- object or an array so `pairs` and `ipairs` need no cast.
local function test_a_document_is_explored_by_shape_then_by_path()
  local doc = assert(Json.decode('{"rows": [{"id": "a", "n": 1}, {"id": "b"}], "ok": true}'))
  assert(json_query.describe(doc) == "{ok: boolean, rows: [2 x {id: string, n?: number}]}")
  assert(Json.get(doc, { "rows", 2, "id" }) == "b")
  local _, why = Json.get(doc, { "rows", 3 })
  assert(why == "$.rows: index 3 out of range, the array has 2", why)
  local keys: {string} = {}
  for _, row in ipairs((assert(Json.items(doc, { "rows" })))) do
    for key in pairs((assert(Json.entries(row)))) do keys[#keys + 1] = key end
  end
  table.sort(keys)
  assert(table.concat(keys, ",") == "id,id,n", table.concat(keys, ","))
end
