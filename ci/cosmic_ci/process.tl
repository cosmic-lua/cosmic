-- Children a fixture starts and supervises: each writes its streams to
-- files under `diagnostics`, and every one still running when a case
-- fails is ended. A paused child hands off over a named pipe.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")

local Time = require("cosmic.time")
-- Bound subprocess waits and the shorter paused-build handshakes separately.
local child_wait_timeout_ns <const> = Time.seconds(30)
-- A paused child reaches its hook after a cold start: a real core
-- extracts and hashes itself first, which a sanitized core or a loaded
-- runner makes several times slower. The bound only guards a hang, and
-- stays under the runner's default 30 s for a test, which the runtime
-- and launcher fixtures get (cosmic_ci/orchestration.tl sets them no
-- COSMIC_TEST_TIMEOUT), so a hang in a test's first handshake fails
-- here, naming it.
local handshake_timeout_ns <const> = Time.seconds(20)

local record Process
  record Running
    label: string
    handle: Child.Handle
    out_fd: integer
    err_fd: integer
    input_fd: integer | nil
    out: string
    err: string
    closed: boolean
  end
end

function Process.chmod(path: string, mode: integer)
  assert(Fs.chmod(path, mode))
end

-- One field of this host's `uname`.
function Process.host_uname(work: string, diagnostics: string, flag: string,
    label: string): string
  local answer = Fixture.run("uname-" .. label,
    { "/usr/bin/env", "uname", flag }, work, diagnostics)
  return (assert(Fixture.small(answer.out, 256):match("^(%S+)"),
    "uname " .. flag .. " produced no output"))
end

-- Starts `argv`, its streams in files under `diagnostics` named for
-- `label`, and its stdin read from the file `input` when one is given.
function Process.start(label: string, argv: {string}, cwd: string,
    values: {string:string}, diagnostics: string,
    input?: string): Process.Running
  local out = diagnostics .. "/" .. label .. ".out"
  local err = diagnostics .. "/" .. label .. ".err"
  local out_fd = assert(Fs.open_write(out))
  local err_fd, err_trouble = Fs.open_write(err)
  if err_fd == nil then
    Fs.close(out_fd)
    error(label .. ": " .. err_trouble)
  end
  local input_fd: integer | nil = nil
  if input then
    local opened, input_trouble = Fs.open_read(input)
    if opened == nil then
      Fs.close(out_fd); Fs.close(err_fd)
      error(label .. ": " .. input_trouble)
    end
    input_fd = opened
  end
  local options: Child.Options = { cwd = cwd, env = values,
    stdout = out_fd, stderr = err_fd, process_group = false }
  if input_fd then options.stdin = input_fd end
  local handle, trouble = Child.start(argv, options)
  if handle == nil then
    if input_fd then Fs.close(input_fd) end
    Fs.close(out_fd); Fs.close(err_fd)
    error(label .. ": " .. trouble)
  end
  return { label = label, handle = handle, out_fd = out_fd, err_fd = err_fd,
    input_fd = input_fd, out = out, err = err, closed = false }
end

local function close_descriptors(running: Process.Running)
  if not running.closed then
    running.closed = true
    local input_closed, input_trouble = true, ""
    if running.input_fd then
      input_closed, input_trouble = Fs.close(running.input_fd)
    end
    local out_closed, out_trouble = Fs.close(running.out_fd)
    local err_closed, err_trouble = Fs.close(running.err_fd)
    assert(input_closed, input_trouble)
    assert(out_closed, out_trouble)
    assert(err_closed, err_trouble)
  end
end

function Process.finish(running: Process.Running, timeout?: integer): Child.Result
  local result, trouble = running.handle:wait(timeout or child_wait_timeout_ns)
  if result == nil then
    running.handle:close(); close_descriptors(running)
    error(running.label .. ": child wait failed: " .. trouble)
  end
  close_descriptors(running)
  return result
end

local function cleanup(running: Process.Running)
  if not running.closed then
    running.handle:close()
    close_descriptors(running)
  end
end

-- Runs `action`, then ends every child it added to the list it was
-- given, whether or not it raised.
function Process.supervised(action: function({Process.Running}))
  local active: {Process.Running} = {}
  local called, failure = pcall(function(): boolean
    action(active); return true
  end)
  for _, running in ipairs(active) do cleanup(running) end
  if not called then error(failure) end
end

function Process.fifo(work: string, diagnostics: string, name: string): string
  local path = work .. "/" .. name
  Fixture.run("mkfifo-" .. name, { "/usr/bin/env", "mkfifo", path }, work,
    diagnostics)
  return path
end

-- Waits for the paused `child` to write "ready" to its pipe at `path`.
-- A child that exits first fails the wait then, rather than when the
-- bound passes.
function Process.await_ready(work: string, diagnostics: string, label: string,
    path: string, child: Process.Running, timeout_ns?: integer)
  local bound = timeout_ns or handshake_timeout_ns
  local deadline = Time.monotonic_ns() + bound
  local reader = Process.start("ready-" .. label,
    { "/usr/bin/env", "cat", path }, work, Fixture.environment(), diagnostics)
  local exited = false
  local called, failure = pcall(function(): boolean
    local first, trouble = Child.wait_any({ reader.handle, child.handle }, bound)
    if first == nil then
      error(label .. ": no readiness from " .. child.label .. ": " .. trouble)
    end
    exited = first ~= reader.handle
    -- The child may have written before it exited, and the reader be
    -- about to end; or it never opened the pipe, and the reader waits in
    -- its open (or is yet to reach it) for a writer that will never
    -- come. An open of our own that does not wait lets that one through
    -- to an end of file; it fails (ENXIO) while no reader has the pipe
    -- open, so it is tried until the reader ends.
    local done = not exited
    while not done and Time.monotonic_ns() < deadline do
      local fd = sys.open(path, sys.O_WRONLY | sys.O_NONBLOCK)
      if fd then assert(Fs.close(fd)) end
      done = Child.wait_any({ reader.handle }, Time.ms(10)) ~= nil
    end
    -- Settled by now, unless the deadline passed: then this ends it.
    local read = Process.finish(reader, Time.ms(1))
    assert(read.ok, label .. ": reading readiness failed; stderr=" .. reader.err)
    return true
  end)
  cleanup(reader)
  if not called then error(failure, 0) end
  local answer = Fixture.small(reader.out, 128)
  if answer == "" and exited then
    local ended = assert(child.handle:wait())
    error(label .. ": " .. child.label .. " exited before it was ready (code=" ..
      tostring(ended.code) .. "; signal=" .. tostring(ended.signal) ..
      "); stdout=" .. child.out .. "; stderr=" .. child.err, 0)
  end
  assert(answer == "ready\n", label .. ": startup hook readiness differs")
end

-- Lets a paused child go on.
function Process.release(work: string, diagnostics: string, label: string,
    path: string)
  local input = work .. "/release-" .. label
  Fixture.write(input, "go\n")
  Fixture.run("release-" .. label, { "/usr/bin/env", "tee", path }, work,
    diagnostics, nil, handshake_timeout_ns, input)
end

return Process
