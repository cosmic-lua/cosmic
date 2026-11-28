--- [`cosmic.agent.worker`]'s [`Worker.program`] under the policy of the agent's tools: Linux's alone, where a snippet
--- without commands may run this program (macOS keeps every `x` grant, so it refuses there).
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Policy = require("cosmic.agent.policy")
local Sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Worker = require("cosmic.agent.worker")

Test.policy{ profiles = { "cosmic", "proc" }, grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } },
  env = { "PATH", "TMPDIR" }, timeout = 60, requires = { "os:linux" } }

--- Under the agent's sandbox, [`Worker.program`] runs this program's own tests, which start it again, and no other
--- program; it refuses a program a snippet could write, and holds a link to the program as the file it names.
local function test_the_program_runs_under_the_policy_of_the_tools_and_only_itself()
  -- Under a policy the child's environment is the policy's, so the set carries none of its own: this program, bare.
  local w = Worker.new()
  local dir = assert(Fs.mkdtemp("agent-program-"))
  assert(Fs.write(dir .. "/money.tl", "local record Money\n  cents: integer\nend\n\nreturn Money\n"))
  assert(Fs.write(dir .. "/money_test.tl", "local _ = require(\"money\")\n\nlocal function test_cents()\n" ..
      "  assert(1 + 1 == 2)\nend\n"))
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local tested = assert(Worker.program(w, { "test" }, dir, p, 60 * 1000000000))
  local tested_out = tested.stdout or ""
  assert(tested.ok and tested_out:find("1 test passed", 1, true) ~= nil, tested_out)
  -- No other program runs, though the policy grants the system's files.
  local code = "local Child = require(\"cosmic.child\")\n" ..
    "local r, _ = Child.run({ \"/bin/sh\", \"-c\", \"true\" }, { timeout_ns = 10000000000 })\n" ..
    "print(\"ran: \" .. tostring(r ~= nil and r.ok))\n"
  local other = assert(Worker.program(w, { "-e", code }, dir, p, 60 * 1000000000))
  local other_out = other.stdout or ""
  assert(other_out:find("ran: false", 1, true) ~= nil, other_out)
  -- The program runs as its core, so its own file may lie where a snippet writes (a tree that carries its tool):
  -- the file is granted no `x`, and a snippet that runs it directly is refused.
  local program = assert(Sys.realpath(w.argv[1]!))
  local core = assert(Child.core(), "this program runs as a core")
  local over = assert(Policy.of(dir, { mode = "write", network = false,
    grants = { { path = Fs.dirname(program), letters = "rw" } } }))
  local exec = "local sys = require(\"cosmic.sys\")\n" ..
    "local done, _, errno = sys.execve(" .. string.format("%q", program) .. ", { \"cosmic\", \"--version\" }, {})\n" ..
    "print(\"exec refused: \" .. tostring(not done and (errno == sys.EPERM or errno == sys.EACCES)))\n"
  local carried = assert(Worker.program(w, { "test" }, dir, over, 60 * 1000000000))
  local carried_out = carried.stdout or ""
  assert(carried.ok and carried_out:find("1 test passed", 1, true) ~= nil, carried_out)
  local inside = assert(Worker.program(w, { "-e", exec }, dir, over, 60 * 1000000000))
  local inside_out = inside.stdout or ""
  assert(inside_out:find("exec refused: true", 1, true) ~= nil, inside_out)
  -- A core a snippet could write is refused: what it wrote would run.
  local over_core = assert(Policy.of(dir, { mode = "write", network = false,
    grants = { { path = Fs.dirname(core), letters = "rw" } } }))
  local refused, why = Worker.program(w, { "--version" }, dir, over_core, 60 * 1000000000)
  assert(refused == nil and tostring(why):find("lies where a snippet may write", 1, true) ~= nil, tostring(why))
  Worker.close(w)
  -- A link in the tree that writes is the program it names, which lies outside it.
  assert(Fs.symlink(program, dir .. "/cosmic"))
  local argv: mut {string} = {}
  for _, word in ipairs(w.argv) do argv[#argv + 1] = word end
  argv[1] = dir .. "/cosmic"
  local linked = Worker.new(argv)
  local through = assert(Worker.program(linked, { "--version" }, dir, p, 60 * 1000000000))
  assert(through.ok, through.stdout)
  Worker.close(linked)
end
