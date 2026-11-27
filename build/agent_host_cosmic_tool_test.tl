--- Host.uses, Host.unused, Host.rename and Host.test, which run this program's own verbs (`cosmic uses`, `cosmic fix`, `cosmic test`) for a snippet, with
--- commands or without ([`cosmic.agent.worker`]'s [`Worker.program`]). They build a tree, so they start the tool itself,
--- which these tests read and run (o/bin), and the tests that run start workers of their own (`nest`).
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Policy = require("cosmic.agent.policy")
local Sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")

Test.policy{ profiles = { "cosmic", "proc" }, grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } },
  env = { "PATH", "TMPDIR" }, timeout = 60 }

--- A set whose worker is `cosmic agent worker` of the tool.
local function set_of_worker(): Worker.Set
  local started = Test.cosmic({ "agent", "worker" }, { env = Test.environment(), timeout_ns = -1 })
  return Worker.new(started.argv, started.options)
end

local function tools_run(name: string, input: {string: Json.Value}, context: Tools.Context): Tools.Result
  return Tools.run(name, input, context)
end

local function test_a_snippet_finds_a_symbols_uses_and_runs_the_tests_without_commands()
  local w = set_of_worker()
  local dir = assert(Fs.mkdtemp("agent-worker-"))
  assert(Fs.write(dir .. "/money.tl", "local record Money\n  cents: integer\nend\n\n" ..
      "--- `12.34`.\nfunction Money.format(m: Money): string\n  return string.format(\"%d.%02d\", m.cents // 100, " ..
      "m.cents % 100)\nend\n\nreturn Money\n"))
  assert(Fs.write(dir .. "/money_test.tl", "local M = require(\"money\")\n\nlocal function test_format()\n" ..
      "  -- format the cents\n  assert(M.format({ cents = 1234 }) == \"12.34\")\nend\n"))
  local context: Tools.Context = { cwd = dir, worker = w }
  local ran = tools_run("run", { code = [[
for _, h in ipairs(Host.uses("Money.format")) do print(h.path .. ":" .. tostring(h.line) .. ": " .. h.text) end
print(#Host.uses("nothing_has_this"))
local r = Host.test()
print(r.ok, r.output:find("1 test passed", 1, true) ~= nil)
print("unused: " .. table.concat(Host.unused(), " "))
local renamed = Host.rename("Money.format", "render")
print("renamed:", renamed.ok, #Host.uses("Money.render"))
local _, run_why = Host.call("cosmic", { verb = "run", args = Json.array() })
local _, flag_why = Host.call("cosmic", { verb = "test", args = Json.array({ "--profile", "x" }) })
local _, out_why = Host.call("cosmic", { verb = "uses", args = Json.array({ "../x" }) })
local _, fix_why = Host.call("cosmic", { verb = "fix", args = Json.array({ "." }) })
print(run_why, flag_why, out_why, fix_why)
]] }, context)
  -- The alias M is a use, and the comment's word is none.
  assert(not ran.is_error and ran.text:find("^money_test.tl:5:   assert%(M.format") ~= nil, ran.text)
  assert(ran.text:find("format the cents", 1, true) == nil, ran.text)
  assert(ran.text:find("\n0\ntrue\ttrue\n", 1, true) ~= nil, ran.text)
  -- A use in a test leaves an export unused.
  assert(ran.text:find("\nunused: Money.format\n", 1, true) ~= nil, ran.text)
  -- A rename reaches the use through the alias M, and the tree builds after.
  assert(ran.text:find("\nrenamed:\ttrue\t1\n", 1, true) ~= nil, ran.text)
  local test_text = assert(Fs.read(dir .. "/money_test.tl"))
  assert(test_text:find("M.render({ cents = 1234 })", 1, true) ~= nil, test_text)
  -- Only cosmic's own verbs run, and their words are no flags nor paths out of the tree.
  assert(ran.text:find("no verb a snippet may run", 1, true) ~= nil, ran.text)
  assert(ran.text:find("--profile is no name or path in the tree", 1, true) ~= nil, ran.text)
  assert(ran.text:find("../x is no name or path in the tree", 1, true) ~= nil, ran.text)
  -- fix runs only as a rename.
  assert(ran.text:find("cosmic fix runs here only as fix --rename", 1, true) ~= nil, ran.text)
  Worker.close(w)
end

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
  -- A program under a grant that writes is refused: a snippet could write what then runs.
  local program = assert(Sys.realpath(w.argv[1]!))
  local over = assert(Policy.of(dir, { mode = "write", network = false,
    grants = { { path = Fs.dirname(program), letters = "rw" } } }))
  local refused, why = Worker.program(w, { "--version" }, dir, over, 60 * 1000000000)
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
