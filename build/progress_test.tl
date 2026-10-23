local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local progress = require("build.progress")

Test.policy{}

--- A phase over `lines`, which reads the time from `now`, where stderr is
--- a terminal or not.
local function phase_on(terminal: boolean, lines: {string}, now: function(): integer): progress.Phase
  return progress.phase("test", "running", "test", {
    say = function(verb: string, detail: string) table.insert(lines, verb .. ": " .. detail) end,
    terminal = terminal,
    now = now,
  })
end

--- A phase that ends within ten seconds says nothing; one that runs past
--- says where it is, and how far.
local function test_a_phase_says_nothing_until_it_has_run_ten_seconds()
  local lines: {string} = {}
  local at = 0
  local phase = phase_on(true, lines, function(): integer return at end)
  at = Clock.seconds(9)
  phase.tick(3, 40)
  assert(#lines == 0, "said before ten seconds")
  at = Clock.seconds(10)
  phase.tick(4, 40)
  assert(lines[1] == "test: running 4/40 tests, 10 s", "said: " .. tostring(lines[1]))
end

--- Where stderr is a terminal a line comes each ten seconds, and where it
--- is a log each thirty, so that a CI log holds a few lines a minute.
local function test_lines_come_at_the_rate_the_stream_asks_for()
  local function count(terminal: boolean): integer
    local lines: {string} = {}
    local at = 0
    local phase = phase_on(terminal, lines, function(): integer return at end)
    for second = 1, 120 do
      at = Clock.seconds(second)
      phase.tick(second, 120)
    end
    return #lines
  end
  local terminal, log = count(true), count(false)
  assert(terminal == 12, "a terminal said " .. tostring(terminal) .. " lines")
  assert(log == 4, "a log said " .. tostring(log) .. " lines")
end

--- A long phase's time is said in minutes and seconds from two minutes.
local function test_elapsed_is_said_in_seconds_then_minutes()
  assert(progress.elapsed(Clock.seconds(59)) == "59 s")
  assert(progress.elapsed(Clock.seconds(119)) == "119 s")
  assert(progress.elapsed(Clock.seconds(125)) == "2 min 5 s")
end
