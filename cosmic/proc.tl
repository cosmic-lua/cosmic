--- The running process itself.

local sys = require("cosmic.sys")

local record Proc
end

--- Ends the process. It does not return.
function Proc.exit(status: integer)
  sys.exit(status) -- exits: a process boundary has no caller to return to
end

--- The process's own identifier.
function Proc.pid(): integer
  return sys.getpid()
end

--- The path of the running executable.
function Proc.executable(): string | nil, string
  local path, trouble = sys.executable()
  if path == nil then
    return nil, trouble
  end
  return path
end

--- Whether a stream is a terminal.
function Proc.is_tty(fd: integer): boolean
  return sys.isatty(fd)
end

return Proc
