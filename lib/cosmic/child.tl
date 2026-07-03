--- Child process management.
--- Spawn and manage child processes with I/O control.
local unix = require("cosmo.unix")
local poll = require("cosmic.poll")

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

--- Pipe for process I/O. fd is a plain field (not a method like io.Handle:fd()).
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
--- stdout/stderr: raw fd dup2'd onto fd 1/2; handle fields nil.
--- Close write end before reading. See Example_spawn_pipe.
local record Opts
  stdin: string | number -- string piped to stdin, or raw fd dup2'd onto fd 0
  stdout: number -- raw fd -> fd 1; handle.stdout becomes nil
  stderr: number -- raw fd -> fd 2; handle.stderr becomes nil
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

--- Creates a new process (fork).
--- @return number The child process id in parent, 0 in child
local function fork(): number
  return unix.fork()
end

--- Spawns a new process using posix_spawn (low-level).
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables (KEY=value format)
--- @return number The child process id on success
local function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawn(prog, argv, envp)
end

--- Spawns a new process with PATH search (low-level).
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables
--- @return number The child process id on success
local function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawnp(prog, argv, envp)
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
  return unix.kill(pid, sig)
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

  -- Handle /zip/ paths: open zip fd for fexecve
  local exec_fd: number
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
    argv[1] = cmd
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
        -- stdin_r == 0: dup2(0, 0) is fine, just close the write end
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
        -- stdout_w == 1: dup2(1, 1) is fine, just close the read end
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
        -- stderr_w == 2: dup2(2, 2) is fine, just close the read end
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
      unix.execve(argv[1], argv, env)
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

  -- Drain stdout and stderr concurrently using poll to avoid deadlock.
  local function drain_pipes(out_pipe: Pipe, err_pipe: Pipe): string, string
    local out_chunks: {string} = {}
    local err_chunks: {string} = {}
    if not out_pipe and not err_pipe then
      return "", ""
    end
    local poller = poll.new()
    if out_pipe then poller:add(out_pipe.fd, poll.POLLIN) end
    if err_pipe then poller:add(err_pipe.fd, poll.POLLIN) end
    while not poller:empty() do
      for fd, events in poller:wait(-1) do
        if events.readable then
          local chunk = unix.read(fd, 65536)
          if not chunk or chunk == "" then
            poller:remove(fd)
          else
            if out_pipe and fd == out_pipe.fd then
              table.insert(out_chunks, chunk)
            elseif err_pipe and fd == err_pipe.fd then
              table.insert(err_chunks, chunk)
            end
          end
        end
        if events.hangup or events.error then
          poller:remove(fd)
        end
      end
    end
    if out_pipe then out_pipe:close() end
    if err_pipe then err_pipe:close() end
    return table.concat(out_chunks), table.concat(err_chunks)
  end

  local handle: Handle = {
    pid = pid,
    stdin = make_pipe(stdin_w),
    stdout = make_pipe(stdout_r),
    stderr = make_pipe(stderr_r),
  }

  --- Wait for the process to exit and return its exit code.
  --- Closes stdin and drains stdout and stderr concurrently before waiting.
  --- @return number The exit code if the process exited normally
  --- @return string Error message if the process terminated abnormally
  function handle:wait(): number, string
    if self.stdin then self.stdin:close() end
    drain_pipes(self.stdout, self.stderr)
    self.stdout = nil
    self.stderr = nil
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
  --- If size is not specified, drains stdout and stderr concurrently, waits for
  --- process to exit, and returns success status, stdout output, and exit code.
  --- @param size number Optional number of bytes to read
  --- @return boolean|string Success status (true if exit code is 0) or output string if size specified
  --- @return string The stdout output from the process
  --- @return number The exit code of the process
  function handle:read(size?: number): boolean | string, string, number
    if not self.stdout then
      return nil, "stdout not captured"
    end
    if self.stdin then self.stdin:close() end
    if size then
      return self.stdout:read(size)
    end
    local out, _ = drain_pipes(self.stdout, self.stderr)
    self.stdout = nil
    self.stderr = nil
    local _, status = unix.wait(self.pid)
    if type(status) ~= "number" then
      return false, out, -1
    end
    local exit_code = unix.WIFEXITED(status) and unix.WEXITSTATUS(status) or -1
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
