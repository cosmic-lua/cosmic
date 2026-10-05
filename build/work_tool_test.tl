--- [`build.work`]'s tests that start the program beside this process: a
--- second build of a tree one holds, and `cosmic test` in a project
--- reached through links. Apart from build/work_test.tl's so those
--- stand while the tree moves.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local work = require("build.work")
local confine = require("build.confine")
local Test = require("cosmic.test")

--- The program itself, which its tests start, and roots of their own for
--- the sandboxed workers of a run they start (`nests`).
Test.policy{
  profiles = { "cosmic" },
  promises = { "nest" },
}

--- A project whose module directory and one test are links into a
--- tree beside it, and a `loop -> .`: `tmp/project`.
local function linked_project(tmp: string): string
  local project = tmp .. "/project"
  assert(Fs.mkdirs(tmp .. "/shared/lib"))
  assert(Fs.mkdirs(project))
  assert(Fs.write(tmp .. "/shared/lib/util.tl", "local util = {}\nutil.answer = 42\nreturn util\n"))
  assert(Fs.write(tmp .. "/shared/linked_test.tl",
    'local util = require("lib.util")\n\nlocal function test_linked()\n  assert(util.answer == 42)\nend\n'))
  assert(Fs.write(project .. "/main_test.tl",
    'local util = require("lib.util")\n\nlocal function test_main()\n  assert(util.answer == 42)\nend\n'))
  assert(Fs.symlink("../shared/lib", project .. "/lib"))
  assert(Fs.symlink("../shared/linked_test.tl", project .. "/linked_test.tl"))
  assert(Fs.symlink(".", project .. "/loop"))
  return project
end

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

--- `cosmic test` in such a project compiles the linked modules and runs
--- the linked test beside its own -- sandboxed where it can be, whose
--- sandbox gives each file of a closure at the linked path it is staged
--- under (build/test_sandbox.tl). Its workers are nested in this test's
--- own sandbox, which the kernel lets root nest only two deep: where
--- they had none, it is skipped ([`Test.skip`]), which only a run held to
--- sandboxing fails.
local function test_cosmic_test_runs_a_project_reached_through_links(tmp: string)
  local project = linked_project(tmp)
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = nil
  local started = this_program.program({ "test" }, {
    cwd = project, env = env, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  local out = (result.stdout or "") .. (result.stderr or "")
  assert(result.code == 0, out)
  assert(out:find("(2 tests, 2 modules", 1, true), out)
  if not out:find("; sandboxed", 1, true) then
    if confine.sandbox_platform() then Test.skip(confine.unsandboxed_reason(out)) end
  end
end
