--- Proves cosmic.json's three spellings of a path -- Lua steps counted
--- from 1, JSON Pointer (RFC 6901) and JSONPath (RFC 9535) counted from
--- 0 -- say the same places, and that each text form is read strictly:
--- what the subset leaves out is refused by name, never read as
--- something else.

local Json = require("cosmic.json")

local function steps_text(steps: Json.Steps): string
  local parts: {string} = {}
  for i, step in ipairs(steps) do
    parts[i] = step is string and Json.quote(step) or tostring(step)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function same_steps(a: Json.Steps, b: Json.Steps): boolean
  return steps_text(a) == steps_text(b)
end

--- The message `f` fails with; the test fails if it does not.
local function failure(value: any, err: string, what?: string): string
  assert(value == nil and err ~= "", (what or "it") .. " should fail")
  return err
end

local DOC <const> = assert(Json.decode([[{
  "users": [{"name": "ada", "tags": ["x", "y"]}, {"name": "bob"}],
  "a/b": 1, "m~n": 2, "": 3, "it's": 4, "nil": null
}]], { null_value = Json.null })) as {string: any}

local function test_a_pointer_counts_from_0_and_escapes_its_separators()
  assert(Json.pointer({}) == "", "the whole value")
  assert(Json.pointer({ "users", 2, "name" }) == "/users/1/name")
  assert(Json.pointer({ "a/b", "m~n", "" }) == "/a~1b/m~0n/")
  assert(failure(Json.pointer({ "users", -1 })) ==
      "json: step 2 is -1, from the end, which a JSON Pointer cannot say")
  assert(failure(Json.pointer({ 0 })) == "json: step 1 is 0: positions count from 1, or from -1 at the end")
end

local function test_a_pointer_is_read_against_the_value()
  assert(same_steps(assert(Json.from_pointer(DOC, "")), {}))
  assert(same_steps(assert(Json.from_pointer(DOC, "/users/1/name")), { "users", 2, "name" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/a~1b")), { "a/b" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/m~0n")), { "m~n" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/")), { "" }), "`/` is the member named \"\"")
  assert(same_steps(assert(Json.from_pointer(DOC, "/nil")), { "nil" }), "a null stand-in is a value")
  local digits = assert(Json.decode('{"2": "two"}'))
  assert(same_steps(assert(Json.from_pointer(digits, "/2")), { "2" }), "a number into an object is a name")
  local cases: {{string}} = {
    { "users", 'json: pointer "users": a JSON Pointer is empty or starts with `/`' },
    { "/users/01", 'json: no value at pointer "/users/01": the value at pointer "/users" is an array, ' ..
        'and "01" is no index' },
    { "/users/-", 'json: no value at pointer "/users/-": `-` names the place past the last element' },
    { "/users/2", 'json: no value at pointer "/users/2"' },
    { "/users/0/name/x", 'json: no value at pointer "/users/0/name/x": the value at pointer ' ..
        '"/users/0/name" is string' },
    { "/a~2", 'json: pointer "/a~2": the `~` at byte 3 is neither `~0` nor `~1`' },
    { "/a~", 'json: pointer "/a~": the `~` at byte 3 is neither `~0` nor `~1`' },
    { "/missing", 'json: no value at pointer "/missing"' },
  }
  for _, case in ipairs(cases) do
    local _, err = Json.from_pointer(DOC, case[1])
    assert(err == case[2], case[1] .. ": " .. err)
  end
  -- `~01` is `~1` read as text, not `/`: `~0` is undone last.
  local tilde = assert(Json.decode('{"~1": 1}'))
  assert(same_steps(assert(Json.from_pointer(tilde, "/~01")), { "~1" }))
end

local function test_get_follows_steps_and_counts_back_from_the_end()
  assert(Json.get(DOC, { "users", 1, "name" }) == "ada")
  assert(Json.get(DOC, { "users", -1, "name" }) == "bob")
  assert(Json.get(DOC, { "users", 1, "tags", -2 }) == "x")
  assert(Json.get(DOC, {}) == DOC)
  assert(failure(Json.get(DOC, { "users", 3 })) == 'json: no value at pointer "/users/2"')
  assert(failure(Json.get(DOC, { "users", -3 })) == 'json: no element 3 from the end at pointer "/users"')
  assert(failure(Json.get(DOC, { "users", "name" })) == 'json: the value at pointer "/users" is an array, not an object')
  assert(failure(Json.get(DOC, { 1 })) == 'json: the value at pointer "" is an object, not an array')
  assert(failure(Json.get(DOC, { "it's", "x" })) == 'json: the value at pointer "/it\'s" is number, not an array or object')
  assert(failure(Json.get({ 1, a = 2 }, { 1 })) == 'json: the value at pointer "" is a table with mixed keys, not an array')
end

local function test_a_normalized_path_counts_from_0()
  assert(Json.path({}) == "$")
  assert(Json.path({ "users", 2, "name" }) == "$['users'][1]['name']")
  assert(Json.path({ "it's", "a\\b", "\n\t\1\127" }) == "$['it\\'s']['a\\\\b']['\\n\\t\\u0001\127']")
  assert(Json.path({ "users", -1 }) == "$['users'][-1]", "from the end, as a query reads it")
  assert(failure(Json.path({ 0 })):match("step 1 is 0"))
end

local function test_a_singular_query_reads_as_steps()
  local cases: {{any}} = {
    { "$", {} },
    { "$.users[0].name", { "users", 1, "name" } },
    { "$['users'][1][\"name\"]", { "users", 2, "name" } },
    { "$.users[-1]", { "users", -1 } },
    { "$['it\\'s']", { "it's" } },
    { "$[\"a\\\"b\"]", { 'a"b' } },
    { "$['\\u00e9\\ud83d\\ude00\\n\\/']", { "\u{e9}\u{1f600}\n/" } },
    { "$.\u{e9}t\u{e9}", { "\u{e9}t\u{e9}" } },
    { "$ .a [ 0 ] ['b']", { "a", 1, "b" } },
    { "$[9007199254740991]", { 9007199254740992 } },
  }
  for _, case in ipairs(cases) do
    local text, want = case[1] as string, case[2] as Json.Steps
    local steps, err = Json.from_path(text)
    assert(steps ~= nil and same_steps(steps, want), text .. ": " .. err .. " " .. steps_text(steps or {}))
  end
  for _, steps in ipairs({ {}, { "users", 1, "name" }, { "it's", "\0", -3 } } as {Json.Steps}) do
    assert(same_steps(assert(Json.from_path((assert(Json.path(steps))))), steps), "a normalized path reads back")
  end
end

--- What the subset leaves out, or the RFC's grammar refuses, is refused,
--- naming the byte.
local function test_queries_are_read_strictly()
  local cases: {{string}} = {
    { "users", "byte 1: a query starts with `$`" },
    { "$users", "byte 2: a segment starts with `.`, `..` or `[`" },
    { "$.a ", "byte 4: blank space after the last segment" },
    { "$. a", "byte 3: after `.` comes a name or `*`" },
    { "$.1a", "byte 3: after `.` comes a name or `*`" },
    { "$..", "byte 4: after `..` comes a name, `*` or `[`" },
    { "$[01]", "byte 3: an index is 0, or has no leading zero and is not -0" },
    { "$[-0]", "byte 3: an index is 0, or has no leading zero and is not -0" },
    { "$[-a]", "byte 3: an index is 0, or has no leading zero and is not -0" },
    { "$[9007199254740992]", "byte 3: an index past 2^53 - 1" },
    { "$[1:2]", "byte 4: slices (`start:end:step`) are not in the subset cosmic reads" },
    { "$[:2]", "byte 3: slices (`start:end:step`) are not in the subset cosmic reads" },
    { "$[?@.a]", "byte 3: filters (`?`) are not in the subset cosmic reads" },
    { "$[0, 1]", "byte 4: unions (`[a, b]`) are not in the subset cosmic reads" },
    { "$['a'", "byte 6: expected `]`" },
    { "$['a]", "byte 3: a string the query ends inside" },
    { "$['\\q']", "byte 4: `\\q` is no escape a JSONPath string has" },
    { "$['\\ud83d']", "byte 4: a high surrogate with no low one after it" },
    { "$['\\ude00']", "byte 4: a low surrogate with no high one before it" },
    { "$['a\nb']", "byte 5: a control character in a string, which must be escaped" },
    { "$[a]", "byte 3: a selector is a name in quotes, an index or `*`" },
    { "$['\xff']", "byte 4: a byte that is not UTF-8" },
  }
  for _, case in ipairs(cases) do
    local q, err = Json.query(case[1])
    assert(q == nil and err == "json: JSONPath " .. case[2], ("%q: %s"):format(case[1], err))
  end
  local _, many = Json.from_path("$..a")
  assert(many == 'json: JSONPath "$..a" selects many values (segment 1): read it with Json.query', many)
  local _, star = Json.from_path("$.a[*]")
  assert(star:match("selects many values %(segment 2%)"), star)
end

--- RFC 9535's own examples (section 1.5), on its bookstore.
local function test_select_answers_the_rfc_examples()
  local store = assert(Json.decode([[{ "store": {
    "book": [
      { "category": "reference", "author": "Nigel Rees", "title": "Sayings of the Century", "price": 8.95 },
      { "category": "fiction", "author": "Evelyn Waugh", "title": "Sword of Honour", "price": 12.99 },
      { "category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3",
        "price": 8.99 },
      { "category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings",
        "isbn": "0-395-19395-8", "price": 22.99 }
    ],
    "bicycle": { "color": "red", "price": 399 } } }]]))
  local function run(text: string): {Json.Match}
    return (assert(Json.select(store, (assert(Json.query(text))))))
  end
  local function values(found: {Json.Match}): string
    local out: {string} = {}
    for i, m in ipairs(found) do out[i] = assert(Json.encode(m.value)) end
    return table.concat(out, " ")
  end
  local function pointers(found: {Json.Match}): string
    local out: {string} = {}
    for i, m in ipairs(found) do out[i] = assert(Json.pointer(m.steps)) end
    return table.concat(out, " ")
  end
  assert(values(run("$.store.book[*].author")) == '"Nigel Rees" "Evelyn Waugh" "Herman Melville" "J. R. R. Tolkien"')
  assert(values(run("$..author")) == '"Nigel Rees" "Evelyn Waugh" "Herman Melville" "J. R. R. Tolkien"')
  assert(pointers(run("$.store.*")) == "/store/bicycle /store/book", "members in byte order")
  assert(values(run("$.store..price")) == "399 8.95 12.99 8.99 22.99", "the node before its children")
  assert(values(run("$..book[2].title")) == '"Moby Dick"')
  assert(values(run("$..book[-1].title")) == '"The Lord of the Rings"')
  assert(#run("$..*") == 27, "every member and element beneath the root")
  assert(#run("$.store.book[4]") == 0 and #run("$.store.book.x") == 0 and #run("$.nothing[0]") == 0,
    "what a selector does not find selects nothing")
  local found = run("$..book[0]")
  assert(#found == 1 and Json.path(found[1].steps) == "$['store']['book'][0]")
  assert(found[1].steps[3] == 1, "a match's steps count from 1")
end

local function test_select_refuses_what_is_not_json()
  local loop: {string: any} = {}
  loop.self = loop
  local _, cycle = Json.select(loop, (assert(Json.query("$..x"))), { max_depth = 5 })
  assert(cycle == 'json: a value nests deeper than 5 levels at pointer "/self/self/self/self/self" ' ..
      "(does it contain itself?)", cycle)
  local _, mixed = Json.select({ a = { 1, b = 2 } }, (assert(Json.query("$.a[0]"))))
  assert(mixed == 'json: the value at pointer "/a" is a table with mixed keys', mixed)
  local everything = assert(Json.query("$"))
  assert(not pcall(function() Json.select({}, everything, { max_depth = 0 }) end), "a depth below 1 raises")
end

--- A table with a hole counts from its highest position, as its
--- elements do; a step of 0, or that is no step, is named.
local function test_steps_count_from_a_holes_highest_position()
  local holed: {any: any} = { [1] = "a", [3] = "c" }
  assert(Json.get(holed, { -1 }) == "c" and Json.get(holed, { -3 }) == "a")
  local last = assert(Json.select(holed, (assert(Json.query("$[-1]")))))
  assert(#last == 1 and last[1].value == "c" and last[1].steps[1] == 3)
  assert(failure(Json.get(holed, { 0 })) == "json: step 1 is 0: positions count from 1, or from -1 at the end")
  assert(failure(Json.get(holed, { 1.5 } as Json.Steps)) == "json: step 1 is 1.5, neither a name nor an integer")
  assert(failure(Json.path({ "\xff" })) == "json: step 1 is a name that is not UTF-8")
  assert(failure(Json.pointer({ "a", "\xff" })) == "json: step 2 is a name that is not UTF-8")
end

--- A place too long for a message keeps its innermost segments, and a
--- key too long even alone keeps its start, in the core's messages and
--- in this module's alike; DEL is escaped in both.
local function test_a_long_place_is_named_by_its_innermost_part()
  local long = string.rep("k", 250)
  local _, encoded = Json.encode({ a = { [long] = print } })
  assert(encoded == 'json: cannot encode a function at pointer ending "/' .. string.rep("k", 40) .. '..."', encoded)
  local slashes = string.rep("/", 150)
  local _, decoded = Json.decode(('{"a": {"%s": 1, "%s": 2}}'):format(slashes, slashes))
  assert(decoded:match('%(pointer ending "/' .. string.rep("~1", 20) .. '%.%.%."%)$'), decoded)
  local _, got = Json.get({ [long] = 1 }, { long, "x" })
  assert(got == 'json: the value at pointer ending "/' .. string.rep("k", 40) .. '..." is number, not an array or object',
    got)
  local loop: {string: any} = {}
  loop.self = loop
  local _, cycle = Json.select(loop, (assert(Json.query("$..x"))), { max_depth = 100 })
  assert(cycle:match('^json: a value nests deeper than 100 levels at pointer ending "/self/') and #cycle < 300, cycle)
  local _, del = Json.encode({ ["a\127"] = print })
  assert(del == 'json: cannot encode a function at pointer "/a\\u007f"', del)
  local _, del_get = Json.get({ ["a\127"] = 1 }, { "a\127", 1 })
  assert(del_get == 'json: the value at pointer "/a\\u007f" is number, not an array or object', del_get)
end
