local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Seams = require("cosmic_ci.seams")
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
    env?: {string:string}
    timeout_ns?: integer
    input?: string
    output?: string
    error?: string
    --- More descriptors the child gets, by the number it sees them as
    --- (Child.Options.fds); the caller keeps and closes them.
    fds?: {integer:integer}
  end
  record Outcome
    result?: Child.Result
    trouble?: string
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
    mut handle?: Child.Handle
    mut descriptors: {integer}
    --- Set when the command could not start, and once it is reaped.
    mut outcome?: Outcome
    mut reaped: boolean
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
  local record Opened
    mut input?: integer
    mut output?: integer
    mut error?: integer
  end
  local fds_opened: Opened = {}
  local opened, open_failure = pcall(function(): boolean
    local input = request.input
    if input then fds_opened.input = assert(Fs.open_read(input)) end
    local output = request.output
    if output then fds_opened.output = assert(Fs.open_write(output)) end
    local request_error = request.error
    if request_error then fds_opened.error = assert(Fs.open_write(request_error)) end
    return true
  end)
  local input_fd, output_fd, error_fd = fds_opened.input, fds_opened.output, fds_opened.error
  local descriptors: mut {integer} = {}
  for _, fd in ipairs({ input_fd or -1, output_fd or -1, error_fd or -1 }) do
    if fd >= 0 then descriptors[#descriptors + 1] = fd end
  end
  if not opened then
    for _, fd in ipairs(descriptors) do
      local _, _ = Fs.close(fd)
    end
    error(open_failure)
  end
  local limit: integer? = nil
  local timeout_ns = request.timeout_ns
  if timeout_ns ~= nil and timeout_ns > 0 then limit = timeout_ns end
  local fds: {integer:integer | string}? = nil
  local request_fds = request.fds
  if request_fds then
    local copy: mut {integer:integer | string} = {}
    for number, fd in pairs(request_fds) do copy[number] = fd end
    fds = copy
  end
  local options: Child.Options = { cwd = request.cwd, process_group = true, env = request.env,
    timeout_ns = limit, stdin = input_fd, stdout = output_fd, stderr = error_fd, fds = fds }
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

--- What a call run under `pcall` came to: what it raised, else its result,
--- or why it answered none.
local record Called
  mut raised?: string
  mut result?: Child.Result
  mut trouble?: string
end

--- The outcome of a command that ran: how it ended, by `called`.
local function judged(called: Called, elapsed: integer): Runner.Outcome
  local raised = called.raised
  if raised ~= nil then
    return { status = "error", code = 1, trouble = limited(raised), elapsed_ns = elapsed }
  end
  local result = called.result
  if not result then
    return { status = "start-error", code = 1,
      trouble = limited(called.trouble or "child operation failed"), elapsed_ns = elapsed }
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
  local called: Called = {}
  local ok, raised = pcall(function()
    local result, trouble = Seams.calls().child_run(request.argv, options)
    called.result, called.trouble = result, trouble
  end)
  if not ok then called.raised = tostring(raised) end
  local elapsed = Clock.monotonic_ns() - started
  release(descriptors)
  return judged(called, elapsed)
end

local type Recording = Runner.Recording

local function start(c: Runner.Context, phase: string, at?: integer): Recording
  local database = State.external_path(c.database, c.candidate)
  local started = at or Clock.monotonic_ns()
  return { context = c, database = database, phase = phase, started = started,
    id = State.start(database, c.worker, c.run, c.attempt, phase, started) }
end

local function complete(recording: Recording, finished: integer, elapsed: integer,
                        status: string, code: integer?, signal: integer?,
                        timed_out: integer, detail: string?)
  local c = recording.context
  State.complete(recording.database, recording.id, c.worker, c.run, c.attempt,
    recording.phase, finished, elapsed, status, code, signal, timed_out, detail)
end

-- Writes `outcome` as `recording`'s complete event, which a failure also
-- names on stderr.
local function finish(recording: Recording, phase: string, outcome: Runner.Outcome)
  local result = outcome.result
  local exit_code: integer? = nil
  local signal: integer? = nil
  local timed_out = 0
  if result then
    exit_code, signal = result.code, result.signal
    timed_out = if result.timed_out then 1 else 0 end
  end
  complete(recording, recording.started + outcome.elapsed_ns, outcome.elapsed_ns,
    outcome.status, exit_code, signal, timed_out, outcome.trouble)
  -- The database keeps the outcome for the summary; the log says it too,
  -- so an operation that fails without output of its own (a timeout, a
  -- command that never started) is named where the failure is read.
  if outcome.status ~= "success" then
    local trouble = outcome.trouble
    local why = if trouble ~= nil then (": " .. trouble) else "" end
    local _, _ = Seams.calls().fs_put(Fs.stderr, phase .. ": " .. outcome.status .. " (status " ..
        tostring(outcome.code) .. ")" .. why .. "\n")
  end
end

--- The outcome an attempt returned, kept where the function that runs it under `pcall` can set it.
local record Made
  mut outcome?: Runner.Outcome
end

-- Runs `attempt` as one operation named `phase`: a start event, then a
-- complete event with its outcome, which a failure also names on stderr.
local function recorded(c: Runner.Context, phase: string,
                        attempt: function(): Runner.Outcome): Runner.Outcome
  local recording = start(c, phase)
  local made: Made = {}
  local called, raised = pcall(function()
    made.outcome = attempt()
  end)
  local attempted = made.outcome
  local outcome: Runner.Outcome
  if called and attempted ~= nil then
    outcome = attempted
  else
    outcome = { status = "error", code = 1,
      trouble = limited(tostring(raised)),
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
  local started: Called = {}
  local ok, raised = pcall(function()
    local options, descriptors = prepare(request)
    running.descriptors = descriptors
    local handle, trouble = Child.start(request.argv, options)
    started.trouble = trouble
    if handle == nil then
      release(descriptors)
      running.descriptors = {}
    else
      running.handle = handle
    end
  end)
  if not ok then
    running.outcome = { status = "error", code = 1, trouble = limited(tostring(raised)),
      elapsed_ns = Clock.monotonic_ns() - recording.started }
  elseif running.handle == nil then
    running.outcome = judged(started, Clock.monotonic_ns() - recording.started)
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
  local handles: mut {Child.Handle} = {}
  for _, command in ipairs(commands) do
    if command.outcome then return command end
    local handle = command.handle
    assert(handle ~= nil, "runner: a running command has neither a handle nor an outcome")
    handles[#handles + 1] = handle
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
  local ended = running.outcome
  if running.reaped then return (assert(ended, "runner: a reaped command has no outcome")) end
  local handle = running.handle
  if handle == nil then
    return settle(running, (assert(ended, "runner: a command with no handle has no outcome")))
  end
  local called: Called = {}
  local ok, raised = pcall(function()
    local result, trouble = handle:wait()
    called.result, called.trouble = result, trouble
  end)
  if not ok then called.raised = tostring(raised) end
  local elapsed = Clock.monotonic_ns() - running.recording.started
  return settle(running, judged(called, elapsed))
end

--- Ends `running` and its process group if it still runs, SIGTERM, a
--- grace period, then SIGKILL, waits for it to go and records it as
--- "cancelled" (status 130). A command that already ended keeps its outcome.
function Runner.stop(running: Runner.Running): Runner.Outcome
  local handle = running.handle
  if handle == nil then return Runner.reap(running) end
  local polled, _ = handle:try_wait()
  if polled ~= nil and polled.finished then return Runner.reap(running) end
  local _, _ = handle:close()
  local elapsed = Clock.monotonic_ns() - running.recording.started
  return settle(running, { status = "cancelled", code = 130, elapsed_ns = elapsed,
    trouble = "stopped before it ended" })
end

--- Records `work`, done in this process, as one operation named `phase`,
--- as `operation` records a command: "success" when it returns true, and
--- "error" with its message when it returns false or raises.
function Runner.step(c: Runner.Context, phase: string,
                     work: function(): boolean, string?): Runner.Outcome
  return recorded(c, phase, function(): Runner.Outcome
    local started = Clock.monotonic_ns()
    local ok, trouble = work()
    local elapsed = Clock.monotonic_ns() - started
    if ok then return { status = "success", code = 0, elapsed_ns = elapsed } end
    local reason = trouble or ""
    if reason == "" then reason = "failed" end
    return { status = "error", code = 1, elapsed_ns = elapsed,
      trouble = limited(reason) }
  end)
end

--- The status a phase's action answered, kept where the function that runs it under `pcall` can set it.
local record Reached
  mut code: integer
end

--- Records a phase's integer exit status, including its nested operations.
--- A raised error records exit code 1 and its full text, also said on stderr;
--- a returned nonzero status is kept as an exit without another diagnostic.
function Runner.phase(c: Runner.Context, phase: string,
                      action: function(): integer): integer
  local recording = start(c, phase, Clock.monotonic_ns())
  local reached: Reached = { code = 1 }
  local called, answer = pcall(function()
    reached.code = action()
  end)
  local code = reached.code
  local status = if code == 0 then "success" else (if called then "exit" else "error" end) end
  local detail: string? = nil
  if not called then detail = tostring(answer) end
  local finished = Clock.monotonic_ns()
  complete(recording, finished, finished - recording.started,
    status, code, nil, 0, detail)
  if detail then
    local _, _ = Seams.calls().fs_put(Fs.stderr, detail .. "\n")
  end
  return code
end

return Runner
