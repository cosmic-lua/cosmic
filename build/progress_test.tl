local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local progress = require("build.progress")

Test.policy{}

--- A phase over `lines`, on a clock the test sets, where stderr is a terminal
--- or not.
local function phase_on(terminal: boolean, lines: {string}, clock: {integer}): progress.Phase
  return progress.phase("test", "running", "test", {
    say = function(verb: string, detail: string) lines[#lines + 1] = verb .. ": " .. detail end,
    terminal = terminal,
    now = function(): integer return clock[1] end,
  })
end

--- A phase that ends within ten seconds says nothing; one that runs past
--- says where it is, and how far.
local function test_a_phase_says_nothing_until_it_has_run_ten_seconds()
  local lines: {string} = {}
  local clock = { 0 }
  local phase = phase_on(true, lines, clock)
  clock[1] = Clock.seconds(9)
  phase:tick(3, 40)
  assert(#lines == 0, lines[1])
  clock[1] = Clock.seconds(10)
  phase:tick(4, 40)
  assert(lines[1] == "test: running 4/40 tests, 10 s", tostring(lines[1]))
end

--- Where stderr is a terminal a line comes each ten seconds, and where it
--- is a log each thirty, so that a CI log holds a few lines a minute.
local function test_lines_come_at_the_rate_the_stream_asks_for()
  local function count(terminal: boolean): integer
    local lines: {string} = {}
    local clock = { 0 }
    local phase = phase_on(terminal, lines, clock)
    for second = 1, 120 do
      clock[1] = Clock.seconds(second)
      phase:tick(second, 120)
    end
    return #lines
  end
  assert(count(true) == 12, "a terminal: " .. count(true))
  assert(count(false) == 4, "a log: " .. count(false))
end

--- A long phase's time is said in minutes and seconds from two minutes.
local function test_elapsed_is_said_in_seconds_then_minutes()
  assert(progress.elapsed(Clock.seconds(59)) == "59 s")
  assert(progress.elapsed(Clock.seconds(119)) == "119 s")
  assert(progress.elapsed(Clock.seconds(125)) == "2 min 5 s")
end
