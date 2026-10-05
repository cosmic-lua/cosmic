--- `cosmic <file.tl> [args]`, run as this program: the file's words
--- reach its top level in `arg`, as `lua file a b` gives them, beside
--- the function it returns (build/dispatch.tl's `run`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which builds the tree around the file it runs.
Test.policy{ profiles = { "cosmic" } }

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
