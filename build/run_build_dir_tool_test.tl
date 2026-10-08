--- A read-only source tree builds into its external cache directory,
--- then reuses that database without writing beside its sources.

local build_paths = require("build.paths")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program itself, which builds the tree around the file it runs.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function run(root: string, env: {string:string}, word: string): Child.Result
  local started = this_program.program({ "main.tl", word }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_a_read_only_tree_builds_into_its_external_cache(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local env = this_program.environment()
  env.COSMIC_BUILD_HOME = nil
  env.XDG_CACHE_HOME = tmp .. "/cache"
  assert(Fs.write(root .. "/main.tl", 'local helper = require("helper")\n' ..
      'return function(argv: {string}): integer\n  print(helper .. argv[1])\n  return 0\nend\n'))
  assert(Fs.write(root .. "/helper.tl", 'return "from "\n'))
  assert(sys.chmod(root, tonumber("555", 8) as integer))
  local first = run(root, env, "here")
  assert(first.code == 0 and first.stdout == "from here\n", tostring(first.stderr))
  local output = build_paths.required(root, env)
  local home = assert(Fs.absolute(tmp .. "/cache/cosmic/trees"))
  assert(Fs.within(output, home), output)
  local path = output .. "/build.db"
  local db = assert(Sqlite.open(path))
  local integrity = assert(Sqlite.text_rows(db, "PRAGMA integrity_check"))
  assert(db:close())
  assert(integrity[1][1] == "ok", integrity[1][1])
  local listed = assert(Fs.list(root))
  assert(#listed == 2, table.concat(listed, " "))
  assert(not Fs.exists(root .. "/o"), "the build wrote into the source tree")
  local again = run(root, env, "again")
  assert(again.code == 0 and again.stdout == "from again\n", tostring(again.stderr))
  assert(build_paths.required(root, env) == output)
  assert(not tostring(again.stderr):find("cannot be written", 1, true), tostring(again.stderr))
  assert(sys.chmod(root, tonumber("755", 8) as integer))
end
