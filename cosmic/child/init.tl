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
--- simply dropping the handle) never leaves a zombie. Side effect: requiring
--- cosmic.child.io sets SIGPIPE to SIG_IGN process-wide (a child closing
--- stdin early gets EPIPE on the write, not a dead parent).
local unix = require("cosmo.unix")
local cfd = require("cosmic.fd")
local childio = require("cosmic.child.io")
local childfast = require("cosmic.child.fast")
local errno = require("cosmic.errno")
local stream = require("cosmic.stream")

--- Structured outcome of a finished child.
--- Exactly one of `code`/`signal` is set: `code` when the child exited,
--- `signal` when a signal killed it. `ok` is true only on a zero exit.
local record Result
  code: integer -- exit status; nil if signaled
  signal: integer -- terminating signal; nil if exited
  ok: boolean -- code == 0, and no io_error
  stdout: string
  stderr: string
  io_error: string -- a read/write/poll failure while pumping I/O; nil if none
end

--- Handle for a spawned process.
--- Fields prefixed `_` are internal bookkeeping; use the methods.
local record Handle is stream.Reader
  metamethod __close: function(self: Handle)
  pid: integer

  -- internal state (do not touch)
  _st: childio.PumpState
  _result: Result
  _closed: boolean

  --- Sends `sig` (default SIGTERM). Fails once reaped (pid may be recycled).
  kill: function(self: Handle, sig?: integer): boolean, string
  --- Non-blocking reap: Result if finished, `nil, nil` if running, or `nil, err` on failure.
  try_wait: function(self: Handle): Result | nil, string
  --- Runs the child to completion (feeding stdin, draining stdout+stderr) and
  --- returns its Result. With `timeout_ms`, returns `nil, "timeout"` if the
  --- child has not finished in time (the handle stays usable). Idempotent.
  wait: function(self: Handle, timeout_ms?: integer): Result | nil, string
  --- Streaming read of up to `size` bytes (default 65536) from the child's
  --- stdout. Returns bare nil at end of file (cosmic.stream contract). For
  --- whole-output capture use `wait`/`run`, which also collect stderr.
  read: function(self: Handle, size?: integer): string | nil, string
end

--- Options for spawning a process.
--- stdout/stderr Handles (cosmic.fd) become the child's fd 1/2 (the
--- matching Result field is then ""); spawn does not take ownership —
--- the child gets its own copy, so close your end when done (see
--- Example_run_pipe). Raw integer fds are not part of this surface
--- (api-review-2); wrap one with fd.wrap() first. "inherit" writes to
--- THIS process's fd 1/2 so output streams as it runs; Result stays "".
local record Options
  stdin: string | cfd.Handle -- string piped to stdin, or Handle -> fd 0
  stdout: cfd.Handle | childio.StdioMode -- child's fd 1, or "inherit"
  stderr: cfd.Handle | childio.StdioMode -- child's fd 2, or "inherit"
  env: {string}
  cwd: string
end

--- Normalize an env table to a list of "KEY=VALUE" strings.
local function normalize_env(env: {string}): {string}
  if env[1] ~= nil then
    return env
  end
  local list: {string} = {}
  for k, v in pairs(env as {string: string}) do -- cast: env list reused as map
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
--- @return integer | nil The file descriptor ready for fexecve
--- @return string Error message on failure
local function prepare_zip_exec(zip_path: string): integer | nil, string
  local fd, err = unix.open(zip_path, unix.O_RDONLY)
  if not fd then
    return nil, errno.str(err, "open zip path: " .. zip_path)
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
local function finish(self: Handle, status: integer): Result
  local r: Result = {
    stdout = table.concat(self._st.out),
    stderr = table.concat(self._st.err_out),
  }
  if unix.WIFEXITED(status) then
    r.code = unix.WEXITSTATUS(status)
    r.ok = r.code == 0
  elseif unix.WIFSIGNALED(status) then
    r.signal = unix.WTERMSIG(status)
    r.ok = false
  else
    r.ok = false
  end
  -- An I/O pump failure must not report a clean, silently-truncated result.
  if self._st.io_err then r.io_error = self._st.io_err; r.ok = false end
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
    childio.wait_retry(self.pid)
  end
  close_fds(self)
end

local handle_mt: metatable < Handle > = {
  __close = function(self: Handle) cleanup(self) end,
  __gc = function(self: Handle) cleanup(self) end,
}

-- Attach the Handle methods and finalizers to a freshly forked child.
local function make_handle(pid: integer, st: childio.PumpState): Handle
  local handle: Handle = {pid = pid, _st = st}

  function handle:kill(sig?: integer): boolean, string
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
    local _, status = childio.wait_retry(self.pid)
    if type(status) ~= "number" then
      return nil, "wait failed: " .. tostring(status)
    end
    return finish(self, status)
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
    return finish(self, status)
  end

  function handle:read(size?: integer): string | nil, string
    local fd = self._st.stdout_fd
    if not fd then
      return nil, "stdout not captured"
    end
    local chunk, err = childio.read_retry(fd, size or 65536)
    if chunk == nil then
      return nil, errno.str(err, "read")
    end
    if chunk == "" then
      return nil -- end of file (api-review-2, #589)
    end
    return chunk
  end

  return setmetatable(handle, handle_mt)
end

--- Spawns a child process with I/O control. Uses fexecve for /zip/ paths.
--- Returns a Handle on success. If the program cannot be executed, spawn
--- itself fails with `nil, "exec failed: ENOENT: ..."`, not a bogus exit
--- code from a later wait(). To spawn cosmic itself, use `rawget(arg, -1)`
--- — NOT arg[0], the script path (/zip/main.lua), not the interpreter.
--- @param argv {string} Command and arguments
--- @param opts Options? Spawn options
--- @return Handle | nil, string? Process handle or nil + error
local function spawn(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}

  -- Resolve caller-provided Handles to raw descriptors once, at the
  -- public boundary; below this point the plumbing speaks raw fds.
  local sio, sio_err = childio.resolve_stdio(opts.stdin, opts.stdout, opts.stderr)
  if not sio then
    return nil, sio_err
  end
  local stdio = sio as childio.Stdio -- cast: record union after guard
  local stdin_data, stdin_fd = stdio.stdin_data, stdio.stdin_fd
  local stdout_fd, stderr_fd = stdio.stdout_fd, stdio.stderr_fd

  -- Resolve the executable into a LOCAL, never by mutating the caller's argv:
  -- a PATH search that wrote back into argv[1] corrupts the caller's table.
  local exec_fd: integer
  local prog = argv[1]
  if is_zip_path(argv[1]) then
    local fd, err = prepare_zip_exec(argv[1])
    if not fd then
      return nil, err
    end
    exec_fd = fd
  elseif not argv[1]:find("/") then
    local cmd = unix.commandv(argv[1])
    if not cmd then
      return nil, "command not found: " .. argv[1]
    end
    prog = cmd
  end

  -- Track every fd we open so a mid-way pipe() failure (fd exhaustion) can be
  -- unwound cleanly, including the exec fd on the early-return path.
  local opened: {integer} = {}
  local function fail(msg: string): Handle, string
    for _, fd in ipairs(opened) do unix.close(fd) end
    if exec_fd then unix.close(exec_fd) end
    return nil, msg
  end
  -- Pipes are CLOEXEC so their ends do not leak into an unrelated child
  -- spawned while this handle is still open (which would keep an earlier
  -- child from seeing stdin EOF). The child's own dup2 onto 0/1/2 clears
  -- CLOEXEC on the ends it keeps.
  local function new_pipe(): integer, integer
    local r, w = unix.pipe(unix.O_CLOEXEC)
    if r == nil or w == nil then
      return nil, nil
    end
    table.insert(opened, r)
    table.insert(opened, w)
    return r, w
  end

  local stdin_r: integer
  local stdin_w: integer
  local stdin_is_fd = stdin_fd ~= nil
  if not stdin_is_fd then
    stdin_r, stdin_w = new_pipe()
    if not stdin_w then return fail("pipe failed (stdin)") end
  end

  local stdout_r: integer
  local stdout_w: integer
  local stdout_is_fd = stdout_fd ~= nil
  if not stdout_is_fd then
    stdout_r, stdout_w = new_pipe()
    if not stdout_w then return fail("pipe failed (stdout)") end
  end

  local stderr_r: integer
  local stderr_w: integer
  local stderr_is_fd = stderr_fd ~= nil
  if not stderr_is_fd then
    stderr_r, stderr_w = new_pipe()
    if not stderr_w then return fail("pipe failed (stderr)") end
  end

  -- Parent-side epilogue shared by both spawn paths: release the pipe ends
  -- the child owns and build the pump state around the ends we keep.
  local function parent_handle(pid: integer): Handle
    if not stdin_is_fd then unix.close(stdin_r) end
    if not stdout_is_fd then unix.close(stdout_w) end
    if not stderr_is_fd then unix.close(stderr_w) end
    -- An opts.stdin string is delivered lazily by the pump (in wait/run), not
    -- written synchronously here: a >pipe-buffer write before anyone drains
    -- stdout/stderr would deadlock. The pump feeds stdin and drains both
    -- output streams in one poll loop, so neither can happen.
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

  -- Fast path: posix_spawn (unix.spawn) needs no fork, runs no Lua in the
  -- child, and reports exec failure from the call itself, so the exec-status
  -- pipe below is unnecessary. It cannot fexecve a /zip/ binary or chdir, and
  -- it skips wiring any fd that already sits at its std number — right for
  -- caller-provided fds (the child inherits them as-is), wrong for our
  -- CLOEXEC pipe ends, which land on 0-2 only when that std fd was closed;
  -- fall back to fork for those cases.
  if not exec_fd and not opts.cwd then
    local pipe_on_std = (not stdin_is_fd and stdin_r == 0)
    or (not stdout_is_fd and stdout_w == 1)
    or (not stderr_is_fd and stderr_w == 2)
    if not pipe_on_std then
      local t0 = stdin_is_fd and stdin_fd or stdin_r
      local t1 = stdout_is_fd and stdout_fd or stdout_w
      local t2 = stderr_is_fd and stderr_fd or stderr_w
      local env = opts.env and normalize_env(opts.env) or nil
      local fpid, ferr = childfast.spawn(prog, argv, env, t0, t1, t2)
      if ferr then
        return fail(ferr)
      end
      if fpid then
        return parent_handle(fpid)
      end
    end
  end

  -- Exec-status pipe: CLOEXEC, so a successful execve closes the write end and
  -- the parent's read EOFs instantly. On exec failure the child writes the
  -- errno string here before _exit, making the failure visible to the parent.
  local exec_r, exec_w = new_pipe()
  if not exec_w then return fail("pipe failed (exec)") end

  local pid, ferr = unix.fork()
  if pid == 0 then
    unix.close(exec_r)
    -- Resolve sources before dup2 below can clobber one (childio.pin_source).
    local src0 = childio.pin_source(stdin_is_fd, stdin_fd, stdin_r, 0)
    local src1 = childio.pin_source(stdout_is_fd, stdout_fd, stdout_w, 1)
    local src2 = childio.pin_source(stderr_is_fd, stderr_fd, stderr_w, 2)
    -- stdin (fd 0)
    if stdin_is_fd then
      if stdin_fd ~= 0 then
        unix.dup(src0, 0)
      end
    else
      if stdin_r ~= 0 then
        unix.close(stdin_w)
        unix.dup(src0, 0)
        unix.close(stdin_r)
      else
        unix.fcntl(0, unix.F_SETFD, 0)
        unix.close(stdin_w)
      end
    end
    -- stdout (fd 1)
    if stdout_is_fd then
      if stdout_fd ~= 1 then
        unix.dup(src1, 1)
      end
    else
      if stdout_w ~= 1 then
        unix.close(stdout_r)
        unix.dup(src1, 1)
        unix.close(stdout_w)
      else
        unix.fcntl(1, unix.F_SETFD, 0)
        unix.close(stdout_r)
      end
    end
    -- stderr (fd 2)
    if stderr_is_fd then
      if stderr_fd ~= 2 then
        unix.dup(src2, 2)
      end
    else
      if stderr_w ~= 2 then
        unix.close(stderr_r)
        unix.dup(src2, 2)
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
      eerr = e
    else
      local _, e = unix.execve(prog, argv, env)
      eerr = e
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
    return nil, errno.str(ferr, "fork")
  end

  -- Parent: close the ends the child owns, then wait on the exec handshake.
  if not stdin_is_fd then unix.close(stdin_r) end
  if not stdout_is_fd then unix.close(stdout_w) end
  if not stderr_is_fd then unix.close(stderr_w) end
  unix.close(exec_w)

  -- A non-empty read means exec failed in the child; EOF means it succeeded.
  -- read_retry retries EINTR, so a nil exec_msg here is a genuine read
  -- failure (exec_rerr set) — a spawn error too, never a silent success.
  local exec_msg, exec_rerr = childio.read_retry(exec_r, 4096)
  unix.close(exec_r)
  if exec_msg == nil or exec_msg ~= "" then
    childio.wait_retry(pid)
    if not stdin_is_fd then unix.close(stdin_w) end
    if not stdout_is_fd then unix.close(stdout_r) end
    if not stderr_is_fd then unix.close(stderr_r) end
    if exec_msg == nil then return nil, errno.str(exec_rerr, "exec status read failed") end
    return nil, errno.str(exec_msg, "exec failed")
  end

  return parent_handle(pid)
end

--- One-shot spawn: run to completion and return the Result.
--- @param argv {string} Command and arguments
--- @param opts Options? Spawn options
--- @return Result | nil, string? The Result, or nil + error
local function run(argv: {string}, opts?: Options): Result | nil, string
  local h, err = spawn(argv, opts)
  if not h then
    return nil, err
  end
  return (h as Handle):wait() -- cast: record union after guard
end

local record ChildModule
  -- Exported types so callers can name/cast the fallible results.
  type Handle = Handle
  type Options = Options
  type Result = Result
  type StdioMode = childio.StdioMode -- Options' stdio mode, from the io shard

  -- High-level spawn API
  spawn: function(argv: {string}, opts?: Options): Handle | nil, string
  run: function(argv: {string}, opts?: Options): Result | nil, string

  -- Zip binary helper
  prepare_zip_exec: function(zip_path: string): integer | nil, string
end

local M: ChildModule = {
  spawn = spawn,
  run = run,
  prepare_zip_exec = prepare_zip_exec,
}

return M
