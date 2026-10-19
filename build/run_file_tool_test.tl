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
    assert(result.code == 0 and result.stdout == "42\n", (result.stdout or "") .. (result.stderr or ""))
  end
  assert(Fs.write(root .. "/foo.tl", implementation(43)))
  local edited = run()
  assert(edited.code == 0 and edited.stdout == "43\n", (edited.stdout or "") .. (edited.stderr or ""))
  assert(Fs.write(root .. "/foo.d.tl",
    "local record Foo\n  renamed: integer\nend\nreturn Foo\n"))
  local refused = run()
  assert(refused.code ~= 0 and (refused.stderr or ""):find("answer", 1, true),
    (refused.stdout or "") .. (refused.stderr or ""))
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

--- A tree of `files`, by name, under `tmp`.
local function tree_of(tmp: string, name: string, files: {string:string}): string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root))
  for file, source in pairs(files) do
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
  local cases: {{string}} = {
    { "direct-syntax", SYNTAX_ERROR, "bad.tl: bad.tl:1:21: syntax error" },
    { "direct-types", TYPE_ERROR, "bad.tl: the compiler refused it" },
    { "through-syntax", SYNTAX_ERROR, "bad.tl: bad.tl:1:21: syntax error" },
    { "through-types", TYPE_ERROR, "bad.tl: the compiler refused it" },
  }
  for _, case in ipairs(cases) do
    local name, broken, refusal = case[1], case[2], case[3]
    local files: {string:string} = { ["bad.tl"] = broken }
    if name:find("^through") then
      files["good.tl"] = 'local m = require("mid")\nprint(m)\n'
      files["mid.tl"] = 'local b = require("bad")\nreturn b\n'
    else
      files["good.tl"] = 'local b = require("bad")\nprint(b)\n'
    end
    local result = run_in(tree_of(tmp, name, files), "good.tl")
    local said = tostring(result.stdout) .. tostring(result.stderr)
    assert(result.code == 1 and result.stdout == "", said)
    assert((result.stderr or ""):find(refusal, 1, true) ~= nil and
        (result.stderr or ""):find("left out", 1, true) == nil, said)
  end
end
