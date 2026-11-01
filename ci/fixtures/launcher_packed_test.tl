local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")
local LauncherFixture = require("cosmic_ci.launcher_fixture")
local Process = require("cosmic_ci.process")
local String = require("cosmic.string")
local Test = require("cosmic.test")

-- The launcher contract's compressed payloads (o/fixtures/launcher,
-- cosmic_ci/launcher_setup.tl): the launcher cuts out the target's decoder
-- stub, runs it on the payload's frame, and publishes what it wrote, which it
-- holds to the length and SHA-256 of the raw payload as it does a raw core.
-- launcher_test.tl is the same launcher on raw payloads; the cases here are
-- the ones the second stage adds. The stub in the compressed fixtures is the
-- build's own (cosmic-unzstd); in `stub-fails`, `stub-short` and `stub-zero`
-- it is a script that fails, writes too little, or writes the right length
-- of zeros; in `stub-slow` it waits for the test while it decodes.
Test.policy{
  grants = {
    { path = "o/fixtures/product/prefix", letters = "r" },
    { path = "o/fixtures/launcher/launcher.test", letters = "r" },
    { path = "o/fixtures/launcher/launcher.packed-test", letters = "r" },
    { path = "o/fixtures/launcher/launcher.stub-fails", letters = "r" },
    { path = "o/fixtures/launcher/launcher.stub-short", letters = "r" },
    { path = "o/fixtures/launcher/launcher.stub-zero", letters = "r" },
    { path = "o/fixtures/launcher/launcher.stub-slow", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-x86_64-linux-musl", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-aarch64-linux-musl", letters = "r" },
    { path = "o/fixtures/launcher/payloads/socket-aarch64-macos", letters = "r" },
  },
  env = { "COSMIC_FIXTURE_TARGET", "COSMIC_FIXTURE_FIGURES" },
  profiles = { "system" },
}

local type Context = LauncherFixture.Context
local environment, setup = LauncherFixture.environment, LauncherFixture.setup
local outcome_ok, run = LauncherFixture.outcome_ok, LauncherFixture.run
local only_core = LauncherFixture.only_core

local function packed(tmp: string, kind?: string): Context
  return setup(tmp, kind or "packed-test")
end

--- The numbers of the arm the launcher selects for this target, which tell
--- where its stub and the stored core lie in the artifact.
local record Arm
  offset: integer
  stored: integer
  length: integer
  stub_offset: integer
  stub_length: integer
end

local function arm_of(ctx: Context): Arm
  local host = if ctx.target == "aarch64-macos" then "'Darwin arm64'" else
    (if ctx.target == "aarch64-linux-musl" then "'Linux aarch64'" else "'Linux x86_64'" end) end
  local line: string? = nil
  for each in Fixture.read(ctx.artifact):sub(1, 16384):gmatch("[^\n]+") do
    if String.starts_with(each, "  " .. host) then
      assert(line == nil, "duplicate selected launcher header")
      line = each
    end
  end
  local text = assert(line, "selected launcher header is missing")
  local function field(name: string): integer
    local digits = assert(text:match(name .. "=(%d+);"), "the arm has no " .. name)
    return assert(math.tointeger(tonumber(digits)))
  end
  return {
    offset = field("cosmic_offset"),
    stored = field("cosmic_stored"),
    length = field("cosmic_length"),
    stub_offset = field("cosmic_stub_block") * 16384,
    stub_length = field("cosmic_stub_length"),
  }
end

--- The artifact with the byte at `at` (0-based) changed.
local function flipped(bytes: string, at: integer): string
  return bytes:sub(1, at) .. string.char(assert(bytes:byte(at + 1)) ~ 0x55) .. bytes:sub(at + 2)
end

local function no_private_entries(cache: string, stem: string)
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(not String.starts_with(name, stem),
      "cache retained private entry: " .. name)
  end
end

--- A launch of `program` that must fail with `pattern` and leave nothing
--- behind it: no public core, no staged stub or core, no payload run.
local function refused(ctx: Context, label: string, pattern: string, program?: string): Fixture.Outcome
  local cache = ctx.work .. "/" .. label .. "-cache"
  local marker = ctx.work .. "/" .. label .. ".marker"
  local answer = run(ctx, label, cache, { PORTABLE_PAYLOAD_MARKER = marker }, program)
  assert(not answer.result.ok and not answer.result.timed_out,
    label .. " unexpectedly succeeded or timed out")
  Fixture.contains(answer.err, pattern)
  assert(Fs.exists(marker) == false, label .. " ran the payload")
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(String.starts_with(name, "."), label .. " published " .. name)
  end
  no_private_entries(cache, ".stub.")
  no_private_entries(cache, ".core.")
  return answer
end

local function hook_environment(cache: string, hook: string, ready: string,
                                go: string): {string:string}
  return environment(cache, { COSMIC_PORTABLE_TEST_HOOK = hook,
    COSMIC_PORTABLE_TEST_READY = ready, COSMIC_PORTABLE_TEST_GO = go })
end

local function test_a_compressed_payload_is_decoded_published_and_run(tmp: string)
  local ctx = packed(tmp)
  Fixture.mkdir(tmp .. "/raw")
  local plain = setup(tmp .. "/raw", "test")
  local cache = ctx.work .. "/cache"
  local marker = ctx.work .. "/cold.marker"
  outcome_ok(run(ctx, "cold", cache, { PORTABLE_PAYLOAD_MARKER = marker }), "cold packed launch")
  assert(Fixture.read(marker) == "ran\n", "the decoded payload did not run")
  local core = only_core(cache)
  assert(assert(Fs.stat(core)).mode & 0x1ff == 0x140, "the decoded core is not 0500")
  assert(assert(Fs.stat(cache)).mode & 0x1ff == 0x1c0, "the cache leaf is not 0700")
  -- Only the core is kept: the stub and the stage are gone.
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(not String.starts_with(name, "."), "cache kept " .. name)
  end
  -- The entry is named for the raw core and holds exactly the bytes a raw
  -- artifact of the same payload extracts.
  local raw_cache = plain.work .. "/cache"
  outcome_ok(run(plain, "raw", raw_cache), "raw launch")
  local raw_core = only_core(raw_cache)
  assert(core:match("([^/]+)$") == raw_core:match("([^/]+)$"),
    "the decoded core is named otherwise than the raw one")
  assert(Fixture.read(core) == Fixture.read(raw_core), "the decoded core differs from the raw one")
  local arm = arm_of(ctx)
  assert(arm.stored < arm.length or arm.length < 2000, "the payload is stored compressed")

  -- A warm start decodes nothing: it neither writes the leaf nor needs it writable.
  local core_stat = assert(Fs.stat(core))
  Process.chmod(cache, 0x140)
  outcome_ok(run(ctx, "warm", cache), "warm packed launch")
  local after = assert(Fs.stat(core))
  assert(after.mtime_ns == core_stat.mtime_ns and after.mtime == core_stat.mtime,
    "a warm start wrote the core")
  assert(#assert(Fs.list(cache)) == 1, "a warm start staged something")
  Process.chmod(cache, 0x1c0)
end

local function test_a_damaged_stub_is_refused_before_it_runs(tmp: string)
  local ctx = packed(tmp)
  local arm = arm_of(ctx)
  local bytes = Fixture.read(ctx.artifact)
  local equal = ctx.work .. "/stub-equal"
  Fixture.write(equal, flipped(bytes, arm.stub_offset + arm.stub_length // 2), 0x1ed)
  refused(ctx, "stub-equal", "extracted decoder digest differs", equal)
  local first = ctx.work .. "/stub-first"
  Fixture.write(first, flipped(bytes, arm.stub_offset), 0x1ed)
  refused(ctx, "stub-first", "extracted decoder digest differs", first)
  local truncated = ctx.work .. "/stub-truncated"
  Fixture.write(truncated, bytes:sub(1, arm.stub_offset + arm.stub_length - 1), 0x1ed)
  refused(ctx, "stub-truncated", "extracted decoder is truncated", truncated)
end

local function test_a_damaged_compressed_core_is_refused_before_it_is_published(tmp: string)
  local ctx = packed(tmp)
  local arm = arm_of(ctx)
  local bytes = Fixture.read(ctx.artifact)
  -- The frame's magic, a byte of its body, and the checksum at its end.
  for name, at in pairs({ magic = arm.offset, body = arm.offset + arm.stored // 2,
      checksum = arm.offset + arm.stored - 1 }) do
    local path = ctx.work .. "/frame-" .. name
    Fixture.write(path, flipped(bytes, at), 0x1ed)
    local answer = refused(ctx, "frame-" .. name, "decoder stub failed with status 1", path)
    Fixture.contains(answer.err, "unzstd: ")
  end
  local cut = ctx.work .. "/frame-cut"
  Fixture.write(cut, bytes:sub(1, arm.offset + arm.stored - 5), 0x1ed)
  refused(ctx, "frame-cut", "decoder stub failed with status 1", cut)
end

local function test_a_stub_that_fails_or_writes_the_wrong_bytes_stops_the_launch(tmp: string)
  local fails = packed(tmp .. "/fails-dir", "stub-fails")
  local answer = refused(fails, "stub-fails", "decoder stub failed with status 7")
  Fixture.contains(answer.err, "stand-in decoder: refusing")
  local short = packed(tmp .. "/short-dir", "stub-short")
  refused(short, "stub-short", "extracted core is truncated")
  local zero = packed(tmp .. "/zero-dir", "stub-zero")
  refused(zero, "stub-zero", "extracted core digest differs")
end

local function test_a_read_only_leaf_is_left_as_it_was(tmp: string)
  local ctx = packed(tmp)
  local leaf = ctx.work .. "/cold-read-only"
  Fixture.mkdir(leaf)
  Process.chmod(leaf, 0x140)
  local before = assert(Fs.stat(leaf))
  local answer = run(ctx, "cold-read-only", leaf)
  assert(not answer.result.ok, "a read-only leaf with no core launched")
  Fixture.contains(answer.err, "selected core is absent and cache is read-only")
  assert(#assert(Fs.list(leaf)) == 0, "a stub was staged in a read-only leaf")
  local after = assert(Fs.stat(leaf))
  assert(after.mtime_ns == before.mtime_ns and after.mode == before.mode, "the leaf changed")
  -- With the core in it, the same leaf runs it and stays as it is.
  Process.chmod(leaf, 0x1c0)
  outcome_ok(run(ctx, "fill", leaf), "fill")
  Process.chmod(leaf, 0x140)
  local filled = assert(Fs.stat(leaf))
  outcome_ok(run(ctx, "warm-read-only", leaf), "warm launch from a read-only leaf")
  local warm = assert(Fs.stat(leaf))
  assert(warm.mtime_ns == filled.mtime_ns and #assert(Fs.list(leaf)) == 1, "a warm launch changed the leaf")
  Process.chmod(leaf, 0x1c0)
end

local function test_concurrent_cold_starts_and_signals_while_the_stub_is_staged(tmp: string)
  local ctx = packed(tmp)
  Process.supervised(function(active: Process.Fleet)
    local race = ctx.work .. "/race-cache"
    local ready1 = Process.fifo(ctx.work, ctx.diagnostics, "race-ready1")
    local go1 = Process.fifo(ctx.work, ctx.diagnostics, "race-go1")
    local ready2 = Process.fifo(ctx.work, ctx.diagnostics, "race-ready2")
    local go2 = Process.fifo(ctx.work, ctx.diagnostics, "race-go2")
    local first = Process.start("race1", { ctx.artifact }, ctx.work,
      hook_environment(race, "after_stub", ready1, go1), ctx.diagnostics)
    Process.adopt(active, first)
    Process.await_ready(ctx.work, ctx.diagnostics, "race1", ready1, first)
    local second = Process.start("race2", { ctx.artifact }, ctx.work,
      hook_environment(race, "after_stub", ready2, go2), ctx.diagnostics)
    Process.adopt(active, second)
    Process.await_ready(ctx.work, ctx.diagnostics, "race2", ready2, second)
    -- Both have a stub staged, under names of their own, runnable by their owner alone.
    local stubs: mut {string} = {}
    for _, name in ipairs((assert(Fs.list(race)))) do
      if String.starts_with(name, ".stub.") then
        stubs[#stubs + 1] = name
        assert(assert(Fs.stat(race .. "/" .. name)).mode & 0x1ff == 0x140, "a staged stub is not 0500")
      end
    end
    assert(#stubs == 2, "expected two staged stubs, found " .. tostring(#stubs))
    Process.release(ctx.work, ctx.diagnostics, "race1", go1)
    Process.release(ctx.work, ctx.diagnostics, "race2", go2)
    assert(Process.finish(first).ok and Process.finish(second).ok, "decoding race failed")
    only_core(race)
    no_private_entries(race, ".stub.")
    no_private_entries(race, ".core.")

    -- A signal while the stub is staged removes it, and the next start is whole.
    local signaled = ctx.work .. "/signal-cache"
    local ready = Process.fifo(ctx.work, ctx.diagnostics, "signal-ready")
    local go = Process.fifo(ctx.work, ctx.diagnostics, "signal-go")
    local victim = Process.start("signaled", { ctx.artifact }, ctx.work,
      hook_environment(signaled, "after_stub", ready, go), ctx.diagnostics)
    Process.adopt(active, victim)
    Process.await_ready(ctx.work, ctx.diagnostics, "signal", ready, victim)
    assert(victim.handle:stop(sys.SIGTERM))
    assert(not Process.finish(victim).ok, "a terminated launch succeeded")
    no_private_entries(signaled, ".stub.")
    no_private_entries(signaled, ".core.")
    outcome_ok(run(ctx, "after-signal", signaled), "launch after a signal")
    only_core(signaled)

    -- A SIGKILL leaves the staged stub: private, plainly named, never published.
    local killed_cache = ctx.work .. "/kill-cache"
    local kill_ready = Process.fifo(ctx.work, ctx.diagnostics, "kill-ready")
    local kill_go = Process.fifo(ctx.work, ctx.diagnostics, "kill-go")
    local killed = Process.start("killed", { ctx.artifact }, ctx.work,
      hook_environment(killed_cache, "after_stub", kill_ready, kill_go), ctx.diagnostics)
    Process.adopt(active, killed)
    Process.await_ready(ctx.work, ctx.diagnostics, "kill", kill_ready, killed)
    assert(killed.handle:stop(sys.SIGKILL))
    assert(not Process.finish(killed).ok, "a killed launch succeeded")
    local litter = 0
    for _, name in ipairs((assert(Fs.list(killed_cache)))) do
      if String.starts_with(name, ".stub.") then litter = litter + 1 end
    end
    assert(litter == 1, "a killed launch left " .. tostring(litter) .. " staged stubs")
    outcome_ok(run(ctx, "after-kill", killed_cache), "launch after a SIGKILL")
    only_core(killed_cache)
  end)
end

--- A launcher whose stub is held while it decodes, and the cache it works in.
--- Returns the launch once the stub has said it is running.
local function held_in_decoder(ctx: Context, active: Process.Fleet, label: string): Process.Running, string, string
  local cache = ctx.work .. "/" .. label .. "-cache"
  local ready = Process.fifo(ctx.work, ctx.diagnostics, label .. "-ready")
  local go = Process.fifo(ctx.work, ctx.diagnostics, label .. "-go")
  local launch = Process.start(label, { ctx.artifact }, ctx.work,
    environment(cache, { COSMIC_PORTABLE_TEST_STUB_READY = ready, COSMIC_PORTABLE_TEST_STUB_GO = go }),
    ctx.diagnostics)
  Process.adopt(active, launch)
  Process.await_ready(ctx.work, ctx.diagnostics, label, ready, launch)
  return launch, cache, go
end

--- Nothing in `cache` is public.
local function nothing_published(cache: string)
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(String.starts_with(name, "."), "a decode that was cut short published " .. name)
  end
end

-- A signal reaches the launcher while the stub itself runs. The shell holds
-- a trap until its foreground command returns, so a SIGTERM takes effect when
-- the stub does, and the launch ends without publishing; a SIGKILL leaves the
-- staged stub and core, private and never public. The next start is whole.
local function test_signals_while_the_stub_is_decoding(tmp: string)
  local ctx = packed(tmp .. "/term", "stub-slow")
  local whole = packed(tmp .. "/whole")
  Process.supervised(function(active: Process.Fleet)
    local term, term_cache, term_go = held_in_decoder(ctx, active, "decode-term")
    assert(term.handle:stop(sys.SIGTERM))
    Process.release(ctx.work, ctx.diagnostics, "decode-term", term_go)
    assert(not Process.finish(term).ok, "a terminated launch succeeded")
    no_private_entries(term_cache, ".stub.")
    no_private_entries(term_cache, ".core.")
    nothing_published(term_cache)
    outcome_ok(run(whole, "after-term", term_cache), "launch after a signal in the decoder")
    only_core(term_cache)

    local kill, kill_cache, kill_go = held_in_decoder(ctx, active, "decode-kill")
    assert(kill.handle:stop(sys.SIGKILL))
    assert(not Process.finish(kill).ok, "a killed launch succeeded")
    -- The orphaned stand-in ends when let go; the launcher is not there to publish.
    Process.release(ctx.work, ctx.diagnostics, "decode-kill", kill_go)
    nothing_published(kill_cache)
    outcome_ok(run(whole, "after-kill-decode", kill_cache), "launch after a SIGKILL in the decoder")
    only_core(kill_cache)
  end)
end

--- The cost of a signed stub's first exec on macOS, which the launcher's
--- TODO (build/launcher.tl) waits on: the stub the launcher would cut out is
--- written to a new file and run with no arguments, which it refuses with its
--- usage status, then run again. The first run pays for validating the
--- signature of a binary no process has run; the second runs the same file.
--- Three new files, the best of each run. The figure is the job log's
--- ([`Fixture.figure`]), and stderr's where there is no orchestration.
--- It asserts nothing about the times: it says them, not judges.
local function test_the_first_exec_of_a_staged_stub_is_timed_on_macos(tmp: string)
  local ctx = packed(tmp)
  if ctx.target ~= "aarch64-macos" then
    Test.skip("the figure is for macOS, whose first exec of a new binary validates its signature")
    return
  end
  local arm = arm_of(ctx)
  local stub = Fixture.read(ctx.artifact):sub(arm.stub_offset + 1, arm.stub_offset + arm.stub_length)
  assert(#stub == arm.stub_length, "the artifact is shorter than its stub")
  local function exec(path: string, label: string): integer
    local started = Clock.monotonic_ns()
    local answer = Fixture.call(label, { path }, ctx.work, ctx.diagnostics, nil, Clock.seconds(30))
    local took = Clock.monotonic_ns() - started
    local result = answer.result
    assert(not result.timed_out and result.signal == nil and result.code == 2,
      label .. " did not end with the stub's usage status; stderr=" .. answer.err)
    return took
  end
  local first: integer? = nil
  local second: integer? = nil
  for n = 1, 3 do
    local path = ctx.work .. "/stub-timed-" .. tostring(n)
    Fixture.write(path, stub, 0x1ed)
    local one = exec(path, "stub-first-" .. tostring(n))
    local two = exec(path, "stub-second-" .. tostring(n))
    if first == nil or one < first then first = one end
    if second == nil or two < second then second = two end
  end
  local line = "launcher cold start: first exec of a new stub " .. tostring(assert(first) // 1000000) ..
    " ms, second exec of it " .. tostring(assert(second) // 1000000) .. " ms, difference " ..
    tostring((first - assert(second)) // 1000000) .. " ms"
  if not Fixture.figure("launcher-cold-start", line) then
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end
end

-- The CPU check is the launcher's first act, ahead of the cache and any stub.
local function test_the_cpu_check_comes_before_any_stub(tmp: string)
  local ctx = packed(tmp)
  local flags: string
  local label: string
  if ctx.target == "x86_64-linux-musl" then
    flags = "processor\t: 0\nflags\t\t: fpu sse4_2 avx xsave abm\n"
    label = "this CPU lacks avx2"
  elseif ctx.target == "aarch64-linux-musl" then
    flags = "processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n"
    label = "this CPU lacks asimddp"
  else
    Test.skip("only the Linux launchers check the CPU")
    return
  end
  local cpuinfo = ctx.work .. "/cpuinfo"
  Fixture.write(cpuinfo, flags)
  local cache = ctx.work .. "/old-cpu-cache"
  local answer = run(ctx, "old-cpu", cache, { COSMIC_PORTABLE_TEST_CPUINFO = cpuinfo })
  assert(not answer.result.ok and answer.result.code == 126, "an old CPU was not refused with 126")
  Fixture.contains(answer.err, label)
  assert(sys.lstat(cache) == nil, "a refused launch made the cache")
end
