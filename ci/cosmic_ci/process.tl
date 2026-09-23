-- Children a fixture starts and supervises: each writes its streams to
-- files under `diagnostics`, and every one still running when a case
-- fails is ended. A paused child hands off over a named pipe.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")

-- Bound subprocess waits and the shorter paused-build handshakes separately.
local child_wait_timeout_ms <const> = 30000
local handshake_timeout_ms <const> = 5000

local record Process
  record Running
    label: string
    handle: Child.Handle
    out_fd: integer
    err_fd: integer
    out: string
    err: string
    closed: boolean
  end
end

function Process.chmod(path: string, mode: integer)
  assert(sys.chmod(path, mode))
end

-- One field of this host's `uname`.
function Process.host_uname(work: string, diagnostics: string, flag: string,
    label: string): string
  local answer = Fixture.run("uname-" .. label,
    { "/usr/bin/env", "uname", flag }, work, diagnostics)
  return (assert(Fixture.small(answer.out, 256):match("^(%S+)"),
    "uname " .. flag .. " produced no output"))
end

function Process.start(label: string, argv: {string}, cwd: string,
    values: {string:string}, diagnostics: string): Process.Running
  local out = diagnostics .. "/" .. label .. ".out"
  local err = diagnostics .. "/" .. label .. ".err"
  local out_fd = assert(Fs.open_write(out))
  local err_fd = assert(Fs.open_write(err))
  local options: Child.Options = { cwd = cwd, env = values,
    stdout = out_fd, stderr = err_fd, process_group = false }
  local handle, trouble = Child.start(argv, options)
  if handle == nil then
    Fs.close(out_fd); Fs.close(err_fd)
    error(label .. ": " .. trouble)
  end
  return { label = label, handle = handle, out_fd = out_fd, err_fd = err_fd,
    out = out, err = err, closed = false }
end

local function close_descriptors(running: Process.Running)
  if not running.closed then
    assert(Fs.close(running.out_fd)); assert(Fs.close(running.err_fd))
    running.closed = true
  end
end

function Process.finish(running: Process.Running, timeout?: integer): Child.Result
  local result, trouble = running.handle:wait(timeout or child_wait_timeout_ms)
  if result == nil then
    running.handle:close(); close_descriptors(running)
    error(running.label .. ": child wait failed: " .. trouble)
  end
  close_descriptors(running)
  return result as Child.Result
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

-- Waits for a paused child to write "ready" to its pipe.
function Process.await_ready(work: string, diagnostics: string, label: string,
    path: string, timeout_ms?: integer)
  local answer = Fixture.run("ready-" .. label,
    { "/usr/bin/env", "cat", path }, work, diagnostics, nil,
    timeout_ms or handshake_timeout_ms)
  assert(Fixture.small(answer.out, 128) == "ready\n",
    label .. ": startup hook readiness differs")
end

-- Lets a paused child go on.
function Process.release(work: string, diagnostics: string, label: string,
    path: string)
  local input = work .. "/release-" .. label
  Fixture.write(input, "go\n")
  Fixture.run("release-" .. label, { "/usr/bin/env", "tee", path }, work,
    diagnostics, nil, handshake_timeout_ms, input)
end

return Process
