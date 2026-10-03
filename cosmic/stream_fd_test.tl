--- The descriptor Reader and Writer that wait: a read or write on a
--- non-blocking descriptor waits for it through [`Poll.wait`], bounded
--- by `timeout_ns`, in a task of [`Poll.run`] or out of one.

local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Clock = require("cosmic.clock")

--- The two ends of a named pipe in `dir`, neither waiting: the reading
--- end open first, as a pipe with no reader refuses a nonblocking writer.
local function fifo(dir: string, name: string): integer, integer
  local path = dir .. "/" .. name
  assert(sys.mkfifo(path, 384))
  local reader = assert(sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(path, sys.O_WRONLY | sys.O_NONBLOCK, 0))
  return reader, writer
end

--- Everything `fd` holds now, without waiting for more.
local function drained(fd: integer): string
  local parts: {string} = {}
  while true do
    local data, _, errno = sys.read(fd, 1 << 16)
    if data == nil or data == "" then
      assert(data == "" or errno == sys.EAGAIN)
      break
    end
    parts[#parts + 1] = data
  end
  return table.concat(parts)
end

local function raises(fn: function(), words: string)
  local ok, err: boolean, any = pcall(fn)
  assert(not ok, "expected a raise naming " .. words)
  assert(tostring(err):find(words, 1, true), tostring(err))
end

--- A read that finds nothing waits `timeout_ns` and then fails with the
--- word every wait answers, leaving the Reader usable: what arrives
--- later is read, and a closed writer ends it.
local function test_a_read_with_a_timeout_fails_with_the_timeout_word(tmp: string)
  local reader, writer = fifo(tmp, "quiet")
  local r = Stream.from_fd(reader, { nonblocking = true, timeout_ns = Clock.ms(80) })
  local before = Clock.monotonic_ns()
  local chunk, why = r:read()
  local elapsed = Clock.monotonic_ns() - before
  assert(chunk == nil and why == Poll.TIMEOUT, tostring(why))
  assert(elapsed >= Clock.ms(79) and elapsed < Clock.seconds(5),
    "timed out after " .. elapsed // Clock.ms(1) .. " ms")
  assert(sys.write(writer, "late") == 4)
  assert(r:read() == "late")
  assert(sys.close(writer))
  local ended, ended_why = r:read()
  assert(ended == nil and ended_why == "", tostring(ended_why))
  assert(sys.close(reader))
end

--- Only a regular file can seek, so only its Reader has a `skip`: a pipe's
--- is read and discarded by [`Stream.skip`].
local function test_a_reader_over_a_pipe_has_no_skip(tmp: string)
  local reader, writer = fifo(tmp, "unseekable")
  local r = Stream.from_fd(reader)
  assert(r.skip == nil)
  assert(sys.write(writer, "abcdef") == 6)
  assert(Stream.skip(r, 4))
  assert(r:read() == "ef")
  assert(sys.close(writer))
  assert(sys.close(reader))
end

--- The same wait in a task lets the others run meanwhile.
local function test_a_read_with_a_timeout_in_a_task_lets_the_others_run(tmp: string)
  local reader, writer = fifo(tmp, "task")
  local r = Stream.from_fd(reader, { nonblocking = true, timeout_ns = Clock.ms(120) })
  local ticks, elapsed = 0, 0
  local chunk, why: string | nil, string
  Poll.run(function()
    local done = false
    local ticker = Poll.spawn(function()
      while not done do
        assert(Poll.delay(Clock.ms(5)))
        ticks = ticks + 1
      end
    end)
    local before = Clock.monotonic_ns()
    chunk, why = r:read()
    elapsed = Clock.monotonic_ns() - before
    done = true
    assert(ticker:join())
  end)
  assert(chunk == nil and why == Poll.TIMEOUT, tostring(why))
  assert(elapsed >= Clock.ms(119) and elapsed < Clock.seconds(5),
    "timed out after " .. elapsed // Clock.ms(1) .. " ms")
  assert(ticks >= 2, "the other task ticked " .. ticks .. " times while the read waited")
  assert(sys.close(reader))
  assert(sys.close(writer))
end

--- A body larger than a pipe holds goes whole into a reader that takes
--- it slowly: the write waits for room as the reader makes it.
local function test_a_write_goes_whole_into_a_slow_reader(tmp: string)
  local reader, writer = fifo(tmp, "slow")
  local body = string.rep("0123456789abcdef", 1 << 16)
  local received: {string} = {}
  Poll.run(function()
    local taking = Poll.spawn(function()
      local r = Stream.from_fd(reader, { nonblocking = true })
      while true do
        local chunk, why = r:read(1 << 14)
        assert(chunk ~= nil or why == "", tostring(why))
        if chunk == nil then break end
        received[#received + 1] = chunk
        assert(Poll.delay(Clock.ms(1)))
      end
    end)
    local w = Stream.to_fd(writer, { nonblocking = true })
    assert(w:write(body))
    assert(w:written() == #body)
    assert(sys.close(writer))
    assert(taking:join(Clock.seconds(30)))
  end)
  assert(table.concat(received) == body)
  assert(sys.close(reader))
end

--- A write that runs out of time fails with the timeout word and says
--- how much went, which is what the reader finds; the Writer goes on
--- from there.
local function test_a_write_that_expires_reports_the_bytes_written(tmp: string)
  local reader, writer = fifo(tmp, "full")
  local w = Stream.to_fd(writer, { nonblocking = true, timeout_ns = Clock.ms(60) })
  local body = string.rep("0123456789abcdef", 1 << 16)
  local before = Clock.monotonic_ns()
  local ok, why = w:write(body)
  local elapsed = Clock.monotonic_ns() - before
  assert(not ok and why == Poll.TIMEOUT, tostring(why))
  assert(elapsed >= Clock.ms(59) and elapsed < Clock.seconds(5),
    "timed out after " .. elapsed // Clock.ms(1) .. " ms")
  local went = w:written()
  assert(went > 0 and went < #body, "wrote " .. went)
  assert(drained(reader) == body:sub(1, went), "the reader found other bytes than went")
  assert(w:write(body:sub(went + 1, went + 4)))
  assert(w:written() == went + 4)
  assert(drained(reader) == body:sub(went + 1, went + 4))
  assert(sys.close(reader))
  assert(sys.close(writer))
end

--- A failure other than a deadline ends the Writer for good, every
--- later write answering it, and a closed one says so. The failure here
--- is a descriptor that is not one.
local function test_a_failed_write_is_sticky()
  local w = Stream.to_fd(1 << 20)
  local ok, why = w:write("x")
  assert(not ok and why ~= "", tostring(why))
  local again, again_why = w:write("y")
  assert(not again and again_why == why, tostring(again_why))
  assert(w:close())
  local late, late_why = w:write("z")
  assert(not late and late_why:find("closed", 1, true) ~= nil, tostring(late_why))
end

--- A `wait` the caller gives is asked for the descriptor and the events
--- instead of Poll.wait: here it drains the pipe, as a supervisor
--- servicing another end would. A deadline or a cancel it answers leaves
--- the Writer usable; any other failure ends it.
local function test_a_wait_the_caller_gives_replaces_the_poll(tmp: string)
  local reader, writer = fifo(tmp, "hook")
  local body = string.rep("0123456789abcdef", 1 << 15)
  local seen: {string} = {}
  local calls, asked = 0, 0
  local fail: string = nil
  local w = Stream.to_fd(writer, { nonblocking = true, wait = function(fd: integer,
                                                                       events: integer, left: integer | nil): boolean, string
    calls = calls + 1
    assert(fd == writer and events == sys.POLLOUT and left == nil)
    if fail ~= nil then return false, fail end
    seen[#seen + 1] = drained(reader)
    return true, ""
  end })
  assert(w:write(body))
  seen[#seen + 1] = drained(reader)
  assert(calls > 0 and table.concat(seen) == body)
  fail = Poll.CANCELLED
  local filled = string.rep("x", 1 << 17)
  local ok, why = w:write(filled)
  assert(not ok and why == Poll.CANCELLED, tostring(why))
  asked = calls
  fail = "the pipe is wanted elsewhere"
  local stuck, stuck_why = w:write(filled)
  assert(not stuck and stuck_why == fail, tostring(stuck_why))
  assert(calls > asked)
  fail = nil
  local sticky, sticky_why = w:write("y")
  assert(not sticky and sticky_why == "the pipe is wanted elsewhere", tostring(sticky_why))
  assert(sys.close(reader))
  assert(sys.close(writer))
end

--- A timeout or a wait of the caller's means a descriptor that does not
--- block, and a timeout is a span a wait can last.
local function test_the_options_are_checked()
  raises(function() local _ = Stream.from_fd(0, { timeout_ns = Clock.ms(5) }) end, "nonblocking")
  raises(function() local _ = Stream.to_fd(1, { timeout_ns = Clock.ms(5) }) end, "nonblocking")
  raises(function()
    local _ = Stream.to_fd(1, { wait = function(_: integer, _: integer, _: integer | nil):
        boolean, string return true, "" end })
  end, "nonblocking")
  raises(function() local _ = Stream.from_fd(0, { nonblocking = true, timeout_ns = -1 }) end,
    "timeout_ns")
end
