local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

--- Runs `body` as a standalone script and answers what it wrote.
local function run(tmp: string, body: string): string, string
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, 'local Log = require("cosmic.log")\n' .. body))
  local result = assert(Child.run({ assert(Proc.executable()), "--standalone", script },
    { stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
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

local function test_a_logger_needs_a_name()
  local Log = require("cosmic.log")
  assert(not pcall(Log.new, ""))
  assert(Log.new("x").name == "x")
end

local function test_a_write_answers_whether_it_landed()
  local Log = require("cosmic.log")
  local log = Log.new("x")
  local ok, trouble = log:verdict("t", true, "a write to stdout")
  assert(ok and trouble == "", trouble)
end
