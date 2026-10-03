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
  end
  record Request
    argv: {string}
    cwd: string
    env: {string:string} | nil
    timeout_ns: integer | nil
    input: string | nil
    output: string | nil
    error: string | nil
    --- More descriptors the child gets, by the number it sees them as
    --- (Child.Options.fds); the caller keeps and closes them.
    fds: {integer:integer} | nil
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
  if request.timeout_ns and request.timeout_ns > 0 then
    options.timeout_ns = request.timeout_ns
  end
  if input_fd then options.stdin = input_fd end
  if output_fd then options.stdout = output_fd end
  if error_fd then options.stderr = error_fd end
  if request.fds then
    local fds: {integer:integer | string} = {}
    for number, fd in pairs(request.fds) do fds[number] = fd end
    options.fds = fds
  end
  local started = Time.monotonic_ns()
  local called, answer, trouble = pcall(Child.run, request.argv, options)
  local elapsed = Time.monotonic_ns() - started
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
  if result.timed_out then
    status, code = "timeout", 124
  elseif result.ok then
    status, code = "success", 0
  elseif result.signal then
    status, code = "signal", 128 + result.signal
  end
  return { result = result, status = status, code = code, elapsed_ns = elapsed }
end

local record Recording
  context: Runner.Context
  database: string
  phase: string
  id: integer
  started: integer
end

local function start(c: Runner.Context, phase: string, at?: integer): Recording
  local database = State.external_path(c.database, c.candidate)
  local started = at or Time.monotonic_ns()
  return { context = c, database = database, phase = phase, started = started,
    id = State.start(database, c.worker, c.run, c.attempt, phase, started) }
end

local function complete(recording: Recording, finished: integer, elapsed: integer,
                        status: string, code: integer | nil, signal: integer | nil,
                        timed_out: integer, detail: string | nil)
  local c = recording.context
  State.complete(recording.database, recording.id, c.worker, c.run, c.attempt,
    recording.phase, finished, elapsed, status, code, signal, timed_out, detail)
end

-- Runs `attempt` as one operation named `phase`: a start event, then a
-- complete event with its outcome, which a failure also names on stderr.
local function recorded(c: Runner.Context, phase: string,
                        attempt: function(): Runner.Outcome): Runner.Outcome
  local recording = start(c, phase)
  local called, answer = pcall(attempt)
  local outcome: Runner.Outcome
  if called then
    outcome = answer as Runner.Outcome
  else
    outcome = { status = "error", code = 1,
      trouble = limited(tostring(answer)),
      elapsed_ns = Time.monotonic_ns() - recording.started }
  end
  local result = outcome.result
  local exit_code: integer | nil = nil
  local signal: integer | nil = nil
  local timed_out = 0
  if result then
    exit_code, signal = result.code, result.signal
    timed_out = result.timed_out and 1 or 0
  end
  complete(recording, recording.started + outcome.elapsed_ns, outcome.elapsed_ns,
    outcome.status, exit_code, signal, timed_out, outcome.trouble)
  -- The database keeps the outcome for the summary; the log says it too,
  -- so an operation that fails without output of its own (a timeout, a
  -- command that never started) is named where the failure is read.
  if outcome.status ~= "success" then
    local why = outcome.trouble and (": " .. outcome.trouble) or ""
    Fs.put(Fs.stderr, phase .. ": " .. outcome.status .. " (status " ..
        tostring(outcome.code) .. ")" .. why .. "\n")
  end
  return outcome
end

function Runner.operation(c: Runner.Context, phase: string,
                          request: Runner.Request): Runner.Outcome
  return recorded(c, phase, function(): Runner.Outcome
    return Runner.execute(request)
  end)
end

--- Records `work`, done in this process, as one operation named `phase`,
--- as `operation` records a command: "success" when it returns true, and
--- "error" with its message when it returns false or raises.
function Runner.step(c: Runner.Context, phase: string,
                     work: function(): boolean, string): Runner.Outcome
  return recorded(c, phase, function(): Runner.Outcome
    local started = Time.monotonic_ns()
    local ok, trouble = work()
    local elapsed = Time.monotonic_ns() - started
    if ok then return { status = "success", code = 0, elapsed_ns = elapsed } end
    return { status = "error", code = 1, elapsed_ns = elapsed,
      trouble = limited((trouble or "") ~= "" and trouble or "failed") }
  end)
end

--- Records a phase's integer exit status, including its nested operations.
--- A raised error records exit code 1 and its full text, also said on stderr;
--- a returned nonzero status is kept as an exit without another diagnostic.
function Runner.phase(c: Runner.Context, phase: string,
                      action: function(): integer): integer
  local recording = start(c, phase, Time.monotonic_ns())
  local called, answer = pcall(action)
  local code = called and answer or 1
  local status = code == 0 and "success" or (called and "exit" or "error")
  local detail: string | nil = nil
  if not called then detail = tostring(answer) end
  local finished = Time.monotonic_ns()
  complete(recording, finished, finished - recording.started,
    status, code, nil, 0, detail)
  if detail then Fs.put(Fs.stderr, detail .. "\n") end
  return code
end

return Runner
