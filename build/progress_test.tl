local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local progress = require("build.progress")

Test.policy{}

--- A phase over `lines`, which reads the time from `now`, where stderr is
--- a terminal or not.
local function phase_on(terminal: boolean, lines: mut {string}, now: function(): integer): progress.Phase
  return progress.phase("test", "running", "test", {
    say = function(verb: string, detail: string) table.insert(lines, verb .. ": " .. detail) end,
    terminal = terminal,
    now = now,
  })
end

--- A phase that ends within ten seconds says nothing; one that runs past
--- says where it is, and how far.
local function test_a_phase_says_nothing_until_it_has_run_ten_seconds()
  local lines: mut {string} = {}
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
    local lines: mut {string} = {}
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

--- A line says what still runs after its count, and asks for it only
--- when a line is due, so a phase that says nothing pays nothing for it.
local function test_a_line_carries_the_detail_it_is_given_when_one_is_due()
  local lines: mut {string} = {}
  local at = 0
  local asked = 0
  local phase = phase_on(true, lines, function(): integer return at end)
  local function detail(): string
    asked = asked + 1
    return "longest running: a 8 s"
  end
  at = Clock.seconds(9)
  phase.tick(3, 40, detail)
  assert(asked == 0 and #lines == 0, "asked for a detail no line says")
  at = Clock.seconds(10)
  phase.tick(4, 40, detail)
  assert(asked == 1, "asked " .. tostring(asked) .. " times")
  assert(lines[1] == "test: running 4/40 tests, 10 s; longest running: a 8 s", "said: " .. tostring(lines[1]))
  at = Clock.seconds(20)
  phase.tick(5, 40, function(): string return "" end)
  assert(lines[2] == "test: running 5/40 tests, 20 s", "an empty detail left a mark: " .. tostring(lines[2]))
end

--- What a stalled phase names: the tests that began first, longest
--- first, however the list came, and no more than asked for.
local function test_the_longest_running_are_named_longest_first()
  local running: {progress.Running} = {
    { name = "b", started_ns = Clock.seconds(50) },
    { name = "a", started_ns = Clock.seconds(5) },
    { name = "c", started_ns = Clock.seconds(80) },
    { name = "d", started_ns = Clock.seconds(70) },
  }
  local now = Clock.seconds(100)
  assert(progress.longest(running, now, 3) == "a 95 s, b 50 s, d 30 s", progress.longest(running, now, 3))
  assert(progress.longest(running, now, 9) == "a 95 s, b 50 s, d 30 s, c 20 s")
  assert(progress.longest({}, now, 3) == "")
  assert(assert(running[1]).name == "b", "it reordered its argument")
end
