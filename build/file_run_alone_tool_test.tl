--- `cosmic <file>` of a file that requires only `cosmic.*` modules, which runs as `--standalone` does, and of one
--- that requires a module of its project, which builds its tree: run as this program, which a tree run needs whole.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The environment of a file run that neither forces `--standalone` nor forbids it, as a shell gives one (a worker's
--- children are given COSMIC_STANDALONE=1), whose tree, where one is built, is under `home`.
local function file_run_environment(home: string): mut {string:string}
  local env = this_program.environment()
  env["COSMIC_STANDALONE"] = ""
  env["COSMIC_BUILD_HOME"] = home
  return env
end

--- `cosmic <file>` runs a file that requires only `cosmic.*` modules as `--standalone` does: no tree is built, its
--- words reach it, and it is still a source run of the module it is: [`Proc.relaunch`] names it as the script to
--- start again, and its top level finds its module's name as its `...`.
--- COSMIC_STANDALONE=0 builds the tree around it instead.
local function test_a_file_that_needs_only_the_standard_library_runs_alone(tmp: string)
  local dir = tmp .. "/alone"
  local home = tmp .. "/builds"
  assert(Fs.mkdirs(dir))
  assert(Fs.mkdirs(home))
  local script = dir .. "/script.tl"
  assert(Fs.write(script, [[
local Proc = require("cosmic.proc")
local own_name = tostring((...))
return function(argv: {string}): integer
  local relaunch = assert(Proc.relaunch())
  print(table.concat(argv, ",") .. "|" .. tostring(relaunch.script) .. "|" .. own_name)
  return 3
end
]]))
  local resolved = assert(Fs.absolute(script))
  local started = this_program.program({ script, "one", "two" }, { cwd = dir, env = file_run_environment(home),
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 3 and result.stdout == "one,two|" .. resolved .. "|script\n",
    tostring(result.stdout) .. tostring(result.stderr))
  assert(#assert(Fs.list(home)) == 0, "a file run that needs no tree built one")
  assert(#assert(Fs.list(dir)) == 1, "a file run that needs no tree wrote beside the file")

  local env = file_run_environment(home)
  env["COSMIC_STANDALONE"] = "0"
  local in_tree = this_program.program({ script, "one", "two" }, { cwd = dir, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local built = assert(Child.run(in_tree.argv, in_tree.options))
  assert(built.code == 3 and built.stdout == "one,two|" .. resolved .. "|script\n",
    tostring(built.stdout) .. tostring(built.stderr))
  assert(#assert(Fs.list(home)) > 0, "COSMIC_STANDALONE=0 built no tree around the file")
end

--- A file that requires a module of its project runs in its tree, which finds the module.
local function test_a_file_that_requires_a_project_module_runs_in_its_tree(tmp: string)
  local dir = tmp .. "/project"
  local home = tmp .. "/builds"
  assert(Fs.mkdirs(dir .. "/lib"))
  assert(Fs.mkdirs(home))
  assert(Fs.write(dir .. "/lib/word.tl", 'local word: string = "word"\nreturn word\n'))
  local script = dir .. "/script.tl"
  assert(Fs.write(script, [[
local word = require("lib.word")
return function(): integer
  print(word)
  return 0
end
]]))
  local started = this_program.program({ script }, { cwd = dir, env = file_run_environment(home),
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0 and result.stdout == "word\n", tostring(result.stdout) .. tostring(result.stderr))
  assert(#assert(Fs.list(home)) > 0, "the tree was not built")
end
