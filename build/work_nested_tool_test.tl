--- [`build.work`]'s test that starts `cosmic test` beside this process, in
--- a project reached through links. Apart from build/work_test.tl's so
--- those stand while the tree moves, and from build/work_tool_test.tl's,
--- whose second build needs no sandbox: the workers of this run nest in
--- this test's own, so the module is not applicable off Linux and skipped
--- where the host gives no nest (`requires`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local confine = require("build.confine")
local Test = require("cosmic.test")

--- The program itself, which its test starts, and roots of their own for
--- the sandboxed workers of the run it starts (`nests`).
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  requires = { "nest" },
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
  if not out:find("; sandboxed", 1, true) then Test.skip(confine.unsandboxed_reason(out)) end
end
