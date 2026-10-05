--- `cosmic <file.tl>`, run as this program, where the tree's o/ cannot be
--- written (another user's, a read-only checkout): it builds into a
--- directory of this user's cache of its own for the tree instead, says
--- so, and reuses it the next run (build/dispatch.tl's `private_dir`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program itself, which builds the tree around the file it runs.
Test.needs{ tool = true }

--- Runs `file` in `root` with this user's cache under `cache`.
local function run(root: string, cache: string, file: string, word: string): Child.Result
  local env = this_program.environment()
  env.XDG_CACHE_HOME = cache
  local started = this_program.program({ file, word }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_a_tree_whose_o_cannot_be_written_builds_in_the_cache(tmp: string)
  -- Root writes whatever the mode says, so a mode holds no root back.
  if sys.getuid() == 0 then return end
  local root = tmp .. "/project"
  local cache = tmp .. "/cache"
  assert(Fs.mkdirs(root .. "/o") and Fs.mkdirs(cache))
  assert(Fs.write(root .. "/main.tl", 'local helper = require("helper")\n' ..
      'return function(argv: {string}): integer\n  print(helper .. argv[1])\n  return 0\nend\n'))
  assert(Fs.write(root .. "/helper.tl", 'return "from "\n'))
  assert(sys.chmod(root .. "/o", tonumber("555", 8) as integer))
  local first = run(root, cache, "main.tl", "here")
  assert(first.code == 0 and first.stdout == "from here\n", tostring(first.stderr))
  assert(tostring(first.stderr):find("cannot be written; building into " .. cache, 1, true),
    tostring(first.stderr))
  local listed = assert(Fs.list(root .. "/o"))
  assert(#listed == 0, "it wrote into the o/ it could not write")
  local again = run(root, cache, "main.tl", "again")
  assert(again.code == 0 and again.stdout == "from again\n", tostring(again.stderr))
  assert(sys.chmod(root .. "/o", tonumber("755", 8) as integer))
end
