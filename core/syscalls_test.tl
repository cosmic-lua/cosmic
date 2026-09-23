--- The syscall table's contract, binding by binding, as core/syscalls.h
--- states it: an argument no correct program passes raises, and a
--- failure a correct caller meets at runtime comes back as `nil` (for a
--- value) or `false` (for an effect), then the error, then the errno.
---
--- Each test calls the C through `cosmic.sys` directly rather than
--- through the typed modules above it, so a binding is held to its own
--- promise and not to whatever a wrapper makes of it. `sys.exit` is the
--- one binding with no test here: it ends the process the test runs in.

local sys = require("cosmic.sys")

--- Asserts `value, message, number` is the failure shape: `nil` or
--- `false` first, a non-empty message, then a positive errno. The call
--- under test goes last, so every value it returns arrives here.
local function failed(value: any, message: any, number: any)
  assert(value == nil or value == false,
    "a failure must lead with nil or false, not " .. tostring(value))
  assert(type(message) == "string" and message ~= "",
    "a failure must say what went wrong")
  assert(math.type(number) == "integer" and (number as integer) > 0,
    "a failure must carry its errno, not " .. tostring(number))
end

--- `failed`, and the errno is `errno` in particular.
local function failed_with(errno: integer, value: any, message: any, number: any)
  failed(value, message, number)
  assert(number == errno, "expected errno " .. errno .. ", got " .. tostring(number))
end

--- Asserts calling `fn` with `...` raises rather than returning.
local function raises(fn: any, ...: any)
  local ok = pcall(fn as function(any...): (any...), ...)
  assert(not ok, "a degenerate argument must raise")
end

--- Opens `path` for writing, creating it, and returns the descriptor.
local function create(path: string): integer
  local fd, trouble = sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420)
  assert(fd ~= nil, trouble)
  return fd
end

local function test_open_and_close(tmp: string)
  local fd = create(tmp .. "/a")
  local closed, trouble = sys.close(fd)
  assert(closed == true, trouble)
  failed(sys.close(fd))
end

local function test_open_refuses_a_missing_path(tmp: string)
  failed_with(sys.ENOENT, sys.open(tmp .. "/missing", sys.O_RDONLY))
end

local function test_open_exclusive_refuses_an_existing_file(tmp: string)
  sys.close(create(tmp .. "/a"))
  failed_with(sys.EEXIST, sys.open(tmp .. "/a", sys.O_CREAT | sys.O_EXCL | sys.O_WRONLY))
end

local function test_open_raises_on_a_path_that_is_not_a_string()
  raises(sys.open, {}, sys.O_RDONLY)
end

local function test_write_read_and_seek(tmp: string)
  local fd = create(tmp .. "/a")
  assert(sys.write(fd, "hello, world") == 12)
  assert(sys.lseek(fd, 0, sys.SEEK_SET) == 0)
  assert(sys.read(fd, 5) == "hello")
  assert(sys.read(fd, 100) == ", world")
  assert(sys.read(fd, 100) == "", "end of file is an empty string")
  assert(sys.lseek(fd, 0, sys.SEEK_END) == 12)
  assert(sys.lseek(fd, -5, sys.SEEK_CUR) == 7)
  sys.close(fd)
end

local function test_read_zero_bytes_is_an_empty_string(tmp: string)
  local fd = create(tmp .. "/a")
  assert(sys.read(fd, 0) == "")
  sys.close(fd)
end

local function test_read_and_write_fail_on_a_closed_descriptor(tmp: string)
  local fd = create(tmp .. "/a")
  sys.close(fd)
  failed(sys.read(fd, 1))
  failed(sys.write(fd, "x"))
  failed(sys.pread(fd, 1, 0))
  failed(sys.lseek(fd, 0, sys.SEEK_SET))
  failed(sys.fstat(fd))
end

local function test_read_raises_on_a_negative_count(tmp: string)
  local fd = create(tmp .. "/a")
  raises(sys.read, fd, -1)
  raises(sys.pread, fd, -1, 0)
  raises(sys.pread, fd, 1, -1)
  sys.close(fd)
end

local function test_pread_reads_at_an_offset_without_moving(tmp: string)
  local fd = create(tmp .. "/a")
  sys.write(fd, "0123456789")
  assert(sys.pread(fd, 3, 4) == "456")
  assert(sys.pread(fd, 10, 8) == "89", "a read past the end is short")
  assert(sys.pread(fd, 1, 100) == "")
  assert(sys.lseek(fd, 0, sys.SEEK_CUR) == 10, "pread leaves the offset alone")
  sys.close(fd)
end

local function test_a_read_larger_than_any_buffer(tmp: string)
  local fd = create(tmp .. "/a")
  local big = string.rep("0123456789abcdef", 16384)
  assert(sys.write(fd, big) == #big)
  assert(sys.pread(fd, #big + 1, 0) == big)
  sys.close(fd)
end

local function test_fstat_and_stat_describe_a_file(tmp: string)
  local fd = create(tmp .. "/a")
  sys.write(fd, "abc")
  local by_fd = assert(sys.fstat(fd))
  sys.close(fd)
  local by_path = assert(sys.stat(tmp .. "/a"))
  for _, st in ipairs({ by_fd, by_path }) do
    assert(st.kind == "file")
    assert(st.size == 3)
    assert(st.nlink == 1)
    assert(st.mtime > 0 and st.mtime_ns >= 0 and st.mtime_ns < 1000000000)
  end
  assert(by_fd.ino == by_path.ino and by_fd.dev == by_path.dev)
  assert(by_fd.uid == by_path.uid and by_fd.gid == by_path.gid)
end

local function test_stat_and_lstat_describe_a_directory(tmp: string)
  assert(assert(sys.stat(tmp)).kind == "dir")
  assert(assert(sys.lstat(tmp)).kind == "dir")
end

local function test_stat_and_lstat_refuse_a_missing_path(tmp: string)
  failed_with(sys.ENOENT, sys.stat(tmp .. "/missing"))
  failed_with(sys.ENOENT, sys.lstat(tmp .. "/missing"))
end

local function test_mkdir_and_rmdir(tmp: string)
  local made, trouble = sys.mkdir(tmp .. "/d")
  assert(made == true, trouble)
  assert(assert(sys.stat(tmp .. "/d")).kind == "dir")
  failed_with(sys.EEXIST, sys.mkdir(tmp .. "/d"))
  local removed, remove_trouble = sys.rmdir(tmp .. "/d")
  assert(removed == true, remove_trouble)
  failed_with(sys.ENOENT, sys.rmdir(tmp .. "/d"))
end

local function test_mkdir_takes_a_mode(tmp: string)
  assert(sys.mkdir(tmp .. "/d", 448))
  assert(assert(sys.stat(tmp .. "/d")).mode & 511 == 448)
end

local function test_rmdir_refuses_a_directory_with_entries(tmp: string)
  assert(sys.mkdir(tmp .. "/d"))
  sys.close(create(tmp .. "/d/a"))
  failed_with(sys.ENOTEMPTY, sys.rmdir(tmp .. "/d"))
end

local function test_unlink(tmp: string)
  sys.close(create(tmp .. "/a"))
  local removed, trouble = sys.unlink(tmp .. "/a")
  assert(removed == true, trouble)
  failed_with(sys.ENOENT, sys.unlink(tmp .. "/a"))
end

local function test_rename_replaces_the_destination(tmp: string)
  local fd = create(tmp .. "/a")
  sys.write(fd, "new")
  sys.close(fd)
  sys.close(create(tmp .. "/b"))
  local moved, trouble = sys.rename(tmp .. "/a", tmp .. "/b")
  assert(moved == true, trouble)
  failed_with(sys.ENOENT, sys.stat(tmp .. "/a"))
  assert(assert(sys.stat(tmp .. "/b")).size == 3)
  failed_with(sys.ENOENT, sys.rename(tmp .. "/a", tmp .. "/c"))
end

local function test_chmod(tmp: string)
  sys.close(create(tmp .. "/a"))
  local changed, trouble = sys.chmod(tmp .. "/a", 384)
  assert(changed == true, trouble)
  assert(assert(sys.stat(tmp .. "/a")).mode & 511 == 384)
  failed_with(sys.ENOENT, sys.chmod(tmp .. "/missing", 384))
end

local function test_readdir_lists_entries_without_dot_and_dot_dot(tmp: string)
  assert(sys.mkdir(tmp .. "/d"))
  sys.close(create(tmp .. "/d/a"))
  sys.close(create(tmp .. "/d/.hidden"))
  assert(sys.mkdir(tmp .. "/d/sub"))
  local entries = assert(sys.readdir(tmp .. "/d"))
  local count = 0
  for _ in pairs(entries) do count = count + 1 end
  assert(count == 3, "three entries, got " .. count)
  assert(entries[".hidden"] == "file" and entries["a"] == "file")
  assert(entries["sub"] == "dir", "each entry says what it is")
  assert(next((assert(sys.readdir(tmp .. "/d/sub")))) == nil)
end

local function test_readdir_refuses_a_missing_path_and_a_file(tmp: string)
  failed_with(sys.ENOENT, sys.readdir(tmp .. "/missing"))
  sys.close(create(tmp .. "/a"))
  failed_with(sys.ENOTDIR, sys.readdir(tmp .. "/a"))
end

local function test_chdir_and_getcwd(tmp: string)
  local before = assert(sys.getcwd())
  local resolved = assert(sys.realpath(tmp))
  local moved, trouble = sys.chdir(tmp)
  -- Put the directory back before anything below can raise: every test
  -- after this one runs in this same process.
  local here = sys.getcwd()
  sys.chdir(before)
  assert(moved == true, trouble)
  assert(here == resolved, tostring(here) .. " is not " .. resolved)
  assert(sys.getcwd() == before)
  failed_with(sys.ENOENT, sys.chdir(tmp .. "/missing"))
end

local function test_realpath_resolves_dot_and_dot_dot(tmp: string)
  assert(sys.mkdir(tmp .. "/d"))
  local resolved = assert(sys.realpath(tmp))
  assert(resolved:sub(1, 1) == "/", "the resolved path is absolute")
  assert(sys.realpath(tmp .. "/./d/..") == resolved)
  failed_with(sys.ENOENT, sys.realpath(tmp .. "/missing"))
end

local function test_mkdtemp_makes_a_fresh_directory(tmp: string)
  local a = assert(sys.mkdtemp(tmp .. "/t-XXXXXX"))
  local b = assert(sys.mkdtemp(tmp .. "/t-XXXXXX"))
  assert(a ~= b, "two directories from one template are distinct")
  assert(a:match("^" .. tmp:gsub("%p", "%%%0") .. "/t%-......$") ~= nil)
  assert(assert(sys.stat(a)).kind == "dir")
end

local function test_mkdtemp_refuses_a_bad_template(tmp: string)
  raises(sys.mkdtemp, tmp .. "/no-placeholder")
  raises(sys.mkdtemp, "XXXXX")
  failed_with(sys.ENOENT, sys.mkdtemp(tmp .. "/missing/t-XXXXXX"))
  raises(sys.mkdtemp, string.rep("x", 1 << 16) .. "XXXXXX")
end

--- It returns only when it fails, which is the one way a test can
--- call it and still report.
local function test_execve_fails_for_a_missing_program(tmp: string)
  failed_with(sys.ENOENT, sys.execve(tmp .. "/missing", { "missing" }, {}))
end

--- Every argv entry and environment name and value is a string already:
--- a number converted where it lay would leave argv pointing at a string
--- nothing holds.
local function test_execve_raises_on_an_entry_that_is_not_a_string(tmp: string)
  local missing = tmp .. "/missing"
  raises(sys.execve, missing, { "missing", 1 }, {})
  raises(sys.execve, missing, { "missing", 1.5 }, {})
  raises(sys.execve, missing, { "missing" }, { NAME = 1 })
  raises(sys.execve, missing, { "missing" }, { [1] = "value" })
  raises(sys.execve, missing, { "missing" }, { ["A=B"] = "value" })
  raises(sys.execve, missing, { "missing", "a\0b" }, {})
end

--- A failed execve leaves this process as it was: SIGPIPE, which it hands
--- the new program at the default, is ignored again here.
local function test_a_failed_execve_keeps_sigpipe_ignored(tmp: string)
  assert(sys.ignore_sigpipe())
  failed_with(sys.ENOENT, sys.execve(tmp .. "/missing", { "missing" }, {}))
  local fd = sys.open("/proc/self/status", sys.O_RDONLY)
  if fd == nil then return end -- no /proc to ask
  local status = assert(sys.read(fd, 1 << 16))
  sys.close(fd)
  local ignored = assert(status:match("SigIgn:%s*(%x+)"), status)
  local mask = math.tointeger(tonumber(ignored, 16)) or 0
  assert(mask & (1 << (sys.SIGPIPE - 1)) ~= 0,
    "SIGPIPE is ignored again: " .. ignored)
end

--- A count is what a read may answer, not what it allocates: one far
--- past any memory reads a small file, a pipe, and a file that says it
--- is empty (/proc's) whole.
local function test_a_read_of_a_huge_count_answers_what_there_is(tmp: string)
  local fd = create(tmp .. "/a")
  assert(sys.write(fd, "small") == 5)
  assert(sys.pread(fd, 1 << 50, 0) == "small")
  assert(sys.pread(fd, 1 << 50, 2) == "all")
  assert(sys.pread(fd, 1 << 50, 5) == "")
  assert(sys.lseek(fd, 1, sys.SEEK_SET) == 1)
  assert(sys.read(fd, 1 << 50) == "mall")
  assert(sys.read(fd, 1 << 50) == "")
  sys.close(fd)

  local ends = assert(sys.pipe())
  assert(sys.write(ends.writer, "piped") == 5)
  assert(sys.read(ends.reader, 1 << 50) == "piped")
  sys.close(ends.reader)
  sys.close(ends.writer)

  local proc = sys.open("/proc/self/status", sys.O_RDONLY)
  if proc == nil then return end -- no /proc to read
  local st = assert(sys.fstat(proc))
  local text = assert(sys.read(proc, 1 << 50))
  sys.close(proc)
  assert(st.size < #text, "the file says it holds less than it does")
  assert(text:find("SigIgn:", 1, true) ~= nil, text)
end

local function test_cpu_count_is_at_least_one()
  local count = sys.cpu_count()
  assert(math.type(count) == "integer" and count >= 1)
end

local function test_executable_is_a_file()
  local path = assert(sys.executable())
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(assert(sys.stat(path)).kind == "file")
end

local function test_environ_agrees_with_getenv()
  local all = sys.environ()
  local seen = 0
  for name, value in pairs(all) do
    assert(sys.getenv(name) == value, name)
    seen = seen + 1
  end
  assert(seen > 0, "the tests run with some environment")
  assert(sys.getenv("COSMIC_TEST_A_NAME_NOTHING_SETS") == nil)
end

local function test_getpid_is_stable_and_positive()
  local pid = sys.getpid()
  assert(pid > 0)
  assert(sys.getpid() == pid)
end

local function test_clocks_read_and_the_monotonic_one_advances()
  assert(assert(sys.clock_gettime(sys.CLOCK_REALTIME)) > 0)
  local before = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC))
  local slept, trouble = sys.nanosleep(2000000)
  assert(slept == true, trouble)
  local after = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC))
  assert(after - before >= 2000000, "slept " .. (after - before) .. "ns")
end

local function test_clock_gettime_refuses_an_unknown_clock()
  failed(sys.clock_gettime(12345))
end

local function test_nanosleep_raises_on_a_negative_duration()
  raises(sys.nanosleep, -1)
  assert(sys.nanosleep(0))
end

local function test_isatty_is_false_for_a_file_and_a_bad_descriptor(tmp: string)
  local fd = create(tmp .. "/a")
  assert(sys.isatty(fd) == false)
  sys.close(fd)
  assert(sys.isatty(fd) == false)
end

local function hex(bytes: string): string
  return (bytes:gsub(".", function(c: string): string
    return string.format("%02x", c:byte())
  end))
end

--- FIPS 180-2's own examples, plus the lengths either side of where the
--- padding spills into a second block.
local function test_digest_sha256_known_answers()
  local cases: {{string}} = {
    { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
    { string.rep("a", 1000000),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
  }
  for _, case in ipairs(cases) do
    local digest = sys.digest("sha256", case[1])
    assert(hex(digest) == case[2], #case[1] .. " bytes hashed to " .. hex(digest))
  end
  for _, len in ipairs({ 55, 56, 63, 64, 65 }) do
    assert(#sys.digest("sha256", string.rep("x", len)) == 32)
  end
end

--- Every algorithm `digest` names, by the size of what it returns.
local function test_digest_sizes_by_algorithm()
  local sizes: {string: integer} = {
    md5 = 16, sha1 = 20, sha224 = 28, sha256 = 32, sha384 = 48, sha512 = 64,
    ["sha3-224"] = 28, ["sha3-256"] = 32, ["sha3-384"] = 48, ["sha3-512"] = 64,
  }
  for algorithm, size in pairs(sizes) do
    assert(#sys.digest(algorithm, "abc") == size, algorithm)
  end
end

--- RFC 4231's second test case.
local function test_hmac_sha256_known_answer()
  local mac = sys.hmac("sha256", "Jefe", "what do ya want for nothing?")
  assert(hex(mac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    hex(mac))
end

local function test_digest_and_hmac_raise_on_an_unknown_algorithm()
  raises(sys.digest, "sha0", "abc")
  raises(sys.hmac, "sha0", "key", "abc")
end

local function test_deflate_and_inflate_round_trip()
  for _, data in ipairs({ "", "a", string.rep("compressible ", 10000),
                          sys.digest("sha256", "seed"):rep(3000) }) do
    local packed = assert(sys.deflate(data))
    assert(sys.inflate(packed, #data) == data, #data .. " bytes did not round-trip")
  end
end

--- miniz's own result code rides in slot three where an errno would,
--- so these check the shape by hand rather than through `failed`.
local function test_inflate_refuses_bytes_that_are_not_deflate()
  local value, message, code = sys.inflate("not deflate at all", 100)
  assert(value == nil and type(message) == "string" and message ~= "")
  assert(math.type(code) == "integer" and code ~= 0)
end

local function test_inflate_refuses_a_size_too_small()
  local data = string.rep("abc", 1000)
  local packed = assert(sys.deflate(data))
  local value, message, code = sys.inflate(packed, #data - 1)
  assert(value == nil and type(message) == "string" and message ~= "")
  assert(math.type(code) == "integer" and code ~= 0)
end

local function test_inflate_raises_on_a_negative_size()
  raises(sys.inflate, "", -1)
end

--- A descriptor past what an int holds is refused, not truncated: 2^32
--- + 2 must never reach the system as descriptor 2.
local function test_a_descriptor_past_an_int_raises()
  local wide = (1 << 32) + 2
  raises(sys.fstat, wide)
  raises(sys.close, wide)
  raises(sys.read, wide, 1)
  raises(sys.write, wide, "x")
  raises(sys.isatty, wide)
  raises(sys.lseek, wide, 0, sys.SEEK_SET)
end

local function test_a_mode_or_flag_past_an_int_raises(tmp: string)
  raises(sys.open, tmp .. "/a", (1 << 40) | sys.O_RDONLY)
  raises(sys.mkdir, tmp .. "/d", 1 << 40)
  raises(sys.clock_gettime, (1 << 32) + sys.CLOCK_MONOTONIC)
end

--- A directory listed and one refused both leave no descriptor behind:
--- the listing's handle is released however the call ends.
local function test_readdir_leaves_no_descriptor_open(tmp: string)
  assert(sys.mkdir(tmp .. "/d"))
  local before = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(before)
  for _ = 1, 50 do
    assert(sys.readdir(tmp .. "/d"))
    failed(sys.readdir(tmp .. "/missing"))
  end
  local after = assert(sys.open(tmp .. "/probe", sys.O_RDWR))
  sys.close(after)
  assert(after == before, "descriptor " .. after .. " opened where " .. before .. " was free")
end
