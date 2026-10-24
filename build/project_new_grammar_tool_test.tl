--- A project written in the new grammar (`mut`, a class, function fields called as `queue:push(word)`, `T?`) with a template
--- and an example, as the tool runs it with the new checker (`COSMIC_GRAMMAR=new`): the fixture of [`build.new_grammar_project`].
--- It is tested, its coverage is counted from the syntax tree of the new checker (the fork's parser reads none of it), a
--- planted error is refused with the new checker's fix, and the words speak of no pin: a project has no ceilings to raise.
--- `cosmic build` of the same project is in build/embed_tool_test.tl. CI's rehearsal job runs this test in its full suite.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local NewGrammarProject = require("build.new_grammar_project")
local this_program = require("build.this_program")

--- The program itself, which this test starts, and the project it builds.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A copy of the fixture under `tmp`, a tree of its own for the run `name`.
local function copy_of(tmp: string, name: string): string
  local root = tmp .. "/" .. name
  assert(NewGrammarProject.write(root))
  return root
end

--- The environment of a run of the program: `grammar` as COSMIC_GRAMMAR and `tmp` as its temporary directory.
local function environment(tmp: string, grammar: string): {string:string}
  local env = this_program.environment()
  env["COSMIC_GRAMMAR"] = grammar
  env["TMPDIR"] = tmp
  return env
end

--- Runs `cosmic test` in `root` with `grammar` as COSMIC_GRAMMAR, unsandboxed (a sandbox nested in this test's own may be
--- refused where the host nests only two deep), and answers what it said.
local function tested(root: string, tmp: string, grammar: string): Child.Result, string
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = environment(tmp, grammar)
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_BUILD_CACHE"] = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return assert(result, trouble), (assert(Fs.read(output)))
end

--- Runs `cosmic fix --check` in `root` with `grammar` as COSMIC_GRAMMAR, and answers what it said.
local function checked(root: string, tmp: string, grammar: string): Child.Result, string
  local started = this_program.program({ "fix", "--check" }, {
    cwd = root, env = environment(tmp, grammar), stdout = "capture", stderr = "stdout", process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  return assert(result, trouble), result.stdout or ""
end

--- Replaces `from` by `to` in the file `name` of `root`, which must hold it once.
local function planted(root: string, name: string, from: string, to: string)
  local text = assert(Fs.read(root .. "/" .. name))
  local at, stop = text:find(from, 1, true)
  assert(at ~= nil and stop ~= nil and text:find(from, stop + 1, true) == nil, name .. " does not hold " .. from .. " once")
  assert(Fs.write(root .. "/" .. name, text:sub(1, at - 1) .. to .. text:sub(stop + 1)))
end

--- That `text` is a refusal that speaks of no pin or ceiling, and holds each of `words`.
local function refusal(result: Child.Result, text: string, words: {string})
  assert(not result.ok and result.code == 1, text)
  for _, word in ipairs(words) do
    assert(text:find(word, 1, true) ~= nil, word .. " is not in: " .. text)
  end
  assert(text:find("pinned", 1, true) == nil and text:find("ceilings.txt", 1, true) == nil and
      text:find("rather than raise", 1, true) == nil and text:find("the TODO of", 1, true) == nil, text)
end

local function test_a_project_in_the_new_grammar_is_tested_and_its_coverage_counted(tmp: string)
  local result, text = tested(copy_of(tmp, "new"), tmp, "new")
  assert(result.ok and text:find("test: 4 tests passed in 3 modules", 1, true) ~= nil, text)
  -- the coverage step read every module through the new checker's tree: it names lines, and fails on none
  local hit, total = text:match("test: coverage [%d.]+%% %((%d+)/(%d+) lines")
  local hits, lines = tonumber(hit), tonumber(total)
  assert(hits ~= nil and lines ~= nil and hits > 40 and lines > hits, text)
  assert(text:find("ERROR", 1, true) == nil and text:find("syntax error", 1, true) == nil, text)
  -- the fork does not read the grammar it is not
  local forked, forked_text = tested(copy_of(tmp, "forked"), tmp, "teal")
  assert(not forked.ok and forked_text:find("syntax error", 1, true) ~= nil, forked_text)
end

--- `cosmic fix --check` reads the project with the new parser where the fork's cannot (the three files that spell `mut`,
--- a class or `T?`) and lays out the rest; the fork's mode refuses those three.
local function test_a_project_in_the_new_grammar_is_checked_by_fix_and_the_fork_refuses_it(tmp: string)
  local result, text = checked(copy_of(tmp, "fix_new"), tmp, "new")
  assert(result.ok, text)
  assert(text:find("fix: 7 Teal + 1 template files, 0 to fix, ", 1, true) ~= nil, text)
  assert(text:find("Teal layout is not applied in the new grammar (3 files read, not laid out)", 1, true) ~= nil, text)
  local forked, forked_text = checked(copy_of(tmp, "fix_forked"), tmp, "teal")
  assert(not forked.ok and forked_text:find("syntax error", 1, true) ~= nil, forked_text)
  assert(forked_text:find("not applied", 1, true) == nil, forked_text)
end

local function test_a_method_called_on_a_record_is_refused_with_the_class_and_function_field_fix(tmp: string)
  local root = copy_of(tmp, "method")
  planted(root, "queue.tl", "  push: function(self: Queue, word: string)\n", "")
  planted(root, "queue.tl", "push = push, ", "")
  planted(root, "queue.tl", "function Queue.new", "function Queue.push(self: Queue, word: string)\n  push(self, word)\nend\n\nfunction Queue.new")
  local result, text = tested(root, tmp, "new")
  refusal(result, text, { "queue_test.tl:5:3: `Queue` has no field `push`", "(field_unknown)",
    "declare `Queue` as a class, or declare `push` as a function field `push: function(Queue, ...)` that every value holds",
    "queue_example.tl:9:3:", "cmd/tally/main.tl:8:5:" })
end

local function test_a_view_written_a_nil_not_taken_and_an_unused_name_are_refused_with_their_fixes(tmp: string)
  local root = copy_of(tmp, "views")
  planted(root, "counter.tl", "  return { label = label, count = 0, seen = {} }",
    "  local unused = 1\n  local seen: {string} = {}\n  local function add() seen[#seen + 1] = label end\n  add()\n  return { label = label, count = 0, seen = seen }")
  local result, text = tested(root, tmp, "new")
  refusal(result, text, { "counter.tl:", "(view_written): declare `seen` `mut {string}` where it is made or received",
    "(unused_variable): name it `_` or `_unused`", "counter_test.tl: not compiled" })
  local nil_root = copy_of(tmp, "nil")
  planted(nil_root, "counter.tl", "  seen: mut {string}\n", "  seen: mut {string}?\n")
  local nil_result, nil_text = tested(nil_root, tmp, "new")
  refusal(nil_result, nil_text, { "(nil_not_allowed): copy `self.seen` to a local and test that" })
end

local function test_a_template_refused_names_its_line_and_the_fix(tmp: string)
  local root = copy_of(tmp, "template")
  planted(root, "report.tmpl", "<h1>{{.title}}</h1>", "<h1>{{.nope}}</h1>")
  local result, text = tested(root, tmp, "new")
  refusal(result, text, { "report.tmpl:2:", "`data.Report` has no field `nope`, nearest `note` (field_unknown): write `note`",
    "counter_test.tl: not compiled: it requires report, which the new checker refused" })
  -- a condition on a string is no condition, and the fix is said in the template's terms
  local string_root = copy_of(tmp, "string")
  planted(string_root, "report.tmpl", "{{with .note}}<p>{{.}}</p>{{end}}", "{{if .title}}<p>x</p>{{end}}")
  local string_result, string_text = tested(string_root, tmp, "new")
  refusal(string_result, string_text, { "report.tmpl:4:", "is `string`, which is no boolean or optional, so it is no condition (condition_type)",
    "`{{if}}` and `{{with}}` need a value that can be absent: make the field optional, or drop the `{{if}}`" })
end

--- A module used as a value is refused with a fix a project can follow: it names no ceiling file and no TODO of the checker.
local function test_a_module_used_as_a_value_is_refused_with_a_fix_that_names_no_ceiling(tmp: string)
  local root = copy_of(tmp, "declaration")
  assert(Fs.write(root .. "/u.tl", "local record u\n  upper: function(s: string): string\nend\n" ..
      "function u.upper(s: string): string\n  return s:upper()\nend\nreturn u\n"))
  assert(Fs.write(root .. "/holder.tl", 'local u = require("u")\nlocal record Holder\n  helper: u\nend\n' ..
      "local h: Holder = { helper = u }\nreturn h\n"))
  local result, text = tested(root, tmp, "new")
  refusal(result, text, { "holder.tl:5:", "(declaration_value)", "require the module where you use it (`local u = require(\"u\")`)" })
end
