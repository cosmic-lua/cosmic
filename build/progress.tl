--- A line of progress from a phase that can take long, so that a run
--- that is slow says where it is: "test: running 120/2300 tests, 40 s".
--- A phase that ends within [`progress.after_ns`] says nothing. Past it
--- the phase says a line each [`progress.terminal_ns`] where stderr is a
--- terminal, and each [`progress.pipe_ns`] where it is not, so that a CI
--- log holds a few lines a minute, never a stream. A line is a plain
--- line, never one rewritten in place.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local logger = require("build.logger")

local record progress
  --- How long a phase runs before it says its first line.
  after_ns: integer
  --- How long between lines where stderr is a terminal.
  terminal_ns: integer
  --- How long between lines where it is not.
  pipe_ns: integer

  --- Where a phase says its lines, and how it reads the time: what a
  --- test supplies in place of stderr and the monotonic clock.
  record Options
    say: function(verb: string, detail: string)
    terminal: boolean
    now: function(): integer
  end

  --- A phase's progress: [`Phase.tick`] it as work finishes.
  record Phase
    --- Says a line, when one is due, that `done` of `total` `unit`s
    --- (a noun, plural by an `s`) are finished.
    tick: function(self: Phase, done: integer, total: integer)
    verb: string
    what: string
    unit: string
    started_ns: integer
    said_ns: integer | nil
    every_ns: integer
    options: Options
  end
end

progress.after_ns = Clock.seconds(10)
progress.terminal_ns = Clock.seconds(10)
progress.pipe_ns = Clock.seconds(30)

--- How long a phase has run, as a line says it: seconds, and from two
--- minutes whole minutes and the seconds left.
function progress.elapsed(ns: integer): string
  local seconds = ns // Clock.seconds(1)
  if seconds < 120 then
    return tostring(seconds) .. " s"
  end
  return tostring(seconds // 60) .. " min " .. tostring(seconds % 60) .. " s"
end

local function tick(self: progress.Phase, done: integer, total: integer)
  local now = self.options.now()
  local ran = now - self.started_ns
  if ran < progress.after_ns then return end
  local said = self.said_ns
  if said ~= nil and now - said < self.every_ns then return end
  self.said_ns = now
  self.options.say(self.verb, self.what .. " " .. tostring(done) .. "/" .. tostring(total) ..
      (self.unit == "" and "" or " " .. self.unit .. "s") .. ", " .. progress.elapsed(ran))
end

--- A phase that began now, said as `verb: what <done>/<total> <unit>s,
--- <elapsed>`. `unit` is "" for none.
--- @param options where it says its lines and reads the time, by
---   default stderr, as [`build.logger`]'s `summary` writes it, and the
---   monotonic clock
function progress.phase(verb: string, what: string, unit: string,
                        options?: progress.Options): progress.Phase
  local opts: progress.Options = options or {
    say = function(v: string, detail: string) local _, _ = logger.summary(v, detail) end,
    terminal = Proc.is_tty(Fs.stderr),
    now = Clock.monotonic_ns,
  }
  return {
    tick = tick, verb = verb, what = what, unit = unit, started_ns = opts.now(),
    every_ns = opts.terminal and progress.terminal_ns or progress.pipe_ns, options = opts,
  }
end

return progress
