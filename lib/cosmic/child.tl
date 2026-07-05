--- Child process management.
--- Spawn and manage child processes with I/O control.
local unix = require("cosmo.unix")
local childio = require("cosmic.child_io")

--- Process resource usage statistics.
local record Rusage
  utime: function(self: Rusage): number, number
  stime: function(self: Rusage): number, number
  maxrss: function(self: Rusage): number
  idrss: function(self: Rusage): number
  ixrss: function(self: Rusage): number
  isrss: function(self: Rusage): number
  minflt: function(self: Rusage): number
  majflt: function(self: Rusage): number
  nswap: function(self: Rusage): number
  inblock: function(self: Rusage): number
  oublock: function(self: Rusage): number
  msgsnd: function(self: Rusage): number
  msgrcv: function(self: Rusage): number
  nsignals: function(self: Rusage): number
  nvcsw: function(self: Rusage): number
  nivcsw: function(self: Rusage): number
end

--- Handle for a spawned process.
--- stdin/stdout/stderr are cosmic.child_io Pipe wrappers (or nil when the
--- corresponding stream was redirected to a raw fd via Opts).
local record Handle
  pid: number
  stdin: childio.Pipe
  stdout: childio.Pipe
  stderr: childio.Pipe
  wait: function(self: Handle): number, string
  read: function(self: Handle, size?: number): boolean | string, string, number
  communicate: function(self: Handle): string, string, number, string
end

--- Options for spawning a process.
--- stdout/stderr: raw fd dup2'd onto fd 1/2; handle fields nil.
--- Close write end before reading. See Example_spawn_pipe.
local record Opts
  stdin: string | number -- string piped to stdin, or raw fd dup2'd onto fd 0
  stdout: number -- raw fd -> fd 1; handle.stdout becomes nil
  stderr: number -- raw fd -> fd 2; handle.stderr becomes nil
  env: {string}
  cwd: string
end

--- Creates a new process (fork).
--- @return number The child process id in parent, 0 in child
local function fork(): number
  return (unix.fork())
end

--- Spawns a new process using posix_spawn (low-level).
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables (KEY=value format)
--- @return number The child process id on success
local function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
  return (unix.spawn(prog, argv, envp))
end

--- Spawns a new process with PATH search (low-level).
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables
--- @return number The child process id on success
local function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
  return (unix.spawnp(prog, argv, envp))
end

--- Waits for child process to terminate.
--- @param pid number? Process id to wait for (-1 for any child)
--- @param options number? Wait options (e.g., WNOHANG)
--- @return number The child process id that terminated
--- @return number Status code (use WIFEXITED, WEXITSTATUS to interpret)
--- @return Rusage Resource usage statistics
local function wait(pid?: number, options?: number): number, number, Rusage
  local wpid, status, rusage = unix.wait(pid, options)
  return wpid, status, rusage as Rusage
end

--- Sends signal to child process.
--- @param pid number Process id to signal
--- @param sig number Signal number (e.g., SIGTERM, SIGKILL)
--- @return boolean True on success
local function kill(pid: number, sig: number): boolean
  return (unix.kill(pid, sig))
end

-- Status helpers --

--- Returns true if process exited normally.
local function WIFEXITED(wstatus: number): boolean
  return unix.WIFEXITED(wstatus)
end

--- Returns the exit code (valid if WIFEXITED is true).
local function WEXITSTATUS(wstatus: number): number
  return unix.WEXITSTATUS(wstatus)
end

--- Returns true if process was terminated by a signal.
local function WIFSIGNALED(wstatus: number): boolean
  return unix.WIFSIGNALED(wstatus)
end

--- Returns the terminating signal number (valid if WIFSIGNALED is true).
local function WTERMSIG(wstatus: number): number
  return unix.WTERMSIG(wstatus)
end

--- Normalize an env table to a list of "KEY=VALUE" strings.
local function normalize_env(env: {string}): {string}
  if env[1] ~= nil then
    return env
  end
  local list: {string} = {}
  for k, v in pairs(env as {string: string}) do
    table.insert(list, k .. "=" .. v)
  end
  return list
end

--- Checks if a path refers to a /zip/ virtual filesystem entry.
local function is_zip_path(p: string): boolean
  return p:sub(1, 5) == "/zip/"
end

--- Prepares an executable fd from a /zip/ path.
--- Opens the path to get a zip fd suitable for fexecve.
--- @param zip_path string Path starting with /zip/
--- @return number The file descriptor ready for fexecve
--- @return string Error message on failure
local function prepare_zip_exec(zip_path: string): number, string
  local fd = unix.open(zip_path, unix.O_RDONLY)
  if not fd then
    return nil, "failed to open zip path: " .. zip_path
  end
  return fd
end

-- High-level spawn API --

--- Spawns a child process with I/O control. Uses fexecve for /zip/ paths.
--- When Opts.stdout/stderr are fds they are dup2'd into child (handle fields
--- nil); MUST close the write end before reading. See Example_spawn_pipe.
--- To spawn cosmic itself, use `rawget(arg, -1)` — NOT arg[0] (gotchas #7).
--- @param argv {string} Command and arguments
--- @param opts Opts? Spawn options
--- @return Handle, string? Process handle or nil + error
local function spawn(argv: {string}, opts?: Opts): Handle, string
  opts = opts or {}

  -- Resolve the executable into a LOCAL, never by mutating the caller's
  -- argv table: a PATH search wrote the resolved path back into argv[1],
  -- corrupting the caller's own table. argv is passed to exec unchanged, so
  -- argv[0] stays the name the caller gave.
  local exec_fd: number
  local prog = argv[1]
  if is_zip_path(argv[1]) then
    local fd, err = prepare_zip_exec(argv[1])
    if not fd then
      return nil, err
    end
    exec_fd = fd
  elseif not (argv[1] as string):find("/") then
    local cmd = unix.commandv(argv[1])
    if not cmd then
      return nil, "command not found: " .. argv[1]
    end
    prog = cmd
  end

  -- Track every fd we open so a mid-way pipe() failure (fd exhaustion) can be
  -- unwound cleanly instead of leaking descriptors — including any exec fd,
  -- which would otherwise leak on this early-return path.
  local opened: {number} = {}
  local function fail(msg: string): Handle, string
    for _, fd in ipairs(opened) do unix.close(fd) end
    if exec_fd then unix.close(exec_fd) end
    return nil, msg
  end
  -- Create pipes CLOEXEC so their ends do not leak into an unrelated child
  -- spawned while this handle is still open: otherwise child B inherits child
  -- A's pipe ends and A never sees stdin EOF until B exits (communicate()
  -- hangs on overlap). The child's own dup2 onto 0/1/2 clears CLOEXEC on the
  -- ends it keeps; the ends that happen to already be fd 0/1/2 are cleared
  -- explicitly below.
  local function new_pipe(): number, number
    local r, w = unix.pipe(unix.O_CLOEXEC)
    if r == nil or w == nil then
      return nil, nil
    end
    table.insert(opened, r)
    table.insert(opened, w)
    return r, w
  end

  local stdin_r: number
  local stdin_w: number
  local stdin_is_fd = type(opts.stdin) == "number"
  if not stdin_is_fd then
    stdin_r, stdin_w = new_pipe()
    if not stdin_w then return fail("pipe failed (stdin)") end
  end

  local stdout_r: number
  local stdout_w: number
  local stdout_is_fd = type(opts.stdout) == "number"
  if not stdout_is_fd then
    stdout_r, stdout_w = new_pipe()
    if not stdout_w then return fail("pipe failed (stdout)") end
  end

  local stderr_r: number
  local stderr_w: number
  local stderr_is_fd = type(opts.stderr) == "number"
  if not stderr_is_fd then
    stderr_r, stderr_w = new_pipe()
    if not stderr_w then return fail("pipe failed (stderr)") end
  end

  local pid = unix.fork()
  if pid == 0 then
    -- stdin (fd 0)
    if stdin_is_fd then
      if opts.stdin ~= 0 then
        unix.dup(opts.stdin as number, 0)
      end
    else
      -- Close the write end first, then dup2 the read end onto fd 0.
      -- If stdin_r already IS fd 0, dup2 is a no-op (same fd), so skip
      -- the close to avoid closing the fd we are about to use.
      if stdin_r ~= 0 then
        unix.close(stdin_w)
        unix.dup(stdin_r, 0)
        unix.close(stdin_r)
      else
        -- stdin_r == 0: no dup2 to clear CLOEXEC, so clear it directly or
        -- fd 0 would close on execve; then just close the write end.
        unix.fcntl(0, unix.F_SETFD, 0)
        unix.close(stdin_w)
      end
    end

    -- stdout (fd 1)
    if stdout_is_fd then
      if opts.stdout ~= 1 then
        unix.dup(opts.stdout as number, 1)
      end
    else
      if stdout_w ~= 1 then
        unix.close(stdout_r)
        unix.dup(stdout_w, 1)
        unix.close(stdout_w)
      else
        -- stdout_w == 1: no dup2 to clear CLOEXEC, so clear it directly.
        unix.fcntl(1, unix.F_SETFD, 0)
        unix.close(stdout_r)
      end
    end

    -- stderr (fd 2)
    if stderr_is_fd then
      if opts.stderr ~= 2 then
        unix.dup(opts.stderr as number, 2)
      end
    else
      if stderr_w ~= 2 then
        unix.close(stderr_r)
        unix.dup(stderr_w, 2)
        unix.close(stderr_w)
      else
        -- stderr_w == 2: no dup2 to clear CLOEXEC, so clear it directly.
        unix.fcntl(2, unix.F_SETFD, 0)
        unix.close(stderr_r)
      end
    end

    -- change working directory if specified
    if opts.cwd then
      if not unix.chdir(opts.cwd) then
        os.exit(126)
      end
    end

    local env = opts.env and normalize_env(opts.env) or unix.environ()
    if exec_fd then
      unix.fexecve(exec_fd, argv, env)
    else
      unix.execve(prog, argv, env)
    end
    os.exit(127)
  end

  if exec_fd then
    unix.close(exec_fd)
  end

  if pid == nil then
    if not stdin_is_fd then
      unix.close(stdin_r)
      unix.close(stdin_w)
    end
    if not stdout_is_fd then
      unix.close(stdout_r)
      unix.close(stdout_w)
    end
    if not stderr_is_fd then
      unix.close(stderr_r)
      unix.close(stderr_w)
    end
    return nil, "fork failed"
  end

  if not stdin_is_fd then
    unix.close(stdin_r)
  end
  if not stdout_is_fd then
    unix.close(stdout_w)
  end
  if not stderr_is_fd then
    unix.close(stderr_w)
  end

  -- An opts.stdin string is delivered lazily by wait()/read()/communicate()
  -- via the pump, NOT written synchronously here: a >pipe-buffer write before
  -- anyone drains stdout/stderr would deadlock, and a child that exits early
  -- would SIGPIPE-kill this process. The pump feeds stdin and drains both
  -- output streams in one poll loop, so neither can happen.
  local stdin_data: string = nil
  if type(opts.stdin) == "string" then
    stdin_data = opts.stdin as string
  end

  local handle: Handle = {
    pid = pid,
    stdin = childio.make_pipe(stdin_w),
    stdout = childio.make_pipe(stdout_r),
    stderr = childio.make_pipe(stderr_r),
  }

  -- Run the process to completion: pump stdin in / stdout+stderr out without
  -- deadlock, then reap. Returns stdout, stderr, exit code (-1 if the process
  -- did not exit normally), and an error string (signal/abnormal exit, or a
  -- pump I/O error) that is nil on a clean normal exit.
  local function finish(): string, string, number, string
    local sfd = handle.stdin and handle.stdin.fd or nil
    handle.stdin = nil
    local out_fd = handle.stdout and handle.stdout.fd or nil
    local err_fd = handle.stderr and handle.stderr.fd or nil
    local out, err_out, io_err = childio.pump(out_fd, err_fd, sfd, stdin_data)
    if handle.stdout then handle.stdout:close(); handle.stdout = nil end
    if handle.stderr then handle.stderr:close(); handle.stderr = nil end
    local _, status = unix.wait(handle.pid)
    local code: number = -1
    local err: string = nil
    if type(status) ~= "number" then
      err = "wait failed: " .. tostring(status)
    elseif unix.WIFEXITED(status) then
      code = unix.WEXITSTATUS(status)
    elseif unix.WIFSIGNALED(status) then
      err = "killed by signal " .. tostring(unix.WTERMSIG(status))
    else
      err = "process terminated abnormally"
    end
    return out, err_out, code, err or io_err
  end

  --- Wait for the process to exit and return its exit code.
  --- Feeds any stdin and drains stdout/stderr first so it cannot deadlock.
  --- @return number The exit code if the process exited normally
  --- @return string Error message if the process terminated abnormally
  function handle:wait(): number, string
    local _, _, code, err = finish()
    if err then
      return nil, err
    end
    return code
  end

  --- Read output from the process.
  --- With a size, reads that many bytes from stdout and returns them (or
  --- nil, err). Without a size, runs the process to completion (feeding stdin,
  --- draining stdout+stderr) and returns success, stdout, and the exit code.
  --- To also capture stderr, use communicate().
  --- @param size number Optional number of bytes to read from stdout
  --- @return boolean|string Success (exit code 0) or, with size, the data read
  --- @return string The stdout output, or the error when size read fails
  --- @return number The exit code of the process
  function handle:read(size?: number): boolean | string, string, number
    if not self.stdout then
      return nil, "stdout not captured"
    end
    if size then
      if self.stdin then self.stdin:close(); self.stdin = nil end
      return self.stdout:read(size)
    end
    local out, _, code = finish()
    return code == 0, out, code
  end

  --- Run the process to completion and capture both output streams.
  --- Feeds any stdin while draining stdout and stderr concurrently, then reaps.
  --- @return string The captured stdout
  --- @return string The captured stderr
  --- @return number The exit code (-1 if the process did not exit normally)
  --- @return string An error (signal death, or a pump I/O error), or nil
  function handle:communicate(): string, string, number, string
    return finish()
  end

  return handle
end

local record ChildModule
  -- High-level spawn API
  spawn: function(argv: {string}, opts?: Opts): Handle, string

  -- Zip binary helpers
  prepare_zip_exec: function(zip_path: string): number, string

  -- Low-level primitives
  fork: function(): number
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): number
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): number
  wait: function(pid?: number, options?: number): number, number, Rusage
  kill: function(pid: number, sig: number): boolean

  -- Status helpers
  WIFEXITED: function(wstatus: number): boolean
  WEXITSTATUS: function(wstatus: number): number
  WIFSIGNALED: function(wstatus: number): boolean
  WTERMSIG: function(wstatus: number): number

  -- Wait options
  WNOHANG: number
  WUNTRACED: number
  WCONTINUED: number

  -- Common signals for child management
  SIGTERM: number
  SIGKILL: number
  SIGINT: number
  SIGCHLD: number
  SIGSTOP: number
  SIGCONT: number
end

local M: ChildModule = {
  -- High-level spawn API
  spawn = spawn,

  -- Zip binary helpers
  prepare_zip_exec = prepare_zip_exec,

  -- Low-level primitives
  fork = fork,
  posix_spawn = posix_spawn,
  posix_spawnp = posix_spawnp,
  wait = wait,
  kill = kill,

  -- Status helpers
  WIFEXITED = WIFEXITED,
  WEXITSTATUS = WEXITSTATUS,
  WIFSIGNALED = WIFSIGNALED,
  WTERMSIG = WTERMSIG,

  -- Wait options
  WNOHANG = unix.WNOHANG,
  WUNTRACED = unix.WUNTRACED,
  WCONTINUED = unix.WCONTINUED,

  -- Common signals for child management
  SIGTERM = unix.SIGTERM,
  SIGKILL = unix.SIGKILL,
  SIGINT = unix.SIGINT,
  SIGCHLD = unix.SIGCHLD,
  SIGSTOP = unix.SIGSTOP,
  SIGCONT = unix.SIGCONT,
}

return M
