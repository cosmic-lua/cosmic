#!/usr/bin/env cosmic
--- Tests for fs file operations: copy, move, touch, write_atomic, temp_file.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cfd = require("cosmic.fd")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function setup(): string
  local test_dir = fs.join(TEST_TMPDIR, "fs_ops_test")
  assert(fs.make_dirs(test_dir))
  return test_dir
end

local function teardown(test_dir: string)
  if test_dir then
    assert(fs.remove_all(test_dir))
  end
end

local function touch(filepath: string, content?: string)
  local f = io.open(filepath, "w")
  if f then
    if content then
      f:write(content)
    end
    f:close()
  end
end

local function test_copy_preserves_mode()
  local test_dir = setup()
  local src = fs.join(test_dir, "src.sh")
  touch(src, "#!/bin/sh\necho hi\n")
  assert(fs.set_mode(src, fs.octal("755")))
  local dst = fs.join(test_dir, "dst.sh")

  local ok, err = fs.copy(src, dst)
  assert(ok, "copy should succeed: " .. (err or ""))

  local f = io.open(dst, "r")
  assert(f, "destination should exist")
  local content = f:read("*a")
  f:close()
  assert(content == "#!/bin/sh\necho hi\n", "content should match")

  local st = check.must(fs.stat(dst), "stat dst should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("755", 8),
    string.format("expected mode 755, got %o", mode))

  teardown(test_dir)
end
test_copy_preserves_mode()

local function test_copy_missing_source()
  local test_dir = setup()
  local ok, err = fs.copy(fs.join(test_dir, "absent"), fs.join(test_dir, "out"))
  assert(not ok, "copy of missing source should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_copy_missing_source()

-- signal-safety wave: copy()'s read/write loops retry automatically
-- instead of surfacing EINTR (matching cosmic.fd's posture). A regular
-- file's read/write essentially never blocks long enough to catch a
-- real signal mid-call, so both tests give copy() a source or
-- destination it can genuinely block on: a pipe, reopened by path via
-- /proc/self/fd (the same trick that lets a plain path-based open()
-- read or write through an already-open pipe fd) -- exactly like cfd's
-- own EINTR test, just exercised through fs.copy() instead of cfd
-- directly.
local function test_copy_retries_eintr_on_read()
  if not fs.is_dir("/proc/self/fd") then
    return -- the /proc/self/fd reopen trick needs procfs; skip elsewhere
  end
  local signal = require("cosmic.signal")
  local test_dir = setup()
  local p = check.must(cfd.pipe())
  local src = "/proc/self/fd/" .. tostring(p.reader:fd())
  local dst = fs.join(test_dir, "read_eintr_dst")

  local fired = false
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number)
        if not fired then
          fired = true
          assert(p.writer:write("hello"))
          assert(p.writer:close())
        end
      end))
  -- Interval timer: keeps firing until the blocked read observes a
  -- signal, so the test cannot hang however the timing lands.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 30,
        interval_ms = 30,
      }))
  local ok, err = fs.copy(src, dst)
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0, interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))

  assert(ok, "copy should retry a read interrupted by a signal: " .. tostring(err))
  assert(fs.read(dst) == "hello",
    "dst should contain the handler's payload, got " .. tostring((fs.read(dst))))
  assert(p:close())
  teardown(test_dir)
end
test_copy_retries_eintr_on_read()

local function test_copy_retries_eintr_on_write()
  if not fs.is_dir("/proc/self/fd") then
    return -- the /proc/self/fd reopen trick needs procfs; skip elsewhere
  end
  local signal = require("cosmic.signal")
  local test_dir = setup()
  local src = fs.join(test_dir, "big_src")
  -- Several times a default pipe's 64K capacity: the first chunk fills
  -- the (initially empty) pipe without blocking, so the SECOND chunk's
  -- write finds a completely full pipe and genuinely blocks until the
  -- handler below drains it.
  local chunk = string.rep("x", 65536)
  assert(fs.write(src, chunk .. chunk .. chunk .. chunk))
  local p = check.must(cfd.pipe())
  -- The reader is drained from the signal handler; non-blocking so a
  -- handler firing before there is anything to drain cannot itself block.
  assert(p.reader:fcntl(cfd.F_SETFL, cfd.O_NONBLOCK))
  local dst = "/proc/self/fd/" .. tostring(p.writer:fd())

  local drained: {string} = {}
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number)
        local got = p.reader:read(65536)
        if got then table.insert(drained, got) end
      end))
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 20,
        interval_ms = 20,
      }))
  local ok, err = fs.copy(src, dst)
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0, interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))
  assert(p.writer:close())

  -- Drain whatever is left buffered in the pipe once copy() is done.
  while true do
    local got = p.reader:read(65536)
    if not got then break end
    table.insert(drained, got)
  end

  assert(ok, "copy should retry a write interrupted by a signal: " .. tostring(err))
  assert(table.concat(drained) == chunk .. chunk .. chunk .. chunk,
    "dst should contain exactly the source bytes, unaffected by the retry")
  assert(p:close())
  teardown(test_dir)
end
test_copy_retries_eintr_on_write()

local function test_move_same_filesystem()
  local test_dir = setup()
  local src = fs.join(test_dir, "a.txt")
  touch(src, "payload")
  local dst = fs.join(test_dir, "b.txt")

  local ok, err = fs.move(src, dst)
  assert(ok, "move should succeed: " .. (err or ""))
  assert(not fs.is_present(src), "source should be gone")
  local f = io.open(dst, "r")
  assert(f, "destination should exist")
  assert(f:read("*a") == "payload", "content should move intact")
  f:close()

  teardown(test_dir)
end
test_move_same_filesystem()

local function test_move_missing_source()
  local test_dir = setup()
  local ok, err = fs.move(fs.join(test_dir, "absent"), fs.join(test_dir, "out"))
  assert(not ok, "move of missing source should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_move_missing_source()

local function test_touch_creates_and_updates()
  local test_dir = setup()
  local p = fs.join(test_dir, "stamp")
  assert(not fs.is_present(p), "file should not exist yet")

  local ok, err = fs.touch(p)
  assert(ok, "touch should create the file: " .. (err or ""))
  assert(fs.is_file(p), "touch should create a regular file")

  -- Backdate mtime, then touch again: mtime must move forward.
  assert(fs.set_times(p, {atime = {secs = 1000}, mtime = {secs = 1000}}))
  local before = check.must(fs.stat(p), "stat should succeed")
  local ok2, err2 = fs.touch(p)
  assert(ok2, "touch should succeed on existing file: " .. (err2 or ""))
  local after = check.must(fs.stat(p), "stat should succeed")
  local before_m = before:modify_time().secs
  local after_m = after:modify_time().secs
  assert(after_m > before_m,
    "touch should update mtime: " .. before_m .. " -> " .. after_m)

  teardown(test_dir)
end
test_touch_creates_and_updates()

-- `touch` stamps first and creates only when that fails, which is what
-- `touch(1)` does and what opening for write cannot: utimensat asks for
-- OWNERSHIP where open asks for WRITE PERMISSION. Both cases the old
-- order refused.
local function test_touch_stamps_what_it_cannot_open_for_write()
  local test_dir = setup()

  local ro = fs.join(test_dir, "readonly")
  assert(fs.write(ro, "x"))
  assert(fs.set_mode(ro, fs.octal("444")))
  assert(fs.set_times(ro, {atime = {secs = 1000}, mtime = {secs = 1000}}))
  local before = check.must(fs.stat(ro), "stat should succeed")
  local ok, err = fs.touch(ro)
  assert(ok, "touch must stamp a read-only file its caller owns: " ..
    (err or ""))
  local after = check.must(fs.stat(ro), "stat should succeed")
  assert(after:modify_time().secs > before:modify_time().secs, "and move its mtime")

  local dir = fs.join(test_dir, "adir")
  assert(fs.make_dirs(dir))
  assert(fs.set_times(dir, {atime = {secs = 1000}, mtime = {secs = 1000}}))
  local dbefore = check.must(fs.stat(dir), "stat should succeed")
  local dok, derr = fs.touch(dir)
  assert(dok, "touch must stamp a directory, not fail EISDIR: " ..
    (derr or ""))
  local dafter = check.must(fs.stat(dir), "stat should succeed")
  assert(dafter:modify_time().secs > dbefore:modify_time().secs, "and move its mtime")

  teardown(test_dir)
end
test_touch_stamps_what_it_cannot_open_for_write()

local function test_write_atomic_roundtrip()
  local test_dir = setup()
  local p = fs.join(test_dir, "config.json")
  touch(p, "old")

  local ok, err = fs.write(p, "new contents", {atomic = true, mode = tonumber("600", 8)})
  assert(ok, "write_atomic should succeed: " .. (err or ""))
  local f = io.open(p, "r")
  assert(f, "file should exist")
  assert(f:read("*a") == "new contents", "contents should be replaced")
  f:close()

  local st = check.must(fs.stat(p), "stat should succeed")
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8),
    string.format("expected mode 600, got %o", mode))

  -- No temporary residue left behind.
  local leftovers = check.must(fs.find(test_dir, {glob = "config.json.*"}))
  assert(#leftovers == 0, "no temp files should remain: " .. tostring(leftovers[1]))

  teardown(test_dir)
end
test_write_atomic_roundtrip()

local function test_write_atomic_failure_keeps_original()
  local test_dir = setup()
  local original = fs.join(test_dir, "keep.txt")
  touch(original, "original")

  -- A destination in a missing directory fails before touching anything.
  local p = fs.join(test_dir, "no-such-subdir", "f.txt")
  local ok, err = fs.write(p, "data", {atomic = true})
  assert(not ok, "write_atomic into a missing directory should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))

  local f = io.open(original, "r")
  assert(f, "unrelated file should be untouched")
  assert(f:read("*a") == "original", "original contents should survive")
  f:close()

  teardown(test_dir)
end
test_write_atomic_failure_keeps_original()

-- write_atomic()'s write loop uses the identical retry construct proven
-- above for copy() (fs/ops.tl's copy and fs/file.tl's write_atomic share
-- the same errno.is_code(_, "EINTR") pattern). It is not independently forced
-- here: write_atomic's destination is always a real mkstemp()'d path
-- (mkstemp creates the file itself from a template), so it cannot be
-- redirected to a pipe the way copy()'s open()-a-given-path can, and
-- there is no portable way to make a local write() block on demand.

local function test_tmpfile_success_contract()
  local test_dir = setup()
  local tf, err = fs.temp_file(fs.join(test_dir, "fs_ops_XXXXXX"))
  local t = check.must(tf, "temp_file should succeed: " .. tostring(err))
  assert(t.path:match("fs_ops_"), "the record carries the path")
  assert(err == nil, "error slot should be nil on success")
  local st = fs.stat_fd(t.handle:fd())
  assert(st, "fstat on temp_file fd should succeed")
  assert(t.handle:close())
  teardown(test_dir)
end
test_tmpfile_success_contract()

-- remove_all failure path: a path whose parent component is a
-- regular file fails with ENOTDIR regardless of privileges.

local function test_rmrf_failure_reports_error()
  local test_dir = setup()
  local blocker = fs.join(test_dir, "afile")
  touch(blocker, "x")
  local ok, err = fs.remove_all(fs.join(blocker, "child"))
  assert(not ok, "remove_all through a file component should fail")
  assert(err and err:match("ENOTDIR"), "error should name ENOTDIR: " .. (err or ""))
  assert(fs.is_file(blocker), "the blocking file must be untouched")
  teardown(test_dir)
end
test_rmrf_failure_reports_error()

local function test_tmpfile_failure_contract()
  -- One record on success; the error in slot 2 on failure.
  local tf, err = fs.temp_file("/no/such/dir/fs_ops_XXXXXX")
  assert(tf == nil, "temp_file should fail in a missing directory")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
end
test_tmpfile_failure_contract()

local function test_write_mode_applies_on_overwrite()
  -- Barf's mode applies only at creation; fs.write enforces the exact
  -- bits on overwrite too, so zip and tar extraction agree about the
  -- permissions of a re-extracted file.
  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local path = fs.join(base, "mode_overwrite.txt")
  assert(fs.write(path, "one", {mode = tonumber("644", 8)}))
  assert(fs.write(path, "two", {mode = tonumber("600", 8)}))
  local st = check.must(fs.stat(path))
  local mode = st:mode() & tonumber("777", 8)
  assert(mode == tonumber("600", 8),
    string.format("overwrite must apply the mode: got %o", mode))
  assert(fs.read(path) == "two", "content overwritten")
  assert(fs.remove_all(path))
end
test_write_mode_applies_on_overwrite()

local function test_set_umask_round_trips()
  local original = fs.set_umask(0)
  local prev = fs.set_umask(tonumber("022", 8))
  assert(prev == 0, "the previous mask comes back, got " .. tostring(prev))
  fs.set_umask(original)
end
test_set_umask_round_trips()
