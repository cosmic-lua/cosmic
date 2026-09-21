--- Bounded child-process supervision with explicit argv, environment,
--- directory and file-descriptor redirection. Output is inherited unless a
--- caller redirects it to a file; this module deliberately does not collect
--- output in memory.
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Result
  code: integer | nil
  signal: integer | nil
  ok: boolean
  timed_out: boolean
end

local record Options
  env: {string:string}
  cwd: string
  stdin: integer | string
  stdout: integer | string
  stderr: integer | string
  process_group: boolean
  timeout_ms: integer
end

local record TryWait
  finished: boolean
  result: Result
end

local record Handle
  metamethod __close: function(Handle)
  pid: integer
  process_group: boolean
  _result: Result
  _closed: boolean
  _guarded: boolean
  wait: function(Handle, timeout_ms?: integer): Result | nil, string
  try_wait: function(Handle): TryWait | nil, string
  stop: function(Handle, signal?: integer): boolean, string
  close: function(Handle): boolean, string
end

local POLL_NS <const> = 10 * 1000 * 1000
local TERM_GRACE_NS <const> = 250 * 1000 * 1000
local KILL_REAP_NS <const> = 1000 * 1000 * 1000
local INT_MAX <const> = 2147483647

local function result(status: sys.ChildStatus, timed_out?: boolean): Result
  local r: Result = {
    ok = status.code == 0 and not timed_out,
    timed_out = timed_out or false,
  }
  if status.code >= 0 then r.code = status.code end
  if status.signal >= 0 then r.signal = status.signal end
  return r
end

local function now(): integer
  return assert(Time.monotonic_ns())
end

local function nap(until_ns: integer)
  local left = until_ns - now()
  if left > 0 then Time.sleep_ns(math.min(POLL_NS, left)) end
end

local function target(self: Handle): integer
  return self.process_group and -self.pid or self.pid
end

local function poll_until(self: Handle, deadline?: integer,
    timed_out?: boolean, ignore_cancel?: boolean): Result | nil, string
  while true do
    if not ignore_cancel then
      local cancelled, cancel_trouble = sys.cancelled_child_signal()
      if cancelled == nil then return nil, cancel_trouble end
      if cancelled ~= 0 then return nil, "cancelled:" .. tostring(cancelled) end
    end
    local status, trouble = sys.waitpid(self.pid, true)
    if not status then return nil, trouble end
    if status.pid ~= 0 then
      local r = result(status, timed_out)
      self._result, self._closed = r, true
      return r
    end
    if deadline and now() >= deadline then return nil, "timeout" end
    nap(deadline or now() + POLL_NS)
  end
end

local function terminate(self: Handle): Result | nil, string
  local ok, trouble = sys.kill(target(self), sys.SIGTERM)
  if not ok then
    -- The child may have exited between the last poll and this signal.
    local reaped = sys.waitpid(self.pid, true)
    if reaped then
      local status = reaped
      if status.pid ~= 0 then
        local r = result(status, true)
        self._result, self._closed = r, true
        return r
      end
    end
    return nil, trouble
  end
  local deadline = now() + TERM_GRACE_NS
  local r: Result
  while not r and now() < deadline do
    local answer, wait_trouble = poll_until(self, math.min(deadline,
      now() + POLL_NS), true, true)
    if answer then r = answer
    elseif wait_trouble ~= "timeout" then return nil, wait_trouble end
  end
  if r and not self.process_group then return r end
  -- Even when the direct child honored TERM, a descendant may have ignored
  -- it. The process group remains addressable until its final member exits.
  local killed, kill_trouble = sys.kill(target(self), sys.SIGKILL)
  if not killed and not r then return nil, kill_trouble end
  if r then return r end
  local final, reap_trouble = poll_until(self, now() + KILL_REAP_NS, true, true)
  if not final then
    return nil, "child did not reap after SIGKILL: " .. reap_trouble
  end
  return final
end

local function emergency_cleanup(self: Handle)
  sys.kill(target(self), sys.SIGKILL)
  for _ = 1, 100 do
    local status = sys.waitpid(self.pid, true)
    if status then
      local finished = status
      if finished.pid ~= 0 then
        self._result, self._closed = result(finished, true), true
        return
      end
    end
    sys.nanosleep(POLL_NS)
  end
end

local handle_mt: metatable<Handle> = {
  __close = function(self: Handle)
    if not self._closed then terminate(self) end
  end,
  __gc = function(self: Handle)
    if not self._closed then terminate(self) end
  end,
}

local function make_handle(pid: integer, process_group: boolean): Handle
  local h: Handle = { pid = pid, process_group = process_group }

  function h:try_wait(): TryWait | nil, string
    if self._result then return { finished = true, result = self._result } end
    local status, trouble = sys.waitpid(self.pid, true)
    if not status then return nil, trouble end
    if status.pid == 0 then return { finished = false } end
    local r = result(status)
    self._result, self._closed = r, true
    return { finished = true, result = r }
  end

  function h:stop(signal?: integer): boolean, string
    if self._closed then return false, "process already reaped" end
    local ok, trouble = sys.kill(target(self), signal or sys.SIGTERM)
    if not ok then return false, trouble end
    return true, ""
  end

  function h:wait(timeout_ms?: integer): Result | nil, string
    if self._result then return self._result end
    if timeout_ms == nil and not self._guarded then
      local status, trouble = sys.waitpid(self.pid, false)
      if not status then return nil, trouble end
      local r = result(status)
      self._result, self._closed = r, true
      return r
    end
    if timeout_ms == nil then return poll_until(self) end
    if timeout_ms < 0 then return nil, "timeout is negative" end
    local r, trouble = poll_until(self, now() + timeout_ms * 1000000)
    if r then return r end
    if trouble ~= "timeout" then return nil, trouble end
    return terminate(self)
  end

  function h:close(): boolean, string
    if self._closed then return true, "" end
    local r, trouble = terminate(self)
    if not r then return false, trouble end
    return true, ""
  end

  return setmetatable(h, handle_mt)
end

local record Child
  type Result = Result
  type Options = Options
  type TryWait = TryWait
  type Handle = Handle
end

local function descriptor(value: integer | string, name: string): integer | nil
  if value == nil or value == "inherit" then return nil end
  if value is integer and value >= 0 and value <= INT_MAX then return value end
  error(name .. " must be a file descriptor or 'inherit'", 3)
end

local function without_nul(value: string, name: string)
  if value:find("\0", 1, true) then error(name .. " contains a NUL byte", 3) end
end

local function validate(argv: {string}, opts: Options): boolean
  if #argv == 0 then error("argv is empty", 3) end
  for i, value in ipairs(argv) do
    if type(value) ~= "string" then error("argv[" .. tostring(i) .. "] must be a string", 3) end
    without_nul(value, "argv[" .. tostring(i) .. "]")
  end
  if opts.cwd ~= nil then without_nul(opts.cwd, "cwd") end
  if opts.env ~= nil then
    for name, value in pairs(opts.env) do
      if type(name) ~= "string" or name == "" or name:find("=", 1, true) then
        error("environment name is empty, non-string, or contains '='", 3)
      end
      if type(value) ~= "string" then error("environment value must be a string", 3) end
      without_nul(name, "environment name")
      without_nul(value, "environment value")
    end
  end
  descriptor(opts.stdin, "stdin")
  descriptor(opts.stdout, "stdout")
  descriptor(opts.stderr, "stderr")
  if opts.timeout_ms ~= nil and (opts.timeout_ms < 0 or opts.timeout_ms > INT_MAX) then
    error("timeout is out of range", 3)
  end
  return true
end

--- Starts one executable and returns an owning handle. argv[1] is an exact
--- path, without PATH lookup. Drop/close of an unfinished handle performs
--- bounded process-group termination; wait(timeout) does the same on expiry.
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  validate(argv, opts)
  local grouped = opts.process_group
  if grouped == nil then grouped = true end
  local pid, trouble = sys.spawn(argv[1], argv, opts.env, opts.cwd,
    descriptor(opts.stdin, "stdin"), descriptor(opts.stdout, "stdout"),
    descriptor(opts.stderr, "stderr"), grouped)
  if not pid then return nil, "start: " .. trouble end
  return make_handle(pid, grouped)
end

--- Runs one executable path to completion. argv[1] is used exactly as given:
--- there is no PATH search. A nil environment inherits this process's
--- environment; a table replaces it exactly. Standard streams inherit by
--- default, or accept caller-owned descriptors (which remain open here).
--- Children own a new process group by default so timeout cleanup includes
--- descendants. start returns that ownership as a Handle; run additionally
--- forwards SIGINT/SIGTERM, performs bounded group cleanup, restores the
--- caller's dispositions, and then re-delivers cancellation.
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  local guarded, guard_trouble = sys.guard_child_signals()
  if not guarded then return nil, "signal guard: " .. guard_trouble end
  local h: Handle
  local function supervised(): Result | nil, string
    local started, trouble = Child.start(argv, opts)
    if not started then return nil, trouble end
    h = started
    h._guarded = true
    return h:wait(opts.timeout_ms)
  end
  local called, r, wait_trouble = pcall(supervised)
  local cancellation: integer
  if called and wait_trouble and wait_trouble:sub(1, 10) == "cancelled:" then
    cancellation = assert(math.tointeger(assert(tonumber(wait_trouble:sub(11)))))
  end
  local cleanup_trouble: string
  if h and not h._closed and (not called or cancellation or not r) then
    local cleaned, answer, failure = pcall(terminate, h)
    if not cleaned then
      cleanup_trouble = tostring(answer)
      emergency_cleanup(h)
    else
      cleanup_trouble = failure
    end
  end
  local late_signal, restore_trouble = sys.unguard_child_signals()
  if late_signal == nil then
    if not called then error(r, 0) end
    return nil, "signal restore: " .. restore_trouble
  end
  cancellation = cancellation or (late_signal ~= 0 and late_signal or nil)
  if cancellation then
    -- Re-deliver after cleanup with the caller's original disposition.
    sys.kill(sys.getpid(), cancellation)
    return nil, cleanup_trouble or wait_trouble or "cancelled"
  end
  if not called then error(r, 0) end
  if cleanup_trouble then return nil, cleanup_trouble end
  return r, wait_trouble
end

return Child
