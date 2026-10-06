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
  assert(Fs.write(root .. "/top.tl", 'print(arg[0] .. "|" .. table.concat(arg, ","))\n' ..
      'return function(argv: {string}): integer\n  print(table.concat(argv, ","))\n' ..
      '  return 0\nend\n'))
  local started = this_program.program({ "top.tl", "one", "two" }, { cwd = root,
    env = this_program.environment(), stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0 and result.stdout == "top.tl|one,two\none,two\n",
    tostring(result.stdout) .. tostring(result.stderr))
end

--- A declaration/implementation pair builds cold and warm. A runtime edit
--- changes the code that runs; a declaration edit changes what callers check.
local function test_a_paired_declaration_runs_its_implementation(tmp: string)
  local root = tmp .. "/paired"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/foo.d.tl",
    "local record Foo\n  answer: integer\nend\nreturn Foo\n"))
  local function implementation(answer: integer): string
    return "local record Foo\n  answer: integer\nend\nreturn {answer = " .. answer .. "} as Foo\n"
  end
  assert(Fs.write(root .. "/foo.tl", implementation(42)))
  assert(Fs.write(root .. "/main.tl", 'local Foo = require("foo")\nprint(Foo.answer)\n'))
  local function run(): Child.Result
    local env = this_program.environment()
    env.COSMIC_BUILD_CACHE = "0"
    local started = this_program.program({ "main.tl" }, { cwd = root,
      env = env,
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
    return (assert(Child.run(started.argv, started.options)))
  end
  for _ = 1, 2 do
    local result = run()
    assert(result.code == 0 and result.stdout == "42\n", result.stdout .. result.stderr)
  end
  assert(Fs.write(root .. "/foo.tl", implementation(43)))
  local edited = run()
  assert(edited.code == 0 and edited.stdout == "43\n", edited.stdout .. edited.stderr)
  assert(Fs.write(root .. "/foo.d.tl",
    "local record Foo\n  renamed: integer\nend\nreturn Foo\n"))
  local refused = run()
  assert(refused.code ~= 0 and (refused.stderr or ""):find("answer", 1, true),
    refused.stdout .. refused.stderr)
end
