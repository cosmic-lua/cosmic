--- `cosmic.test`'s `needs` as it runs: what it refuses, and what it
--- keeps for `declared`. A test module may call `needs` only once, at
--- its top, so each case runs in a script of its own.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `body` as a script under this program, answering what it wrote.
local function run(tmp: string, body: string): string
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, 'local Fs = require("cosmic.fs")\n' ..
    'local T = require("cosmic.test")\n' ..
    "local function say(text: string) Fs.put(Fs.stdout, text .. \"\\n\") end\n" ..
    "return function(): integer\n" .. body .. "\n  return 0\nend\n"))
  local result = assert(Child.run({ assert(Proc.executable()), "--standalone", script },
    { env = observations.environment(), stdout = "capture", stderr = "capture",
      timeout_ms = 30000 }))
  assert(result.code == 0, tostring(result.stdout) .. tostring(result.stderr))
  return result.stdout or ""
end

--- A value no `Needs` could be is refused, saying why, and nothing is
--- kept of it.
local function test_needs_refuses_what_no_declaration_is(tmp: string)
  local said = run(tmp, table.concat({
    "  local cases: {any} = { 1, { reeds = {} }, { reads = \"a\" }, { reads = { 1 } },",
    "    { tool = \"yes\" }, { network = 3 }, { reads = true } }",
    "  for _, case in ipairs(cases) do",
    "    local ok, why = pcall(function(): string T.needs(case as T.Needs) return \"\" end)",
    "    say(tostring(ok) .. \" \" .. tostring(why):gsub(\"^.-cosmic%.test: \", \"\"))",
    "  end",
    "  say(tostring(T.declared()))",
  }, "\n"))
  assert(said == table.concat({
    "false needs takes a table, got number",
    "false needs has no field reeds",
    "false needs reads takes a list of strings",
    "false needs reads takes a list of strings",
    "false needs tool takes true or false",
    "false needs network takes a list of strings",
    "false needs reads takes a list of strings",
    "nil",
  }, "\n") .. "\n", said)
end

--- One call is kept for `declared`, as it was handed; a second is
--- refused.
local function test_needs_keeps_one_call(tmp: string)
  local said = run(tmp, table.concat({
    "  say(tostring(T.declared()))",
    "  T.needs { reads = { \"data/\" }, network = true, tool = false }",
    "  local got = assert(T.declared())",
    "  say(got.reads[1] .. \" \" .. tostring(got.network) .. \" \" .. tostring(got.tool))",
    "  local ok, why = pcall(function(): string T.needs { tool = true } return \"\" end)",
    "  say(tostring(ok) .. \" \" .. tostring(why):gsub(\"^.-cosmic%.test: \", \"\"))",
  }, "\n"))
  assert(said == "nil\ndata/ true false\n" ..
    "false needs is called once, at the top of a test module\n", said)
end
