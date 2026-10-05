--- The running process itself.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")

-- `relaunch` lives in the raw process table, under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why.
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_process
if type(extra) == "table" then
  raw = extra as raw_process
else
  raw = require("cosmic.internal.process")
end

local record Proc
  --- A named account's numeric user and primary group identifiers.
  type User = raw_process.User

  --- The outcome of [`Proc.find_result`], without reading its diagnostic.
  record FindResult
    enum Kind
      "resolved"
      "not_found"
      "not_executable"
    end

    --- Whether a spelling was selected, no candidate was found, or a
    --- regular candidate could not execute.
    kind: Kind
    --- The selected spelling when resolved, or the first regular file
    --- this process cannot execute. Nil when no candidate was found.
    path: string | nil
    --- Empty when resolved; the reason lookup refused otherwise.
    reason: string
  end

  --- What [`Proc.exec`] reads.
  record ExecOptions
    --- The program's whole environment, by name: it replaces this
    --- process's rather than adding to it. Nil inherits this process's.
    env: {string:string}
  end

  --- How to start this same program again: the executable and the
  --- arguments that must lead its command line, the environment entries
  --- to add, and the descriptors to hand the child (see
  --- [`Child.Options.fds`]).
  record Relaunch
    --- The executable and the arguments that lead the command line.
    argv: {string}
    --- Entries to add to the child's environment.
    env: {string:string}
    --- Descriptors to hand the child, as [`Child.Options.fds`] takes them.
    fds: {integer:integer}
    --- The working directory this process started in, for the child's
    --- [`Child.Options.cwd`]; nil where it could not be read then.
    cwd: string
  end
end

-- The descriptors a relaunched child sees its artifact and core as:
-- high, so they stay clear of any a caller hands it.
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

--- Looks up an explicitly named account, answering its uid and primary
--- gid. A missing account is nil and an empty reason; a lookup failure
--- is nil and its reason. Empty names, NUL bytes and nonstrings raise.
--- This consults the host's account service in the calling process, so
--- resolve names before entering a sandbox or starting a child. The
--- caller buffer grows up to 1 MiB; that limits neither libc's own
--- allocation nor the time a directory service may take.
function Proc.user(name: string): Proc.User | nil, string
  local user, trouble = raw.user(name)
  if user == nil then return nil, trouble end
  return user, ""
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
--- is: `argv` is just its path, and `env` and `fds` are empty. A core run
--- against a database (`core --database <path>`) is started again on that
--- database: `argv` is the core, `--database` and the database's absolute
--- path, and `env` and `fds` are empty, so a child stays on it. Append the
--- child's own arguments to `argv`, add `env` to its environment, and pass
--- `fds` to [`Child.start`]. Returns nil and why when this process has no
--- artifact to start again, or its executable or core cannot be reopened.
function Proc.relaunch(): Proc.Relaunch | nil, string
  if relaunch ~= nil then return relaunch, "" end
  local found, trouble = raw.relaunch(ARTIFACT_FD, CORE_FD)
  if found == nil then return nil, trouble end
  if found.database ~= nil then
    relaunch = { argv = { found.path, "--database", found.database }, env = {}, fds = {}, cwd = found.cwd }
    return relaunch, ""
  end
  if found.host then
    relaunch = { argv = { found.path }, env = {}, fds = {}, cwd = found.cwd }
    return relaunch, ""
  end
  -- One core descriptor serves every relaunch; it is closed on exec, so
  -- nothing but a child it is handed to ever inherits it.
  relaunch = {
    argv = { found.path, "--artifact", assert(found.artifact) },
    env = assert(found.environment),
    fds = { [ARTIFACT_FD] = assert(found.artifact_fd), [CORE_FD] = assert(found.core_fd) },
    cwd = found.cwd,
  }
  return relaunch, ""
end

-- The search list `find` uses when PATH is unset, as execvp does.
local DEFAULT_PATH <const> = "/bin:/usr/bin"

--- Selects a spelling for the program `name`: itself when it holds a
--- slash, otherwise the first executable regular file in `path`, a
--- colon-separated list that defaults to PATH (or /bin:/usr/bin when
--- PATH is unset). Empty entries search the working directory; relative
--- entries give relative answers. A slash-containing name is resolved
--- without checking that it exists or can execute.
---
--- With no executable match, the first regular file this process cannot
--- execute gives `not_executable`; no regular candidate gives `not_found`.
--- A directory or a path that cannot be inspected is not a candidate.
--- An empty name raises.
function Proc.find_result(name: string, path?: string): Proc.FindResult
  if name == "" then
    error("proc: find_result's name is empty", 2)
  end
  if name:find("/", 1, true) ~= nil then
    return { kind = "resolved", path = name, reason = "" }
  end
  local search = path or Env.get("PATH") or DEFAULT_PATH
  local unrunnable: string = nil
  for dir in (search .. ":"):gmatch("([^:]*):") do
    local candidate = (dir == "" and "." or dir) .. "/" .. name
    local st, _ = sys.stat(candidate)
    if st ~= nil and st.kind == "file" then
      -- Asked of this process, as execvp asks: an execute bit only
      -- others hold is no use to it.
      local runnable, _ = sys.access(candidate, sys.X_OK)
      if runnable then
        return { kind = "resolved", path = candidate, reason = "" }
      end
      unrunnable = unrunnable or candidate
    end
  end
  if unrunnable ~= nil then
    return { kind = "not_executable", path = unrunnable, reason = unrunnable .. ": not executable" }
  end
  return { kind = "not_found", reason = name .. ": not found" }
end

--- Where a shell's `which` or `command -v` finds a program:
--- [`Proc.find_result`]'s resolved path, or nil and its reason for
--- refusal. A slash-containing name passes through without being checked;
--- an empty name raises. The refusal distinguishes no such program from
--- a regular file this process cannot execute (a shell's 127 and 126).
function Proc.find(name: string, path?: string): string | nil, string
  if name == "" then
    error("proc: find's name is empty", 2)
  end
  local result = Proc.find_result(name, path)
  if result.kind == "resolved" then return result.path, "" end
  return nil, result.reason
end

--- Whether a stream is a terminal: `isatty`, or the shell's `test -t`.
function Proc.is_tty(fd: integer): boolean
  return sys.isatty(fd)
end

--- Replaces this process with the program `argv[1]` names, run with
--- `argv` -- its first element the path, and the program's own name --
--- and `opts.env` as its whole environment, by default this process's
--- own; the process id stays the same. As [`Child.start`] takes
--- `argv` and `opts.env`. No shell is involved, and no `PATH` is
--- searched. It returns only when it fails.
function Proc.exec(argv: {string}, opts?: Proc.ExecOptions): boolean, string
  local path = argv[1]
  if path == nil then error("proc: argv is empty", 2) end
  local environment = opts ~= nil and opts.env or nil
  local _, trouble = sys.execve(path, argv, environment or sys.environ())
  return false, path .. ": " .. trouble
end

return Proc
