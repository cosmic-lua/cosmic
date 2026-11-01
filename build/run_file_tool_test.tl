--- `cosmic <file.tl> [args]`, run as this program: the file's words
--- reach its top level in `arg`, as `lua file a b` gives them, beside
--- the function it returns (build/dispatch.tl's `run`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which builds the tree around the file it runs.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_a_file_finds_its_words_in_arg_at_its_top_level(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/top.tl", 'print((arg[0] or "") .. "|" .. table.concat(arg, ","))\n' ..
      'return function(argv: {string}): integer\n  print(table.concat(argv, ","))\n' ..
      '  return 0\nend\n'))
  local started = this_program.program({ "top.tl", "one", "two" }, { cwd = root,
    env = this_program.environment(), stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0 and result.stdout == "top.tl|one,two\none,two\n",
    tostring(result.stdout) .. tostring(result.stderr))
end

--- Runs `file` in `root` as this program, with no compile cache shared
--- across trees, so each case compiles what it holds.
local function run_in(root: string, file: string): Child.Result
  local env = this_program.environment()
  env.COSMIC_BUILD_CACHE = "0"
  local started = this_program.program({ file }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

--- A declaration beside its source stops a file run, naming both files; the run goes on once the declaration is deleted.
local function test_a_declaration_beside_its_source_stops_a_file_run(tmp: string)
  local root = tmp .. "/paired"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/foo.d.tl", "local record Foo\n  answer: integer\nend\nreturn Foo\n"))
  assert(Fs.write(root .. "/foo.tl",
    "local record Foo\n  answer: integer\nend\nlocal foo: Foo = { answer = 42 }\nreturn foo\n"))
  assert(Fs.write(root .. "/main.tl", 'local Foo = require("foo")\nprint(Foo.answer)\n'))
  local refused = run_in(root, "main.tl")
  assert(refused.code ~= 0 and refused.stdout == "", (refused.stdout or "") .. (refused.stderr or ""))
  assert((refused.stderr or ""):find("foo.d.tl: foo.tl is already the module foo", 1, true) ~=
      nil, refused.stderr)
  assert(Fs.remove(root .. "/foo.d.tl"))
  local result = run_in(root, "main.tl")
  assert(result.code == 0 and result.stdout == "42\n", (result.stdout or "") .. (result.stderr or ""))
end

--- A tree of `files`, by name, under `tmp`.
local function tree_of(tmp: string, name: string, files: {string:string}): string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root))
  for file, source in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. file)))
    assert(Fs.write(root .. "/" .. file, source))
  end
  return root
end

local SYNTAX_ERROR <const> = "local function f(...x: string) end\nreturn f\n"
local TYPE_ERROR <const> = "local n: integer = \"s\"\nreturn n\n"

--- A broken file the run's file does not require -- one that does not
--- parse, or does not type-check -- is left out with one warning, and the
--- file runs; so is a sibling that requires the broken one, with no line
--- of its own.
local function test_a_broken_sibling_does_not_stop_a_file_run(tmp: string)
  for name, broken in pairs({ syntax = SYNTAX_ERROR, types = TYPE_ERROR }) do
    local root = tree_of(tmp, name, { ["good.tl"] = 'print("ok")\n', ["bad.tl"] = broken,
      ["other.tl"] = 'local b = require("bad")\nprint(b)\n' })
    local result = run_in(root, "good.tl")
    local said = tostring(result.stdout) .. tostring(result.stderr)
    assert(result.code == 0 and result.stdout == "ok\n", said)
    local _, lines = (result.stderr or ""):gsub("\n", "")
    assert(lines == 1 and (result.stderr or ""):find(
      "warning: bad.tl is left out of this run, which does not require it: bad.tl:1:", 1, true) ~= nil, said)
  end
end

--- A broken file the run's file requires, itself or through another,
--- still stops the run with the refusal a whole build gives.
local function test_a_broken_required_file_still_stops_a_file_run(tmp: string)
  local direct = 'local b = require("bad")\nprint(b)\n'
  local through = 'local m = require("mid")\nprint(m)\n'
  local mid = 'local b = require("bad")\nreturn b\n'
  local record Case
    name: string
    files: {string:string}
  end
  local cases: {Case} = {
    { name = "direct-syntax", files = { ["good.tl"] = direct, ["bad.tl"] = SYNTAX_ERROR } },
    { name = "direct-types", files = { ["good.tl"] = direct, ["bad.tl"] = TYPE_ERROR } },
    { name = "through-syntax", files = { ["good.tl"] = through, ["mid.tl"] = mid, ["bad.tl"] = SYNTAX_ERROR } },
    { name = "through-types", files = { ["good.tl"] = through, ["mid.tl"] = mid, ["bad.tl"] = TYPE_ERROR } },
  }
  for _, case in ipairs(cases) do
    local name, files = case.name, case.files
    local refusal = if files["bad.tl"] == SYNTAX_ERROR then "bad.tl:1:21: expected `:` after `...`, found `x` (expected_token)" else
      "bad.tl: the compiler refused it" end
    local result = run_in(tree_of(tmp, name, files), "good.tl")
    local said = tostring(result.stdout) .. tostring(result.stderr)
    assert(result.code == 1 and result.stdout == "", said)
    assert((result.stderr or ""):find(refusal, 1, true) ~= nil and
        (result.stderr or ""):find("left out", 1, true) == nil, said)
  end
end

--- What `foo` (the file `file`, a `.tl` or a `.d.tl` that declares itself a binding) requires is reached as what a
--- source requires is: a caller is checked against it, so a broken module only it requires stops the run.
local function broken_file_stops_a_file_run(tmp: string, file: string)
  local record_text = 'local types = require("types")\nlocal record Foo\n  answer: types.N\nend\n'
  local foo = if file == "foo.d.tl" then "--- @kind binding\n" .. record_text .. "return Foo\n" else record_text .. "return Foo\n" end
  local root = tree_of(tmp, "declared-" .. file, {
    ["good.tl"] = 'local foo = require("foo")\nprint(foo.answer)\n',
    [file] = foo,
    ["types.tl"] = 'local record types\n  type N = integer\nend\nlocal n: integer = "s"\nprint(n)\nreturn types\n',
  })
  local result = run_in(root, "good.tl")
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.code == 1 and (result.stderr or ""):find("types.tl: the compiler refused it", 1, true) ~= nil and
      (result.stderr or ""):find("left out", 1, true) == nil, said)
end

local function test_a_broken_file_a_declaration_requires_stops_a_file_run(tmp: string)
  broken_file_stops_a_file_run(tmp, "foo.d.tl")
end

--- A type-only module is a `.tl`, whose requires are reached the same way.
local function test_a_broken_file_a_type_module_requires_stops_a_file_run(tmp: string)
  broken_file_stops_a_file_run(tmp, "foo.tl")
end

--- Files alike are one source to the build; each broken one is told of.
local function test_each_broken_file_of_one_source_is_told(tmp: string)
  local root = tree_of(tmp, "alike", { ["good.tl"] = 'print("ok")\n', ["bad.tl"] = SYNTAX_ERROR,
    ["copy.tl"] = SYNTAX_ERROR })
  local result = run_in(root, "good.tl")
  local stderr = result.stderr or ""
  assert(result.code == 0 and result.stdout == "ok\n" and
      stderr:find("warning: bad.tl is left out of this run, which does not require it: bad.tl:1:21:", 1, true) ~= nil and
      stderr:find("warning: copy.tl is left out of this run, which does not require it: copy.tl:1:21:", 1, true) ~= nil,
    tostring(result.stdout) .. stderr)
end

--- Runs `file` in `root` as this program with the new checker (`COSMIC_GRAMMAR=new`).
local function run_new_in(root: string, file: string): Child.Result
  local env = this_program.environment()
  env["COSMIC_BUILD_CACHE"] = "0"
  env["COSMIC_GRAMMAR"] = "new"
  local started = this_program.program({ file }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

--- The file run with the new checker: a broken sibling it does not reach is left out in the checker's words, one it reaches
--- stops the run with them, and a file that is whole runs.
local function test_a_file_run_with_the_new_checker_is_told_a_refusal_in_its_words(tmp: string)
  local root = tree_of(tmp, "new", { ["good.tl"] = 'print("ok")\n', ["bad.tl"] = TYPE_ERROR,
    ["other.tl"] = 'local b = require("bad")\nprint(b)\n' })
  local result = run_new_in(root, "good.tl")
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.code == 0 and result.stdout == "ok\n", said)
  assert((result.stderr or ""):find("warning: bad.tl is left out of this run, which does not require it: bad.tl:1:", 1, true) ~= nil and
      (result.stderr or ""):find("(not_assignable)", 1, true) ~= nil, said)
  local needing = tree_of(tmp, "new-needed", { ["good.tl"] = 'local b = require("bad")\nprint(b)\n', ["bad.tl"] = TYPE_ERROR })
  local stopped = run_new_in(needing, "good.tl")
  local stopped_said = tostring(stopped.stdout) .. tostring(stopped.stderr)
  assert(stopped.code == 1 and stopped.stdout == "" and (stopped.stderr or ""):find("bad.tl: the compiler refused it", 1, true) ~= nil and
      (stopped.stderr or ""):find("(not_assignable)", 1, true) ~= nil, stopped_said)
end

--- A script's `#!/usr/bin/env cosmic` first line is skipped, as Lua skips it, and the lines after it keep their numbers: the
--- run's output, a runtime error's line and a refusal's line are the file's.
local function test_a_script_with_a_hashbang_line_runs_and_keeps_its_line_numbers(tmp: string)
  local hashbang = "#!/usr/bin/env cosmic\n"
  local root = tree_of(tmp, "hashbang", {
    ["ok.tl"] = hashbang .. 'print("ran")\n',
    ["fails.tl"] = hashbang .. 'local n: integer = 1\nerror("boom " .. tostring(n))\n',
    ["refused.tl"] = hashbang .. '\nlocal n: integer = "s"\nreturn n\n',
  })
  local ran = run_in(root, "ok.tl")
  assert(ran.code == 0 and ran.stdout == "ran\n", tostring(ran.stdout) .. tostring(ran.stderr))
  local failed = run_in(root, "fails.tl")
  assert(failed.code ~= 0 and (failed.stderr or ""):find("fails:3: boom 1", 1, true) ~= nil, tostring(failed.stderr))
  local refused = run_in(root, "refused.tl")
  assert(refused.code ~= 0 and (refused.stderr or ""):find("refused.tl:3:", 1, true) ~= nil and
      (refused.stderr or ""):find("(not_assignable)", 1, true) ~= nil, tostring(refused.stderr))
end

--- A file that is Lua is not run, nor is any file that is not Teal: cosmic runs Teal, checked, and says so with
--- what to do, before it builds anything or runs a word of the file.
local function test_a_lua_file_is_refused_and_not_run(tmp: string)
  local root = tmp .. "/lua"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/hello.lua", 'print("ran as lua")\n'))
  assert(Fs.write(root .. "/notes.txt", "words\n"))
  for _, named in ipairs({ "hello.lua", "./hello.lua", root .. "/hello.lua" }) do
    local result = run_in(root, named)
    assert(result.code == 1 and result.stdout == "", named .. ": " .. tostring(result.stdout) ..
        tostring(result.stderr))
    local said = result.stderr or ""
    assert(said:find("is Lua, and cosmic runs Teal, checked", 1, true) ~= nil and
        said:find("rename it to hello.tl", 1, true) ~= nil and said:find("cosmic fix", 1, true) ~= nil, said)
  end
  local other = run_in(root, "./notes.txt")
  assert(other.code == 1 and other.stdout == "" and
      (other.stderr or ""):find("is not a Teal source: cosmic runs files that end in .tl", 1, true) ~= nil,
    tostring(other.stderr))
end

--- A `.lua` file beside a Teal module is no module of the program: the build stages Teal, so a `require` of it is
--- refused as any module the project does not have.
local function test_a_lua_module_beside_a_teal_one_is_no_module(tmp: string)
  local root = tmp .. "/beside"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/helper.lua", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/main.tl", 'local Helper = require("helper")\nprint(Helper.answer)\n'))
  local result = run_in(root, "main.tl")
  assert(result.code ~= 0 and result.stdout == "", tostring(result.stdout) .. tostring(result.stderr))
  assert((result.stderr or ""):find("helper", 1, true) ~= nil, tostring(result.stderr))
end

--- `--standalone` takes the file's name as it is given, and checks and compiles what it holds as Teal whatever it is
--- called: a `.lua` file with Lua's looseness is refused by the checker, not run as Lua.
local function test_a_lua_file_run_standalone_is_checked_as_teal(tmp: string)
  local file = tmp .. "/loose.lua"
  assert(Fs.write(file, "local function twice(n) return n * 2 end\nprint(twice(21))\n"))
  local started = this_program.program({ "--standalone", file }, { env = this_program.environment(),
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 1 and result.stdout == "" and (result.stderr or ""):find("param_untyped", 1, true) ~= nil,
    tostring(result.stdout) .. tostring(result.stderr))
end
