--- The logger cosmic's own verbs write through. It remembers whether it
--- has printed a verdict line, so [`build/dispatch.tl`] can end an exit
--- path a verb left without one -- a usage error, a setup failure, a
--- stale tool -- in `<verb>: FAIL`: every verb ends in a verdict line.

local Fs = require("cosmic.fs")
local Log = require("cosmic.log")

local record verdict
  --- The logger, whose complaints carry "cosmic".
  log: Log.Logger
  --- Whether `log` has printed a verdict line in this process.
  given: boolean
  on_stderr: function(verb: string, passed: boolean, detail?: string): boolean, string
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

--- `log`'s verdict line on stderr, for a verb whose stdout is data a
--- pipe reads, as `cosmic sql --to`'s is: it counts as given.
function verdict.on_stderr(verb: string, passed: boolean, detail?: string): boolean, string
  verdict.given = true
  local to_stderr: Log.Logger = {
    name = plain.name,
    say = function(_: Log.Logger, line: string): boolean, string
      return Fs.put(Fs.stderr, line .. "\n")
    end,
    complain = plain.complain,
    verdict = plain.verdict,
  }
  return to_stderr:verdict(verb, passed, detail)
end

return verdict
