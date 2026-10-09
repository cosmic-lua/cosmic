--- The cases of cosmic.signal's guard that a signal must reach in a
--- process of its own: a file run by this program again, past its
--- launcher, as a nested cosmic, whose guard sends it the signal and,
--- closing, may deliver it. They declare `tool`, as a file run builds the
--- tree the file sits in. The cases that start nothing are in
--- cosmic/signal_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself (`tool`), which runs every fixture, started past
--- its launcher so that no host program is read.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A released guard hands its signal back rather than delivering it,
--- and a later close -- here the `<close>` scope's -- delivers nothing
--- either. The nested cosmic outlives the SIGTERM it sent itself.
local function test_guard_release_keeps_the_signal_from_close(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/released.tl"
  assert(Fs.write(fixture, [[
local Fs = require("cosmic.fs")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  do
    local guard <close> = assert(Signal.guard())
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    answers[#answers + 1] = tostring(guard:cancelled())
    answers[#answers + 1] = tostring((guard:release()))
    answers[#answers + 1] = tostring((guard:release()))
    answers[#answers + 1] = tostring((guard:close()))
  end
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, term, term, "true" }, "|"), tostring(got))
end

--- A guard keeps taking signals after its first: a SIGTERM after a
--- Ctrl-C the child handled is what a supervisor must pass on next,
--- and release answers the last one delivered rather than losing it. The nested
--- cosmic outlives both.
local function test_guard_release_answers_the_last_signal(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/latest.tl"
  assert(Fs.write(fixture, [[
local Fs = require("cosmic.fs")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  answers[#answers + 1] = tostring(guard:cancelled())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:cancelled())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring((guard:release()))
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local int, term = tostring(sys.SIGINT), tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ int, term, term }, "|"), tostring(got))
end

--- `take` answers each signal once, a repeat of the same one included,
--- while `cancelled` keeps answering the last: a supervisor passes a
--- second SIGTERM on after its child handled the first.
local function test_guard_take_answers_a_repeated_signal_again(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/take.tl"
  assert(Fs.write(fixture, [[
local Fs = require("cosmic.fs")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:take())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  answers[#answers + 1] = tostring(guard:cancelled())
  answers[#answers + 1] = tostring(guard:take())
  answers[#answers + 1] = tostring(guard:take())
  answers[#answers + 1] = tostring(guard:cancelled())
  answers[#answers + 1] = tostring((guard:release()))
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, term, term, "0", term, term }, "|"), tostring(got))
end

--- Only the last guard to close delivers: an inner guard's close, the
--- outer open, leaves the signal it caught to the outer, whose close
--- delivers it. The nested cosmic dies of it there, not before.
local function test_only_the_last_guard_to_close_delivers(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/nested.tl"
  assert(Fs.write(fixture, [[
local Fs = require("cosmic.fs")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local answers: {string} = {}
  local outer <close> = assert(Signal.guard())
  do
    local inner <close> = assert(Signal.guard())
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    answers[#answers + 1] = tostring(inner:cancelled())
  end
  answers[#answers + 1] = "alive"
  answers[#answers + 1] = tostring(outer:cancelled())
  assert(Fs.write(argv[1], table.concat(answers, "|")))
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == table.concat({ term, "alive", term }, "|"), tostring(got) .. " " .. tostring(r.stderr))
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end

--- A guard closed while a later one is still open leaves its signal
--- to that one, which never saw it, since it opened after: closing it,
--- the last, delivers the signal all the same.
local function test_the_last_guard_delivers_one_closed_before_it(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/crossed.tl"
  assert(Fs.write(fixture, [[
local Fs = require("cosmic.fs")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local first = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local second = assert(Signal.guard())
  assert(first:close())
  assert(Fs.write(argv[1], tostring(first:cancelled()) .. "|" .. tostring(second:cancelled())))
  assert(second:close())
  return 0
end
]]))
  local started = this_program.program({ fixture, report },
    { stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  local got = Fs.read(report)
  assert(got == tostring(sys.SIGTERM) .. "|0", tostring(got) .. " " .. tostring(r.stderr))
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end
