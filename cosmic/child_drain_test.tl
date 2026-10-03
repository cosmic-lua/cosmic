--- Bounded output transfer preserves Reader errors and caller supervision.
local Child = require("cosmic.child")
local _Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local this_program = require("build.this_program")

--- Each child only runs a chunk through this program's core.
Test.needs{ lua = true }

local function start(script: string, options?: Child.Options): Child.Handle
  local started = this_program.program({ "-e", script }, options or { stdout = "stream" })
  return (assert(Child.start(started.argv, started.options)))
end

local function options(out: Stream.Writer, limit?: integer, ns?: integer): Child.DrainOptions
  return { stdout = out, max_bytes = limit or 65536, timeout_ns = ns or Time.seconds(5) }
end

local function finish(h: Child.Handle, opts: Child.DrainOptions): integer
  local bytes = 0
  while true do
    local got = h:drain(opts)
    bytes = bytes + got.bytes
    if got.kind == "eof" then break end
    assert(got.kind == "limit", got.kind .. ": " .. got.reason)
  end
  return bytes
end

local function test_prefix_reader_and_repeated_drain_do_not_replay()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdefghij"))')
  assert(assert(h.stdout_stream):read(3) == "abc")
  local out = Stream.collect()
  assert(finish(h, options(out, 2)) == 7)
  assert(out:result() == "defghij")
  assert(h:drain(options(out)).kind == "eof")
  assert(assert(h:wait()).ok)
end

local function test_both_streams_are_fair_under_small_repeated_budgets()
  local h <close> = start([[
local Fs = require("cosmic.fs")
for i = 1, 256 do assert(Fs.put(1, "abcd")) assert(Fs.put(2, "WXYZ")) end]],
    { stdout = "stream", stderr = "stream", capture_limit = 17 })
  local out, err = Stream.collect(), Stream.collect()
  local opts = options(out, 3)
  opts.stderr = err
  assert(finish(h, opts) == 2048)
  assert(out:result() == string.rep("abcd", 256))
  assert(err:result() == string.rep("WXYZ", 256))
  assert(assert(h:wait()).ok)
end

local function test_wait_then_drain_prefers_known_eof_to_exact_limit()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcd"))')
  assert(assert(h:wait()).ok)
  local out = Stream.collect()
  local got = h:drain(options(out, 4))
  assert(got.kind == "eof" and got.bytes == 4 and got.reason == "")
  assert(out:result() == "abcd")
end

local function test_zero_timeout_copies_one_round_without_waiting()
  local h <close> = start('assert(require("cosmic.fs").put(1, string.rep("x", 131072)))',
    { stdout = "stream", capture_limit = 262144 })
  assert(assert(h:wait()).ok)
  local out = Stream.collect()
  local got = h:drain(options(out, 262144, 0))
  assert(got.kind == "timeout" and got.bytes > 0 and got.bytes <= 65536)
  assert(finish(h, options(out)) + got.bytes == 131072)
  assert(out:result() == string.rep("x", 131072))
end

local function test_deadline_keeps_the_child_running()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  local got = h:drain(options(Stream.collect(), nil, Time.ms(10)))
  assert(got.kind == "timeout" and got.bytes == 0)
  assert(not assert(h:try_wait()).finished)
  assert(assert(h.stdin_stream):close())
  assert(h:drain(options(Stream.collect())).kind == "eof")
  local result = assert(h:wait())
  assert(result.ok and not result.timed_out)
end

local function test_fresh_guard_event_is_not_consumed_and_old_reader_stays_failed()
  local h <close> = start([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local guard = assert(Child.guard())
assert(Fs.put(1, "ready"))
while guard:cancelled() == 0 do Time.sleep_ns(Time.ms(1)) end
assert(Fs.put(1, "last"))
assert(guard:release() ~= 0)]])
  assert(assert(h.stdout_stream):read() == "ready")
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local reader = assert(h.stdout_stream)
  local data, old = reader:read()
  assert(data == nil and old ~= "")
  local out = Stream.collect()
  local got = h:drain(options(out))
  assert(got.kind == "interrupted" and got.bytes == 0)
  assert(guard:take() == sys.SIGTERM)
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  got = h:drain(options(out))
  assert(got.kind == "interrupted" and got.bytes == 0)
  assert(guard:take() == sys.SIGTERM)
  assert(h:stop(sys.SIGTERM))
  assert(finish(h, options(out)) == 4 and out:result() == "last")
  local again, why = reader:read()
  assert(again == nil and why == old)
  assert(guard:release() == sys.SIGTERM)
  assert(assert(h:wait()).ok)
end

local function test_invalid_bounds_and_sink_mapping_consume_nothing()
  local h <close> = start('assert(require("cosmic.fs").put(1, "safe"))')
  local out = Stream.collect()
  for _, bad in ipairs({
      { stdout = out, max_bytes = 0, timeout_ns = 0 },
      { stdout = out, max_bytes = 4, timeout_ns = -1 },
      { stderr = out, max_bytes = 4, timeout_ns = 0 },
      { stdout = out, stderr = out, max_bytes = 4, timeout_ns = 0 },
  }) do
    assert(not pcall(function() h:drain(bad) end))
  end
  assert(finish(h, options(out)) == 4 and out:result() == "safe")
end

local function test_explicit_reader_and_handle_close_refuse_drain()
  for _, reader_close in ipairs({ true, false }) do
    local h <close> = start('return 0')
    if reader_close then assert(assert(h.stdout_stream):close()) else assert(h:close()) end
    local got = h:drain(options(Stream.collect()))
    assert(got.kind == "failed" and got.reason:find("closed", 1, true))
  end
end

local function test_sink_failure_is_not_replayed_and_borrowed_sink_stays_open()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdef"))')
  local sink = Stream.collect()
  local original = sink.write
  local writes = 0
  sink.write = function(self: Stream.Collector, bytes: string): boolean, string
    writes = writes + 1
    assert(original(self, bytes:sub(1, 1)))
    return false, "sink: full"
  end
  local got = h:drain(options(sink))
  assert(got.kind == "failed" and got.reason == "sink: full" and got.bytes == 6)
  assert(h:drain(options(sink)).reason == "sink: full" and writes == 1)
  sink.write = original
  assert(sink:write("still open"))
  assert(sink:result() == "astill open")
end

local function test_a_parked_reader_refuses_drain_until_its_task_is_killed()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  Poll.run(function()
    local reader = Poll.spawn(function() local _, _ = assert(h.stdout_stream):read() end)
    assert(Poll.delay(0))
    local ok, why: boolean, any = pcall(function() h:drain(options(Stream.collect(), nil, 0)) end)
    assert(not ok and tostring(why):find("already being consumed", 1, true))
    reader:kill()
    assert(h:drain(options(Stream.collect(), nil, 0)).kind == "timeout")
  end)
end

local function test_cooperative_cancel_releases_drain_ownership()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  Poll.run(function()
    local got: Child.DrainResult
    local task = Poll.spawn(function() got = h:drain(options(Stream.collect())) end)
    assert(Poll.delay(0))
    task:cancel()
    assert(task:join())
    assert(got.kind == "failed" and got.reason == Poll.CANCELLED)
    assert(h:drain(options(Stream.collect(), nil, 0)).kind == "timeout")
  end)
end

local function test_a_new_signal_wakes_a_parked_drain_without_taking_it()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  local guard = assert(Child.guard())
  Poll.run(function()
    local got: Child.DrainResult
    local task = Poll.spawn(function() got = h:drain(options(Stream.collect())) end)
    assert(Poll.delay(0))
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    assert(task:join())
    assert(got.kind == "interrupted" and got.bytes == 0)
    assert(guard:take() == sys.SIGTERM)
  end)
  assert(guard:release() == sys.SIGTERM)
end

local function test_closing_the_captured_guard_under_another_ends_the_wait()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  local outer = assert(Child.guard())
  Poll.run(function()
    local got: Child.DrainResult
    local task = Poll.spawn(function() got = h:drain(options(Stream.collect())) end)
    assert(Poll.delay(0))
    local inner = assert(Child.guard())
    assert(outer:release() == 0)
    assert(task:join())
    assert(got.kind == "failed" and got.reason == "child: the guard is closed")
    assert(inner:release() == 0)
  end)
  assert(h:drain(options(Stream.collect(), nil, 0)).kind == "timeout")
end

local function test_an_explicit_handle_close_wakes_drain_before_cleanup_finishes()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  Poll.run(function()
    local got: Child.DrainResult
    local task = Poll.spawn(function() got = h:drain(options(Stream.collect())) end)
    assert(Poll.delay(0))
    assert(h:close())
    assert(task:join())
    assert(got.kind == "failed" and got.reason == "child: the handle is closed")
  end)
end

local function test_a_parked_drain_refuses_another_read_and_drain()
  local h <close> = start('assert(require("cosmic.fs").take(0, 1))',
    { stdin = "stream", stdout = "stream" })
  Poll.run(function()
    local task = Poll.spawn(function() h:drain(options(Stream.collect())) end)
    assert(Poll.delay(0))
    assert(not pcall(function() assert(h.stdout_stream):read() end))
    assert(not pcall(function() h:drain(options(Stream.collect(), nil, 0)) end))
    task:kill()
    assert(assert(h.stdin_stream):close())
    local data, why = assert(h.stdout_stream):read()
    assert(data == nil and why == "")
  end)
end

local function test_a_raising_sink_closes_inputs_and_releases_ownership()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdef"))')
  local sink = Stream.collect()
  local write = sink.write
  sink.write = function(_self: Stream.Collector, _data: string): boolean, string
    error("writer raised")
  end
  local ok, why: boolean, any = pcall(function() h:drain(options(sink)) end)
  assert(not ok and tostring(why):find("writer raised", 1, true))
  assert(h:drain(options(sink)).kind == "failed")
  sink.write = write
  assert(sink:write("open"))
end

local function test_killing_a_task_in_a_yielding_sink_releases_ownership()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdef"))')
  local sink = Stream.collect()
  local writing = false
  sink.write = function(_self: Stream.Collector, _data: string): boolean, string
    writing = true
    return Poll.delay(Time.seconds(10))
  end
  Poll.run(function()
    local task = Poll.spawn(function() h:drain(options(sink)) end)
    while not writing do assert(Poll.delay(0)) end
    task:kill()
    assert(h:drain(options(Stream.collect())).kind == "failed")
    local data, why = assert(h.stdout_stream):read()
    assert(data == nil and why ~= "")
  end)
end

local function test_saved_source_failure_follows_prefix_and_wins_at_exact_limit()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdef"))')
  local fd = h._streams[1].fd
  local read = sys.read
  local seen = false
  sys.read = function(which: integer, count: integer): string | nil, string, integer
    if which == fd and seen then return nil, "read: cancelled-looking real error", sys.EBADF end
    local data, why, errno = read(which, count)
    if which == fd and data ~= nil and #data ~= 0 then seen = true end
    return data, why, errno
  end
  local ok, why: boolean, any = pcall(function() assert(assert(h:wait()).ok) end)
  sys.read = read
  assert(ok, tostring(why))
  local out = Stream.collect()
  local first = h:drain(options(out, 2))
  assert(first.kind == "limit" and first.bytes == 2)
  local second = h:drain(options(out, 4))
  assert(second.kind == "failed" and second.bytes == 4)
  assert(second.reason == "read: cancelled-looking real error" and out:result() == "abcdef")
  local data, failure = assert(h.stdout_stream):read()
  assert(data == nil and failure == second.reason)
end

local function test_merged_stderr_uses_only_stdout_sink()
  local h <close> = start([[
local Fs = require("cosmic.fs")
assert(Fs.put(1, "first")) assert(Fs.put(2, "second"))]],
    { stdout = "stream", stderr = "stdout" })
  local out = Stream.collect()
  assert(finish(h, options(out, 2)) == 11 and out:result() == "firstsecond")
end

local function test_eof_does_not_claim_a_still_running_child_finished()
  local h <close> = start([[
local Fs = require("cosmic.fs")
assert(Fs.close(1)) assert(Fs.take(0, 1))]],
    { stdin = "stream", stdout = "stream" })
  local got = h:drain(options(Stream.collect()))
  assert(got.kind == "eof")
  assert(not assert(h:try_wait()).finished)
end

local function escaped(script: string): Child.Handle
  local chunk = [[
local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local program = require("build.this_program").program({ "-e", ... }, { process_group = false })
assert(Child.start(program.argv, program.options))
sys.exit(0)
]]
  return start((chunk:gsub("%.%.%.", function(): string return string.format("%q", script) end)),
    { stdout = "stream", process_group = false })
end

local function test_escaped_writer_is_drained_after_the_leader_exits()
  local h <close> = escaped([[
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
Time.sleep_ns(Time.ms(50)) assert(Fs.put(1, "late"))]])
  local out = Stream.collect()
  assert(finish(h, options(out)) == 4 and out:result() == "late")
  assert(assert(h:wait()).ok)
  Child.end_strays()
end

local function test_silent_escaped_writer_obeys_deadline_without_ending_child()
  local h <close> = escaped('require("cosmic.time").sleep_ns(require("cosmic.time").seconds(10))')
  local got = h:drain(options(Stream.collect(), nil, Time.ms(20)))
  assert(got.kind == "timeout" and got.bytes == 0)
  Child.end_strays()
  assert(assert(h:wait()).ok)
end

local function test_a_single_write_never_exceeds_the_chunk_bound()
  local h <close> = start('assert(require("cosmic.fs").put(1, string.rep("x", 262144)))')
  local sink = Stream.collect()
  local original = sink.write
  local biggest = 0
  sink.write = function(self: Stream.Collector, bytes: string): boolean, string
    biggest = math.max(biggest, #bytes)
    return original(self, bytes)
  end
  assert(finish(h, options(sink, 200000)) == 262144)
  assert(biggest <= 65536 and sink:result() == string.rep("x", 262144))
end

local function test_shielded_drain_continues_after_task_cancel()
  local h <close> = start([[
local Fs = require("cosmic.fs")
assert(Fs.take(0, 1)) assert(Fs.put(1, "finished"))]],
    { stdin = "stream", stdout = "stream" })
  Poll.run(function()
    local got: Child.DrainResult
    local sink = Stream.collect()
    local task = Poll.spawn(function()
      Poll.shielded(function() got = h:drain(options(sink)) end)
    end)
    assert(Poll.delay(0))
    task:cancel()
    assert(assert(h.stdin_stream):close())
    assert(task:join())
    assert(got.kind == "eof" and sink:result() == "finished")
  end)
end

local function test_tiny_budgets_alternate_when_both_queues_are_ready()
  local h <close> = start([[local Fs = require("cosmic.fs")
assert(Fs.put(1, "abcd")) assert(Fs.put(2, "WXYZ"))]],
    { stdout = "stream", stderr = "stream" })
  assert(assert(h:wait()).ok)
  local out, err = Stream.collect(), Stream.collect()
  local opts = options(out, 1)
  opts.stderr = err
  for i = 1, 4 do
    local first = h:drain(opts)
    assert(first.bytes == 1 and #out:result() == i and #err:result() == i - 1)
    local second = h:drain(opts)
    assert(second.bytes == 1 and #out:result() == i and #err:result() == i)
  end
  assert(out:result() == "abcd" and err:result() == "WXYZ")
end

local function test_missing_stdout_sink_cannot_fall_back_to_stderr_sink()
  local h <close> = start([[local Fs = require("cosmic.fs")
assert(Fs.put(1, "output")) assert(Fs.put(2, "error"))]],
    { stdout = "stream", stderr = "stream" })
  assert(assert(h:wait()).ok)
  local out, err = Stream.collect(), Stream.collect()
  local incomplete: Child.DrainOptions = { stderr = err, max_bytes = 100, timeout_ns = 0 }
  local ok, why: boolean, any = pcall(function() h:drain(incomplete) end)
  assert(not ok and tostring(why):find("sink for each streamed output", 1, true))
  assert(err:result() == "")
  local complete = options(out)
  complete.stderr = err
  assert(finish(h, complete) == 11)
  assert(out:result() == "output" and err:result() == "error")
end

local function test_reader_abandonment_of_escaped_writer_is_not_drain_eof()
  local h <close> = escaped('require("cosmic.time").sleep_ns(require("cosmic.time").seconds(10))')
  assert(assert(h:wait()).ok)
  local reader = assert(h.stdout_stream)
  local data, why = reader:read()
  assert(data == nil and why == "")
  local got = h:drain(options(Stream.collect()))
  assert(got.kind == "failed" and got.reason == "child: the reader is closed")
  data, why = reader:read()
  assert(data == nil and why == "", "ordinary Reader retains its legacy EOF")
  Child.end_strays()
end

local function test_sink_cannot_change_the_calls_validated_bounds()
  local h <close> = start('assert(require("cosmic.fs").put(1, "abcdefghi"))')
  local sink = Stream.collect()
  local opts = options(sink, 3)
  local write = sink.write
  sink.write = function(self: Stream.Collector, bytes: string): boolean, string
    opts.max_bytes, opts.timeout_ns = 0, 0
    return write(self, bytes)
  end
  local got = h:drain(opts)
  assert(got.kind == "limit" and got.bytes == 3 and sink:result() == "abc")
  sink.write = write
  assert(finish(h, options(sink)) == 6 and sink:result() == "abcdefghi")
end
