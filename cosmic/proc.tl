--- The running process itself.

local sys = require("cosmic.sys")

local record Proc
end

--- Ends the process with a status. This is the explicit replacement for
--- os.exit; it does not run finalizers and does not return.
function Proc.exit(status: integer)
  sys.exit(status) -- exits: a process boundary has no caller to return to
end

--- The process's own identifier.
function Proc.pid(): integer
  return sys.getpid()
end

--- The logical path that directly relaunches this program. A portable program
--- returns its artifact path rather than the private cached native core.
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

--- Replaces this process with another program. This is lower-level than
--- os.execute: it does not invoke a shell, wait for a child, or return command
--- status. There is no io.popen stream API. On success the process keeps the
--- same process id,
--- the given arguments with the program's own name first, and the
--- given environment. It returns only when it fails.
function Proc.exec(path: string, argv: {string},
                   environment: {string:string}): boolean, string
  local _, trouble = sys.execve(path, argv, environment)
  return false, path .. ": " .. trouble
end

return Proc
