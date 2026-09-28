--- `cosmic json` (build/json.tl), run in this process with its input and
--- output stood in for: found, missing, `--exists`, `--keys`, `--shape`,
--- `-r`, standard input, a text that is not JSON, and a path that is not
--- one. build/json_tool_test.tl starts the program for what a process
--- alone shows: real standard input, and no verdict line.

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
  local ran = run({ "$.users[1]", file(tmp) })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out == '{\n  "id": 1,\n  "name": "ann"\n}\n', ran.out)
  local scalar = run({ ".n", file(tmp) })
  assert(scalar.code == 0 and scalar.out == "3\n", scalar.out)
end

local function test_compact_prints_one_line(tmp: string)
  local ran = run({ "--compact", "users", file(tmp) })
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
  local spaced = run({ '["a key"]["x y"]', file(tmp) })
  assert(spaced.code == 0 and spaced.out == "true\n", spaced.out)
  local null = run({ ".nothing", file(tmp) })
  assert(null.code == 0 and null.out == "null\n", null.out)
  assert(run({ "--exists", ".nothing", file(tmp) }).code == 0)
end

local function test_raw_prints_a_string_without_quotes(tmp: string)
  local raw = run({ "-r", ".name", file(tmp) })
  assert(raw.code == 0 and raw.out == "cosmic\n", raw.out)
  local long = run({ "--raw", ".users[2].name", file(tmp) })
  assert(long.out == "bo\n", long.out)
  local quoted = run({ ".name", file(tmp) })
  assert(quoted.out == '"cosmic"\n', quoted.out)
  -- Only a string is raw: a number and an object print as JSON.
  assert(run({ "-r", ".n", file(tmp) }).out == "3\n")
  assert(run({ "-r", "--", ".empty", file(tmp) }).out == "{}\n")
end

local function test_a_missing_path_exits_1_with_the_message_of_get(tmp: string)
  local ran = run({ ".nope", file(tmp) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err == "cosmic: json: $: no key \"nope\"\n", ran.err)
  local index = run({ ".users[3]", file(tmp) })
  assert(index.code == 1, index.err)
  assert(index.err:find("$.users: index 3 out of range, the array has 2", 1, true), index.err)
  local through = run({ ".n.x", file(tmp) })
  assert(through.code == 1 and through.err:find("$.n: expected an object", 1, true), through.err)
end

local function test_exists_prints_nothing_and_answers_by_status(tmp: string)
  local found = run({ "--exists", ".users[2].id", file(tmp) })
  assert(found.code == 0 and found.out == "" and found.err == "")
  local missing = run({ "--exists", ".users[2].zip", file(tmp) })
  assert(missing.code == 1 and missing.out == "" and missing.err == "", missing.err)
end

local function test_keys_lists_an_objects_keys_sorted(tmp: string)
  local ran = run({ "--keys", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "a key\nempty\nn\nname\nnone\nnothing\ntags\nusers\n", ran.out)
  assert(run({ "--keys", ".empty", file(tmp) }).out == "")
  assert(run({ "--keys", ".empty", file(tmp) }).code == 0)
end

local function test_keys_of_an_array_is_its_length(tmp: string)
  local ran = run({ "--keys", ".users", file(tmp) })
  assert(ran.code == 0 and ran.out == "2\n", ran.out)
  assert(run({ "--keys", ".none", file(tmp) }).out == "0\n")
end

local function test_keys_of_a_scalar_is_a_failure_naming_what_it_is(tmp: string)
  local ran = run({ "--keys", ".name", file(tmp) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("$.name: --keys needs an object or an array, got string", 1, true), ran.err)
end

local function test_shape_prints_describe(tmp: string)
  local ran = run({ "--shape", ".users", file(tmp) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "[2 x {id: number, name: string}]\n", ran.out)
  local whole = run({ "--shape", file(tmp, '{"ids": [1, 2], "ok": true}') })
  assert(whole.out == "{ids: [2 x number], ok: boolean}\n", whole.out)
end

local function test_a_dash_or_no_file_reads_standard_input()
  local piped = run({ "--compact", ".a", "-" }, '{"a": [1, 2]}')
  assert(piped.code == 0 and piped.out == "[1,2]\n", piped.err)
  local none = run({ "--compact", ".a" }, '{"a": 7}')
  assert(none.code == 0 and none.out == "7\n", none.err)
  local root = run({ "--compact" }, '[true]')
  assert(root.out == "[true]\n", root.out)
  local both = run({ "--keys", "$", "-" }, '{"b": 1, "a": 2}')
  assert(both.out == "a\nb\n", both.out)
  assert(run({ "-" }, "3").out == "3\n")
end

local function test_a_lone_word_is_a_file_unless_it_reads_as_a_path(tmp: string)
  local path = file(tmp, '{"a": 1}')
  assert(run({ path }).out == '{\n  "a": 1\n}\n')
  assert(run({ "--exists", "./doc.json" }, "{}").code == 2, "./doc.json is a file, not read from stdin")
  assert(run({ "$.a" }, '{"a": 1}').out == "1\n")
  assert(run({ "[1]" }, '[5, 6]').out == "5\n")
end

local function test_invalid_json_exits_2_naming_the_file(tmp: string)
  local path = file(tmp, '{"a": ')
  local ran = run({ ".a", path })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cosmic: json: " .. path .. ": ", 1, true), ran.err)
  local piped = run({ ".a" }, "not json")
  assert(piped.code == 2 and piped.err:find("standard input: ", 1, true), piped.err)
  assert(run({ ".a" }, "").code == 2)
end

local function test_an_unreadable_file_exits_2(tmp: string)
  local ran = run({ ".a", tmp .. "/absent.json" })
  assert(ran.code == 2 and ran.err:find("absent.json", 1, true), ran.err)
  local dir = run({ ".a", tmp })
  assert(dir.code == 2, dir.err)
end

local function test_a_bad_path_exits_2(tmp: string)
  local ran = run({ "$[", file(tmp) })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("path column 2: expected an integer or a quoted key", 1, true), ran.err)
  local wild = run({ "$.users[*]", file(tmp) })
  assert(wild.code == 2 and wild.err:find("not supported yet", 1, true), wild.err)
  local descent = run({ "$..name", file(tmp) })
  assert(descent.code == 2 and descent.err:find("not supported yet", 1, true), descent.err)
  local star = run({ '$["*"]', file(tmp, '{"*": 4}') })
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
    { ".a", path, "extra" },
  }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("cosmic json ", 1, true), ran.err)
  end
  assert(run({ "--no-such-flag", path }).err:find("--no-such-flag", 1, true))
end

local function test_raw_prints_a_string_with_a_newline_as_it_is(tmp: string)
  local ran = run({ "-r", ".a", file(tmp, '{"a": "one\\ntwo"}') })
  assert(ran.code == 0 and ran.out == "one\ntwo\n", ran.out)
end

local function test_invalid_utf8_on_standard_input_exits_2()
  local ran = run({ ".a" }, '{"a": "\xff"}')
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("standard input: ", 1, true), ran.err)
end

local function test_an_empty_word_is_named(tmp: string)
  local file_name = run({ "" }, "{}")
  assert(file_name.code == 2 and file_name.err:find("an empty file name", 1, true), file_name.err)
  local both = run({ ".a", "" }, "{}")
  assert(both.code == 2 and both.err:find("an empty file name", 1, true), both.err)
  local path = run({ "", file(tmp) })
  assert(path.code == 2 and path.err:find("path is empty", 1, true), path.err)
end

local function test_after_dashdash_the_words_are_path_and_file(tmp: string)
  local dotted = tmp .. "/.data.json"
  assert(Fs.write(dotted, '{"a": 1}'))
  -- One word after `--` is the file, though it reads as a path.
  local lone = run({ "--compact", "--", dotted })
  assert(lone.code == 0 and lone.out == '{"a":1}\n', lone.err)
  local bracket = tmp .. "/[x]"
  assert(Fs.write(bracket, "[7]"))
  local named = run({ "--", "[1]", bracket })
  assert(named.code == 0 and named.out == "7\n", named.err)
  local stdin = run({ "--", "-" }, "5")
  assert(stdin.code == 0 and stdin.out == "5\n", stdin.err)
  assert(run({ "--" }, "6").out == "6\n")
  assert(run({ "--", "a", "b", "c" }).code == 2)
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
