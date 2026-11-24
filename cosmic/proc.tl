--- The running process itself.

local Env = require("cosmic.env")
local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")

-- `relaunch` lives in the raw process table, under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why.
local type raw_process = require("cosmic.internal.process")

local raw = require("cosmic.internal.process")
local source_run = require("cosmic.internal.source_run")

local record Proc
  --- A named account's numeric user and primary group identifiers.
  type User = raw_process.User

  --- The message of [`Proc.user`]'s failure for a name no account has.
  NO_ACCOUNT: string

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
    cwd?: string
    --- Under a source run (`cosmic <file.tl>`), the file's absolute path;
    --- nil in any other process: a built program, `-e`, `--standalone`, a
    --- test. `argv` starts cosmic itself, so a child given `argv` and its own
    --- words runs a verb of cosmic's; one given `argv`, then `script`, then
    --- its words and `cwd` runs this program again (see [`Proc.relaunch`]).
    script?: string
  end
end

-- The descriptors a relaunched child sees its artifact and core as:
-- high, so they stay clear of any a caller hands it.
local ARTIFACT_FD <const> = 254
local CORE_FD <const> = 255

local record Cached
  mut relaunch?: Proc.Relaunch
end

local cached: Cached = {}

Proc.NO_ACCOUNT = "no such account"

--- Ends the process with a status. This is the explicit replacement for
--- os.exit; it does not run finalizers and does not return.
--
-- TODO: once cosmic.sys is declared (lang/declarations.tl lists the bindings) with `exit` as `never`, the new
-- checker reports this function's end as reachable (`missing_return`): the C binding [`sys.exit`] is not known to end
-- control, and declaring it removes the gap.
function Proc.exit(status: integer): never
  sys.exit(status)
end

--- The process's own identifier: `getpid`, or the shell's `$$`.
function Proc.pid(): integer
  return sys.getpid()
end

--- The logical path that directly relaunches this program. A portable program
--- returns its artifact path rather than the private cached native core.
--- Nil and a [`Failure`] where the path cannot be read.
function Proc.executable(): (string) | (nil, Failure)
  local path, trouble = sys.executable()
  if path == nil then
    return nil, Failure.new(trouble)
  end
  return path
end

--- Looks up an explicitly named account, answering its uid and primary
--- gid, or nil and a [`Failure`]: of kind "other" and the message
--- [`Proc.NO_ACCOUNT`] for a name no account has, or of kind "system"
--- with the lookup's errno where it failed. Empty names and NUL bytes
--- raise.
--- This consults the host's account service in the calling process, so
--- resolve names before entering a sandbox or starting a child. The
--- caller buffer grows up to 1 MiB; that limits neither libc's own
--- allocation nor the time a directory service may take.
function Proc.user(name: string): (Proc.User) | (nil, Failure)
  local user, _, errno = raw.user(name)
  if user ~= nil then return user end
  if errno == 0 then return nil, Failure.new(Proc.NO_ACCOUNT, name) end
  return nil, Failure.system(errno, name)
end

--- How many processors are online, at least one: what `getconf
--- _NPROCESSORS_ONLN` answers, which is `nproc` less any CPU affinity. The
--- natural bound on how many children to run at once for CPU-bound work.
function Proc.cpu_count(): integer
  return sys.cpu_count()
end

--- The start [`Proc.relaunch`] answers, before a source run's script is
--- added to it.
local function started(): Proc.Relaunch?, string
  local found, trouble = raw.relaunch(ARTIFACT_FD, CORE_FD)
  if found == nil then return nil, trouble end
  local database = found.database
  if database ~= nil then
    return { argv = { found.path, "--database", database }, env = {}, fds = {}, cwd = found.cwd }, ""
  end
  if found.host == true then
    return { argv = { found.path }, env = {}, fds = {}, cwd = found.cwd }, ""
  end
  -- One core descriptor serves every relaunch; it is closed on exec, so
  -- nothing but a child it is handed to ever inherits it.
  return {
    argv = { found.path, "--artifact", assert(found.artifact) },
    env = assert(found.environment),
    fds = { [ARTIFACT_FD] = assert(found.artifact_fd), [CORE_FD] = assert(found.core_fd) },
    cwd = found.cwd,
  }, ""
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
--- `fds` to [`Child.start`]. Returns nil and a [`Failure`] when this
--- process has no artifact to start again, or its executable or core
--- cannot be reopened.
---
--- Under a source run (`cosmic <file.tl>`) the program is cosmic: `argv`
--- starts cosmic, as a script that drives cosmic's verbs needs, and
--- `script` names the file. To run the script again, put `script` after
--- `argv` and before the child's own arguments, and start the child in
--- `cwd`: a file run builds the working directory's tree when the file is
--- under it, else the file's own directory, so a child started elsewhere
--- builds another tree, where the project's modules may not be. Each such
--- child checks the tree and runs the source as it is when the child
--- starts.
function Proc.relaunch(): (Proc.Relaunch) | (nil, Failure)
  local relaunch = cached.relaunch
  if relaunch == nil then
    local found, trouble = started()
    if found == nil then return nil, Failure.new(trouble) end
    relaunch = found
  end
  -- Read on each call: one the tool makes before it loads the file finds
  -- no script yet.
  local script = source_run.script
  if relaunch.script ~= script then
    relaunch = { argv = relaunch.argv, env = relaunch.env, fds = relaunch.fds, cwd = relaunch.cwd, script = script }
  end
  cached.relaunch = relaunch
  return relaunch
end

-- The search list `find` uses when PATH is unset, as execvp does.
local DEFAULT_PATH <const> = "/bin:/usr/bin"

--- Where a shell's `which` or `command -v` finds the program `name`:
--- itself when it holds a slash, otherwise the first executable regular
--- file in `path`, a colon-separated list that defaults to PATH (or
--- /bin:/usr/bin when PATH is unset). Empty entries search the working
--- directory; relative entries give relative answers. A slash-containing
--- name is resolved without checking that it exists or can execute.
---
--- With no executable match it answers nil and a system [`Failure`], as
--- a shell's 127 and 126 tell apart: `EACCES` about the first regular
--- file this process cannot execute, else `ENOENT` about `name`. A
--- directory or a path that cannot be inspected is not a candidate. An
--- empty name raises.
---
---     local git, why = Proc.find("git")
---     if git == nil and why.errno == sys.ENOENT then print("no git") end
function Proc.find(name: string, path?: string): (string) | (nil, Failure)
  if name == "" then
    error("proc: find's name is empty", 2)
  end
  if name:find("/", 1, true) ~= nil then
    return name
  end
  local search = path or Env.read("PATH") or DEFAULT_PATH
  local unrunnable: string? = nil
  for dir in (search .. ":"):gmatch("([^:]*):") do
    local candidate = (if dir == "" then "." else dir end) .. "/" .. name
    local st, _ = sys.stat(candidate)
    if st ~= nil and st.kind == "file" then
      -- Asked of this process, as execvp asks: an execute bit only
      -- others hold is no use to it.
      local runnable, _ = sys.access(candidate, sys.X_OK)
      if runnable then
        return candidate
      end
      unrunnable = unrunnable or candidate
    end
  end
  if unrunnable ~= nil then
    return nil, Failure.system(sys.EACCES, unrunnable)
  end
  return nil, Failure.system(sys.ENOENT, name)
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
--- searched. It returns only when it fails, with a [`Failure`] about the
--- path.
function Proc.exec(argv: {string}, opts?: Proc.ExecOptions): Failure
  local path = argv[1]
  if path == nil then error("proc: argv is empty", 2) end
  local environment = if opts ~= nil then opts.env else nil end
  local _, _, errno = sys.execve(path, argv, environment or sys.environ())
  return Failure.system(errno, path)
end

return Proc
