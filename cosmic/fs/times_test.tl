#!/usr/bin/env cosmic
--- Tests for fs.set_times and fs.set_times_fd.
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

-- set_times/set_times_fd: exact timestamp semantics, not just
-- "touch moved mtime forward".

local function test_set_times_sets_exact_times()
  local test_dir = setup()
  local p = fs.join(test_dir, "stamped")
  touch(p, "x")

  local ok, err = fs.set_times(p, {atime = {secs = 1234567890, nsecs = 500000000}, mtime = {secs = 987654321, nsecs = 250000000}})
  assert(ok, "set_times should succeed: " .. (err or ""))

  local st = check.must(fs.stat(p), "stat should succeed")
  local at, mt = st:access_time(), st:modify_time()
  local a_s, a_ns, m_s, m_ns = at.secs, at.nsecs, mt.secs, mt.nsecs
  assert(a_s == 1234567890 and a_ns == 500000000,
    "atime should be exactly what was set, got " .. a_s .. "." .. a_ns)
  assert(m_s == 987654321 and m_ns == 250000000,
    "mtime should be exactly what was set, got " .. m_s .. "." .. m_ns)

  teardown(test_dir)
end
test_set_times_sets_exact_times()

-- Keep-current semantics key off *_secs, not *_nsecs: a nil secs must
-- leave that timestamp untouched no matter what nsecs is, and a real
-- secs value with nsecs omitted must land on literal 0, never epoch
-- (nil secs) and never "now" (the raw binding's own default).
local function test_set_times_omitted_field_keeps_current()
  local test_dir = setup()
  local p = fs.join(test_dir, "kept")
  touch(p, "x")
  assert(fs.set_times(p, {atime = {secs = 1111111111, nsecs = 111111111}, mtime = {secs = 2222222222, nsecs = 222222222}}))

  -- nil atime_secs (with a non-nil atime_nsecs, which must be ignored
  -- too) leaves atime alone; mtime is set exactly.
  local ok, err = fs.set_times(p, {mtime = {secs = 3333333333}})
  assert(ok, "set_times should succeed: " .. (err or ""))

  local st = check.must(fs.stat(p), "stat should succeed")
  local at, mt = st:access_time(), st:modify_time()
  local a_s, a_ns, m_s, m_ns = at.secs, at.nsecs, mt.secs, mt.nsecs
  assert(a_s == 1111111111 and a_ns == 111111111,
    "atime must be unchanged when secs is nil, got " .. a_s .. "." .. a_ns)
  assert(m_s == 3333333333 and m_ns == 0,
    "mtime should be exactly what was set, got " .. m_s .. "." .. m_ns)

  teardown(test_dir)
end
test_set_times_omitted_field_keeps_current()

local function test_set_times_bare_secs_means_zero_nsecs()
  local test_dir = setup()
  local p = fs.join(test_dir, "zero_nsecs")
  touch(p, "x")
  assert(fs.set_times(p, {atime = {secs = 1, nsecs = 500000000}, mtime = {secs = 1, nsecs = 500000000}}))

  -- secs given, nsecs omitted: nsecs must be literal 0, not "now" (the
  -- raw binding's own default) and not "keep current".
  local ok, err = fs.set_times(p, {atime = {secs = 4444444444}, mtime = {secs = 5555555555}})
  assert(ok, "set_times should succeed: " .. (err or ""))

  local st = check.must(fs.stat(p), "stat should succeed")
  local at, mt = st:access_time(), st:modify_time()
  local a_s, a_ns, m_s, m_ns = at.secs, at.nsecs, mt.secs, mt.nsecs
  assert(a_s == 4444444444 and a_ns == 0,
    "atime nsecs should default to 0, got " .. a_s .. "." .. a_ns)
  assert(m_s == 5555555555 and m_ns == 0,
    "mtime nsecs should default to 0, got " .. m_s .. "." .. m_ns)

  teardown(test_dir)
end
test_set_times_bare_secs_means_zero_nsecs()

local function test_set_times_missing_path()
  local test_dir = setup()
  local ok, err = fs.set_times(fs.join(test_dir, "absent"), {atime = {secs = 1}, mtime = {secs = 1}})
  assert(not ok, "set_times on a missing path should fail")
  assert(err and err:match("ENOENT"), "error should name ENOENT: " .. (err or ""))
  teardown(test_dir)
end
test_set_times_missing_path()

local function test_set_times_fd_sets_exact_times()
  local test_dir = setup()
  local p = fs.join(test_dir, "fstamped")
  touch(p, "x")

  local hh = check.must(cfd.open(p, 0))
  local ok, err = fs.set_times_fd(hh:fd(), {atime = {secs = 111}, mtime = {secs = 222}})
  assert(ok, "set_times_fd should succeed: " .. (err or ""))

  local st = check.must(fs.stat_fd(hh:fd()), "fstat should succeed")
  local at, mt = st:access_time(), st:modify_time()
  local a_s, a_ns, m_s, m_ns = at.secs, at.nsecs, mt.secs, mt.nsecs
  assert(a_s == 111 and a_ns == 0,
    "atime should be 111.0, got " .. a_s .. "." .. a_ns)
  assert(m_s == 222 and m_ns == 0,
    "mtime should be 222.0, got " .. m_s .. "." .. m_ns)
  assert(hh:close())

  teardown(test_dir)
end
test_set_times_fd_sets_exact_times()

local function test_set_times_fd_omitted_field_keeps_current()
  local test_dir = setup()
  local p = fs.join(test_dir, "fkept")
  touch(p, "x")

  local hh = check.must(cfd.open(p, 0))
  assert(fs.set_times_fd(hh:fd(), {atime = {secs = 1111111111, nsecs = 111111111}, mtime = {secs = 2222222222, nsecs = 222222222}}))

  -- nil atime_secs (with a non-nil atime_nsecs, ignored along with it)
  -- leaves atime alone; mtime with nsecs omitted lands on literal 0.
  local ok, err = fs.set_times_fd(hh:fd(), {mtime = {secs = 3333333333}})
  assert(ok, "set_times_fd should succeed: " .. (err or ""))

  local st = check.must(fs.stat_fd(hh:fd()), "fstat should succeed")
  local at, mt = st:access_time(), st:modify_time()
  local a_s, a_ns, m_s, m_ns = at.secs, at.nsecs, mt.secs, mt.nsecs
  assert(a_s == 1111111111 and a_ns == 111111111,
    "atime must be unchanged when secs is nil, got " .. a_s .. "." .. a_ns)
  assert(m_s == 3333333333 and m_ns == 0,
    "mtime nsecs should default to 0, got " .. m_s .. "." .. m_ns)
  assert(hh:close())

  teardown(test_dir)
end
test_set_times_fd_omitted_field_keeps_current()

local function test_set_times_fd_bad_fd()
  local ok, err = fs.set_times_fd(9999, {atime = {secs = 1}, mtime = {secs = 1}})
  assert(not ok, "set_times_fd on a bad fd should fail")
  assert(err and err:match("EBADF"), "error should name EBADF: " .. (err or ""))
end
test_set_times_fd_bad_fd()

print("all fs times tests passed")
