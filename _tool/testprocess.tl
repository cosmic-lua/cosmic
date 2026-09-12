--- Bounded, file-backed supervision for one test process.
---
--- Test output goes to files rather than pipes. A descendant that inherits
--- stdout or stderr therefore cannot keep the runner blocked after the test
--- process exits. Timeouts terminate the test's process group, escalating
--- from SIGTERM to SIGKILL, and always reap the direct child.

local child = require("cosmic.child")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")
local signal = require("cosmic.signal")
local time = require("cosmic.time")

local TAIL_BYTES < const > = 16 * 1024
local POLL_MS < const > = 10
local TERM_GRACE_MS < const > = 250
local KILL_REAP_MS < const > = 1000

local record Options
  env: {string}
  temp_dir: string
  timeout_ms: integer
end

local record Result
  signal: integer | nil
  exit_code: integer
  stdout: string
  stderr: string
  elapsed_ms: integer
  timed_out: boolean
  cleanup_error: string
  start_error: string
end

local function close_handle(h: fd.Handle | nil): string
  if not h then return "" end
  local ok, err = h:close()
  if not ok then return tostring(err or "close failed") end
  return ""
end

-- Read a fixed snapshot through the descriptor opened before the child ran.
-- The child may unlink or replace the pathname, but cannot turn this regular
-- file description into a blocking FIFO. Timeout results need only the tail.
local function read_capture(h: fd.Handle, tail_only: boolean): string, string
  local size, serr = h:seek(0, fd.SEEK_END)
  if not size then return "", tostring(serr or "capture seek failed") end
  local offset = tail_only and math.max(0, size - TAIL_BYTES) or 0
  local remaining = size - offset
  local chunks: {string} = {}
  while remaining > 0 do
    local chunk, rerr = h:read(math.min(64 * 1024, remaining), offset)
    if not chunk then
      if rerr then return table.concat(chunks), rerr end
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
    remaining = remaining - #chunk
  end
  return table.concat(chunks), ""
end

--- Last at most 16 KiB of a stream.
--- @param content string Captured bytes
--- @return string Tail bytes
local function tail(content: string): string
  if #content <= TAIL_BYTES then return content end
  return content:sub(#content - TAIL_BYTES + 1)
end

local function poll(handle: child.Handle, deadline_ms: integer): child.Result | nil, string
  while true do
    local answer, err = handle:try_wait()
    if not answer then return nil, err end
    if answer.finished then return answer.result end
    local remaining = deadline_ms - time.monotonic_ms()
    if remaining <= 0 then return nil, "timeout" end
    local _rem, serr = time.sleep_ms(math.min(POLL_MS, remaining))
    if serr and not tostring(serr):find("EINTR", 1, true) then
      return nil, serr
    end
  end
end

local function send(handle: child.Handle, sig: integer): string
  local ok, err = signal.killpg(handle.pid, sig)
  if ok then return "" end
  -- A group may have disappeared between the reap poll and signal. The
  -- direct stop is still the safe fallback and gives a more useful error.
  local stopped, serr = handle:stop(sig)
  if stopped then return "" end
  return tostring(err or serr or "signal failed")
end

local function exit_code(result: child.Result): integer
  if result.code ~= nil then return result.code end
  if result.signal ~= nil then return 128 + result.signal end
  return 1
end

--- Run one argv under a monotonic deadline.
--- @param argv {string} Test command and arguments
--- @param opts Options Environment, capture directory, and positive limit
--- @return Result The bounded process result
local function run(argv: {string}, opts: Options): Result
  local stdout_path = fs.join(opts.temp_dir, "capture.out")
  local stderr_path = fs.join(opts.temp_dir, "capture.err")
  local stdin_h, stdin_err = fd.open("/dev/null", fd.O_RDONLY)
  local stdout_h, stdout_err = fd.open(stdout_path,
    fd.O_WRONLY | fd.O_CREAT | fd.O_TRUNC, tonumber("600", 8))
  local stderr_h, stderr_err = fd.open(stderr_path,
    fd.O_WRONLY | fd.O_CREAT | fd.O_TRUNC, tonumber("600", 8))
  local stdout_capture, stdout_capture_err = fd.open(stdout_path, fd.O_RDONLY)
  local stderr_capture, stderr_capture_err = fd.open(stderr_path, fd.O_RDONLY)
  if not stdin_h or not stdout_h or not stderr_h
  or not stdout_capture or not stderr_capture then
    local _ = close_handle(stdin_h)
    local _ = close_handle(stdout_h)
    local _ = close_handle(stderr_h)
    local _ = close_handle(stdout_capture)
    local _ = close_handle(stderr_capture)
    return {
      exit_code = 127, stdout = "", stderr = "", elapsed_ms = 0,
      timed_out = false, cleanup_error = "",
      start_error = tostring(stdin_err or stdout_err or stderr_err
        or stdout_capture_err or stderr_capture_err or "capture open failed"),
    }
  end

  local started_ms = time.monotonic_ms()
  local handle, start_err = child.start(argv, {
      env = opts.env, stdin = stdin_h, stdout = stdout_h, stderr = stderr_h,
      process_group = true,
    })
  local close_errors: {string} = {}
  for _, h in ipairs({stdin_h, stdout_h, stderr_h}) do
    local cerr = close_handle(h)
    if cerr ~= "" then close_errors[#close_errors + 1] = cerr end
  end
  if not handle then
    local stdout, stdout_read_err = read_capture(stdout_capture, true)
    local stderr, stderr_read_err = read_capture(stderr_capture, true)
    for _, item in ipairs({stdout_read_err, stderr_read_err,
        close_handle(stdout_capture), close_handle(stderr_capture)}) do
      if item ~= "" then close_errors[#close_errors + 1] = item end
    end
    return {
      exit_code = 127,
      stdout = stdout,
      stderr = stderr,
      elapsed_ms = time.monotonic_ms() - started_ms,
      timed_out = false,
      cleanup_error = table.concat(close_errors, "; "),
      start_error = tostring(start_err or "start failed"),
    }
  end

  local deadline_ms = started_ms + opts.timeout_ms
  local finished, wait_err = poll(handle, deadline_ms)
  local timed_out = wait_err == "timeout"
  local cleanup_errors = close_errors

  if not finished then
    if not timed_out then
      cleanup_errors[#cleanup_errors + 1] = tostring(wait_err or "wait failed")
    end
    local terr = send(handle, signal.SIGTERM)
    if terr ~= "" then cleanup_errors[#cleanup_errors + 1] = "SIGTERM: " .. terr end
    local term_deadline = time.monotonic_ms() + TERM_GRACE_MS
    finished, wait_err = poll(handle, term_deadline)
    -- Kill the group even when the direct child accepted SIGTERM: descendants
    -- can ignore it and otherwise survive their timed-out test file.
    local kerr = send(handle, signal.SIGKILL)
    if kerr ~= "" and not finished then
      cleanup_errors[#cleanup_errors + 1] = "SIGKILL: " .. kerr
    end
    if not finished then
      finished, wait_err = poll(handle, time.monotonic_ms() + KILL_REAP_MS)
    end
    if not finished then
      -- SIGKILL cannot be handled, but kernel I/O can delay its delivery.
      -- Never trade the runner's declared bound for an unbounded reap.
      cleanup_errors[#cleanup_errors + 1] = "reap exceeded " ..
      tostring(KILL_REAP_MS) .. "ms: " .. tostring(wait_err)
      handle:_abandon_after_kill()
    end
  end

  local stdout, stdout_read_err = read_capture(stdout_capture, timed_out or not finished)
  local stderr, stderr_read_err = read_capture(stderr_capture, timed_out or not finished)
  for _, item in ipairs({stdout_read_err, stderr_read_err,
      close_handle(stdout_capture), close_handle(stderr_capture)}) do
    if item ~= "" then cleanup_errors[#cleanup_errors + 1] = item end
  end
  if not finished then
    cleanup_errors[#cleanup_errors + 1] = tostring(wait_err or "wait failed")
  end
  return {
    signal = finished and finished.signal or nil,
    exit_code = finished and exit_code(finished) or 1,
    stdout = stdout,
    stderr = stderr,
    elapsed_ms = time.monotonic_ms() - started_ms,
    timed_out = timed_out,
    cleanup_error = table.concat(cleanup_errors, "; "),
    start_error = "",
  }
end

local record TestProcessModule
  type Options = Options
  type Result = Result
  TAIL_BYTES: integer
  tail: function(content: string): string
  run: function(argv: {string}, opts: Options): Result
end

local M: TestProcessModule = {
  TAIL_BYTES = TAIL_BYTES,
  tail = tail,
  run = run,
}

return M
