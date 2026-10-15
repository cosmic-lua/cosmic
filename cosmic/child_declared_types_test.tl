--- The declarations of cosmic.child tell the truth about nil: a stream
--- that has ended holds no descriptor, and a wait whose deadline has
--- passed has no time left to wait. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary as a kind its type does not admit; in any other run the
--- tests skip.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")
local this_program = require("build.this_program")

--- Each child only runs a chunk through this program's core.
Test.policy{ profiles = { "cosmic" } }

--- Runs `script` through this program with `options`, answering the result.
local function run(script: string, options: Child.Options): Child.Result
  local started = this_program.program({ "-e", script }, options)
  return (assert(Child.run(started.argv, started.options)))
end

local function test_an_ended_stream_and_a_passed_deadline_are_as_declared()
  local found = TypeWatch.during(function()
    local done = run('assert(require("cosmic.fs").put(1, "hi"))', { stdout = "capture", stderr = "capture" })
    assert(done.ok and done.stdout == "hi")
    local late = run("while true do end", { stdout = "capture", timeout_ns = Clock.ms(200) })
    assert(not late.ok)
  end)
  assert(#found == 0, #found .. " violations:\n" .. table.concat(found, "\n"))
end
