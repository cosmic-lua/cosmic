--- [`build.work`]'s test that starts the program beside this process: a
--- second build of a tree one holds. Apart from build/work_test.tl's so those
--- stand while the tree moves; `cosmic test` in a project reached through
--- links is in build/work_nested_tool_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local work = require("build.work")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

--- A second process building the same tree waits for the first's
--- transaction instead of failing with "database is locked": two builds
--- of one tree at once, from two terminals or two parallel tests, both
--- finish.
local function test_a_second_build_of_a_tree_waits_for_the_first(tmp: string)
  assert(Fs.write(tmp .. "/main.tl", "return function(): integer return 0 end\n"))
  local held = assert(work.open(tmp))
  local output = tmp .. "/second.out"
  local fd = assert(Fs.open_write(output))
  local build = this_program.program({ "main.tl" },
    { cwd = tmp, stdout = fd, stderr = fd })
  local second, trouble = Child.start(build.argv, build.options)
  assert(Fs.close(fd))
  assert(second, trouble)
  assert(Clock.sleep_ns(300000000))
  assert(work.abort(held))
  local result = assert(second:wait(Clock.seconds(60)))
  assert(result.ok, "the second build failed: " .. (Fs.read(output) or ""))
end

--- A warmed compiled source cannot hide a rewrite behind a normalized mtime.
local function test_a_settled_source_rewrite_runs_new_bytecode(tmp: string)
  local path = tmp .. "/main.tl"
  assert(Fs.write(path, 'print("OLD")\n'))
  assert(Fs.set_mtime(path, 0, 0))
  local function run(): string
    local started = this_program.program({ "main.tl" }, { cwd = tmp,
      env = this_program.environment(), stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(60) })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.ok, result.stdout .. result.stderr)
    return result.stdout
  end
  assert(run() == "OLD\n")
  local handle = assert(work.open(tmp))
  local now = Clock.now_ns
  Clock.now_ns = function(): integer return now() + Clock.seconds(3) end
  local ok, staged, trouble = pcall(work.stage, handle, false)
  Clock.now_ns = now
  assert(ok and staged ~= nil, tostring(trouble))
  assert(work.close(handle))
  assert(run() == "OLD\n")
  local before = assert(Fs.stat(path))
  local fd = assert(Fs.open_write(path))
  assert(Fs.put(fd, 'print("NEW")\n'))
  assert(Fs.close(fd))
  assert(Fs.set_mtime(path, 0, 0))
  local after = assert(Fs.stat(path))
  assert(after.size == before.size and after.ino == before.ino)
  assert(run() == "NEW\n", "the preserved mtime must not reuse OLD bytecode")
end
