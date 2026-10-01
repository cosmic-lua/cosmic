--- The cases of cosmic/test_test.tl about [`cosmic.test`]'s `needs` as it
--- runs: what it refuses, and what it hands a runner. A test module may
--- call `needs` only once, at its top, so each case runs in a script of
--- its own, which plays the runner through the hook [`build.test_worker`]
--- installs. They declare `lua` because they start this program only to run
--- a script standalone.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local Time = require("cosmic.time")

--- The program itself, which its tests start to run a file `--standalone`
--- (`standalone`).
Test.needs{ lua = true, standalone = true }

--- Runs `body` as a script under this program, with a runner installed
--- that says what `needs` is handed, answering what it wrote.
local function run(tmp: string, body: string): string
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, table.concat({
    'local Fs = require("cosmic.fs")',
    'local T = require("cosmic.test")',
    "local function say(text: string) Fs.put(Fs.stdout, text .. \"\\n\") end",
    "local runner = { loaded = false, handed = function(needs: T.Needs)",
    "  say(\"handed \" .. tostring(needs.reads and needs.reads[1]) .. \" \" ..",
    "    tostring(needs.network and needs.network[1]) .. \" \" .. tostring(needs.tool))",
    "end }",
    "local hooks = T as {string:any}",
    "hooks.__runner = runner",
    "local function try(f: function()): string",
    "  local ok, why = pcall(function(): string f() return \"\" end)",
    "  return tostring(ok) .. \" \" .. (tostring(why):gsub(\"^.-cosmic%.test: \", \"\"))",
    "end",
    "return function(): integer",
    body,
    "  return 0",
    "end",
  }, "\n") .. "\n"))
  local started = this_program.program({ "--standalone", script },
    { stdout = "capture", stderr = "capture",
      timeout_ns = Time.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stdout) .. tostring(result.stderr))
  return result.stdout or ""
end

--- A value no `Needs` could be is refused, saying why, and nothing of it
--- reaches the runner.
local function test_needs_refuses_what_no_declaration_is(tmp: string)
  local said = run(tmp, table.concat({
    "  local cases: {any} = { 1, { reeds = {} }, { reads = \"a\" }, { reads = { 1 } },",
    "    { tool = \"yes\" }, { network = 3 }, { network = { 3 } }, { reads = true },",
    "    { network = true }, { network = { \"127.0.0.1\", \"::1\" } },",
    "    { network = { \"localhost\" } }, { network = { \"example.com\" } } }",
    "  for _, case in ipairs(cases) do",
    "    say(try(function() T.needs(case as T.Needs) end))",
    "  end",
  }, "\n"))
  assert(said == table.concat({
    "false needs takes a table, got number",
    "false needs has no field reeds",
    "false needs reads takes a list of strings",
    "false needs reads takes a list of strings",
    "false needs tool takes true or false",
    "false needs network takes a list of strings",
    "false needs network takes a list of strings",
    "false needs reads takes a list of strings",
    "false needs " .. Test.any_host_refusal,
    "false needs " .. Test.network_trouble("::1"),
    "false needs " .. Test.network_trouble("localhost"),
    "false needs " .. Test.network_trouble("example.com"),
  }, "\n") .. "\n", said)
end

--- One call reaches the runner as it was handed; a second is refused,
--- naming where the first was made, as is one once the module has
--- loaded.
local function test_needs_is_called_once_while_the_module_loads(tmp: string)
  local said = run(tmp, table.concat({
    "  T.needs { reads = { \"data/\" }, network = { \"127.0.0.1\" }, tool = false }",
    "  say(try(function() T.needs { tool = true } end))",
    "  runner.loaded = true",
    "  say(try(function() T.needs { tool = true } end))",
  }, "\n"))
  local lines: {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 3, said)
  assert(lines[1] == "handed data/ 127.0.0.1 false", said)
  assert(lines[2]:match("^false needs is called once, and .*script%.tl:15 called it already; " ..
    "a test module never requires another that calls it$") ~= nil, said)
  assert(lines[3] == "false needs is called at the top of a test module, while it loads", said)
end
