--- What build/must_confine_test.tl and build/must_confine_sandboxed_test.tl
--- share: a tree for a suite, the runs of `cosmic test` on it, and what such
--- a run prints of a refused start. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")

local record must_confine_fixture
  --- What a run printed and whether it passed.
  record Run
    text: string
    ok: boolean
  end
end

--- Makes `root`, a tree for a suite, with a stand-in program
--- (build/stand_in.tl) at bin/probe for its tests to start, which
--- declare it: in the tree, since a sandboxed worker has a /tmp of its
--- own over this test's.
function must_confine_fixture.suite_tree(tmp: string, root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), root .. "/bin/probe"))
end

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed and whether it passed.
function must_confine_fixture.run(root: string, output: string, env: {string:string},
                                  words?: {string}): must_confine_fixture.Run
  local fd = assert(Fs.open_write(output))
  local args: {string} = { "test" }
  for _, word in ipairs(words or {}) do args[#args + 1] = word end
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return { text = text, ok = result.ok }
end

--- The environment a suite runs in: the pinned one, with no verdict cache
--- shared, COSMIC_SANDBOX as `mode` has it, and its workers sandboxed
--- where they can be, whatever this run's switch: this one's own
--- sandbox may refuse theirs, which a run that requires one would fail
--- on.
function must_confine_fixture.environment(mode: string | nil): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_TEST_SANDBOX = nil
  env.COSMIC_SANDBOX = mode
  return env
end

--- The line a run printed for one failing test of `module`, from its
--- message on.
function must_confine_fixture.failure_of(text: string, module: string, name: string): string | nil
  return text:match("FAIL  suite%." .. module .. " " .. name .. ": ([^\n]*)")
end

--- What a run prints of a start refused in a worker held by a Landlock
--- ruleset, which the kernel refuses every mount: `bin/probe` cannot start
--- in a root of its own.
--- @param module the module whose worker is held
function must_confine_fixture.refusal(module: string): string
  return "bin/probe cannot start in a root of its own: " .. module .. "'s worker is held " ..
    "by a Landlock ruleset, under which the kernel refuses every mount; declare " ..
    "the promise \"nest\" in its Test.policy"
end

--- Makes `root`, a tree for a suite as [`suite_tree`] does, with `held_test.tl`
--- in it: three tests, of which a start in a root of its own, through
--- `confine` and through a sandbox of its own that unveils, fails in a
--- worker held by a Landlock ruleset, and a plain one passes.
function must_confine_fixture.held_suite(tmp: string, root: string)
  must_confine_fixture.suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")

Test.policy { grants = { { path = "bin/probe", letters = "r" } } }

local record Confine
  confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine
local type Searcher = function(string): any, any

local function raw(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("build.confine")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process
    end
  end
  error("no raw table")
end

local function test_confined(tmp: string)
  confine.confine({ reads = { "bin/probe" } })
  local ran, _ = Child.run({ "bin/probe", "write " .. tmp .. "/ran ran" })
  confine.confine(nil)
  assert(ran == nil, "an unconfined process ran in its place")
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
end

local function test_own_sandbox()
  local pid, _ = raw().spawn("bin/probe", { "bin/probe", "exit 0" }, nil, nil, nil, nil, nil,
    false, nil, { unveil = { reads = { "bin/probe" } }, offline = true })
  assert(pid == nil, "a process started in a root of its own")
end

local function test_plain()
  assert(Child.run({ "bin/probe", "exit 0" }))
end
]]))
end

return must_confine_fixture
