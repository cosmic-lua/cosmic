--- A line of progress from a phase that can take long, so that a run
--- that is slow says where it is: "test: running 120/2300 tests, 40 s".
--- A phase that ends within ten seconds says nothing. Past it the phase
--- says a line each ten seconds where stderr is a terminal, and each
--- thirty where it is not, so that a CI log holds a few lines a minute,
--- never a stream. A line is a plain line, never one rewritten in place.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local logger = require("build.logger")

local record progress
  --- Where a phase says its lines, and how it reads the time: what a
  --- test supplies in place of stderr and the monotonic clock.
  record Options
    say: function(verb: string, detail: string)
    terminal: boolean
    now: function(): integer
  end

  --- A phase's progress, which `tick` is told of as work finishes.
  record Phase
    --- Says a line, when one is due, that `done` of `total` are finished.
    tick: function(done: integer, total: integer)
  end
end

--- How long a phase runs before it says its first line.
local after_ns <const> = Clock.seconds(10)
--- How long between lines where stderr is a terminal, and where it is not.
local terminal_ns <const> = Clock.seconds(10)
local pipe_ns <const> = Clock.seconds(30)

--- How long a phase has run, as a line says it: seconds, and from two
--- minutes whole minutes and the seconds left.
function progress.elapsed(ns: integer): string
  local seconds = ns // Clock.seconds(1)
  if seconds < 120 then
    return tostring(seconds) .. " s"
  end
  return tostring(seconds // 60) .. " min " .. tostring(seconds % 60) .. " s"
end

local function say_to_stderr(verb: string, detail: string)
  local _, _ = logger.summary(verb, detail)
end

--- A phase that began now, said as `verb: what <done>/<total> <unit>s,
--- <elapsed>`, `unit` a noun made plural by an `s`.
--- @param options where it says its lines and reads the time, by
---   default stderr, as [`build.logger`]'s `summary` writes it, and the
---   monotonic clock
function progress.phase(verb: string, what: string, unit: string,
                        options?: progress.Options): progress.Phase
  local say = say_to_stderr
  local terminal = Proc.is_tty(Fs.stderr)
  local now = Clock.monotonic_ns
  if options ~= nil then
    say, terminal, now = options.say, options.terminal, options.now
  end
  local every_ns = pipe_ns
  if terminal then every_ns = terminal_ns end
  local started_ns = now()
  -- The time of the last line said, held in a list of at most one: a
  -- function may change what a table holds, not a local of its maker.
  local said: {integer} = {}
  return {
    tick = function(done: integer, total: integer)
      local at = now()
      if at - started_ns < after_ns then return end
      for _, last in ipairs(said) do
        if at - last < every_ns then return end
      end
      table.remove(said)
      table.insert(said, at)
      say(verb, what .. " " .. tostring(done) .. "/" .. tostring(total) .. " " .. unit .. "s, " ..
          progress.elapsed(at - started_ns))
    end,
  }
end

return progress
