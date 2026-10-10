--- build.confine's `forbid_running`, the hold on what a process may run,
--- which is a Landlock ruleset and so a host with Landlock's
--- (`requires`: only Linux has it).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")

--- /proc, where the stand-in program a test starts finds itself; `nests`,
--- since the process it holds has a root of its own; and the program
--- itself, which the hold names.
Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  requires = { "landlock" },
}

--- `forbid_running` given `within`, the paths a process the policy holds may
--- run, since it cannot list /: the program is refused by its own name, by
--- a link to it and by /proc/self/exe, and a sibling program, in a directory
--- it is told, still runs. A process of its own takes the hold, which
--- lasts for good.
local function test_forbid_running_within_refuses_the_program_by_every_name(tmp: string)
  local sibling = assert(stand_in.build(tmp .. "/sibling/stand-in"))
  local program = confine.itself()[1]
  assert(Fs.mkdirs(tmp .. "/links"))
  assert(Fs.symlink(program, tmp .. "/links/program"))
  local within = { Fs.dirname(sibling), tmp .. "/links", Fs.dirname(program) }
  local chunk = string.format([=[
local Child = require("cosmic.child")
local confine = require("build.confine")
local ok, why = confine.forbid_running(confine.itself(), %s)
assert(ok, why)
local function ran(argv)
  local result, trouble = Child.run(argv)
  if result == nil then return trouble end
  return "ran " .. tostring(result.code)
end
local out = {
  "program " .. ran({ %q }),
  "link " .. ran({ %q }),
  "exe " .. ran({ "/proc/self/exe" }),
  "sibling " .. ran({ %q, "exists / 3" }),
}
require("cosmic.fs").put(1, table.concat(out, "\n"))
]=], "{ " .. string.format("%q, %q, %q", within[1], within[2], within[3]) .. " }",
    program, tmp .. "/links/program", sibling)
  local started = this_program.program({ "-e", chunk }, { stdout = "capture", stderr = "stdout" })
  local result = assert(Child.run(started.argv, started.options))
  local said = assert(result.stdout)
  assert(said:find("program child: start: Permission denied", 1, true), said)
  assert(said:find("link child: start: Permission denied", 1, true), said)
  assert(said:find("exe child: start: Permission denied", 1, true), said)
  assert(said:find("sibling ran 3", 1, true), said)
end
