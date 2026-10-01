--- The case of test/coverage_native_test.tl about a process's first
--- coverage window, which only a fresh process shows: it declares
--- `lua` because it starts this program only to run a script
--- standalone.

local Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its test starts to run a file `--standalone`
--- (`standalone`).
Test.needs{ lua = true, standalone = true }

--- A process's first window keeps the C that ran before it opened --
--- startup -- and every later one starts empty. Run in a fresh process,
--- since this test's own worker opened its first window long ago.
local function test_first_window_keeps_startup(tmp: string)
  if next(Coverage.native_lines()) == nil then return end
  local script = tmp .. "/windows.tl"
  assert(Fs.write(script, [[
local Coverage = require("cosmic.coverage")
local function main_hits(): integer
  local session = assert(Coverage.start())
  local hits = assert(Coverage.stop(session))
  local count = 0
  for _ in pairs(hits["core/main.c"] or {}) do count = count + 1 end
  return count
end
return function(): integer
  print(main_hits(), main_hits())
  return 0
end
]]))
  local started = this_program.program({ "--standalone", script },
    { env = this_program.environment(), cwd = tmp, stdout = "capture", stderr = "capture",
      timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stderr))
  local out = assert(r.stdout)
  local first, second = out:match("^(%d+)\t(%d+)\n$")
  assert(first ~= nil and second ~= nil, "unexpected output: " .. out)
  assert(first ~= "0", "the first window saw no startup in core/main.c")
  assert(second == "0", "a later window kept startup: " .. second)
end
