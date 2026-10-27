--- Lines a command-line program writes: what it found on stdout, and what
--- went wrong on stderr under the program's own name. Whether it passed
--- is its exit status.
---
---     local log = Log.new("notes")
---     log:say("1  buy milk")              -- stdout: "1  buy milk"
---     log:complain("no such note: 9")     -- stderr: "notes: no such note: 9"

local Fs = require("cosmic.fs")

local record Log
  --- Where one program's lines go, and the name its complaints carry.
  record Logger
    --- The name `complain` prefixes to a line, as `name: line`.
    name: string

    --- `line` on stdout, as it is. False and why when the write fails,
    --- as it does once a reader has closed the pipe; a caller that has
    --- nowhere else to say so may ignore it.
    say: function(self: Logger, line: string): boolean, string

    --- `line` on stderr, after the logger's name and ": ", answering as
    --- `say` does.
    mut complain: function(self: Logger, line: string): boolean, string
  end
end

local function say(_: Log.Logger, line: string): boolean, string
  return Fs.put(Fs.stdout, line .. "\n")
end

local function complain(self: Log.Logger, line: string): boolean, string
  return Fs.put(Fs.stderr, self.name .. ": " .. line .. "\n")
end

--- A logger whose complaints carry `name`, as a program's own name.
--- Raises when the name is empty: a complaint must say whose it is.
--- @param name string The program's name
--- @return Logger The logger
function Log.new(name: string): Log.Logger
  if name == "" then
    error("log: the logger's name is empty", 2)
  end
  return { name = name, say = say, complain = complain }
end

return Log
