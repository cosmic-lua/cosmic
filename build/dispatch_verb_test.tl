--- A verb's command line loads that verb's module of [`cosmic.cli`] alone: [`cosmic.cli`] loads every verb's. This is a
--- module of its own because it names [`build.dispatch`]: the program its child runs as is then sealed with the
--- compiler, and a child of that costs seconds of CPU time before its first line, which a module of cheap children
--- (see [`build.dispatch_tool_test`]) must not pay.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local test_child = require("build.test_child")

--- The program itself, started with `-e`.
Test.policy{ profiles = { "cosmic" } }

--- What a child that did not succeed did: how it ended, then what it printed. A failure line a log cuts short
--- still says whether the child timed out, was killed or exited with a status.
local function ended(r: Child.Result): string
  local how = if r.timed_out then "timed out" elseif r.signal ~= nil then "killed by signal " .. tostring(r.signal)
    else "exited with status " .. tostring(r.code) end
  return how .. "; stderr: " .. tostring(r.stderr) .. "; stdout: " .. tostring(r.stdout)
end

--- The child of [`test_a_verb_loads_its_own_cli_module_alone`]: runs `cosmic rand int 1 1` in this process, then
--- prints the names of the modules loaded.
test_child.register("verb_loaded", function(_args: {string}): integer
  local code = require("build.dispatch").main({ "rand", "int", "1", "1" })
  print(test_child.loaded())
  return code
end)

--- A verb's command line loads that verb's module of [`cosmic.cli`] alone: [`cosmic.cli`] loads every verb's.
local function test_a_verb_loads_its_own_cli_module_alone(tmp: string)
  local started = Test.cosmic(test_child.words(tmp, "build.dispatch_verb_test", "verb_loaded"),
    { env = {}, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, ended(r))
  local loaded = " " .. ((r.stdout or ""):gsub("\n", " ")) .. " "
  local clis: mut {string} = {}
  for name in loaded:gmatch("%S+") do
    if name == "cosmic.cli" or name:sub(1, 11) == "cosmic.cli." then clis[#clis + 1] = name end
  end
  assert(#clis == 1 and clis[1] == "cosmic.cli.rand", "`cosmic rand` loads " .. table.concat(clis, ", "))
end
