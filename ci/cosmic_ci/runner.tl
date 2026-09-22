local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")
local Time = require("cosmic.time")

local record Runner
  record Context
    database: string
    worker: string
    run: string
    attempt: string
    candidate: string
    driver: string
  end
  record Request
    argv: {string}
    cwd: string
    env: {string:string} | nil
    timeout_ms: integer | nil
    input: string | nil
    output: string | nil
    error: string | nil
  end
  record Outcome
    result: Child.Result | nil
    trouble: string | nil
    status: string
    code: integer
    elapsed_ns: integer
  end
end

local function limited(value: string): string
  if #value > 1000 then return value:sub(1, 1000) end
  return value
end

function Runner.execute(request: Runner.Request): Runner.Outcome
  local input_fd: integer | nil = nil
  local output_fd: integer | nil = nil
  local error_fd: integer | nil = nil
  local opened, open_failure = pcall(function(): boolean
    if request.input then input_fd = assert(Fs.open_read(request.input)) end
    if request.output then output_fd = assert(Fs.open_write(request.output)) end
    if request.error then error_fd = assert(Fs.open_write(request.error)) end
    return true
  end)
  if not opened then
    for _, fd in ipairs({ input_fd or -1, output_fd or -1, error_fd or -1 }) do
      if fd >= 0 then Fs.close(fd) end
    end
    error(open_failure)
  end
  local options: Child.Options = { cwd = request.cwd, process_group = true }
  if request.env then options.env = request.env end
  if request.timeout_ms and request.timeout_ms > 0 then
    options.timeout_ms = request.timeout_ms
  end
  if input_fd then options.stdin = input_fd end
  if output_fd then options.stdout = output_fd end
  if error_fd then options.stderr = error_fd end
  local started = assert(Time.monotonic_ns())
  local called, answer, trouble = pcall(Child.run, request.argv, options)
  local elapsed = assert(Time.monotonic_ns()) - started
  local close_ok, close_trouble = true, ""
  for _, fd in ipairs({ input_fd or -1, output_fd or -1, error_fd or -1 }) do
    if fd >= 0 then
      local ok, why = Fs.close(fd)
      if not ok then close_ok, close_trouble = false, tostring(why) end
    end
  end
  if not close_ok then error(close_trouble) end
  if not called then
    return { status = "error", code = 1, trouble = limited(tostring(answer)),
      elapsed_ns = elapsed }
  end
  local result = answer as Child.Result | nil
  if not result then
    return { status = "start-error", code = 1,
      trouble = limited(trouble or "child operation failed"), elapsed_ns = elapsed }
  end
  local status, code = "exit", result.code or 1
  if result.timed_out then status, code = "timeout", 124
  elseif result.ok then status, code = "success", 0
  elseif result.signal then status, code = "signal", 128 + result.signal end
  return { result = result, status = status, code = code, elapsed_ns = elapsed }
end

function Runner.operation(c: Runner.Context, phase: string,
    request: Runner.Request): Runner.Outcome
  local database = State.external_path(c.database, c.candidate, c.driver)
  local started = assert(Time.monotonic_ns())
  local id = State.start(database, c.worker, c.run, c.attempt, phase, started)
  local called, answer = pcall(Runner.execute, request)
  local outcome: Runner.Outcome
  if called then
    outcome = answer as Runner.Outcome
  else
    outcome = { status = "error", code = 1,
      trouble = limited(tostring(answer)),
      elapsed_ns = assert(Time.monotonic_ns()) - started }
  end
  local result = outcome.result
  local exit_code: integer | nil = nil
  local signal: integer | nil = nil
  local timed_out = 0
  if result then
    exit_code, signal = result.code, result.signal
    timed_out = result.timed_out and 1 or 0
  end
  State.complete(database, id, c.worker, c.run, c.attempt, phase,
    started + outcome.elapsed_ns, outcome.elapsed_ns, outcome.status,
    exit_code, signal, timed_out, outcome.trouble)
  return outcome
end

return Runner
