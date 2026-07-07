--- Child process management.
---
--- The high-level spawn API. `spawn` starts a process and hands back a
--- `Handle` you can `kill`, `wait` on (with an optional timeout), poll with
--- `try_wait`, or stream from with `read`. `run` is the one-shot form that
--- spawns, waits, and returns a structured `Result`. Low-level syscall
--- passthroughs (fork/wait/kill/posix_spawn, the W* status helpers) live in
--- `cosmic.proc`; this module builds the ergonomic layer on top.
---
--- A Handle owns the child: `wait`/`run` reap it and cache the `Result`, so a
--- second `wait` returns the same value instead of failing. An abandoned
--- handle is not leaked — its `__gc`/`__close` metamethods SIGKILL and reap an
--- un-waited child and close its pipes, so `local h <close> = spawn{...}` (or
--- simply dropping the handle) never leaves a zombie.
local unix = require("cosmo.unix")
local childio = require("cosmic.child_io")
local errno = require("cosmic.errno")

--- Structured outcome of a finished child.
--- Exactly one of `code`/`signal` is set: `code` when the child exited,
--- `signal` when a signal killed it. `ok` is true only on a zero exit.
local record Result
  code: integer -- exit status; nil if signaled
  signal: integer -- terminating signal; nil if exited
  ok: boolean -- code == 0
  stdout: string
  stderr: string
end

--- Handle for a spawned process.
--- Fields prefixed `_` are internal bookkeeping; use the methods.
local record Handle
  pid: integer

  -- internal state (do not touch)
  _st: childio.PumpState
  _result: Result
  _closed: boolean

  --- Sends `sig` (default SIGTERM) to the child. Fails once the child has
  --- been reaped, since its pid may have been recycled.
  kill: function(self: Handle, sig?: number): boolean, string
  --- Non-blocking reap: the cached/final Result if the child has finished,
  --- `nil, nil` while it is still running, or `nil, err` on a wait error.
  try_wait: function(self: Handle): Result | nil, string
  --- Runs the child to completion (feeding stdin, draining stdout+stderr) and
  --- returns its Result. With `timeout_ms`, returns `nil, "timeout"` if the
  --- child has not finished in time; the handle stays usable (wait again, or
  --- kill it). Idempotent: repeat calls return the same cached Result.
  wait: function(self: Handle, timeout_ms?: integer): Result | nil, string
  --- Streaming read of up to `size` bytes from the child's stdout. Returns
  --- "" at end of file. `size` is required; for whole-output capture use
  --- `wait`/`run`, which also collect stderr and cannot deadlock.
  read: function(self: Handle, size: integer): string | nil, string
end

--- Options for spawning a process.
--- stdout/stderr as numbers are raw fds dup2'd onto the child's fd 1/2 (the
--- corresponding Result field is then ""). See Example_spawn_pipe.
local record Opts
  stdin: string | number -- string piped to stdin, or raw fd dup2'd onto fd 0
  stdout: number -- raw fd -> fd 1
  stderr: number -- raw fd -> fd 2
  env: {string}
  cwd: string
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

--- Prepares an executable fd from a /zip/ path for fexecve.
--- @param zip_path string Path starting with /zip/
--- @return number | nil The file descriptor ready for fexecve
--- @return string Error message on failure
local function prepare_zip_exec(zip_path: string): number | nil, string
  local fd = unix.open(zip_path, unix.O_RDONLY)
  if not fd then
    return nil, "failed to open zip path: " .. zip_path
  end
  return fd
end

-- Close the child's stdin/stdout/stderr fds still held in the pump state,
-- once. Safe to call repeatedly.
local function close_fds(self: Handle)
  local st = self._st
  if st.stdin_fd then unix.close(st.stdin_fd); st.stdin_fd = nil end
  if st.stdout_fd then unix.close(st.stdout_fd); st.stdout_fd = nil end
  if st.stderr_fd then unix.close(st.stderr_fd); st.stderr_fd = nil end
end

-- Build and cache the Result from a reaped status word, then release fds.
local function finish(self: Handle, status: number): Result
  local r: Result = {
    stdout = table.concat(self._st.out),
    stderr = table.concat(self._st.err_out),
  }
  if unix.WIFEXITED(status) then
    r.code = unix.WEXITSTATUS(status) as integer
    r.ok = r.code == 0
  elseif unix.WIFSIGNALED(status) then
    r.signal = unix.WTERMSIG(status) as integer
    r.ok = false
  else
    r.ok = false
  end
  self._result = r
  close_fds(self)
  return r
end

-- Kill (SIGKILL) and reap an un-waited child, then close its fds. Runs from
-- __gc/__close so an abandoned handle never leaks a zombie or descriptors.
local function cleanup(self: Handle)
  if self._closed then return end
  self._closed = true
  if not self._result then
    unix.kill(self.pid, unix.SIGKILL)
    unix.wait(self.pid)
  end
  close_fds(self)
end

local handle_mt: metatable < Handle > = {
  __close = function(self: Handle) cleanup(self) end,
  __gc = function(self: Handle) cleanup(self) end,
}

-- Attach the Handle methods and finalizers to a freshly forked child.
local function make_handle(pid: number, st: childio.PumpState): Handle
  local handle: Handle = {pid = pid as integer, _st = st}

  function handle:kill(sig?: number): boolean, string
    if self._result then
      return false, "kill: process already reaped"
    end
    local ok, err = unix.kill(self.pid, sig or unix.SIGTERM)
    if not ok then
      return false, errno.str(err, "kill")
    end
    return true
  end

  function handle:wait(timeout_ms?: integer): Result | nil, string
    if self._result then
      return self._result
    end
    local deadline: number = nil
    if timeout_ms then
      deadline = childio.now_ms() + timeout_ms
    end
    local timed_out = childio.pump(self._st, deadline)
    if timed_out then
      return nil, "timeout"
    end
    local _, status = unix.wait(self.pid)
    if type(status) ~= "number" then
      return nil, "wait failed: " .. tostring(status)
    end
    return finish(self, status as number)
  end

  function handle:try_wait(): Result | nil, string
    if self._result then
      return self._result
    end
    local wpid, status = unix.wait(self.pid, unix.WNOHANG)
    if wpid == nil then
      return nil, "wait failed: " .. tostring(status)
    end
    if wpid == 0 then
      return nil -- still running
    end
    -- Reaped: the child is gone, so draining hits EOF promptly.
    childio.pump(self._st, nil)
    return finish(self, status as number)
  end

  function handle:read(size: integer): string | nil, string
    local fd = self._st.stdout_fd
    if not fd then
      return nil, "stdout not captured"
    end
    local chunk, err = unix.read(fd, size)
    if chunk == nil then
      return nil, errno.str(err, "read")
    end
    return chunk
  end

  return setmetatable(handle, handle_mt)
end

--- Spawns a child process with I/O control. Uses fexecve for /zip/ paths.
--- Returns a Handle on success. If the program cannot be executed, spawn
--- itself fails with `nil, "exec failed: ENOENT: ..."` — the error surfaces
--- here, not as a bogus exit code from a later wait().
--- To spawn cosmic itself, use `rawget(arg, -1)` — NOT arg[0], which is
--- the script path (/zip/main.lua), not the interpreter.
--- @param argv {string} Command and arguments
--- @param opts Opts? Spawn options
--- @return Handle | nil, string? Process handle or nil + error
local function spawn(argv: {string}, opts?: Opts): Handle | nil, string
  opts = opts or {}

  -- Resolve the executable into a LOCAL, never by mutating the caller's argv:
  -- a PATH search that wrote back into argv[1] corrupts the caller's table.
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
  -- unwound cleanly, including the exec fd on the early-return path.
  local opened: {number} = {}
  local function fail(msg: string): Handle, string
    for _, fd in ipairs(opened) do unix.close(fd) end
    if exec_fd then unix.close(exec_fd) end
    return nil, msg
  end
  -- Pipes are CLOEXEC so their ends do not leak into an unrelated child
  -- spawned while this handle is still open (which would keep an earlier
  -- child from seeing stdin EOF). The child's own dup2 onto 0/1/2 clears
  -- CLOEXEC on the ends it keeps.
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

  -- Exec-status pipe: CLOEXEC, so a successful execve closes the write end and
  -- the parent's read EOFs instantly. On exec failure the child writes the
  -- errno string here before _exit, making the failure visible to the parent.
  local exec_r, exec_w = new_pipe()
  if not exec_w then return fail("pipe failed (exec)") end

  local pid = unix.fork()
  if pid == 0 then
    unix.close(exec_r)

    -- stdin (fd 0)
    if stdin_is_fd then
      if opts.stdin ~= 0 then
        unix.dup(opts.stdin as number, 0)
      end
    else
      if stdin_r ~= 0 then
        unix.close(stdin_w)
        unix.dup(stdin_r, 0)
        unix.close(stdin_r)
      else
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
        unix.fcntl(2, unix.F_SETFD, 0)
        unix.close(stderr_r)
      end
    end

    if opts.cwd then
      if not unix.chdir(opts.cwd) then
        local _ = unix.write(exec_w, "chdir failed: " .. tostring(opts.cwd))
        os.exit(127)
      end
    end

    local env = opts.env and normalize_env(opts.env) or unix.environ()
    local eerr: string
    if exec_fd then
      local _, e = unix.fexecve(exec_fd, argv, env)
      eerr = e as string
    else
      local _, e = unix.execve(prog, argv, env)
      eerr = e as string
    end
    -- Only reached when exec failed. Report the errno through the pipe so the
    -- parent's spawn() can return it, then exit distinctly.
    local _ = unix.write(exec_w, tostring(eerr))
    os.exit(127)
  end

  if exec_fd then
    unix.close(exec_fd)
  end

  if pid == nil then
    for _, fd in ipairs(opened) do unix.close(fd) end
    return nil, "fork failed"
  end

  -- Parent: close the ends the child owns, then wait on the exec handshake.
  if not stdin_is_fd then unix.close(stdin_r) end
  if not stdout_is_fd then unix.close(stdout_w) end
  if not stderr_is_fd then unix.close(stderr_w) end
  unix.close(exec_w)

  -- A non-empty read means exec failed inside the child: reap it and surface
  -- the error from spawn itself. EOF (empty read) means exec succeeded.
  local exec_msg = unix.read(exec_r, 4096)
  unix.close(exec_r)
  if exec_msg ~= nil and exec_msg ~= "" then
    unix.wait(pid)
    if not stdin_is_fd then unix.close(stdin_w) end
    if not stdout_is_fd then unix.close(stdout_r) end
    if not stderr_is_fd then unix.close(stderr_r) end
    return nil, errno.str(exec_msg, "exec failed")
  end

  -- An opts.stdin string is delivered lazily by the pump (in wait/run), not
  -- written synchronously here: a >pipe-buffer write before anyone drains
  -- stdout/stderr would deadlock. The pump feeds stdin and drains both output
  -- streams in one poll loop, so neither can happen.
  local stdin_data: string = nil
  if type(opts.stdin) == "string" then
    stdin_data = opts.stdin as string
  end

  local st: childio.PumpState = {
    stdout_fd = stdout_is_fd and nil or stdout_r,
    stderr_fd = stderr_is_fd and nil or stderr_r,
    stdin_fd = stdin_is_fd and nil or stdin_w,
    stdin_data = stdin_data,
    stdin_off = 0,
    out = {},
    err_out = {},
  }

  return make_handle(pid, st)
end

--- One-shot spawn: run to completion and return the Result.
--- @param argv {string} Command and arguments
--- @param opts Opts? Spawn options
--- @return Result | nil, string? The Result, or nil + error
local function run(argv: {string}, opts?: Opts): Result | nil, string
  local h, err = spawn(argv, opts)
  if not h then
    return nil, err
  end
  return (h as Handle):wait()
end

local record ChildModule
  -- Exported types so callers can name/cast the fallible results.
  type Handle = Handle
  type Opts = Opts
  type Result = Result

  -- High-level spawn API
  spawn: function(argv: {string}, opts?: Opts): Handle | nil, string
  run: function(argv: {string}, opts?: Opts): Result | nil, string

  -- Zip binary helper
  prepare_zip_exec: function(zip_path: string): number | nil, string
end

local M: ChildModule = {
  spawn = spawn,
  run = run,
  prepare_zip_exec = prepare_zip_exec,
}

return M
