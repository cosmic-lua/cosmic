local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")

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
  --- An operation's start event, kept until its complete event.
  record Recording
    context: Context
    database: string
    phase: string
    id: integer
    started: integer
  end
  --- A command started by [`Runner.spawn`] and not yet reaped. Its
  --- recording and descriptors belong to the runner; hand it only to
  --- [`Runner.wait_any`], [`Runner.reap`] and [`Runner.stop`].
  record Running
    phase: string
    recording: Recording
    handle: Child.Handle | nil
    descriptors: {integer}
    --- Set when the command could not start, and once it is reaped.
    outcome: Outcome | nil
    reaped: boolean
  end
end

local function limited(value: string): string
  if #value > 1000 then return value:sub(1, 1000) end
  return value
end

--- Opens the files `request` names and builds the options its child is
--- started with; the descriptors are the caller's to close. Raises, with
--- none left open, when a file cannot be opened.
local function prepare(request: Runner.Request): Child.Options, {integer}
  local input_fd: integer | nil = nil
  local output_fd: integer | nil = nil
  local error_fd: integer | nil = nil
  local opened, open_failure = pcall(function(): boolean
    if request.input then input_fd = assert(Fs.open_read(request.input)) end
    if request.output then output_fd = assert(Fs.open_write(request.output)) end
    if request.error then error_fd = assert(Fs.open_write(request.error)) end
    return true
  end)
  local descriptors: {integer} = {}
  for _, fd in ipairs({ input_fd or -1, output_fd or -1, error_fd or -1 }) do
    if fd >= 0 then descriptors[#descriptors + 1] = fd end
  end
  if not opened then
    for _, fd in ipairs(descriptors) do Fs.close(fd) end
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
  return options, descriptors
end

--- Closes `descriptors`, raising the last failure after closing them all.
local function release(descriptors: {integer})
  local close_ok, close_trouble = true, ""
  for _, fd in ipairs(descriptors) do
    local ok, why = Fs.close(fd)
    if not ok then close_ok, close_trouble = false, tostring(why) end
  end
  if not close_ok then error(close_trouble) end
end

--- The outcome of a command that ran: how it ended, by `result`, or why
--- it did not (`called`, `answer` and `trouble` as pcall of Child.run
--- answers).
local function judged(called: boolean, answer: any, trouble: string | nil,
                      elapsed: integer): Runner.Outcome
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
    status, code = "signal", Child.shell_status(result)
  end
  return { result = result, status = status, code = code, elapsed_ns = elapsed }
end

function Runner.execute(request: Runner.Request): Runner.Outcome
  local options, descriptors = prepare(request)
  local started = Clock.monotonic_ns()
  local called, answer, trouble = pcall(Child.run, request.argv, options)
  local elapsed = Clock.monotonic_ns() - started
  release(descriptors)
  return judged(called, answer, trouble, elapsed)
end

local type Recording = Runner.Recording

local function start(c: Runner.Context, phase: string, at?: integer): Recording
  local database = State.external_path(c.database, c.candidate)
  local started = at or Clock.monotonic_ns()
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

-- Writes `outcome` as `recording`'s complete event, which a failure also
-- names on stderr.
local function finish(recording: Recording, phase: string, outcome: Runner.Outcome)
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
      elapsed_ns = Clock.monotonic_ns() - recording.started }
  end
  finish(recording, phase, outcome)
  return outcome
end

function Runner.operation(c: Runner.Context, phase: string,
                          request: Runner.Request): Runner.Outcome
  return recorded(c, phase, function(): Runner.Outcome
    return Runner.execute(request)
  end)
end

--- Starts `request` as the operation `phase` without waiting for it: the
--- start event is written now (by this process alone: the state database
--- is written from one process), the complete event when the command is
--- reaped ([`Runner.reap`]), stopped ([`Runner.stop`]) or returned by
--- [`Runner.wait_any`]. The request's timeout counts from here and ends
--- the command while it is waited on, as `operation`'s does. A command
--- that cannot start is returned already ended, its outcome an "error" or
--- "start-error", for `reap` to record. The caller reaps or stops every
--- command it spawned.
function Runner.spawn(c: Runner.Context, phase: string,
                      request: Runner.Request): Runner.Running
  local recording = start(c, phase)
  local running: Runner.Running = { phase = phase, recording = recording,
    descriptors = {}, reaped = false }
  local called, answer, started_trouble = pcall(function(): Child.Handle | nil, string
    local options, descriptors = prepare(request)
    running.descriptors = descriptors
    local handle, trouble = Child.start(request.argv, options)
    if handle == nil then
      release(descriptors)
      running.descriptors = {}
    end
    return handle, trouble
  end)
  if not called then
    running.outcome = { status = "error", code = 1, trouble = limited(tostring(answer)),
      elapsed_ns = Clock.monotonic_ns() - recording.started }
  else
    local handle = answer as Child.Handle | nil
    if handle then
      running.handle = handle
    else
      running.outcome = judged(true, nil, started_trouble as string | nil,
        Clock.monotonic_ns() - recording.started)
    end
  end
  return running
end

local function settle(running: Runner.Running, outcome: Runner.Outcome): Runner.Outcome
  running.handle = nil
  local released, trouble = pcall(function(): boolean
    release(running.descriptors)
    return true
  end)
  running.descriptors = {}
  if not released then
    outcome = { status = "error", code = 1, trouble = limited(tostring(trouble)),
      elapsed_ns = outcome.elapsed_ns }
  end
  running.outcome = outcome
  running.reaped = true
  finish(running.recording, running.phase, outcome)
  return outcome
end

--- Waits for the first of `commands` ([`Runner.spawn`]ed; the caller drops
--- each it has reaped) to end and returns it, ready to reap. A command that never started
--- counts as ended. Each command's own timeout ends it while it is
--- waited on. Raises when the wait itself fails, the commands left running.
function Runner.wait_any(commands: {Runner.Running}): Runner.Running
  assert(#commands > 0, "runner: no commands to wait for")
  local handles: {Child.Handle} = {}
  for _, command in ipairs(commands) do
    if command.outcome then return command end
    handles[#handles + 1] = command.handle as Child.Handle
  end
  local done, trouble = Child.wait_any(handles)
  if done == nil then error("runner: waiting failed: " .. tostring(trouble), 0) end
  for _, command in ipairs(commands) do
    if command.handle == done then return command end
  end
  error("runner: waited on a command it did not start", 0)
end

--- Reaps `running`, which has ended ([`Runner.wait_any`] returned it) or is
--- waited for here, and records its complete event. Returns the outcome,
--- the same again if it is reaped twice. A command that ran past its
--- timeout was ended, as `operation`'s is: "timeout", status 124.
function Runner.reap(running: Runner.Running): Runner.Outcome
  if running.reaped then return running.outcome as Runner.Outcome end
  local handle = running.handle
  if handle == nil then
    return settle(running, running.outcome as Runner.Outcome)
  end
  local called, answer, trouble = pcall(handle.wait, handle)
  local elapsed = Clock.monotonic_ns() - running.recording.started
  return settle(running, judged(called, answer, trouble, elapsed))
end

--- Ends `running` and its process group if it still runs, SIGTERM, a
--- grace period, then SIGKILL, waits for it to go and records it as
--- "cancelled" (status 130). A command that already ended keeps its outcome.
function Runner.stop(running: Runner.Running): Runner.Outcome
  local handle = running.handle
  if handle == nil then return Runner.reap(running) end
  local polled = handle:try_wait()
  if polled and polled.finished then return Runner.reap(running) end
  local _, _ = handle:close()
  local elapsed = Clock.monotonic_ns() - running.recording.started
  return settle(running, { status = "cancelled", code = 130, elapsed_ns = elapsed,
    trouble = "stopped before it ended" })
end

--- Records `work`, done in this process, as one operation named `phase`,
--- as `operation` records a command: "success" when it returns true, and
--- "error" with its message when it returns false or raises.
function Runner.step(c: Runner.Context, phase: string,
                     work: function(): boolean, string): Runner.Outcome
  return recorded(c, phase, function(): Runner.Outcome
    local started = Clock.monotonic_ns()
    local ok, trouble = work()
    local elapsed = Clock.monotonic_ns() - started
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
  local recording = start(c, phase, Clock.monotonic_ns())
  local called, answer = pcall(action)
  local code = called and answer or 1
  local status = code == 0 and "success" or (called and "exit" or "error")
  local detail: string | nil = nil
  if not called then detail = tostring(answer) end
  local finished = Clock.monotonic_ns()
  complete(recording, finished, finished - recording.started,
    status, code, nil, 0, detail)
  if detail then Fs.put(Fs.stderr, detail .. "\n") end
  return code
end

return Runner
