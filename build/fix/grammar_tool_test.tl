--- What `cosmic fix` does on a project of its own: whether the tree builds is the new checker's to say, in its words;
--- an `assert(...)` that spills is left alone; a Teal file is laid out by a fix and noted by a check; and the fork's grammar, which
--- `COSMIC_GRAMMAR=teal` names, is refused. It declares `tool` because it starts this program.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- `cosmic fix`, with `--check` where `check`, in `root`, compiling with the checker `grammar` names, and what it said.
local function fix_in(root: string, grammar: string, check: boolean): Child.Result, string
  local words = if check then { "fix", "--check" } else { "fix" } end
  local env = this_program.environment()
  env["COSMIC_GRAMMAR"] = grammar
  local started = this_program.program(words, { cwd = root, env = env,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(120) })
  local result = assert(Child.run(started.argv, started.options))
  return result, result.stdout or ""
end

--- [`fix_in`] with the new checker.
local function fix_new(root: string, check: boolean): Child.Result, string
  return fix_in(root, "new", check)
end

--- A project the new checker refuses fails the run, `--check` or not, in the checker's words (a code and its fix); fixed,
--- it passes.
local function test_a_tree_the_new_checker_refuses_fails_in_its_words(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local x: integer = "no"\n\nreturn x\n'))
  for _, check in ipairs({ true, false }) do
    local failed, out = fix_new(root, check)
    assert(not failed.ok, out)
    assert(out:find("a.tl:1:", 1, true) ~= nil and out:find("): ", 1, true) ~= nil, out)
    assert(out:find("fix: the tree not building, ", 1, true) ~= nil, out)
  end
  assert(Fs.write(root .. "/a.tl", "local x: integer = 1\n\nreturn x\n"))
  local passed, out = fix_new(root, false)
  assert(passed.ok, out)
end

--- An `assert(...)` that passes on a second value is not wrapped in parentheses: the new checker refuses it, and the refusal
--- is the run's failure, in its own words; `cosmic fix` writes nothing.
local function test_a_spilling_assert_is_refused_by_the_new_checker_and_left_as_written(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local source = 'local function read(): (string?, string)\n  return "7", ""\nend\n' ..
    "local n = tonumber(assert(read()))\nlocal m: number? = n\nreturn m\n"
  assert(Fs.write(root .. "/spill.tl", source))
  for _, check in ipairs({ true, false }) do
    local failed, out = fix_new(root, check)
    assert(not failed.ok, out)
    assert(out:find("spill.tl:4:11: no overload of `tonumber` takes the arguments (string, string) (overload_none)",
      1, true) ~= nil, out)
    assert(out:find("fixed  spill.tl", 1, true) == nil and out:find("would fix  spill.tl", 1, true) == nil, out)
    assert(Fs.read(root .. "/spill.tl") == source, "the file was written")
  end
end

--- A module with a function the links below name.
local OTHER = "local record other\nend\n\n--- Answers one.\nfunction other.thing(): integer\n  return 1\nend\n\nreturn other\n"

--- A file laid out badly on purpose, whose doc comment names `Other.thing` in a plain span.
local NEW_GRAMMAR = 'local Other = require("other")\n\n--- Two, from `Other.thing`.\n' ..
  'local function two(word: string?): integer\n    return Other.thing()   +   #(word or "") + 1\nend\n\nreturn two\n'

--- A file laid out badly on purpose.
local BADLY_LAID_OUT = 'local function one(word: string?): integer\n    return #(word or "")\nend\n\nreturn one\n'

--- The text of NEW_GRAMMAR with its span linked, laid out.
local NEW_LAID = 'local Other = require("other")\n\n--- Two, from [`Other.thing`].\n' ..
  'local function two(word: string?): integer\n  return Other.thing() + #(word or "") + 1\nend\n\nreturn two\n'

--- The text of NEW_GRAMMAR laid out, its span not yet linked.
local PLAIN_LAID = (NEW_LAID:gsub("%[`Other.thing`%]", "`Other.thing`"))

--- The text of BADLY_LAID_OUT, laid out.
local ONE_LAID = 'local function one(word: string?): integer\n  return #(word or "")\nend\n\nreturn one\n'

--- A check notes the files that are not laid out, lists them, writes nothing and does not fail; a fix writes their
--- layout, and a run after it has nothing to note or write.
local function test_a_check_notes_a_file_that_is_not_laid_out_and_a_fix_writes_it(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/laid.tl", BADLY_LAID_OUT))
  local linked = (NEW_GRAMMAR:gsub("`Other.thing`", "[`Other.thing`]"))
  assert(Fs.write(root .. "/new.tl", linked))
  local checked, said = fix_new(root, true)
  assert(checked.ok, said)
  assert(said:find("fix: note  2 Teal files are not laid out; `cosmic fix` lays them out", 1, true) ~= nil, said)
  assert(said:find("fix: note  not laid out  laid.tl", 1, true) ~= nil, said)
  assert(said:find("fix: note  not laid out  new.tl", 1, true) ~= nil, said)
  assert(said:find("not laid out  other.tl", 1, true) == nil, said)
  assert(said:find("would fix", 1, true) == nil and said:find("fix: 3 Teal files, 0 to fix", 1, true) ~= nil, said)
  assert(Fs.read(root .. "/laid.tl") == BADLY_LAID_OUT and Fs.read(root .. "/new.tl") == linked, "a check wrote a file")
  local written, wrote = fix_new(root, false)
  assert(written.ok, wrote)
  assert(wrote:find("fixed  laid.tl", 1, true) ~= nil and wrote:find("fixed  new.tl", 1, true) ~= nil, wrote)
  assert(wrote:find("fix: 3 Teal files, 2 fixed", 1, true) ~= nil and wrote:find("not laid out", 1, true) == nil, wrote)
  assert(Fs.read(root .. "/laid.tl") == ONE_LAID, "the file was not laid out")
  assert(Fs.read(root .. "/new.tl") == NEW_LAID, "the file was not laid out")
  for _, check in ipairs({ true, false }) do
    local again, repeated = fix_new(root, check)
    assert(again.ok and repeated:find("not laid out", 1, true) == nil and repeated:find("fixed  ", 1, true) == nil, repeated)
    assert(repeated:find(if check then "fix: 3 Teal files, 0 to fix" else "fix: 3 Teal files, 0 fixed" end, 1, true) ~= nil,
      repeated)
  end
end

--- A declaration file is laid out as one: the header, not the body's padding. A link written into a file that a fix
--- laid out leaves it laid out.
local function test_a_declaration_file_is_laid_out_by_a_fix_and_linking_leaves_a_file_laid_out(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/api.d.tl", "local  record Api\n  name:    string\nend\n\nreturn Api\n"))
  assert(Fs.write(root .. "/new.tl", NEW_GRAMMAR))
  local _, said = fix_new(root, true)
  assert(said:find("not laid out  api.d.tl", 1, true) ~= nil, said)
  local written, wrote = fix_new(root, false)
  assert(written.ok, wrote)
  assert(Fs.read(root .. "/api.d.tl") == "local record Api\n  name:    string\nend\n\nreturn Api\n", wrote)
  assert(Fs.read(root .. "/new.tl") == NEW_LAID, "linking did not leave the file laid out")
  local again, repeated = fix_new(root, true)
  assert(again.ok and repeated:find("not laid out", 1, true) == nil and repeated:find("would fix", 1, true) == nil, repeated)
end

--- `COSMIC_GRAMMAR=teal` names the fork's grammar, which is gone: the run fails saying so and names `cosmic migrate`, and
--- reads no file.
local function test_the_forks_grammar_is_refused_naming_migrate(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", NEW_GRAMMAR))
  local failed, said = fix_in(root, "teal", true)
  assert(not failed.ok, said)
  assert(said:find("COSMIC_GRAMMAR=teal: the fork's grammar is gone; `cosmic migrate` rewrites a project to the new one",
    1, true) ~= nil, said)
  assert(Fs.read(root .. "/new.tl") == NEW_GRAMMAR, "the file was written")
end

--- A link of a file in the new grammar is checked against the project and a plain span is linked in place, byte for byte
--- with the rest of the file as it was: the new tree's positions are the file's own.
local function test_the_links_of_a_file_in_the_new_grammar_are_checked_and_written_in_place(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", PLAIN_LAID))
  local checked, said = fix_new(root, true)
  assert(not checked.ok, said)
  assert(said:find("FAIL  new.tl:3: link: `Other.thing` would link to other.thing", 1, true) ~= nil, said)
  assert(said:find("1 plain reference to link", 1, true) ~= nil, said)
  assert(Fs.read(root .. "/new.tl") == PLAIN_LAID, "a check wrote the file")
  local written, wrote = fix_new(root, false)
  assert(written.ok, wrote)
  assert(wrote:find("fixed  new.tl (links)", 1, true) ~= nil, wrote)
  local expected = NEW_LAID
  assert(Fs.read(root .. "/new.tl") == expected, "the file was not the text with the one span linked")
  -- a link that names nothing fails, at the line it is on
  assert(Fs.write(root .. "/new.tl", (expected:gsub("%[`Other.thing`%]", "[`Other.nope`]"))))
  local broken, why = fix_new(root, true)
  assert(not broken.ok, why)
  assert(why:find("FAIL  new.tl:3: link: Other.nope does not resolve", 1, true) ~= nil, why)
  assert(why:find("1 link not resolving", 1, true) ~= nil, why)
end

--- A file neither parser reads fails in the new parser's words, with its fix, and the layout note still says nothing of it.
local function test_a_file_neither_parser_reads_fails_in_the_new_parsers_words(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/bad.tl", "local x: = 1\n\nreturn x\n"))
  -- a second refused file makes the build's refusal several lines, one of them the file neither parser reads
  assert(Fs.write(root .. "/typed.tl", 'local y: integer = "no"\n\nreturn y\n'))
  for _, check in ipairs({ true, false }) do
    local failed, said = fix_new(root, check)
    assert(not failed.ok, said)
    assert(said:find("fix: FAIL  bad.tl:1:10: expected a type, found `=` (expected_type): write a type", 1, true) ~= nil, said)
    assert(said:find("1 of 2 files refused", 1, true) ~= nil, said)
    local _, times = said:gsub("bad.tl:1:10: expected a type", "")
    assert(times == 1, "the error is said " .. tostring(times) .. " times: " .. said)
    assert(said:find("not applied", 1, true) == nil, said)
  end
end

--- The note is on a failing run too, not only a clean one: a refused file beside a file not laid out, and the file
--- is written by a fix though the tree does not build.
local function test_the_layout_note_is_on_a_failing_summary(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", (NEW_GRAMMAR:gsub("`Other.thing`", "it"))))
  assert(Fs.write(root .. "/typed.tl", 'local y: integer = "no"\n\nreturn y\n'))
  local failed, said = fix_new(root, true)
  assert(not failed.ok, said)
  assert(said:find("fix: the tree not building, ", 1, true) ~= nil, said)
  assert(said:find("fix: note  1 Teal file is not laid out; `cosmic fix` lays it out", 1, true) ~= nil, said)
  local fixed, wrote = fix_new(root, false)
  assert(not fixed.ok and wrote:find("fixed  new.tl", 1, true) ~= nil, wrote)
end
