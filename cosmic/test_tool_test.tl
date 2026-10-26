--- The cases of cosmic/test_test.tl about [`cosmic.test`]'s `policy` as it
--- runs: what it refuses, and what it hands a runner. A test module may
--- call `policy` only once, at its top, so each case runs in a script of
--- its own, which plays the runner through the hook [`build.test_worker`]
--- installs. They declare `lua` because they start this program only to run
--- a script standalone.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")

--- The program itself, which its tests start to run a file `--standalone`
--- ([`build.standalone`]).
Test.policy{ profiles = { "cosmic" } }

--- Runs `body` as a script under this program, with a runner installed
--- that says what `policy` stands for, answering what it wrote. The cases
--- hand `policy` what no `Policy` is, which no typed script would run: the
--- script loads them as a chunk of Lua text.
local function run(tmp: string, body: string): string
  local script = tmp .. "/script.tl"
  local cases = table.concat({
    'local Fs = require("cosmic.fs")',
    'local T = require("cosmic.test")',
    "local function say(text) Fs.put(Fs.stdout, text .. \"\\n\") end",
    "local runner = { loaded = false, handed = function(needs)",
    "  say(\"handed \" .. tostring((needs.reads or {})[1]) .. \" \" ..",
    "    tostring((needs.network or {})[1]) .. \" \" .. tostring(needs.tool))",
    "end }",
    "T.__runner = runner",
    "local function try(f)",
    "  local ok, why = pcall(function() f() return \"\" end)",
    "  return tostring(ok) .. \" \" .. (tostring(why):gsub(\"^.-: test: \", \"\"))",
    "end",
    body,
  }, "\n")
  assert(Fs.write(script, table.concat({
    "local Globals = require(\"cosmic.internal.globals\")",
    "return function(): integer",
    "  local chunk = assert(load(" .. string.format("%q", cases) .. ", \"=script.tl\", \"t\", Globals.table()))",
    "  chunk()",
    "  return 0",
    "end",
  }, "\n") .. "\n"))
  local started = this_program.program({ "--standalone", script },
    { stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stdout) .. tostring(result.stderr))
  return result.stdout or ""
end

--- `policy` hands the runner the `needs` its policy stands for, and is
--- refused, saying why, for what no `Policy` could be or no `needs` could
--- stand for; a second call is refused, naming where the first was made, as
--- is one once the module has loaded. Which fields it translates, and how a
--- build reads it, are cosmic/test_policy_test.tl's.
local function test_policy_hands_the_runner_its_needs(tmp: string)
  local said = run(tmp, table.concat({
    "  local cases = { 1, { reeds = {} }, { env = \"a\" }, { isolate = { \"file\" } },",
    "    { grants = { { path = \"d\", letters = \"rw\" } } } }",
    "  for _, case in ipairs(cases) do",
    "    say(try(function() T.policy(case) end))",
    "  end",
    "  T.policy { grants = { { path = \"data/\", letters = \"r\" }, { path = \"o/bin\", letters = \"rx\" } },",
    "    profiles = { \"cosmic\" }, loopback = { \"127.0.0.1\" }, promises = { \"fork\" } }",
    "  say(try(function() T.policy { } end))",
    "  runner.loaded = true",
    "  say(try(function() T.policy { } end))",
  }, "\n"))
  local lines: mut {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 8, said)
  assert(lines[1] == "false policy takes a table, got number", said)
  assert(lines[2]:find("^false policy has no field reeds; it has connect, database, env") ~= nil, said)
  assert(lines[3] == "false policy env takes a list of strings", said)
  assert(lines[4]:find("^false policy isolate is not yet taken") ~= nil, said)
  assert(lines[5]:find("^false policy grants%[1%]%.letters \"rw\" is not yet taken") ~= nil, said)
  assert(lines[6] == "handed data/ 127.0.0.1 true", said)
  assert(lines[7]:match("^false policy is called once, and .*script%.tl:%d+ called it already; " ..
      "a test module never requires another that calls it$") ~= nil, said)
  assert(lines[8] == "false policy is called at the top of a test module, while it loads", said)
end
