--- Child process management.
--- Spawn and manage child processes with I/O control.
local unix = require("cosmo.unix")

--- Process resource usage statistics.
--- Contains CPU time, memory usage, I/O, and context switch counters.
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

--- Pipe for reading/writing process I/O.
local record Pipe
  fd: number
  write: function(self: Pipe, data: string): number
  read: function(self: Pipe, size?: number): string
  close: function(self: Pipe)
end

--- Handle for a spawned process.
local record Handle
  pid: number
  stdin: Pipe
  stdout: Pipe
  stderr: Pipe
  wait: function(self: Handle): number, string
  read: function(self: Handle, size?: number): boolean | string, string, number
end

--- Options for spawning a process.
local record Opts
  stdin: string | number
  stdout: number
  stderr: number
  env: {string}
  cwd: string
end

local function make_pipe(fd: number): Pipe
  if not fd then
    return nil
  end
  local pipe: Pipe = {fd = fd}

  function pipe:write(data: string): number
    return unix.write(self.fd, data)
  end

  function pipe:read(size?: number): string
    if size then
      return unix.read(self.fd, size)
    end
    local chunks: {string} = {}
    while true do
      local chunk = unix.read(self.fd, 65536)
      if not chunk or chunk == "" then
        break
      end
      table.insert(chunks, chunk)
    end
    return table.concat(chunks)
  end

  pipe.close = function(self: Pipe)
    if self.fd then
      local _ = unix.close(self.fd)
      self.fd = nil
    end
  end

  return pipe
end

-- Low-level primitives --

--- Creates a new process (fork).
--- Returns twice: parent gets child's pid (> 0), child gets 0.
--- @return number The child process id in parent, 0 in child
local function fork(): number
  return unix.fork()
end

--- Spawns a new process using posix_spawn (low-level).
--- More efficient than fork() + execve() on some systems.
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables (KEY=value format). Inherits if not specified
--- @return number The child process id on success
local function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawn(prog, argv, envp)
end

--- Spawns a new process with PATH search (low-level).
--- Like posix_spawn() but searches for prog in $PATH directories.
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return number The child process id on success
local function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawnp(prog, argv, envp)
end

--- Waits for child process to terminate.
--- @param pid number? Process id to wait for. -1 waits for any child (default)
--- @param options number? Wait options (e.g., WNOHANG for non-blocking)
--- @return number The child process id that terminated
--- @return number Status code (use WIFEXITED, WEXITSTATUS, etc. to interpret)
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
  return unix.kill(pid, sig)
end

-- Status helpers --

--- Returns true if process exited normally (via exit() or return from main).
--- @param wstatus number Status code from wait()
--- @return boolean True if process exited cleanly
local function WIFEXITED(wstatus: number): boolean
  return unix.WIFEXITED(wstatus)
end

--- Returns the exit code passed to exit().
--- Only valid if WIFEXITED(wstatus) is true.
--- @param wstatus number Status code from wait()
--- @return number The exit code
local function WEXITSTATUS(wstatus: number): number
  return unix.WEXITSTATUS(wstatus)
end

--- Returns true if process was terminated by a signal.
--- @param wstatus number Status code from wait()
--- @return boolean True if terminated by signal
local function WIFSIGNALED(wstatus: number): boolean
  return unix.WIFSIGNALED(wstatus)
end

--- Returns the signal number that terminated the process.
--- Only valid if WIFSIGNALED(wstatus) is true.
--- @param wstatus number Status code from wait()
--- @return number The signal number
local function WTERMSIG(wstatus: number): number
  return unix.WTERMSIG(wstatus)
end

-- High-level spawn API --

--- Spawns a child process with I/O control.
--- @param argv {string} Command and arguments
--- @param opts Opts? Spawn options (stdin, stdout, stderr, env, cwd)
--- @return Handle Process handle with stdin, stdout, stderr pipes
--- @return string? Error message if spawn failed
local function spawn(argv: {string}, opts?: Opts): Handle, string
  opts = opts or {}

  if not (argv[1] as string):find("/") then
    local cmd = unix.commandv(argv[1])
    if not cmd then
      return nil, "command not found: " .. argv[1]
    end
  end

  local stdin_r: number
  local stdin_w: number
  local stdin_is_fd = type(opts.stdin) == "number"
  if not stdin_is_fd then
    stdin_r, stdin_w = unix.pipe()
  end

  local stdout_r: number
  local stdout_w: number
  local stdout_is_fd = type(opts.stdout) == "number"
  if not stdout_is_fd then
    stdout_r, stdout_w = unix.pipe()
  end

  local stderr_r: number
  local stderr_w: number
  local stderr_is_fd = type(opts.stderr) == "number"
  if not stderr_is_fd then
    stderr_r, stderr_w = unix.pipe()
  end

  local pid = unix.fork()
  if pid == 0 then
    -- stdin (fd 0)
    if stdin_is_fd then
      if opts.stdin ~= 0 then
        unix.close(0)
        unix.dup(opts.stdin as number)
      end
    else
      unix.close(0)
      unix.close(stdin_w)
      unix.dup(stdin_r)
      unix.close(stdin_r)
    end

    -- stdout (fd 1)
    if stdout_is_fd then
      if opts.stdout ~= 1 then
        unix.close(1)
        unix.dup(opts.stdout as number)
      end
    else
      unix.close(1)
      unix.close(stdout_r)
      unix.dup(stdout_w)
      unix.close(stdout_w)
    end

    -- stderr (fd 2)
    if stderr_is_fd then
      if opts.stderr ~= 2 then
        unix.close(2)
        unix.dup(opts.stderr as number)
      end
    else
      unix.close(2)
      unix.close(stderr_r)
      unix.dup(stderr_w)
      unix.close(stderr_w)
    end

    -- change working directory if specified
    if opts.cwd then
      if not unix.chdir(opts.cwd) then
        os.exit(126)
      end
    end

    if opts.env then
      if (argv[1] as string):find("/") then
        unix.execve(argv[1], argv, opts.env)
      else
        unix.execvpe(argv[1], argv, opts.env)
      end
    else
      -- no explicit env: inherit the parent's environment.
      -- environ() returns {string} ("KEY=VALUE" entries); copy to a
      -- plain table to avoid any issues with the original's identity.
      local src = unix.environ() as {string}
      local env: {string} = {}
      for i = 1, #src do env[i] = src[i] end
      if (argv[1] as string):find("/") then
        unix.execve(argv[1], argv, env)
      else
        unix.execvpe(argv[1], argv, env)
      end
    end
    os.exit(127)
  end

  if pid == nil then
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

  local handle: Handle = {
    pid = pid,
    stdin = make_pipe(stdin_w),
    stdout = make_pipe(stdout_r),
    stderr = make_pipe(stderr_r),
  }

  --- Wait for the process to exit and return its exit code.
  --- Closes stdin and reads/closes stdout and stderr before waiting.
  --- @return number The exit code if the process exited normally
  --- @return string Error message if the process terminated abnormally
  function handle:wait(): number, string
    if self.stdin then self.stdin:close() end
    if self.stdout then self.stdout:read() end
    if self.stderr then self.stderr:read() end
    if self.stdout then self.stdout:close() end
    if self.stderr then self.stderr:close() end
    local _, status = unix.wait(self.pid)
    if type(status) ~= "number" then
      return nil, "wait failed: " .. tostring(status)
    end
    if unix.WIFEXITED(status) then
      return unix.WEXITSTATUS(status)
    end
    if unix.WIFSIGNALED(status) then
      return nil, "killed by signal " .. tostring(unix.WTERMSIG(status))
    end
    return nil, "process terminated abnormally"
  end

  --- Read output from the process.
  --- If size is specified, reads that many bytes and returns the data as a string.
  --- If size is not specified, reads all output, waits for process to exit, and returns
  --- success status, output, and exit code.
  --- @param size number Optional number of bytes to read
  --- @return boolean|string Success status (true if exit code is 0) or output string if size specified
  --- @return string The stdout output from the process
  --- @return number The exit code of the process
  function handle:read(size?: number): boolean | string, string, number
    if not self.stdout then
      return nil, "stdout not captured"
    end
    if self.stdin then self.stdin:close() end
    local out = self.stdout:read(size)
    if size then
      return out
    end
    local exit_code = self:wait()
    return exit_code == 0, out, exit_code
  end

  if type(opts.stdin) == "string" then
    handle.stdin:write(opts.stdin as string)
    handle.stdin:close()
  end

  return handle
end

local record ChildModule
  -- High-level spawn API
  spawn: function(argv: {string}, opts?: Opts): Handle, string

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
