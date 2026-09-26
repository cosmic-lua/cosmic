--- `cosmic.test`'s `needs` as it runs: what it refuses, and what it
--- hands a runner. A test module may call `needs` only once, at its top,
--- so each case runs in a script of its own, which plays the runner
--- through the hook `build.test_worker` installs.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

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
    "    tostring(needs.network) .. \" \" .. tostring(needs.tool))",
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
  local result = assert(Child.run({ assert(Proc.executable()), "--standalone", script },
    { env = observations.environment(), stdout = "capture", stderr = "capture",
      timeout_ms = 30000 }))
  assert(result.code == 0, tostring(result.stdout) .. tostring(result.stderr))
  return result.stdout or ""
end

--- A value no `Needs` could be is refused, saying why, and nothing of it
--- reaches the runner.
local function test_needs_refuses_what_no_declaration_is(tmp: string)
  local said = run(tmp, table.concat({
    "  local cases: {any} = { 1, { reeds = {} }, { reads = \"a\" }, { reads = { 1 } },",
    "    { tool = \"yes\" }, { network = 3 }, { network = { 3 } }, { reads = true } }",
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
    "false needs network takes true, false or a list of hosts",
    "false needs network takes true, false or a list of hosts",
    "false needs reads takes a list of strings",
  }, "\n") .. "\n", said)
end

--- One call reaches the runner as it was handed; a second is refused,
--- naming where the first was made, as is one once the module has
--- loaded.
local function test_needs_is_called_once_while_the_module_loads(tmp: string)
  local said = run(tmp, table.concat({
    "  T.needs { reads = { \"data/\" }, network = true, tool = false }",
    "  say(try(function() T.needs { tool = true } end))",
    "  runner.loaded = true",
    "  say(try(function() T.needs { tool = true } end))",
  }, "\n"))
  local lines: {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 3, said)
  assert(lines[1] == "handed data/ true false", said)
  assert(lines[2]:match("^false needs is called once, and .*script%.tl:15 called it already; " ..
    "a test module never requires another that calls it$") ~= nil, said)
  assert(lines[3] == "false needs is called at the top of a test module, while it loads", said)
end

--- Each field `Needs` has is one `fields` names, taking what the type
--- does, so the checks the build and `needs` make keep to the type.
local function test_every_field_of_needs_is_one_fields_names()
  local every: Test.Needs = {
    reads = {}, host = {}, env = {}, network = true, processes = true, tool = true,
    store = true,
  }
  local want: {string:string} = {
    reads = "list", host = "list", env = "list", network = "either",
    processes = "flag", tool = "flag", store = "flag",
  }
  local count = 0
  for name in pairs(every as {string:any}) do
    count = count + 1
    assert(Test.fields[name] == want[name], name)
  end
  for _ in pairs(Test.fields) do count = count - 1 end
  assert(count == 0, "fields names one Needs does not have")
end
