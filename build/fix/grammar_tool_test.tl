--- What `cosmic fix` does on a project of its own: whether the tree builds is the new checker's to say, in its words;
--- an `assert(...)` that spills is left alone; a file is read and checked and not laid out; and the fork's grammar, which
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

--- The note the run says once, that it reads and checks and does not lay out.
local NOTE <const> = "fix: note  Teal is read and checked, not laid out: `cosmic fix` has no layout for the new grammar yet"

--- A file is read and checked, not laid out, and the run says once that it does not: a file laid out badly passes a check
--- and a fix, and is left as written.
local function test_a_file_is_read_and_checked_and_not_laid_out(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/laid.tl", BADLY_LAID_OUT))
  assert(Fs.write(root .. "/new.tl", (NEW_GRAMMAR:gsub("`Other.thing`", "[`Other.thing`]"))))
  local text = assert(Fs.read(root .. "/new.tl"))
  for _, check in ipairs({ true, false }) do
    local ran, said = fix_new(root, check)
    assert(ran.ok, said)
    assert(said:find("would fix", 1, true) == nil and said:find("fixed  ", 1, true) == nil, said)
    local _, count = said:gsub((NOTE:gsub("%p", "%%%0")), "")
    assert(count == 1, said)
    local summary = if check then "fix: 3 Teal files, 0 to fix" else "fix: 3 Teal files, 0 fixed" end
    assert(said:find(summary, 1, true) ~= nil, said)
  end
  assert(Fs.read(root .. "/new.tl") == text, "the file was rewritten")
  assert(Fs.read(root .. "/laid.tl") == BADLY_LAID_OUT, "the file was laid out")
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
  assert(Fs.write(root .. "/new.tl", NEW_GRAMMAR))
  local checked, said = fix_new(root, true)
  assert(not checked.ok, said)
  assert(said:find("FAIL  new.tl:3: link: `Other.thing` would link to other.thing", 1, true) ~= nil, said)
  assert(said:find("1 plain reference to link", 1, true) ~= nil, said)
  assert(Fs.read(root .. "/new.tl") == NEW_GRAMMAR, "a check wrote the file")
  local written, wrote = fix_new(root, false)
  assert(written.ok, wrote)
  assert(wrote:find("fixed  new.tl (links)", 1, true) ~= nil, wrote)
  local expected = (NEW_GRAMMAR:gsub("`Other.thing`", "[`Other.thing`]"))
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

--- The layout note is on a failing run too, not only a clean one: a refused file beside a file read and not laid out,
--- `--check` or not.
local function test_the_layout_note_is_on_a_failing_summary(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", (NEW_GRAMMAR:gsub("`Other.thing`", "it"))))
  assert(Fs.write(root .. "/typed.tl", 'local y: integer = "no"\n\nreturn y\n'))
  for _, check in ipairs({ true, false }) do
    local failed, said = fix_new(root, check)
    assert(not failed.ok, said)
    assert(said:find("fix: the tree not building, ", 1, true) ~= nil and said:find(NOTE, 1, true) ~= nil, said)
  end
end
