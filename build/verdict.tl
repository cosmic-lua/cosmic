--- The logger cosmic's own verbs write through. It remembers whether it
--- has printed a verdict line, so `build/dispatch.tl` can end an exit
--- path a verb left without one -- a usage error, a setup failure, a
--- stale tool -- in `<verb>: FAIL`: every verb ends in a verdict line.

local Log = require("cosmic.log")

local record verdict
  --- The logger, whose complaints carry "cosmic".
  log: Log.Logger
  --- Whether `log` has printed a verdict line in this process.
  given: boolean
end

local plain = Log.new("cosmic")

verdict.given = false

verdict.log = {
  name = plain.name,
  say = plain.say,
  complain = plain.complain,
  verdict = function(_: Log.Logger, verb: string, passed: boolean,
      detail?: string): boolean, string
    verdict.given = true
    return plain:verdict(verb, passed, detail)
  end,
}

return verdict
