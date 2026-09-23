--- The running process itself.

local sys = require("cosmic.sys")

local record Proc
  --- How to start this same program again: the executable and the
  --- arguments that must lead its command line, the environment entries
  --- to add, and the descriptors to hand the child (see
  --- `Child.Options.fds`).
  record Relaunch
    argv: {string}
    env: {string:string}
    fds: {integer:integer}
  end
end

--- The descriptors a relaunched child sees its artifact and core as:
--- high, so they stay clear of any a caller hands it.
local ARTIFACT_FD <const> = 254
local CORE_FD <const> = 255

local relaunch: Proc.Relaunch

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
  return path, ""
end

--- How many processors are online, at least one: the natural bound on
--- how many children to run at once for CPU-bound work.
function Proc.cpu_count(): integer
  return sys.cpu_count()
end

--- How to start this same program again exactly: the same native core,
--- artifact, and database this process runs, executed directly with the
--- private startup contract its launcher would give it, so the child
--- skips the launcher and cannot land on another core -- a checked build
--- relaunches as a checked build. Append the child's own arguments to
--- `argv`, add `env` to its environment, and pass `fds` to
--- `Child.start`. Nil for a process not started from a portable
--- artifact; `Proc.executable` is the way to start that one again.
function Proc.relaunch(): Proc.Relaunch | nil, string
  if relaunch ~= nil then return relaunch, "" end
  local found, trouble = sys.relaunch(ARTIFACT_FD, CORE_FD)
  if found == nil then return nil, trouble end
  -- One core descriptor serves every relaunch; it is closed on exec, so
  -- nothing but a child it is handed to ever inherits it.
  relaunch = {
    argv = { found.path, "--artifact", found.artifact },
    env = found.environment,
    fds = { [ARTIFACT_FD] = found.artifact_fd, [CORE_FD] = found.core_fd },
  }
  return relaunch, ""
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
