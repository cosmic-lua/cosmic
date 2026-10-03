--- `cosmic json` (build/json.tl), run in this process with its input and
--- output stood in for. build/json_tool_test.tl starts the program for
--- what a process alone shows: real standard input, and no verdict line.

local Fs = require("cosmic.fs")
local json = require("build.json")

local DOC <const> = [[
{"name": "cosmic", "n": 3, "tags": ["lua", "teal"], "nothing": null,
 "a key": {"x y": true}, "users": [{"name": "ann", "id": 1}, {"name": "bo", "id": 2}], "empty": {}, "none": []}
]]

local record Ran
  code: integer
  out: string
  err: string
end

local function argv_of(words: {string}): {integer:string}
  local argv: {integer:string} = { [0] = "cosmic", [1] = "json" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  return argv
end

--- One run: `words` after `cosmic json`, and `stdin` standing in for
--- standard input.
local function run(words: {string}, stdin?: string): Ran
  local argv = argv_of(words)
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = json.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): string | nil, string
      if stdin == nil then return nil, "no standard input in this test" end
      return stdin, ""
    end,
  })
  return ran
end

local function file(tmp: string, text?: string): string
  local path = tmp .. "/doc.json"
  assert(Fs.write(path, text or DOC))
  return path
end

local function test_a_found_value_prints_as_indented_json(tmp: string)
  local ran = run({ "$.users[0]", file(tmp) })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out == '{\n  "id": 1,\n  "name": "ann"\n}\n', ran.out)
  local scalar = run({ "$.n", file(tmp) })
  assert(scalar.code == 0 and scalar.out == "3\n", scalar.out)
end

--- Indices count from 0, as JSONPath counts, and from -1 at the end.
local function test_an_index_counts_from_0_or_from_the_end(tmp: string)
  assert(run({ "-r", "$.users[0].name", file(tmp) }).out == "ann\n")
  assert(run({ "-r", "$.users[1].name", file(tmp) }).out == "bo\n")
  assert(run({ "-r", "$.users[-1].name", file(tmp) }).out == "bo\n")
  assert(run({ "-r", "$.tags[-2]", file(tmp) }).out == "lua\n")
  local past = run({ "$.users[2]", file(tmp) })
  assert(past.code == 1 and past.err == 'cosmic: json: no value at pointer "/users/2"\n', past.err)
  local before = run({ "$.users[-3]", file(tmp) })
  assert(before.code == 1 and before.err:find('no element 3 from the end at pointer "/users"', 1, true), before.err)
  -- `--flat` under a place counted from the end spells it from 0.
  local flat = run({ "--flat", "$.users[-1]", file(tmp) })
  assert(flat.out == "$.users[1].id = 2\n$.users[1].name = \"bo\"\n", flat.out)
end

local function test_compact_prints_one_line(tmp: string)
  local ran = run({ "--compact", "$.users", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == '[{"id":1,"name":"ann"},{"id":2,"name":"bo"}]\n', ran.out)
end

local function test_no_path_is_the_root(tmp: string)
  local whole = run({ "--compact", file(tmp, '{"a": [1]}') })
  assert(whole.code == 0 and whole.out == '{"a":[1]}\n', whole.out)
  local rooted = run({ "--compact", "$", file(tmp, '{"a": [1]}') })
  assert(rooted.out == '{"a":[1]}\n', rooted.out)
end

local function test_a_key_with_spaces_and_a_null_are_found(tmp: string)
  local spaced = run({ "$['a key']['x y']", file(tmp) })
  assert(spaced.code == 0 and spaced.out == "true\n", spaced.out)
  local double = run({ '$["a key"]["x y"]', file(tmp) })
  assert(double.code == 0 and double.out == "true\n", double.out)
  local null = run({ "$.nothing", file(tmp) })
  assert(null.code == 0 and null.out == "null\n", null.out)
  assert(run({ "--exists", "$.nothing", file(tmp) }).code == 0)
end

local function test_raw_prints_a_string_without_quotes(tmp: string)
  local raw = run({ "-r", "$.name", file(tmp) })
  assert(raw.code == 0 and raw.out == "cosmic\n", raw.out)
  local long = run({ "--raw", "$.users[1].name", file(tmp) })
  assert(long.out == "bo\n", long.out)
  local quoted = run({ "$.name", file(tmp) })
  assert(quoted.out == '"cosmic"\n', quoted.out)
  -- Only a string is raw: a number and an object print as JSON.
  assert(run({ "-r", "$.n", file(tmp) }).out == "3\n")
  assert(run({ "-r", "--", "$.empty", file(tmp) }).out == "{}\n")
end

local function test_a_missing_path_exits_1_naming_its_pointer(tmp: string)
  local ran = run({ "$.nope", file(tmp) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err == 'cosmic: json: no value at pointer "/nope"\n', ran.err)
  local through = run({ "$.n.x", file(tmp) })
  assert(through.code == 1 and
      through.err == 'cosmic: json: the value at pointer "/n" is number, not an array or object\n', through.err)
  local kind = run({ "$.users.x", file(tmp) })
  assert(kind.code == 1 and kind.err:find('the value at pointer "/users" is an array, not an object', 1, true),
    kind.err)
end

local function test_exists_prints_nothing_and_answers_by_status(tmp: string)
  local found = run({ "--exists", "$.users[1].id", file(tmp) })
  assert(found.code == 0 and found.out == "" and found.err == "")
  local missing = run({ "--exists", "$.users[1].zip", file(tmp) })
  assert(missing.code == 1 and missing.out == "" and missing.err == "", missing.err)
end

local function test_keys_lists_an_objects_keys_sorted(tmp: string)
  local ran = run({ "--keys", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "a key\nempty\nn\nname\nnone\nnothing\ntags\nusers\n", ran.out)
  assert(run({ "--keys", "$.empty", file(tmp) }).out == "")
  assert(run({ "--keys", "$.empty", file(tmp) }).code == 0)
end

local function test_keys_of_an_array_is_its_length(tmp: string)
  local ran = run({ "--keys", "$.users", file(tmp) })
  assert(ran.code == 0 and ran.out == "2\n", ran.out)
  assert(run({ "--keys", "$.none", file(tmp) }).out == "0\n")
end

local function test_keys_of_a_scalar_is_a_failure_naming_what_it_is(tmp: string)
  local ran = run({ "--keys", "$.name", file(tmp) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err == 'cosmic: json: pointer "/name": --keys needs an object or an array, got string\n', ran.err)
end

local function test_shape_prints_describe(tmp: string)
  local ran = run({ "--shape", "$.users", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "[2 x {id: number, name: string}]\n", ran.out)
  local whole = run({ "--shape", file(tmp, '{"ids": [1, 2], "ok": true}') })
  assert(whole.out == "{ids: [2 x number], ok: boolean}\n", whole.out)
end

local function test_a_dash_or_no_file_reads_standard_input()
  local piped = run({ "--compact", "$.a", "-" }, '{"a": [1, 2]}')
  assert(piped.code == 0 and piped.out == "[1,2]\n", piped.err)
  local none = run({ "--compact", "$.a" }, '{"a": 7}')
  assert(none.code == 0 and none.out == "7\n", none.err)
  local root = run({ "--compact" }, '[true]')
  assert(root.out == "[true]\n", root.out)
  local both = run({ "--keys", "$", "-" }, '{"b": 1, "a": 2}')
  assert(both.out == "a\nb\n", both.out)
  assert(run({ "-" }, "3").out == "3\n")
end

--- A JSONPath query begins with `$`, so a lone word that does not is the
--- file, whatever else it begins with.
local function test_a_lone_word_is_the_path_only_when_it_begins_with_a_dollar(tmp: string)
  local path = file(tmp, '{"a": 1}')
  assert(run({ path }).out == '{\n  "a": 1\n}\n')
  assert(run({ "--exists", "./doc.json" }, "{}").code == 2, "./doc.json is a file, not read from stdin")
  assert(run({ "$.a" }, '{"a": 1}').out == "1\n")
  assert(run({ "$[0]" }, '[5, 6]').out == "5\n")
  local dotted = tmp .. "/.data.json"
  assert(Fs.write(dotted, '{"b": 2}'))
  assert(run({ "--compact", dotted }).out == '{"b":2}\n')
  local bracket = run({ "[0]" }, "[5]")
  assert(bracket.code == 2 and bracket.err:find("[0]", 1, true), bracket.err)
end

--- A path is a JSONPath query: `$` comes first, with no other start.
local function test_a_path_without_a_dollar_is_refused(tmp: string)
  for _, path in ipairs({ ".n", "n", "users[0]", "[0]", "..id" }) do
    local ran = run({ path, file(tmp) })
    assert(ran.code == 2 and ran.out == "", path .. ": " .. ran.out)
    assert(ran.err:find("cosmic: json: JSONPath byte 1: a query starts with `$`; cosmic json ", 1, true), ran.err)
  end
end

--- Filters, slices and unions are refused with cosmic.json's message,
--- naming what was meant, not read as anything else.
local function test_a_filter_slice_or_union_is_refused_by_name(tmp: string)
  for _, case in ipairs({
      { "$.users[?@.id == 1]", "JSONPath byte 9: filters (`?`) are not in the subset cosmic reads" },
      { "$.users[0:1]", "JSONPath byte 10: slices (`start:end:step`) are not in the subset cosmic reads" },
      { "$.users[:1]", "JSONPath byte 9: slices (`start:end:step`) are not in the subset cosmic reads" },
      { "$.users[0, 1]", "JSONPath byte 10: unions (`[a, b]`) are not in the subset cosmic reads" },
  }) do
    local ran = run({ case[1], file(tmp) })
    assert(ran.code == 2 and ran.out == "", case[1] .. ": " .. ran.out)
    assert(ran.err:find("cosmic: json: " .. case[2], 1, true), ran.err)
  end
end

local function test_invalid_json_exits_2_naming_the_file(tmp: string)
  local path = file(tmp, '{"a": ')
  local ran = run({ "$.a", path })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cosmic: json: " .. path .. ": ", 1, true), ran.err)
  local piped = run({ "$.a" }, "not json")
  assert(piped.code == 2 and piped.err:find("standard input: ", 1, true), piped.err)
  assert(run({ "$.a" }, "").code == 2)
end

local function test_an_unreadable_file_exits_2(tmp: string)
  local ran = run({ "$.a", tmp .. "/absent.json" })
  assert(ran.code == 2 and ran.err:find("absent.json", 1, true), ran.err)
  local dir = run({ "$.a", tmp })
  assert(dir.code == 2, dir.err)
end

local function test_a_bad_path_exits_2(tmp: string)
  local ran = run({ "$[", file(tmp) })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("JSONPath byte 3: the query ends inside `[`", 1, true), ran.err)
  local unclosed = run({ "$.users[*", file(tmp) })
  assert(unclosed.code == 2 and unclosed.err:find("expected `]`", 1, true), unclosed.err)
  local descent = run({ "$..", file(tmp) })
  assert(descent.code == 2 and descent.err:find("after `..` comes a name, `*` or `[`", 1, true), descent.err)
  local star = run({ "$['*']", file(tmp, '{"*": 4}') })
  assert(star.code == 0 and star.out == "4\n", star.err)
end

local function test_a_command_line_it_cannot_read_exits_2(tmp: string)
  local path = file(tmp)
  for _, words in ipairs({
      { "--no-such-flag", path },
      { "--exists", "--keys", path },
      { "--keys", "--shape", path },
      { "--exists", "-r", path },
      { "--keys", "--compact", path },
      { "$.a", path, "extra" },
      { "--flat", "--exists", path },
      { "--flat", "-r", path },
      { "--flat", "--compact", path },
      { "--keys", "$.users[*]", path },
      { "--shape", "$..id", path },
  }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("cosmic json ", 1, true), ran.err)
  end
  assert(run({ "--no-such-flag", path }).err:find("--no-such-flag", 1, true))
end

local function test_raw_prints_a_string_with_a_newline_as_it_is(tmp: string)
  local ran = run({ "-r", "$.a", file(tmp, '{"a": "one\\ntwo"}') })
  assert(ran.code == 0 and ran.out == "one\ntwo\n", ran.out)
end

local function test_invalid_utf8_on_standard_input_exits_2()
  local ran = run({ "$.a" }, '{"a": "\xff"}')
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("standard input: ", 1, true), ran.err)
end

local function test_an_empty_word_is_named(tmp: string)
  local file_name = run({ "" }, "{}")
  assert(file_name.code == 2 and file_name.err:find("an empty file name", 1, true), file_name.err)
  local both = run({ "$.a", "" }, "{}")
  assert(both.code == 2 and both.err:find("an empty file name", 1, true), both.err)
  local path = run({ "", file(tmp) })
  assert(path.code == 2 and path.err:find("a query starts with `$`", 1, true), path.err)
end

local function test_after_dashdash_the_words_are_path_and_file(tmp: string)
  local dollar = tmp .. "/$.json"
  assert(Fs.write(dollar, '{"a": 1}'))
  -- One word after `--` is the file, though it reads as a path.
  local lone = run({ "--compact", "--", dollar })
  assert(lone.code == 0 and lone.out == '{"a":1}\n', lone.err)
  local named = run({ "--", "$.a", dollar })
  assert(named.code == 0 and named.out == "1\n", named.err)
  local stdin = run({ "--", "-" }, "5")
  assert(stdin.code == 0 and stdin.out == "5\n", stdin.err)
  assert(run({ "--" }, "6").out == "6\n")
  assert(run({ "--", "a", "b", "c" }).code == 2)
end

--- A `--` makes a lone word the file only when the word comes after it.
local function test_a_path_before_dashdash_is_still_the_path(tmp: string)
  local before = run({ "$.n", "--" }, '{"n": 3}')
  assert(before.code == 0 and before.out == "3\n", before.err)
  local after = run({ "--compact", "--", "$.n" })
  assert(after.code == 2 and after.err:find("$.n", 1, true), after.err)
  local both = run({ "$.n", "--", file(tmp) })
  assert(both.code == 0 and both.out == "3\n", both.err)
end

--- A lone word in another path language is a file; when there is no
--- such file, the complaint says what a path starts with.
local function test_a_missing_file_that_reads_like_a_path_hints_at_the_dollar(tmp: string)
  for _, word in ipairs({ ".users", "[0]", ".users[0].name" }) do
    local ran = run({ word }, "{}")
    assert(ran.code == 2 and ran.err:find("; a path starts with `$`", 1, true), ran.err)
  end
  local plain = run({ tmp .. "/absent.json" })
  assert(plain.code == 2 and not plain.err:find("a path starts", 1, true), plain.err)
  local dashed = run({ "--", ".users" })
  assert(dashed.code == 2 and not dashed.err:find("a path starts", 1, true), dashed.err)
end

local function test_usage_names_the_escapes_for_a_file_that_reads_as_a_path()
  local ran = run({ "--bogus" })
  assert(ran.err:find("./name", 1, true) and ran.err:find("--", 1, true), ran.err)
end

local function test_a_failed_write_exits_2_and_says_so(tmp: string)
  local complaints = ""
  local code = json.run(argv_of({ file(tmp) }), {
    out = function(_: string): boolean, string return false, "No space left on device" end,
    err = function(line: string) complaints = complaints .. line .. "\n" end,
    stdin = function(): string | nil, string return nil, "unused" end,
  })
  assert(code == 2, code)
  assert(complaints == "cosmic: json: standard output: No space left on device\n", complaints)
  for _, mode in ipairs({ "--keys", "--shape" }) do
    local again = json.run(argv_of({ mode, file(tmp) }), {
      out = function(_: string): boolean, string return false, "closed" end,
      err = function(_: string) end,
      stdin = function(): string | nil, string return nil, "unused" end,
    })
    assert(again == 2, mode)
  end
end

local FLAT_DOC <const> = {
  '$["a key"]["x y"] = true',
  "$.empty = {}",
  "$.n = 3",
  "$.name = \"cosmic\"",
  "$.none = []",
  "$.nothing = null",
  "$.tags[0] = \"lua\"",
  "$.tags[1] = \"teal\"",
  "$.users[0].id = 1",
  "$.users[0].name = \"ann\"",
  "$.users[1].id = 2",
  "$.users[1].name = \"bo\"",
}

local function test_flat_prints_every_leaf_as_a_path_and_a_value(tmp: string)
  local ran = run({ "--flat", file(tmp) })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out == table.concat(FLAT_DOC, "\n") .. "\n", ran.out)
end

local function test_flat_under_a_path_keeps_the_full_paths(tmp: string)
  local ran = run({ "--flat", "$.users[1]", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "$.users[1].id = 2\n$.users[1].name = \"bo\"\n", ran.out)
  local leaf = run({ "--flat", "$.n", file(tmp) })
  assert(leaf.out == "$.n = 3\n", leaf.out)
  local empty = run({ "--flat", "$.empty", file(tmp) })
  assert(empty.out == "$.empty = {}\n", empty.out)
  local whole = run({ "--flat", "-" }, "[1, [2]]")
  assert(whole.out == "$[0] = 1\n$[1][0] = 2\n", whole.out)
  local scalar = run({ "--flat" }, '"x"')
  assert(scalar.out == '$ = "x"\n', scalar.out)
  local missing = run({ "--flat", "$.nope", file(tmp) })
  assert(missing.code == 1 and missing.out == "" and missing.err:find('pointer "/nope"', 1, true), missing.err)
end

local function test_flat_over_a_query_flattens_each_match(tmp: string)
  local ran = run({ "--flat", "$.users[*]", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == table.concat({ FLAT_DOC[9], FLAT_DOC[10], FLAT_DOC[11], FLAT_DOC[12] }, "\n") .. "\n", ran.out)
  local none = run({ "--flat", "$..zip", file(tmp) })
  assert(none.code == 1 and none.out == "", none.out)
end

local function test_a_wildcard_prints_each_match_as_a_path_and_a_value(tmp: string)
  local ran = run({ "$.users[*].name", file(tmp) })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out == "$.users[0].name = \"ann\"\n$.users[1].name = \"bo\"\n", ran.out)
  local star = run({ "$.tags.*", file(tmp) })
  assert(star.out == "$.tags[0] = \"lua\"\n$.tags[1] = \"teal\"\n", star.out)
  -- A container matched prints as compact JSON on its line.
  local containers = run({ "$.users[*]", file(tmp) })
  assert(containers.out == "$.users[0] = {\"id\":1,\"name\":\"ann\"}\n" ..
      "$.users[1] = {\"id\":2,\"name\":\"bo\"}\n", containers.out)
  local null = run({ "$.*", file(tmp, '{"a": null, "b": [], "c": {}}') })
  assert(null.out == "$.a = null\n$.b = []\n$.c = {}\n", null.out)
end

local function test_descent_finds_a_key_at_any_depth_including_the_top(tmp: string)
  local ran = run({ "$..id", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "$.users[0].id = 1\n$.users[1].id = 2\n", ran.out)
  local top = run({ "$..a", file(tmp, '{"a": 1, "b": {"a": 2}}') })
  assert(top.out == "$.a = 1\n$.b.a = 2\n", top.out)
  local index = run({ "$..[0]", file(tmp, '{"a": [[7, 8], 9]}') })
  assert(index.out == "$.a[0] = [7,8]\n$.a[0][0] = 7\n", index.out)
  local quoted = run({ "$..['x y']", file(tmp) })
  assert(quoted.out == '$["a key"]["x y"] = true\n', quoted.out)
end

--- A value a query reaches by more than one way prints once.
local function test_a_value_reached_twice_prints_once(tmp: string)
  local doc = file(tmp, '{"a": {"a": {"a": 1}}}')
  local ran = run({ "$..*..a", doc })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "$.a.a = {\"a\":1}\n$.a.a.a = 1\n", ran.out)
  local raw = run({ "-r", "$..*..a", doc })
  assert(raw.out == "{\"a\":1}\n1\n", raw.out)
end

local function test_a_query_with_no_match_exits_1_naming_it(tmp: string)
  local ran = run({ "$.users[*].zip", file(tmp) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err == "cosmic: json: $.users[*].zip: no match\n", ran.err)
  assert(run({ "$.n.*", file(tmp) }).code == 1)
end

local function test_exists_of_a_query_is_at_least_one_match(tmp: string)
  local found = run({ "--exists", "$..name", file(tmp) })
  assert(found.code == 0 and found.out == "" and found.err == "", found.err)
  local missing = run({ "--exists", "$..zip", file(tmp) })
  assert(missing.code == 1 and missing.out == "" and missing.err == "", missing.err)
  assert(run({ "--exists", "$.users[*].id", file(tmp) }).code == 0)
  assert(run({ "--exists", "$.tags[*]", file(tmp, '{"tags": []}') }).code == 1)
end

local function test_keys_and_shape_refuse_a_query_of_many_with_a_usage_error(tmp: string)
  for _, mode in ipairs({ "--keys", "--shape" }) do
    for _, query in ipairs({ "$.users[*]", "$..id", "$.*" }) do
      local ran = run({ mode, query, file(tmp) })
      assert(ran.code == 2 and ran.out == "", mode .. " " .. query .. ": " .. ran.out)
      assert(ran.err:find(mode .. " reads one value", 1, true) and ran.err:find("cosmic json ", 1, true), ran.err)
    end
  end
  -- A singular query still works with them, and so does a key named `*`.
  assert(run({ "--keys", "$['*']", file(tmp, '{"*": {"a": 1}}') }).out == "a\n")
  assert(run({ "--keys", "$.users[-1]", file(tmp) }).out == "id\nname\n")
end

local function test_raw_of_a_query_prints_the_values_one_per_line(tmp: string)
  local ran = run({ "-r", "$.users[*].name", file(tmp) })
  assert(ran.code == 0 and ran.out == "ann\nbo\n", ran.out)
  local mixed = run({ "-r", "$..id", file(tmp) })
  assert(mixed.out == "1\n2\n", mixed.out)
  local kinds = run({ "--raw", "$.*", file(tmp, '{"a": "s", "b": 2.5, "c": [1], "d": null, "e": true}') })
  assert(kinds.out == "s\n2.5\n[1]\nnull\ntrue\n", kinds.out)
  local none = run({ "-r", "$..zip", file(tmp) })
  assert(none.code == 1 and none.out == "")
end

local function test_a_name_that_is_no_shorthand_is_quoted(tmp: string)
  assert(run({ "$['*']", file(tmp, '{"*": 4}') }).out == "4\n")
  assert(run({ "$['a*']", file(tmp, '{"a*": 5}') }).out == "5\n")
  local star = run({ "$.a*", file(tmp, '{"a*": 5}') })
  assert(star.code == 2 and star.err:find("JSONPath byte 4", 1, true), star.err)
  local ran = run({ "$.users[0].name", file(tmp) })
  assert(ran.out == '"ann"\n', ran.out)
end

--- A doc each of whose `--flat` paths must read back to its leaf: names
--- that need quoting or escaping, a `=` in a name and in a string, the
--- empty name, an empty container, a null, and numbers at the edges.
local ROUND_DOC <const> = [=[
{"a b": [1, {"c\"d": [true, null, {}, []], "e": "x = y"}],
 "": {"": 0, "q.r": -1.5}, "$": 1e2, "k = v": "s = t", "é": "é\n", "[0]": [[]], "*": {"*": 3},
 "..": 4, "list": [10, 20, 30], "it's": "a\\b"}
]=]

--- The path of a `--flat` line, and its value: the path ends at the
--- first ` = ` outside a quoted name.
local function split_flat(line: string): string, string
  local in_quote = false
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if in_quote then
      if c == "\\" then i = i + 1 elseif c == '"' then in_quote = false end
    elseif c == '"' then
      in_quote = true
    elseif line:sub(i, i + 2) == " = " then
      return line:sub(1, i - 1), line:sub(i + 3)
    end
    i = i + 1
  end
  error("no ` = ` in " .. line)
end

local function test_every_path_flat_prints_reads_back_to_its_leaf(tmp: string)
  local doc = file(tmp, ROUND_DOC)
  local flat = run({ "--flat", doc })
  assert(flat.code == 0, flat.err)
  local lines: {string} = {}
  for line in flat.out:gmatch("[^\n]+") do lines[#lines + 1] = line end
  -- The 18 leaves of the document, none twice.
  assert(#lines == 18, #lines .. "\n" .. flat.out)
  local seen: {string:boolean} = {}
  for _, line in ipairs(lines) do
    local path, value = split_flat(line)
    assert(not seen[path], "twice: " .. path)
    seen[path] = true
    local back = run({ "--compact", path, doc })
    assert(back.code == 0, path .. ": " .. back.err)
    assert(back.out == value .. "\n", path .. " gave " .. back.out .. " for " .. line)
    -- And a line `--flat` prints under that path is the same line.
    local again = run({ "--flat", path, doc })
    assert(again.out:find(line, 1, true) == 1, path .. ": " .. again.out)
  end
  assert(seen['$["it\'s"]'] and seen['$["a b"][1]["c\\"d"][0]'] and seen["$.list[2]"], flat.out)
end

--- A path `--flat` prints pastes into a shell's single quotes: one of
--- words and indices holds no `'`, and starts `$[` only for a position
--- or a name that is no word, so a double-quoted paste of it meets no
--- `$[` arithmetic either.
local function test_a_printed_path_of_words_and_indices_holds_no_quote_or_dollar_bracket(tmp: string)
  local flat = run({ "--flat", file(tmp) })
  local plain = 0
  for line in flat.out:gmatch("[^\n]+") do
    if not line:find('["', 1, true) then
      plain = plain + 1
      assert(not line:find("'", 1, true) and not line:find("$[", 1, true), line)
    end
  end
  assert(plain == 11, flat.out)
  local found = run({ "$.users[*].name", file(tmp) })
  assert(not found.out:find("'", 1, true) and not found.out:find("$[", 1, true), found.out)
end

local function test_flat_over_nested_matches_prints_each_leaf_once(tmp: string)
  local nested = '{"a": {"a": {"x": 1}, "y": 2}, "b": {"a": 3, "c": [{"a": [4, {"a": 5}]}]}}'
  local ran = run({ "--flat", "$..a", file(tmp, nested) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == table.concat({
    "$.a.a.x = 1", "$.a.y = 2", "$.b.a = 3", "$.b.c[0].a[0] = 4",
    "$.b.c[0].a[1].a = 5",
  }, "\n") .. "\n", ran.out)
  -- The same leaves plain --flat prints under the same subtrees, once each.
  local whole = run({ "--flat", file(tmp, nested) }).out
  for _, line in ipairs({ "$.a.a.x = 1", "$.b.c[0].a[1].a = 5" }) do
    assert(whole:find(line, 1, true))
  end
  local everything = run({ "--flat", "$..*", file(tmp, nested) })
  assert(everything.code == 0 and everything.out == whole, everything.out)
  local plain = run({ "--flat", "$..*", file(tmp) })
  assert(plain.out == run({ "--flat", file(tmp) }).out, plain.out)
  local star = run({ "--flat", "$.*", file(tmp) })
  assert(star.out == run({ "--flat", file(tmp) }).out, star.out)
  -- A sibling key that only begins like a match is not under it.
  local siblings = run({ "--flat", "$..a", file(tmp, '{"a": {"x": 1}, "ab": {"a": 2}}') })
  assert(siblings.out == "$.a.x = 1\n$.ab.a = 2\n", siblings.out)
  local array = run({ "--flat", "$..[0]", file(tmp, '[[1, [2]], 3]') })
  assert(array.out == "$[0][0] = 1\n$[0][1][0] = 2\n", array.out)
  -- A name with a `/`, which a pointer writes `~1`, is not two levels.
  local slash = run({ "--flat", "$..b", file(tmp, '{"a/b": {"b": 1}, "a": {"b": {"b": 2}}}') })
  assert(slash.out == '$.a.b.b = 2\n$["a/b"].b = 1\n', slash.out)
end

local function test_flat_of_many_nested_matches_prints_only_the_distinct_leaves(tmp: string)
  local parts: {string} = {}
  for i = 1, 200 do parts[i] = '{"a": {"a": {"a": ' .. i .. '}}}' end
  local ran = run({ "--flat", "$..a", file(tmp, "[" .. table.concat(parts, ",") .. "]") })
  local lines = 0
  for _ in ran.out:gmatch("\n") do lines = lines + 1 end
  assert(ran.code == 0 and lines == 200, lines)
end
