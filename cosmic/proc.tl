--- The running process itself.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")

--- `relaunch` lives in the raw process table, under the reserved
--- `cosmic.internal.` namespace -- see cosmic/child.tl and
--- cosmic/sqlite.tl for why.
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_process
if type(extra) == "table" then
  raw = extra as raw_process
else
  raw = require("cosmic.internal.process")
end

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

--- The process's own identifier: `getpid`, or the shell's `$$`.
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

--- How many processors are online, at least one: what `getconf
--- _NPROCESSORS_ONLN` answers, which is `nproc` less any CPU affinity. The
--- natural bound on how many children to run at once for CPU-bound work.
function Proc.cpu_count(): integer
  return sys.cpu_count()
end

--- How to start this same program again exactly: the same native core,
--- artifact, and database this process runs, executed directly with the
--- private startup contract its launcher would give it, so the child
--- skips the launcher and cannot land on another core -- a checked build
--- relaunches as a checked build. A host program is executed again as it
--- is, since it has no launcher to skip. Append the child's own arguments to
--- `argv`, add `env` to its environment, and pass `fds` to
--- `Child.start`. Nil for a process not started from a portable
--- artifact; `Proc.executable` is the way to start that one again.
function Proc.relaunch(): Proc.Relaunch | nil, string
  if relaunch ~= nil then return relaunch, "" end
  local found, trouble = raw.relaunch(ARTIFACT_FD, CORE_FD)
  if found == nil then return nil, trouble end
  if found.host then
    relaunch = { argv = { found.path }, env = {}, fds = {} }
    return relaunch, ""
  end
  -- One core descriptor serves every relaunch; it is closed on exec, so
  -- nothing but a child it is handed to ever inherits it.
  relaunch = {
    argv = { found.path, "--artifact", assert(found.artifact) },
    env = assert(found.environment),
    fds = { [ARTIFACT_FD] = assert(found.artifact_fd), [CORE_FD] = assert(found.core_fd) },
  }
  return relaunch, ""
end

--- The search list `find` uses when PATH is unset, as execvp does.
local DEFAULT_PATH <const> = "/bin:/usr/bin"

--- Where the program `name` would run from, found as a shell (or `which`,
--- or `command -v`) finds it:
--- `name` itself when it holds a slash, else the first executable file
--- of that name in `path` -- a colon-separated list, PATH's value by
--- default -- where an empty entry is the working directory. A relative
--- entry gives a relative answer, as a shell's would. Nothing runnable
--- is `nil` and why: no such file, or one that is there but not
--- executable (a shell's 127 and 126). An empty name raises.
function Proc.find(name: string, path?: string): string | nil, string
  if name == "" then
    error("Proc.find: the name is empty", 2)
  end
  if name:find("/", 1, true) ~= nil then
    return name, ""
  end
  local search = path or Env.get("PATH") or DEFAULT_PATH
  local unrunnable: string = nil
  for dir in (search .. ":"):gmatch("([^:]*):") do
    local candidate = (dir == "" and "." or dir) .. "/" .. name
    local st, _ = sys.stat(candidate)
    if st ~= nil and st.kind == "file" then
      -- TODO: ask whether this process may run the file --
      -- faccessat(AT_EACCESS, X_OK) -- once cosmic.sys carries it; an
      -- execute bit for anyone is taken for one this user holds, so a
      -- file only others may run is answered where execvp would skip it.
      if st.mode & 0x49 ~= 0 then
        return candidate, ""
      end
      unrunnable = unrunnable or candidate
    end
  end
  if unrunnable ~= nil then
    return nil, unrunnable .. ": not executable"
  end
  return nil, name .. ": not found"
end

--- Whether a stream is a terminal: `isatty`, or the shell's `test -t`.
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
