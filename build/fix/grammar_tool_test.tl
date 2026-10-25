--- What `cosmic fix` does under `COSMIC_GRAMMAR=new` on a project of its own: whether the tree builds is the new
--- checker's to say, in its words, and an `assert(...)` that spills is left alone (the wrapping is the fork's). It
--- declares `tool` because it starts this program.

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

--- An `assert(...)` that passes on a second value is not wrapped in parentheses: the fork's checker names the spill and
--- `cosmic fix` writes the fix, the new checker's refusal is the run's failure, in its own words.
local function test_a_spilling_assert_is_refused_by_the_new_checker_and_left_as_written(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local source = 'local function read(): string | nil, string return "7", "" end\n' ..
    "return tonumber(assert(read()))\n"
  assert(Fs.write(root .. "/spill.tl", source))
  for _, check in ipairs({ true, false }) do
    local failed, out = fix_new(root, check)
    assert(not failed.ok, out)
    assert(out:find("spill.tl:2:8: no overload of `tonumber`", 1, true) ~= nil, out)
    assert(out:find("(overload_none)", 1, true) ~= nil, out)
    assert(out:find("fixed  spill.tl", 1, true) == nil and out:find("would fix  spill.tl", 1, true) == nil, out)
    assert(Fs.read(root .. "/spill.tl") == source, "the file was written")
  end
end

--- A module the fork reads, with a function the links below name.
local OTHER = "local record other\nend\n\n--- Answers one.\nfunction other.thing(): integer\n  return 1\nend\n\nreturn other\n"

--- A file in the new grammar (`string?`) laid out badly on purpose, whose doc comment names `Other.thing` in a plain span.
local NEW_GRAMMAR = 'local Other = require("other")\n\n--- Two, from `Other.thing`.\n' ..
  'local function two(word: string?): integer\n    return Other.thing()   +   #(word or "") + 1\nend\n\nreturn two\n'

--- A file the fork reads and lays out badly on purpose.
local FORK_TEAL = 'local function one(word: string | nil): integer\n    return #(word or "")\nend\n\nreturn one\n'

--- A file only the new parser reads is read, not laid out, and the run says once that its layout is not applied; a file the
--- fork reads keeps its layout.
local function test_a_file_only_the_new_grammar_reads_is_not_laid_out(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/fork.tl", FORK_TEAL))
  assert(Fs.write(root .. "/new.tl", (NEW_GRAMMAR:gsub("`Other.thing`", "[`Other.thing`]"))))
  local text = assert(Fs.read(root .. "/new.tl"))
  local checked, said = fix_new(root, true)
  assert(not checked.ok, said)
  assert(said:find("would fix  fork.tl", 1, true) ~= nil, said)
  assert(said:find("would fix  new.tl", 1, true) == nil and said:find("FAIL  new.tl", 1, true) == nil, said)
  assert(said:find("1 of 3 files to fix", 1, true) ~= nil, said)
  local _, count = said:gsub("Teal layout is not applied in the new grammar %(1 file read, not laid out%)", "")
  assert(count == 1, said)
  local written, wrote = fix_new(root, false)
  assert(written.ok, wrote)
  assert(wrote:find("fixed  fork.tl", 1, true) ~= nil and wrote:find("fixed  new.tl", 1, true) == nil, wrote)
  assert(Fs.read(root .. "/new.tl") == text, "the file in the new grammar was rewritten")
  assert(Fs.read(root .. "/fork.tl") ~= FORK_TEAL, "the file the fork reads was not laid out")
  local again, repeated = fix_new(root, true)
  assert(again.ok, repeated)
  assert(repeated:find("Teal layout is not applied in the new grammar", 1, true) ~= nil, repeated)
end

--- Without `COSMIC_GRAMMAR=new` the file stays refused in the fork's words, and nothing says the layout is not applied.
local function test_a_file_in_the_new_grammar_is_still_refused_by_the_fork_s_reading(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", NEW_GRAMMAR))
  local failed, said = fix_in(root, "teal", true)
  assert(not failed.ok, said)
  assert(said:find("FAIL  new.tl: new.tl:4:", 1, true) ~= nil and said:find("syntax error", 1, true) ~= nil, said)
  assert(said:find("not applied", 1, true) == nil, said)
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

--- The layout note is on the summary of a failing run too, not only of a clean one: a refused file beside a file in the new
--- grammar, `--check` or not, and a file that is only to fix.
local function test_the_layout_note_is_on_a_failing_summary(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/new.tl", (NEW_GRAMMAR:gsub("`Other.thing`", "it"))))
  assert(Fs.write(root .. "/typed.tl", 'local y: integer = "no"\n\nreturn y\n'))
  local note = "Teal layout is not applied in the new grammar (1 file read, not laid out)"
  local failed, said = fix_new(root, true)
  assert(not failed.ok, said)
  assert(said:find("fix: the tree not building, ", 1, true) ~= nil and said:find(note, 1, true) ~= nil, said)
  assert(Fs.remove(root .. "/typed.tl"))
  assert(Fs.write(root .. "/fork.tl", FORK_TEAL))
  local fixable, fixable_said = fix_new(root, true)
  assert(not fixable.ok, fixable_said)
  assert(fixable_said:find("1 of 3 files to fix", 1, true) ~= nil and fixable_said:find(note, 1, true) ~= nil, fixable_said)
end
