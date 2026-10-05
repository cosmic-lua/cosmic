--- A streamed child's queued bytes precede its terminal I/O failure.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- Children run chunks through this program's core, without a shell.
Test.policy{ profiles = { "cosmic" } }

local function output(fd: integer): Child.Handle
  local options: Child.Options = { stdout = "null", stderr = "null" }
  if fd == 1 then options.stdout = "stream" else options.stderr = "stream" end
  local script = 'assert(require("cosmic.fs").put(' .. tostring(fd) .. ', "abcdef"))'
  local started = this_program.program({ "-e", script }, options)
  return (assert(Child.start(started.argv, started.options)))
end

--- Restore the real syscalls even when an assertion or injected failure
--- raises, before a surrounding handle closes and reaps its child.
local function patched(action: function())
  local read, poll = sys.read, sys.poll
  local ok, trouble: boolean, any = pcall(action)
  sys.read, sys.poll = read, poll
  assert(ok, tostring(trouble))
end

local function prefix(reader: Stream.Reader)
  for _, expected in ipairs({ "ab", "cd", "ef" }) do
    local chunk, trouble = reader:read(2)
    assert(chunk == expected and trouble == "", tostring(chunk) .. ": " .. trouble)
  end
end

local function failed(reader: Stream.Reader, reason: string)
  for _ = 1, 2 do
    local chunk, trouble = reader:read(2)
    assert(chunk == nil and trouble == reason, tostring(chunk) .. ": " .. trouble)
  end
end

--- A wait can discover an error after queuing valid output. The caller
--- still reads that prefix, bounded by max_bytes, before the saved error.
local function test_a_read_failure_follows_queued_stdout_and_stderr()
  for _, child_fd in ipairs({ 1, 2 }) do
    local h <close> = output(child_fd)
    local reader = assert(child_fd == 1 and h.stdout_stream or h.stderr_stream)
    local fd = h._streams[1].fd
    local reason = "read: injected terminal failure"
    local bytes, refused = 0, false
    patched(function()
      local read = sys.read
      sys.read = function(which: integer, count: integer): string | nil, string, integer
        if which == fd and bytes == 6 then
          refused = true
          return nil, reason, sys.EBADF
        end
        local data, trouble, errno = read(which, count)
        if which == fd and data ~= nil then bytes = bytes + #data end
        return data, trouble, errno
      end
      assert(assert(h:wait(Clock.seconds(5))).ok)
    end)
    assert(refused and bytes == 6, "the fault must follow the real output")
    prefix(reader)
    failed(reader, reason)
    assert(reader:close())
    failed(reader, reason)
  end
end

--- A raw pump failure must not turn an output into clean EOF, even when
--- another operation found it before the Reader was used.
local function test_a_raw_poll_failure_follows_queued_bytes()
  local h <close> = output(1)
  local pipe = h._streams[1]
  local fd = pipe.fd
  local reason = "poll: injected terminal failure"
  local refused = false
  patched(function()
    local poll = sys.poll
    sys.poll = function(fds: {integer}, events: {integer}, ms: integer): {integer} | nil, string, integer
      if pipe.size == 6 and not refused then
        for _, which in ipairs(fds) do
          if which == fd then
            refused = true
            return nil, reason, sys.EBADF
          end
        end
      end
      return poll(fds, events, ms)
    end
    assert(assert(h:wait(Clock.seconds(5))).ok)
  end)
  assert(refused, "the fault must follow the queued prefix")
  local reader = assert(h.stdout_stream)
  prefix(reader)
  failed(reader, reason)
  assert(h:close())
  failed(reader, reason)
end

--- A failure with no queued prefix is visible on the first read too.
local function test_a_raw_poll_failure_before_any_output_is_sticky()
  local h <close> = output(1)
  local reason = "poll: no output could be read"
  patched(function()
    sys.poll = function(_fds: {integer}, _events: {integer}, _ms: integer): {integer} | nil, string, integer
      return nil, reason, sys.EBADF
    end
    assert(h:try_wait())
  end)
  local reader = assert(h.stdout_stream)
  failed(reader, reason)
  assert(h:close())
  failed(reader, reason)
end

--- Guard cancellation stays the Reader's first failure even when a
--- later wait discovers a distinct terminal error in the source pipe.
local function test_a_source_failure_does_not_replace_sticky_guard_cancellation()
  local h <close> = output(1)
  local reader = assert(h.stdout_stream)
  local g = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local chunk, cancellation = reader:read()
  assert(g:release() == sys.SIGTERM)
  assert(chunk == nil and cancellation == "child: cancelled by signal " .. tostring(sys.SIGTERM))
  local pipe = h._streams[1]
  local fd = pipe.fd
  local reason = "read: cancelled by signal is only diagnostic text here"
  local refused = false
  patched(function()
    local read = sys.read
    sys.read = function(which: integer, count: integer): string | nil, string, integer
      if which == fd then
        refused = true
        return nil, reason, sys.EBADF
      end
      return read(which, count)
    end
    assert(h:wait(Clock.seconds(5)))
  end)
  assert(refused and pipe.failure == reason, "the source owns its separate terminal failure")
  failed(reader, cancellation)
end

--- Transient nonblocking and signal-interrupted reads retain neither
--- failure nor EOF, so the output remains readable.
local function test_transient_read_errors_leave_the_stream_readable()
  local h <close> = output(1)
  local fd = h._streams[1].fd
  local transient = 0
  patched(function()
    local read = sys.read
    sys.read = function(which: integer, count: integer): string | nil, string, integer
      if which == fd and transient < 2 then
        transient = transient + 1
        return nil, "transient read", transient == 1 and sys.EAGAIN or sys.EINTR
      end
      return read(which, count)
    end
    assert(assert(h:wait(Clock.seconds(5))).ok)
  end)
  assert(transient == 2)
  local reader = assert(h.stdout_stream)
  prefix(reader)
  local chunk, trouble = reader:read()
  assert(chunk == nil and trouble == "", trouble)
end

--- A descriptor closed while a pump is answering is no longer its
--- output, even when its number has already been reused by another file.
local function test_a_failed_pump_does_not_close_a_reused_descriptor()
  local h <close> = output(1)
  local reader = assert(h.stdout_stream)
  local fd = h._streams[1].fd
  local replacement: integer
  local ok, why: boolean, any = pcall(function()
    patched(function()
      local poll = sys.poll
      sys.poll = function(fds: {integer}, events: {integer}, ms: integer): {integer} | nil, string, integer
        if replacement ~= nil then return poll(fds, events, ms) end
        assert(reader:close())
        replacement = assert(Fs.open_read("/dev/null"))
        assert(replacement == fd, "the closed output's descriptor must be reused")
        return nil, "poll: output closed during the wait", sys.EBADF
      end
      assert(h:try_wait())
    end)
    assert(sys.fstat(replacement), "the stale pump closed the replacement descriptor")
    local chunk, trouble = reader:read()
    assert(chunk == nil and trouble == "child: the reader is closed", trouble)
  end)
  if replacement ~= nil then assert(Fs.close(replacement)) end
  assert(ok, tostring(why))
end
