--- The case of cosmic/log_test.tl that runs a script under this
--- program, to see where each line lands. It declares `lua` because
--- it starts this program only to run a script standalone.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.needs{ lua = true }

--- Runs `body` as a standalone script and answers what it wrote.
local function run(tmp: string, body: string): string, string
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, 'local Log = require("cosmic.log")\n' .. body))
  local started = this_program.program({ "--standalone", script },
    { stdout = "capture", stderr = "capture",
      timeout_ms = 30000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  return result.stdout or "", result.stderr or ""
end

local function test_lines_go_where_they_belong(tmp: string)
  local out, err = run(tmp, [[
local log = Log.new("notes")
log:say("found 2")
log:complain("no such note: 9")
log:verdict("rm", false, "no such note")
log:verdict("ls", true, "2 notes, 3 ms")
log:verdict("build", false)
log:verdict("fix", true, "")
]])
  assert(out == "found 2\nrm: FAIL (no such note)\nls: PASS (2 notes, 3 ms)\n" ..
    "build: FAIL\nfix: PASS\n", out)
  assert(err == "notes: no such note: 9\n", err)
end
