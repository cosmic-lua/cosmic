--- `cosmic test` prunes the build directories beside its checkout's
--- ([`build.cache_lifetime`]): the pass itself is
--- build/cache_lifetime_test.tl's.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, whose run of `test` prunes.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A run in a project prunes the directory of one no run has used for
--- over thirty days, says so, and leaves its own and a recent one's.
--- Its workers run unsandboxed (`COSMIC_TEST_SANDBOX=0`), as
--- `rebuild_lock_tool_test.tl`'s do.
local function test_a_test_run_prunes_a_stale_build_directory(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/ok_test.tl", "local function test_ok()\n  assert(true)\nend\n"))
  local own = assert(build_paths.prepare(root))
  local base = Fs.dirname(own)
  local function sibling(name: string, days: integer): string
    local directory = build_paths.in_home("/projects/" .. name, base)
    assert(Fs.mkdirs(directory .. "/bin"))
    assert(Fs.write(directory .. "/build.db", "x"))
    local used = build_paths.under(directory).used
    assert(Fs.write(used, ""))
    assert(sys.utimensat(used, nil, nil, Clock.now_ns() // 1000000000 - days * 24 * 3600, 0))
    return directory
  end
  local stale, recent = sibling("stale", 40), sibling("recent", 2)
  local output = tmp .. "/run.out"
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  local result = assert(h:wait(Clock.seconds(60)))
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("test: removed 1 build directory unused for thirty days", 1, true), text)
  assert(not Fs.exists(stale), "the stale build directory stayed")
  assert(Fs.exists(recent .. "/build.db"), "a recent build directory went")
  assert(Fs.exists(own), "the run's own build directory went")
end
