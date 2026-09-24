--- Lines a command-line program writes: what it found on stdout, what went
--- wrong on stderr under the program's own name, and the verdict line
--- every cosmic verb ends in -- `fix: PASS (3 files, 0 fixed, 12 ms)`.
---
---     local log = Log.new("notes")
---     log:complain("no such note: 9") -- stderr: "notes: no such note: 9"
---     log:verdict("rm", false, "no such note")

local Fs = require("cosmic.fs")

local record Log
  --- Where one program's lines go, and the name its complaints carry.
  record Logger
    name: string

    --- `line` on stdout, as it is. False and why when the write fails,
    --- as it does once a reader has closed the pipe; a caller that has
    --- nowhere else to say so may ignore it.
    say: function(self: Logger, line: string): boolean, string

    --- `line` on stderr, after the logger's name and ": ", answering as
    --- `say` does.
    complain: function(self: Logger, line: string): boolean, string

    --- A verdict line on stdout: `verb: PASS` or `verb: FAIL`, and the
    --- detail in parentheses when there is one; answers as `say` does.
    verdict: function(self: Logger, verb: string, passed: boolean,
      detail?: string): boolean, string
  end
end

local function say(_: Log.Logger, line: string): boolean, string
  return Fs.put(Fs.stdout, line .. "\n")
end

local function complain(self: Log.Logger, line: string): boolean, string
  return Fs.put(Fs.stderr, self.name .. ": " .. line .. "\n")
end

local function verdict(self: Log.Logger, verb: string, passed: boolean,
    detail?: string): boolean, string
  local line = verb .. (passed and ": PASS" or ": FAIL")
  if detail ~= nil and detail ~= "" then
    line = line .. " (" .. detail .. ")"
  end
  return self:say(line)
end

--- A logger whose complaints carry `name`, as a program's own name.
--- Raises when the name is empty: a complaint must say whose it is.
--- @param name string The program's name
--- @return Logger The logger
function Log.new(name: string): Log.Logger
  if name == "" then
    error("log: a logger needs a name", 2)
  end
  return { name = name, say = say, complain = complain, verdict = verdict }
end

return Log
