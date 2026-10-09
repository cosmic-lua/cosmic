--- `cosmic <file.tl>`, run as this program, where the tree cannot be
--- written (another user's, a read-only checkout): it builds, as every
--- tree does, in a build directory of this user's cache of its own for
--- the tree ([`build.paths`]), and reuses it the next run.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local build_paths = require("build.paths")

--- The program itself, which builds the tree around the file it runs.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Runs `file` in `root` with this user's cache under `cache`, and no
--- COSMIC_BUILD_HOME, so the build directory is that cache's.
local function run(root: string, cache: string, file: string, word: string): Child.Result
  local env = this_program.environment()
  env.XDG_CACHE_HOME = cache
  env.COSMIC_BUILD_HOME = nil
  local started = this_program.program({ file, word }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_a_tree_that_cannot_be_written_builds_in_the_cache(tmp: string)
  if sys.getuid() == 0 then
    Test.skip("this process is root, which writes whatever the mode says, so a mode holds no root back")
    return
  end
  local root = tmp .. "/project"
  local cache = tmp .. "/cache"
  assert(Fs.mkdirs(root) and Fs.mkdirs(cache))
  assert(Fs.write(root .. "/main.tl", 'local helper = require("helper")\n' ..
      'return function(argv: {string}): integer\n  print(helper .. argv[1])\n  return 0\nend\n'))
  assert(Fs.write(root .. "/helper.tl", 'return "from "\n'))
  assert(sys.chmod(root, tonumber("555", 8) as integer))
  local first = run(root, cache, "main.tl", "here")
  assert(first.code == 0 and first.stdout == "from here\n", tostring(first.stderr))
  local directory = assert(build_paths.directory(root, { XDG_CACHE_HOME = cache }))
  assert(Fs.within(directory, assert(sys.realpath(cache)) .. "/cosmic/trees"), directory)
  assert(Fs.exists(directory .. "/cosmic.db"), "it built nowhere in the cache")
  local listed = assert(Fs.list(root))
  assert(#listed == 2, "it wrote into the tree it could not write")
  local again = run(root, cache, "main.tl", "again")
  assert(again.code == 0 and again.stdout == "from again\n", tostring(again.stderr))
  assert(sys.chmod(root, tonumber("755", 8) as integer))
end
