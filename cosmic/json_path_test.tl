--- Proves cosmic.json's three spellings of a path -- Lua steps counted
--- from 1, JSON Pointer (RFC 6901) and JSONPath (RFC 9535) counted from
--- 0 -- say the same places, and that each text form is read strictly:
--- what the subset leaves out is refused by name, never read as
--- something else.

local Array = require("cosmic.array")
local type Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

--- The value of a value-and-reason pair, which is there: `assert` takes no optional that may hold `false`, which it would
--- raise for as for nil.
local function known_value(value: Json.Value?, why?: string): Json.Value
  assert(value ~= nil, why)
  return value
end

--- A text `input` and the `err` its reading is refused with.
local record Said
  input: string
  err: string
end

--- A singular query `text` and the `steps` it reads as.
local record Read
  text: string
  steps: Json.Steps
end

local function steps_text(steps: Json.Steps): string
  local parts: mut {string} = {}
  for _, step in ipairs(steps) do
    local text = if step is string then Json.quote(step) else tostring(step) end
    parts[#parts + 1] = text
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function same_steps(a: Json.Steps, b: Json.Steps): boolean
  return steps_text(a) == steps_text(b)
end

--- The message `f` fails with; the test fails if it does not.
local function failure(value: any, err: Failure?, what?: string): string
  assert(value == nil and err ~= nil, (what or "it") .. " should fail")
  return tostring(err)
end

local DOC <const> = assert(Json.decode_object([[{
  "users": [{"name": "ada", "tags": ["x", "y"]}, {"name": "bob"}],
  "a/b": 1, "m~n": 2, "": 3, "it's": 4, "nil": null
}]], { null_value = Json.null }))

local function test_a_pointer_counts_from_0_and_escapes_its_separators()
  assert(assert(Json.pointer({})) == "", "the whole value")
  assert(assert(Json.pointer({ "users", 2, "name" })) == "/users/1/name")
  assert(assert(Json.pointer({ "a/b", "m~n", "" })) == "/a~1b/m~0n/")
  local miss1, refusal1 = Json.pointer({ "users", -1 })
  assert(failure(miss1, refusal1) ==
      "json: step 2 is -1, from the end, which a JSON Pointer cannot say")
  local miss2, refusal2 = Json.pointer({ 0 })
  assert(failure(miss2, refusal2) == "json: step 1 is 0: positions count from 1, or from -1 at the end")
end

local function test_a_pointer_is_read_against_the_value()
  assert(same_steps(assert(Json.from_pointer(DOC, "")), {}))
  assert(same_steps(assert(Json.from_pointer(DOC, "/users/1/name")), { "users", 2, "name" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/a~1b")), { "a/b" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/m~0n")), { "m~n" }))
  assert(same_steps(assert(Json.from_pointer(DOC, "/")), { "" }), "`/` is the member named \"\"")
  assert(same_steps(assert(Json.from_pointer(DOC, "/nil")), { "nil" }), "a null stand-in is a value")
  local got1, why1 = Json.decode('{"2": "two"}')
  assert(got1 ~= nil, tostring(why1))
  local digits = known_value(got1)
  assert(same_steps(assert(Json.from_pointer(digits, "/2")), { "2" }), "a number into an object is a name")
  local cases: {Said} = {
    { input = "users", err = 'json: pointer "users": a JSON Pointer is empty or starts with `/`' },
    {
      input = "/users/01",
      err = 'json: no value at pointer "/users/01": the value at pointer "/users" is an array, ' ..
        'and "01" is no index',
    },
    { input = "/users/-", err = 'json: no value at pointer "/users/-": `-` names the place past the last element' },
    { input = "/users/2", err = 'json: no value at pointer "/users/2"' },
    {
      input = "/users/0/name/x",
      err = 'json: no value at pointer "/users/0/name/x": the value at pointer ' ..
        '"/users/0/name" is string',
    },
    { input = "/a~2", err = 'json: pointer "/a~2": the `~` at byte 3 is neither `~0` nor `~1`' },
    { input = "/a~", err = 'json: pointer "/a~": the `~` at byte 3 is neither `~0` nor `~1`' },
    { input = "/missing", err = 'json: no value at pointer "/missing"' },
  }
  for _, case in ipairs(cases) do
    local _, err = Json.from_pointer(DOC, case.input)
    assert(tostring(err) == case.err, case.input .. ": " .. tostring(err))
  end
  -- `~01` is `~1` read as text, not `/`: `~0` is undone last.
  local got2, why2 = Json.decode('{"~1": 1}')
  assert(got2 ~= nil, tostring(why2))
  local tilde = known_value(got2)
  assert(same_steps(assert(Json.from_pointer(tilde, "/~01")), { "~1" }))
end

local function test_get_follows_steps_and_counts_back_from_the_end()
  local got3, why3 = Json.get(DOC, { "users", 1, "name" })
  assert(got3 ~= nil, tostring(why3))
  assert(got3 == "ada")
  local got4, why4 = Json.get(DOC, { "users", -1, "name" })
  assert(got4 ~= nil, tostring(why4))
  assert(got4 == "bob")
  local got5, why5 = Json.get(DOC, { "users", 1, "tags", -2 })
  assert(got5 ~= nil, tostring(why5))
  assert(got5 == "x")
  local got6, why6 = Json.get(DOC, {})
  assert(got6 ~= nil, tostring(why6))
  assert(got6 == DOC)
  local miss3, refusal3 = Json.get(DOC, { "users", 3 })
  assert(failure(miss3, refusal3) == 'json: no value at pointer "/users/2"')
  local miss4, refusal4 = Json.get(DOC, { "users", -3 })
  assert(failure(miss4, refusal4) == 'json: no element 3 from the end at pointer "/users"')
  local miss5, refusal5 = Json.get(DOC, { "users", "name" })
  assert(failure(miss5, refusal5) == 'json: the value at pointer "/users" is an array, not an object')
  local miss6, refusal6 = Json.get(DOC, { 1 })
  assert(failure(miss6, refusal6) == 'json: the value at pointer "" is an object, not an array')
  local miss7, refusal7 = Json.get(DOC, { "it's", "x" })
  assert(failure(miss7, refusal7) == 'json: the value at pointer "/it\'s" is number, not an array or object')
  local miss8, refusal8 = Json.get({ [0] = 1 }, { 1 })
  assert(failure(miss8, refusal8) == 'json: the value at pointer "" is a table with mixed keys, not an array')
end

--- The text of `value`; the test fails if it does not encode.
local function text_of(value: Json.Value?): string
  local text, err = Json.encode_any(value)
  assert(text ~= nil, err)
  return text
end

local CONFIG <const> = '{"server":{"hosts":["a","b"],"port":80},"tags":[]}'

local function test_set_answers_a_changed_copy()
  local got7, why7 = Json.decode(CONFIG)
  assert(got7 ~= nil, tostring(why7))
  local config = known_value(got7)
  local got8, why8 = Json.set(config, { "server", "port" }, 8080)
  assert(got8 ~= nil, tostring(why8))
  assert(text_of(got8) == '{"server":{"hosts":["a","b"],"port":8080},"tags":[]}')
  local got9, why9 = Json.set(config, { "name" }, "x")
  assert(got9 ~= nil, tostring(why9))
  assert(text_of(got9) == '{"name":"x","server":{"hosts":["a","b"],"port":80},"tags":[]}',
    "a member not there is made")
  local got10, why10 = Json.set(config, { "server", "hosts", 1 }, "z")
  assert(got10 ~= nil, tostring(why10))
  assert(text_of(got10) == '{"server":{"hosts":["z","b"],"port":80},"tags":[]}')
  local got11, why11 = Json.set(config, { "server", "hosts", -1 }, "z")
  assert(got11 ~= nil, tostring(why11))
  assert(text_of(got11) == '{"server":{"hosts":["a","z"],"port":80},"tags":[]}',
    "a negative position counts from the end")
  local got12, why12 = Json.set(config, { "server", "hosts", 3 }, "c")
  assert(got12 ~= nil, tostring(why12))
  assert(text_of(got12) == '{"server":{"hosts":["a","b","c"],"port":80},"tags":[]}',
    "one past the end appends")
  local got13, why13 = Json.set(config, { "tags", 1 }, "t")
  assert(got13 ~= nil, tostring(why13))
  assert(text_of(got13) == '{"server":{"hosts":["a","b"],"port":80},"tags":["t"]}',
    "an empty array is appended to")
  local got14, why14 = Json.set(config, { "tags" }, Json.null)
  assert(got14 ~= nil, tostring(why14))
  assert(text_of(got14) == '{"server":{"hosts":["a","b"],"port":80},"tags":null}')
  local whole, err = Json.set(config, {}, "v")
  assert(whole == "v" and err == nil, "no steps: the new value itself")
  assert(text_of(config) == CONFIG, "the value given is as it was")
end

--- A set copies the tables its steps pass and shares the rest, and a copied
--- array is still one where it is empty.
local function test_set_and_remove_refuse_a_path_longer_than_a_value_nests()
  local steps: mut {string | integer} = {}
  for _ = 1, Json.depth_limit + 1 do
    steps[#steps + 1] = "k"
  end
  local miss9, refusal9 = Json.set(DOC, steps, 1)
  local why = failure(miss9, refusal9)
  assert(why:find("the path is longer than a value may nest (depth ", 1, true) ~= nil, why)
  local miss10, refusal10 = Json.remove(DOC, steps)
  assert(failure(miss10, refusal10) == why)
  -- Names the pointer escapes are told as `get` tells them.
  local miss11, refusal11 = Json.set(DOC, { "a/b", 3 }, 1)
  local escaped = failure(miss11, refusal11)
  assert(escaped:find('"/a~1b', 1, true) ~= nil, escaped)
end

local function test_set_copies_the_way_and_shares_the_rest()
  local got15, why15 = Json.decode(CONFIG)
  assert(got15 ~= nil, tostring(why15))
  local config = known_value(got15)
  local got16, why16 = Json.set(config, { "server", "port" }, 1)
  assert(got16 ~= nil, tostring(why16))
  local set = known_value(got16)
  local got17, why17 = Json.get(set, { "server" })
  assert(got17 ~= nil, tostring(why17))
  local got18, why18 = Json.get(config, { "server" })
  assert(got18 ~= nil, tostring(why18))
  assert(not rawequal(set, config) and not rawequal(got17, got18))
  local got19, why19 = Json.get(set, { "tags" })
  assert(got19 ~= nil, tostring(why19))
  local got20, why20 = Json.get(config, { "tags" })
  assert(got20 ~= nil, tostring(why20))
  assert(rawequal(got19, got20), "off the way: shared")
  local got21, why21 = Json.get(set, { "server", "hosts" })
  assert(got21 ~= nil, tostring(why21))
  local got22, why22 = Json.get(config, { "server", "hosts" })
  assert(got22 ~= nil, tostring(why22))
  assert(rawequal(got21, got22))
  local got23, why23 = Json.remove(config, { "server", "hosts", 1 })
  assert(got23 ~= nil, tostring(why23))
  local emptied = known_value(got23)
  local got24, why24 = Json.remove(emptied, { "server", "hosts", 1 })
  assert(got24 ~= nil, tostring(why24))
  local none = known_value(got24)
  assert(text_of(none) == '{"server":{"hosts":[],"port":80},"tags":[]}', "an array emptied is an array")
  local got25, why25 = Json.get(none, { "server", "hosts" })
  assert(got25 ~= nil, tostring(why25))
  assert(Json.is_array(got25))
end

local function test_set_refuses_a_place_it_would_have_to_invent()
  local got26, why26 = Json.decode(CONFIG)
  assert(got26 ~= nil, tostring(why26))
  local config = known_value(got26)
  local miss12, refusal12 = Json.set(config, { "server", "hosts", 4 }, "d")
  assert(failure(miss12, refusal12) ==
      'json: no value at pointer "/server/hosts/3": the array at pointer "/server/hosts" holds 2, ' ..
      'and set appends at position 3, leaving no hole')
  local miss13, refusal13 = Json.set(config, { "tags", 2 }, "t")
  assert(failure(miss13, refusal13) ==
      'json: no value at pointer "/tags/1": the array at pointer "/tags" holds 0, ' ..
      'and set appends at position 1, leaving no hole')
  local miss14, refusal14 = Json.set(config, { "client", "port" }, 1)
  assert(failure(miss14, refusal14) ==
      'json: no value at pointer "/client": set makes the last step only, so set an object or an array there first')
  local miss15, refusal15 = Json.set(config, { "server", "hosts", 3, "name" }, "c")
  assert(failure(miss15, refusal15) ==
      'json: no value at pointer "/server/hosts/2": set makes the last step only, ' ..
      'so set an object or an array there first')
  local miss16, refusal16 = Json.set(config, { "server", "hosts", -3 }, "z")
  assert(failure(miss16, refusal16) ==
      'json: no element 3 from the end at pointer "/server/hosts"')
  local miss17, refusal17 = Json.set(config, { "tags", -1 }, "z")
  assert(failure(miss17, refusal17) == 'json: no element 1 from the end at pointer "/tags"')
  local miss18, refusal18 = Json.set(config, { "server", "hosts", "name" }, 1)
  assert(failure(miss18, refusal18) ==
      'json: the value at pointer "/server/hosts" is an array, not an object')
  local miss19, refusal19 = Json.set(config, { 1 }, 1)
  assert(failure(miss19, refusal19) == 'json: the value at pointer "" is an object, not an array')
  local miss20, refusal20 = Json.set(config, { "server", "port", "x" }, 1)
  assert(failure(miss20, refusal20) ==
      'json: the value at pointer "/server/port" is number, not an array or object')
  local miss21, refusal21 = Json.set("text", { "a" }, 1)
  assert(failure(miss21, refusal21) == 'json: the value at pointer "" is string, not an array or object')
  local miss22, refusal22 = Json.set(config, { "tags", 0 }, 1)
  assert(failure(miss22, refusal22) ==
      "json: step 2 is 0: positions count from 1, or from -1 at the end")
  assert(text_of(config) == CONFIG, "a refused set changes nothing")
end

local function test_remove_answers_a_copy_without_the_place()
  local got27, why27 = Json.decode(CONFIG)
  assert(got27 ~= nil, tostring(why27))
  local config = known_value(got27)
  local got28, why28 = Json.remove(config, { "tags" })
  assert(got28 ~= nil, tostring(why28))
  assert(text_of(got28) == '{"server":{"hosts":["a","b"],"port":80}}')
  local got29, why29 = Json.remove(config, { "server", "hosts", 1 })
  assert(got29 ~= nil, tostring(why29))
  assert(text_of(got29) == '{"server":{"hosts":["b"],"port":80},"tags":[]}',
    "an array closes up")
  local got30, why30 = Json.remove(config, { "server", "hosts", -1 })
  assert(got30 ~= nil, tostring(why30))
  assert(text_of(got30) == '{"server":{"hosts":["a"],"port":80},"tags":[]}')
  assert(text_of(config) == CONFIG, "the value given is as it was")
  local miss23, refusal23 = Json.remove(config, {})
  assert(failure(miss23, refusal23) ==
      "json: remove takes a step or more: the whole value is in nothing it could be removed from")
  local miss24, refusal24 = Json.remove(config, { "name" })
  assert(failure(miss24, refusal24) == 'json: no value at pointer "/name"')
  local miss25, refusal25 = Json.remove(config, { "client", "port" })
  assert(failure(miss25, refusal25) == 'json: no value at pointer "/client"')
  local miss26, refusal26 = Json.remove(config, { "server", "hosts", 3 })
  assert(failure(miss26, refusal26) == 'json: no value at pointer "/server/hosts/2"')
  local miss27, refusal27 = Json.remove(config, { "tags", -1 })
  assert(failure(miss27, refusal27) == 'json: no element 1 from the end at pointer "/tags"')
  local miss28, refusal28 = Json.remove(config, { "server", "name", 1 })
  assert(failure(miss28, refusal28) == 'json: no value at pointer "/server/name"')
  local miss29, refusal29 = Json.remove(config, { "server", 1 })
  assert(failure(miss29, refusal29) == 'json: the value at pointer "/server" is an object, not an array')
end

--- An array with a hole keeps it through a copy, and one whose highest
--- position is far past its others is copied by what it holds: a walk of
--- every position to 1 << 40 would not end.
local function test_set_and_remove_keep_an_arrays_holes()
  local got31, why31 = Json.decode('{"row": [1, null, 3]}')
  assert(got31 ~= nil, tostring(why31))
  local dropped = known_value(got31)
  local got32, why32 = Json.set(dropped, { "row", 1 }, 0)
  assert(got32 ~= nil, tostring(why32))
  local set = known_value(got32)
  local got33, why33 = Json.get(set, { "row", 1 })
  assert(got33 ~= nil, tostring(why33))
  local got34, why34 = Json.get(set, { "row", -1 })
  assert(got34 ~= nil, tostring(why34))
  assert(got33 == 0 and got34 == 3)
  local miss30, refusal30 = Json.get(set, { "row", 2 })
  assert(failure(miss30, refusal30) == 'json: no value at pointer "/row/1"')
  local got35, why35 = Json.set(dropped, { "row", 2 }, 2)
  assert(got35 ~= nil, tostring(why35))
  assert(text_of(got35) == '{"row":[1,2,3]}', "a hole is filled")
  local got36, why36 = Json.set(dropped, { "row", 4 }, 4)
  assert(got36 ~= nil, tostring(why36))
  local appended = known_value(got36)
  local got37, why37 = Json.get(appended, { "row", -1 })
  assert(got37 ~= nil, tostring(why37))
  local got38, why38 = Json.get(appended, { "row", 3 })
  assert(got38 ~= nil, tostring(why38))
  assert(got37 == 4 and got38 == 3)
  local got39, why39 = Json.remove(dropped, { "row", 1 })
  assert(got39 ~= nil, tostring(why39))
  local fewer = known_value(got39)
  local got40, why40 = Json.get(fewer, { "row", -1 })
  assert(got40 ~= nil, tostring(why40))
  local got41, why41 = Json.get(fewer, { "row", 2 })
  assert(got41 ~= nil, tostring(why41))
  assert(got40 == 3 and got41 == 3)
  local miss31, refusal31 = Json.remove(dropped, { "row", 2 })
  assert(failure(miss31, refusal31) == 'json: no value at pointer "/row/1"')
  local far = assert(Json.with_holes({ [1] = "a", [1 << 40] = "z" }))
  local got42, why42 = Json.set(far, { 1 }, "b")
  assert(got42 ~= nil, tostring(why42))
  local near = known_value(got42)
  local got43, why43 = Json.get(near, { 1 })
  assert(got43 ~= nil, tostring(why43))
  local got44, why44 = Json.get(near, { -1 })
  assert(got44 ~= nil, tostring(why44))
  assert(got43 == "b" and got44 == "z")
  local got45, why45 = Json.remove(far, { 1 })
  assert(got45 ~= nil, tostring(why45))
  local closed = known_value(got45)
  local got46, why46 = Json.get(closed, { (1 << 40) - 1 })
  assert(got46 ~= nil, tostring(why46))
  assert(got46 == "z")
end

local function test_a_normalized_path_counts_from_0()
  assert(assert(Json.path({})) == "$")
  assert(assert(Json.path({ "users", 2, "name" })) == "$['users'][1]['name']")
  assert(assert(Json.path({ "it's", "a\\b", "\n\t\1\127" })) == "$['it\\'s']['a\\\\b']['\\n\\t\\u0001\127']")
  assert(assert(Json.path({ "users", -1 })) == "$['users'][-1]", "from the end, as a query reads it")
  local miss32, refusal32 = Json.path({ 0 })
  assert(failure(miss32, refusal32):match("step 1 is 0"))
end

local function test_a_singular_query_reads_as_steps()
  local cases: {Read} = {
    { text = "$", steps = {} },
    { text = "$.users[0].name", steps = { "users", 1, "name" } },
    { text = "$['users'][1][\"name\"]", steps = { "users", 2, "name" } },
    { text = "$.users[-1]", steps = { "users", -1 } },
    { text = "$['it\\'s']", steps = { "it's" } },
    { text = "$[\"a\\\"b\"]", steps = { 'a"b' } },
    { text = "$['\\u00e9\\ud83d\\ude00\\n\\/']", steps = { "\u{e9}\u{1f600}\n/" } },
    { text = "$.\u{e9}t\u{e9}", steps = { "\u{e9}t\u{e9}" } },
    { text = "$ .a [ 0 ] ['b']", steps = { "a", 1, "b" } },
    { text = "$[9007199254740991]", steps = { 9007199254740992 } },
  }
  for _, case in ipairs(cases) do
    local text, want = case.text, case.steps
    local steps, err = Json.from_path(text)
    assert(steps ~= nil and same_steps(steps, want), text .. ": " .. tostring(err) .. " " .. steps_text(steps or {}))
  end
  local normalized: {Json.Steps} = { {}, { "users", 1, "name" }, { "it's", "\0", -3 } }
  for _, steps in ipairs(normalized) do
    assert(same_steps(assert(Json.from_path((assert(Json.path(steps))))), steps), "a normalized path reads back")
  end
end

--- What the subset leaves out, or the RFC's grammar refuses, is refused,
--- naming the byte.
local function test_queries_are_read_strictly()
  local cases: {Said} = {
    { input = "users", err = "byte 1: a query starts with `$`" },
    { input = "$users", err = "byte 2: a segment starts with `.`, `..` or `[`" },
    { input = "$.a ", err = "byte 4: blank space after the last segment" },
    { input = "$. a", err = "byte 3: after `.` comes a name or `*`" },
    { input = "$.1a", err = "byte 3: after `.` comes a name or `*`" },
    { input = "$..", err = "byte 4: after `..` comes a name, `*` or `[`" },
    { input = "$[01]", err = "byte 3: an index is 0, or has no leading zero and is not -0" },
    { input = "$[-0]", err = "byte 3: an index is 0, or has no leading zero and is not -0" },
    { input = "$[-a]", err = "byte 3: an index is 0, or has no leading zero and is not -0" },
    { input = "$[9007199254740992]", err = "byte 3: an index past 2^53 - 1" },
    { input = "$[1:2]", err = "byte 4: slices (`start:end:step`) are not in the subset cosmic reads" },
    { input = "$[:2]", err = "byte 3: slices (`start:end:step`) are not in the subset cosmic reads" },
    { input = "$[?@.a]", err = "byte 3: filters (`?`) are not in the subset cosmic reads" },
    { input = "$[0, 1]", err = "byte 4: unions (`[a, b]`) are not in the subset cosmic reads" },
    { input = "$['a'", err = "byte 6: expected `]`" },
    { input = "$['a]", err = "byte 3: a string the query ends inside" },
    { input = "$['\\q']", err = "byte 4: `\\q` is no escape a JSONPath string has" },
    { input = "$['\\ud83d']", err = "byte 4: a high surrogate with no low one after it" },
    { input = "$['\\ude00']", err = "byte 4: a low surrogate with no high one before it" },
    { input = "$['a\nb']", err = "byte 5: a control character in a string, which must be escaped" },
    { input = "$[a]", err = "byte 3: a selector is a name in quotes, an index or `*`" },
    { input = "$['\xff']", err = "byte 4: a byte that is not UTF-8" },
  }
  for _, case in ipairs(cases) do
    local q, err = Json.query(case.input)
    assert(q == nil and tostring(err) == "json: JSONPath " .. case.err, ("%q: %s"):format(case.input, err))
  end
  local _, many = Json.from_path("$..a")
  assert(tostring(many) == 'json: JSONPath "$..a" selects many values (segment 1): read it with Json.query', many)
  local _, star = Json.from_path("$.a[*]")
  assert(tostring(star):match("selects many values %(segment 2%)"), star)
end

--- RFC 9535's own examples (section 1.5), on its bookstore.
local function test_select_answers_the_rfc_examples()
  local store = assert(Json.decode_object([[{ "store": {
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
    local out: mut {string} = {}
    for i, m in ipairs(found) do out[i] = assert(Json.encode_any(m.value)) end
    return table.concat(out, " ")
  end
  local function pointers(found: {Json.Match}): string
    local out: mut {string} = {}
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
  assert(#found == 1 and assert(Json.path(found[1].steps)) == "$['store']['book'][0]")
  -- `#found == 1` was just asserted.
  assert(Array.at(found, 1).steps[3] == 1, "a match's steps count from 1")
end

local function test_select_refuses_what_is_not_json()
  local loop: {string: any} = {}
  loop.self = loop -- checked: map_field
  local _, cycle = Json.select(loop, (assert(Json.query("$..x"))), { max_depth = 5 })
  assert(tostring(cycle) == 'json: a value nests deeper than 5 levels at pointer "/self/self/self/self/self" ' ..
      "(does it contain itself?)", cycle)
  local _, mixed = Json.select({ a = { 1, b = 2 } }, (assert(Json.query("$.a[0]")))) -- checked: literal_shape
  assert(tostring(mixed) == 'json: the value at pointer "/a" is a table with mixed keys', mixed)
  local everything = assert(Json.query("$"))
  Test.raises(function() local _, _ = Json.select({}, everything, { max_depth = 0 }) end) -- checked: literal_needs_type
end

--- A table with a hole counts from its highest position, as its
--- elements do; a step of 0, or that is no step, is named.
local function test_steps_count_from_a_holes_highest_position()
  local holed: {any: any} = { [1] = "a", [3] = "c" } -- declared: key_type
  local got47, why47 = Json.get(holed, { -1 })
  assert(got47 ~= nil, tostring(why47))
  local got48, why48 = Json.get(holed, { -3 })
  assert(got48 ~= nil, tostring(why48))
  assert(got47 == "c" and got48 == "a")
  local last = assert(Json.select(holed, (assert(Json.query("$[-1]")))))
  assert(#last == 1 and last[1].value == "c" and last[1].steps[1] == 3)
  local miss33, refusal33 = Json.get(holed, { 0 })
  assert(failure(miss33, refusal33) == "json: step 1 is 0: positions count from 1, or from -1 at the end")
  local miss34, refusal34 = Json.path({ "\xff" })
  assert(failure(miss34, refusal34) == "json: step 1 is a name that is not UTF-8")
  local miss35, refusal35 = Json.pointer({ "a", "\xff" })
  assert(failure(miss35, refusal35) == "json: step 2 is a name that is not UTF-8")
end

--- A place too long for a message keeps its innermost segments, and a
--- key too long even alone keeps its start, in the core's messages and
--- in this module's alike; DEL is escaped in both.
local function test_a_long_place_is_named_by_its_innermost_part()
  local long = string.rep("k", 250)
  local _, encoded = Json.encode_any({ a = { [long] = print } })
  assert(tostring(encoded) == 'json: cannot encode a function at pointer ending "/' .. string.rep("k", 40) .. '..."', encoded)
  local slashes = string.rep("/", 150)
  local _, decoded = Json.decode(('{"a": {"%s": 1, "%s": 2}}'):format(slashes, slashes))
  assert(tostring(decoded):match('%(pointer ending "/' .. string.rep("~1", 20) .. '%.%.%."%)$'), decoded)
  local _, got = Json.get({ [long] = 1 }, { long, "x" })
  assert(tostring(got) == 'json: the value at pointer ending "/' .. string.rep("k", 40) .. '..." is number, not an array or object',
    got)
  local loop: {string: any} = {}
  loop.self = loop -- checked: map_field
  local _, cycle = Json.select(loop, (assert(Json.query("$..x"))), { max_depth = 100 })
  assert(tostring(cycle):match('^json: a value nests deeper than 100 levels at pointer ending "/self/') ~= nil and #tostring(cycle) < 300, cycle)
  local _, del = Json.encode_any({ ["a\127"] = print })
  assert(tostring(del) == 'json: cannot encode a function at pointer "/a\\u007f"', del)
  local _, del_get = Json.get({ ["a\127"] = 1 }, { "a\127", 1 })
  assert(tostring(del_get) == 'json: the value at pointer "/a\\u007f" is number, not an array or object', del_get)
end

--- A pointer text of 200 bytes or more with no `/` has no segment to
--- keep; naming it raises if the message assumes one.
local function test_a_long_text_with_no_slash_is_refused_by_name()
  local steps, why = Json.from_pointer(Json.null, string.rep("k", 250))
  assert(steps == nil)
  assert(tostring(why) == 'json: pointer ending "' .. string.rep("k", 41) .. '...": a JSON Pointer is empty or starts with `/`', why)
end
