--- The logger cosmic's own verbs write through, whose complaints carry
--- "cosmic", and the summary a verb ends a run with. A verb's stdout is
--- its result; stderr says what went wrong, and how a run that passed
--- went.

local Fs = require("cosmic.fs")
local Log = require("cosmic.log")

local record logger
  --- The logger, whose complaints carry "cosmic".
  mut log: Log.Logger
  summary: function(verb: string, detail: string): boolean, string
end

logger.log = Log.new("cosmic")

--- `verb: detail` on stderr: how a run went, its counts and how long it
--- took (`fix: 3 Teal files, 0 fixed, 12 ms`), or why it found nothing.
--- False and why when the write fails, as [`Log.Logger.say`] answers.
function logger.summary(verb: string, detail: string): boolean, string
  return Fs.put(Fs.stderr, verb .. ": " .. detail .. "\n")
end

return logger
