--- The syscall table's contract, binding by binding, as core/syscalls.h
--- states it: an argument no correct program passes raises, and a
--- failure a correct caller meets at runtime comes back as `nil` (for a
--- value) or `false` (for an effect), then the error, then the errno.
---
--- Each test calls the C through `cosmic.sys` directly rather than
--- through the typed modules above it, so a binding is held to its own
--- promise and not to whatever a wrapper makes of it; so too core/process.h's
--- calls and `digest` and `hmac`, through the raw tables the store hands
--- `cosmic.child` and `cosmic.hash`. `sys.exit` is the one binding with
--- no test here: it ends the process the test runs in.

local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local type raw_hash = require("cosmic.internal.hash")
local type raw_process = require("cosmic.internal.process")

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader, as
--- `require` would hand it.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares
local hash = raw_behind("cosmic.hash") as raw_hash -- cast: the table cosmic/internal/hash.d.tl declares

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
  -- The runner's tmp is reached through a link, so lstat of a
  -- directory is asked of one made here.
  local dir = tmp .. "/d"
  assert(sys.mkdir(dir))
  assert(assert(sys.stat(dir)).kind == "dir")
  assert(assert(sys.lstat(dir)).kind == "dir")
end

local function test_stat_and_lstat_refuse_a_missing_path(tmp: string)
  failed_with(sys.ENOENT, sys.stat(tmp .. "/missing"))
  failed_with(sys.ENOENT, sys.lstat(tmp .. "/missing"))
end

--- Each time is whole seconds and the nanoseconds after them, as a
--- Stat reports it; nil seconds leave that time alone, and naming
--- neither, nanoseconds without seconds, or nanoseconds outside
--- [0, 1e9) are mistakes that raise.
local function test_utimensat_sets_either_time_to_the_nanosecond(tmp: string)
  local path = tmp .. "/f"
  assert(sys.close(create(path)))
  assert(sys.utimensat(path, 5, 6, 7, 8))
  local st = assert(sys.stat(path))
  assert(st.atime == 5 and st.atime_ns == 6 and st.mtime == 7 and st.mtime_ns == 8)
  assert(sys.utimensat(path, nil, nil, -1, 999999999))
  st = assert(sys.stat(path))
  assert(st.mtime == -1 and st.mtime_ns == 999999999, st.mtime .. "." .. st.mtime_ns)
  assert(st.atime == 5 and st.atime_ns == 6)
  assert(sys.utimensat(path, 9))
  st = assert(sys.stat(path))
  assert(st.atime == 9 and st.atime_ns == 0 and st.mtime == -1)
  raises(sys.utimensat, path)
  raises(sys.utimensat, path, nil, nil, nil, nil)
  raises(sys.utimensat, path, nil, 5, 7)
  raises(sys.utimensat, path, 1, 1000000000)
  raises(sys.utimensat, path, nil, nil, 1, -1)
  failed_with(sys.ENOENT, sys.utimensat(tmp .. "/missing", nil, nil, 0))
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
  assert(process.ignore_sigpipe())
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

  local ends = assert(process.pipe())
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

--- Whether `fd` is closed on exec, as /proc says; nil where there is no
--- /proc to ask.
-- TODO: ask the descriptor itself, once cosmic.sys carries
-- fcntl(F_GETFD): without /proc (macOS, a sandbox) the close-on-exec
-- promises of dup and dup2 go unchecked.
local function closed_on_exec(fd: integer): boolean | nil
  local info = sys.open("/proc/self/fdinfo/" .. fd, sys.O_RDONLY)
  if info == nil then return nil end
  local text = assert(sys.read(info, 4096))
  sys.close(info)
  local flags = assert(tonumber(assert(text:match("flags:%s*(%d+)")), 8))
  return flags & 0x80000 ~= 0
end

--- A copy names what its original does and is closed on exec; `dup2`
--- points a descriptor at another's file, which is how a caller takes
--- over its own standard output for a while: what `print` writes from C
--- lands there too, and the descriptor stays open across exec.
local function test_dup_and_dup2_redirect_a_descriptor(tmp: string)
  local ends = assert(process.pipe())
  local copy = assert(sys.dup(ends.writer))
  assert(copy ~= ends.writer)
  assert(sys.write(copy, "copied") == 6)
  assert(sys.read(ends.reader, 64) == "copied")
  assert(closed_on_exec(copy) ~= false, "a copy is closed on exec")

  local path = tmp .. "/out"
  local file = create(path)
  local saved = assert(sys.dup(1))
  local redirected, trouble = pcall(function(): string
    assert(sys.dup2(file, 1))
    assert(closed_on_exec(1) ~= true, "a descriptor dup2 made is left open across exec")
    print("printed")
    return ""
  end)
  assert(sys.dup2(saved, 1))
  sys.close(saved)
  assert(redirected, trouble)
  assert(sys.pread(file, 64, 0) == "printed\n")
  local before = closed_on_exec(file)
  assert(sys.dup2(file, file))
  assert(closed_on_exec(file) == before, "dup2 of a descriptor onto itself changes nothing")
  sys.close(file)

  sys.close(copy)
  local gone, dup_trouble, errno = sys.dup(copy)
  assert(gone == nil and dup_trouble ~= "" and errno == sys.EBADF, dup_trouble)
  local ok, dup2_trouble, dup2_errno = sys.dup2(copy, ends.writer)
  assert(ok == false and dup2_trouble ~= "" and dup2_errno == sys.EBADF, dup2_trouble)
  assert(sys.write(ends.writer, "kept") == 4)
  assert(sys.read(ends.reader, 64) == "kept")
  sys.close(ends.reader)
  sys.close(ends.writer)
end

--- A child held to a ruleset reads and runs only what it names, and what
--- it starts is held too; the process that made the ruleset is not. Where
--- there is no Landlock, making one says so.
local function test_a_landlock_ruleset_holds_a_child_to_what_it_names(tmp: string)
  local inside, outside = tmp .. "/in", tmp .. "/out"
  assert(sys.mkdir(inside, 0x1c0) and sys.mkdir(outside, 0x1c0))
  local written = create(inside .. "/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  written = create(outside .. "/f")
  assert(sys.write(written, "out") == 3)
  sys.close(written)
  local reads: {string} = { inside }
  for _, dir in ipairs({ "/bin", "/usr", "/lib", "/lib64", "/etc" }) do
    if sys.stat(dir) ~= nil then reads[#reads + 1] = dir end
  end
  local ruleset, trouble, errno = process.landlock_ruleset(reads, {})
  if ruleset == nil then
    -- No Landlock: not built in, turned off, or refused by a filter (a
    -- container's seccomp profile).
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    return
  end
  local output = create(tmp .. "/said")
  local pid = assert(process.spawn("/bin/sh", { "sh", "-c",
    "cat in/f; echo; sh -c 'cat out/f' || echo refused; echo x > in/g || echo unwritten" },
    nil, tmp, nil, output, output, false, nil, { ruleset = ruleset }))
  sys.close(ruleset)
  local status = assert(process.waitpid(pid, false))
  assert(status.code == 0, tostring(status.code))
  local said = assert(sys.pread(output, 4096, 0))
  sys.close(output)
  assert(said:find("^in\n") and said:find("refused\n", 1, true) and
    said:find("unwritten\n", 1, true), said)
  assert(not said:find("\nout\n", 1, true), said)
  local mine = assert(sys.open(outside .. "/f", sys.O_RDONLY))
  assert(sys.read(mine, 16) == "out")
  sys.close(mine)
  -- A directory given to write is written; a ruleset whose descriptor is
  -- the one just above the child's own -- where the exec status goes --
  -- still holds it.
  assert(sys.mkdir(tmp .. "/w", 0x1c0))
  local writing = assert(process.landlock_ruleset(reads, { tmp .. "/w" }))
  local report = create(tmp .. "/report")
  -- A free descriptor a shell can name (at most 9 is the child's own).
  local free = 10
  while free > 4 and sys.fstat(free) ~= nil do free = free - 1 end
  assert(sys.fstat(free) == nil, "no descriptor from 4 to 10 is free")
  assert(sys.dup2(writing, free))
  sys.close(writing)
  local own = tostring(free - 1)
  local wrote = assert(process.spawn("/bin/sh", { "sh", "-c",
    "echo w > w/f && cat w/f >&" .. own .. "; echo x > in/h 2>/dev/null || echo held >&" .. own },
    nil, tmp, nil, nil, nil, false, { [free - 1] = report }, { ruleset = free }))
  sys.close(free)
  assert(assert(process.waitpid(wrote, false)).code == 0)
  local reported = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(reported == "w\nheld\n", reported)
  local bad, bad_trouble = process.landlock_ruleset({ tmp .. "/nowhere" }, {})
  assert(bad == nil and bad_trouble ~= "", "a path that is not there refuses the ruleset")
end

--- A pledged child runs under a seccomp filter, and so does what it
--- starts; an unpledged one runs as this process does (under a filter
--- of its own when a container gives it one), and a promise no one keeps
--- is refused before anything starts. (That the filter refuses a socket
--- of a family not promised is seen only from outside, with strace.)
-- TODO: check a refused socket from inside the child once cosmic.sys can
-- open one: curl, the only socket maker, words a refused socket and a
-- refused connection alike.
local function test_a_pledge_holds_a_child_and_what_it_starts(tmp: string)
  local refused = pcall(process.spawn, "/bin/sh", { "sh", "-c", "true" }, nil, nil, nil, nil, nil,
    false, nil, { pledge = { "fly" } })
  assert(not refused, "a promise no one keeps is refused")
  local function filtered(sandbox: raw_process.Sandbox | nil): string
    local output = create(tmp .. "/status")
    local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c",
      "grep Seccomp: /proc/self/status; sh -c 'grep Seccomp: /proc/self/status'" },
      nil, nil, nil, output, output, false, nil, sandbox)
    if pid == nil then
      sys.close(output)
      assert(errno == sys.ENOSYS, trouble)
      return "unsupported"
    end
    assert(assert(process.waitpid(pid, false)).code == 0)
    local said = assert(sys.pread(output, 4096, 0))
    sys.close(output)
    return (said:gsub("%s+", " "))
  end
  local status_file = sys.open("/proc/self/status", sys.O_RDONLY)
  if status_file == nil then
    -- No /proc to ask: a pledge is at most refused as unsupported.
    local ok, _, errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, nil, nil, nil, nil,
      false, nil, { pledge = {} })
    if ok == nil then assert(errno == sys.ENOSYS) else process.waitpid(ok, false) end
    return
  end
  local own = assert(sys.read(status_file, 65536)):match("Seccomp:%s*(%d)")
  sys.close(status_file)
  local pledged = filtered({ pledge = {} })
  if pledged ~= "unsupported" then
    assert(pledged == "Seccomp: 2 Seccomp: 2 ", pledged)
    assert(filtered({ pledge = { "unix", "inet" } }) == "Seccomp: 2 Seccomp: 2 ")
  end
  local plain = filtered(nil)
  assert(plain == "Seccomp: " .. own .. " Seccomp: " .. own .. " ", plain)
end

--- An unveiled child has a root of its own holding only the paths it was
--- given, at their own names once resolved: a path outside them is not
--- there to stat, one given to read is read-only, one given to write is
--- written, it keeps no capability, and an offline one has no network
--- but a loopback. An empty unveiling leaves it nothing, not even a
--- program to run. Where unprivileged namespaces are refused, spawning
--- one says so.
local function test_an_unveiled_child_has_only_what_it_was_given(tmp: string)
  local standard = { "/bin", "/usr", "/lib", "/lib64", "/etc", "/proc" }
  local shell = sys.realpath("/bin/sh")
  local reachable = false
  for _, dir in ipairs(standard) do
    if shell ~= nil and shell:sub(1, #dir + 1) == dir .. "/" then reachable = true end
  end
  if not reachable then return end -- a /bin/sh from elsewhere (/nix/store)
  local inside, outside, out = tmp .. "/in", tmp .. "/out", tmp .. "/w"
  for _, dir in ipairs({ inside, outside, out }) do assert(sys.mkdir(dir, 0x1c0)) end
  local written = create(inside .. "/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  sys.close(create(outside .. "/f"))
  assert(sys.symlink(inside, tmp .. "/link"))
  -- Given through a link, a path is had under the name it resolves to and,
  -- as a link to that, under the name given; a file can be given as well
  -- as a directory: /dev/null alone of /dev.
  local reads: {string} = { tmp .. "/link", "/dev/null" }
  for _, dir in ipairs(standard) do
    if sys.stat(dir) ~= nil then reads[#reads + 1] = dir end
  end
  local report = create(tmp .. "/report")
  local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c",
    "cat link/f; echo; test -e out/f && echo outside-seen || echo outside-absent; " ..
    "cat " .. assert(sys.realpath(inside)) .. "/f; echo; " ..
    "(echo x > link/g) 2>/dev/null || echo read-only; echo w > w/f && cat w/f; " ..
    "grep CapEff: /proc/self/status | tr -d ' \\t'; " ..
    "if test -r /proc/self/net/dev; then grep -c : /proc/self/net/dev; else echo 1; fi" },
    nil, tmp, nil, report, report, false, nil,
    { unveil = { reads = reads, writes = { out } }, offline = true })
  if pid == nil then
    sys.close(report)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "in\noutside-absent\nin\nread-only\nw\n" ..
    "CapEff:0000000000000000\n1\n", said)
  -- The parent is not held.
  assert(sys.stat(outside .. "/f") ~= nil)
  -- With /proc, /dev/fd leads into it; a directory made above a given
  -- path has the mode of the one it stands for, as a cache that checks
  -- its own directory's mode needs.
  local private = tmp .. "/private"
  assert(sys.mkdir(private, 0x1c0))
  assert(sys.mkdir(private .. "/inner", 0x1ed))
  local mirrored: {string} = { "/proc", private .. "/inner" }
  for _, path in ipairs(reads) do mirrored[#mirrored + 1] = path end
  local second = create(tmp .. "/second")
  local again = assert(process.spawn("/bin/sh", { "sh", "-c",
    "test -e /dev/fd/0 && echo fd; stat -c %a " .. assert(sys.realpath(private)) ..
    "; ls -A /tmp | grep -c . ; echo t > /tmp/f && cat /tmp/f" },
    nil, "/", nil, second, second, false, nil,
    { unveil = { reads = mirrored }, offline = true }))
  assert(assert(process.waitpid(again, false)).code == 0)
  local seen = assert(sys.pread(second, 4096, 0))
  sys.close(second)
  -- And a /tmp of its own, empty but for the paths given beneath the
  -- host's, which it can write to.
  local given_under_tmp = assert(sys.realpath(private)):sub(1, 5) == "/tmp/" and 1 or 0
  assert(seen == "fd\n700\n" .. tostring(given_under_tmp) .. "\nt\n", seen)
  local nothing, _, nothing_errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, tmp,
    nil, nil, nil, false, nil, { unveil = { reads = {}, writes = {} } })
  assert(nothing == nil and nothing_errno == sys.ENOENT, "an empty unveiling leaves no program")
  assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { "relative" } } }), "an unveiled path must be absolute")
end

local function test_cpu_count_is_at_least_one()
  local count = sys.cpu_count()
  assert(math.type(count) == "integer" and count >= 1)
end

local function test_uname_reports_nonempty_sysname_and_machine()
  local names, trouble = sys.uname()
  assert(names ~= nil and trouble == nil, "uname answers with one record")
  assert(#names.sysname > 0, "sysname is nonempty")
  assert(#names.machine > 0, "machine is nonempty")
  -- Stable across a call: this is the running host, not a moving target.
  local again = assert(sys.uname())
  assert(again.sysname == names.sysname and again.machine == names.machine)
end

--- C reads a path up to its first NUL, so a call handed "<dir>\0/x"
--- would act on "<dir>" -- a different file from the one named. Every
--- path-taking call refuses such a path with EINVAL instead, and the
--- file the truncated path names is never touched.
local function test_every_path_call_refuses_an_embedded_nul(tmp: string)
  local file = tmp .. "/file"
  sys.close(create(file))
  local nul = file .. "\0/../escaped"
  failed_with(sys.EINVAL, sys.open(nul, sys.O_RDONLY))
  failed_with(sys.EINVAL, sys.open_temporary(nul))
  failed_with(sys.EINVAL, sys.stat(nul))
  failed_with(sys.EINVAL, sys.lstat(nul))
  failed_with(sys.EINVAL, sys.mkdir(tmp .. "/made\0x"))
  assert(sys.stat(tmp .. "/made") == nil, "mkdir acted on the truncated path")
  failed_with(sys.EINVAL, sys.rmdir(tmp .. "\0x"))
  failed_with(sys.EINVAL, sys.unlink(nul))
  failed_with(sys.EINVAL, sys.rename(nul, tmp .. "/moved"))
  failed_with(sys.EINVAL, sys.rename(file, tmp .. "/moved\0x"))
  failed_with(sys.EINVAL, sys.chmod(nul, 511))
  failed_with(sys.EINVAL, sys.readdir(tmp .. "\0x"))
  failed_with(sys.EINVAL, sys.tree_digest(tmp .. "\0x", false))
  failed_with(sys.EINVAL, sys.chdir(tmp .. "\0x"))
  failed_with(sys.EINVAL, sys.realpath(nul))
  failed_with(sys.EINVAL, sys.mkdtemp(tmp .. "/t\0-XXXXXX"))
  failed_with(sys.EINVAL, sys.symlink(nul, tmp .. "/link"))
  failed_with(sys.EINVAL, sys.symlink(file, tmp .. "/link\0x"))
  failed_with(sys.EINVAL, sys.readlink(nul))
  failed_with(sys.EINVAL, sys.utimensat(nul, 0, 0))
  -- execve, like spawn, refuses a NUL by raising, before it allocates.
  raises(sys.execve, tmp .. "\0/sh", { "sh" }, {})
  raises(sys.execve, "/bin/sh", { "sh", "-c\0x" }, {})
  raises(sys.execve, "/bin/sh", { "sh" }, { A = "b\0c" })
  -- spawn refused a NUL before this rule existed, by raising, and
  -- `cosmic.child` relies on that; it never truncates either way.
  raises(process.spawn, tmp .. "\0/sh", { "sh" }, nil, nil, nil, nil, nil, false)
  raises(process.spawn, "/bin/sh", { "sh" }, nil, tmp .. "\0x", nil, nil, nil, false)
  -- The file the truncated paths name is exactly as it was.
  local st = assert(sys.stat(file))
  assert(st.kind == "file" and st.mode & 511 == 420)
  assert(sys.stat(tmp .. "/moved") == nil and sys.lstat(tmp .. "/link") == nil)
end

local function test_executable_is_a_file()
  local path = assert(sys.executable())
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(assert(sys.stat(path)).kind == "file")
end

--- The core's own lookup of its path refuses a buffer the path does not
--- fit in, NUL included, rather than answering it cut short. Only the
--- checked core can hand it a buffer that small.
local function test_executable_path_refuses_a_room_it_does_not_fit()
  if testing.configuration ~= "sanitized" then return end
  local path = assert(testing.executable_path(4096))
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(testing.executable_path(#path + 1) == path)
  local short = testing.executable_path(#path)
  assert(short == nil, "a path with no room for its NUL came back as " ..
    tostring(short))
  assert(testing.executable_path(1) == nil)
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

local function test_getuid_owns_what_the_process_creates(tmp: string)
  local path = tmp .. "/mine"
  assert(sys.mkdir(path))
  local st = assert(sys.stat(path))
  assert(st.uid == sys.getuid(), tostring(st.uid) .. " " .. tostring(sys.getuid()))
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
    local digest = hash.digest("sha256", case[1])
    assert(hex(digest) == case[2], #case[1] .. " bytes hashed to " .. hex(digest))
  end
  for _, len in ipairs({ 55, 56, 63, 64, 65 }) do
    assert(#hash.digest("sha256", string.rep("x", len)) == 32)
  end
end

--- Every algorithm `digest` names, by the size of what it returns.
local function test_digest_sizes_by_algorithm()
  local sizes: {string: integer} = {
    md5 = 16, sha1 = 20, sha224 = 28, sha256 = 32, sha384 = 48, sha512 = 64,
    ["sha3-224"] = 28, ["sha3-256"] = 32, ["sha3-384"] = 48, ["sha3-512"] = 64,
  }
  for algorithm, size in pairs(sizes) do
    assert(#hash.digest(algorithm, "abc") == size, algorithm)
  end
end

--- RFC 4231's second test case.
local function test_hmac_sha256_known_answer()
  local mac = hash.hmac("sha256", "Jefe", "what do ya want for nothing?")
  assert(hex(mac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    hex(mac))
end

local function test_digest_and_hmac_raise_on_an_unknown_algorithm()
  raises(hash.digest, "sha0", "abc")
  raises(hash.hmac, "sha0", "key", "abc")
end

--- A pid past what an int holds is refused, not truncated, by the
--- calls that take one, and so is pid 0, which would name this
--- process's own group.
local function test_a_pid_past_an_int_raises()
  raises(sys.kill, 2147483648, 0)
  raises(process.waitpid, 2147483648, true)
  raises(process.waitpid, 0, true)
end

--- The calls that start and reap a child, and hold this process's
--- signals while it does, are the raw process table's, and not the
--- public `cosmic.sys`'s: a public `waitpid(-1)` would take the status
--- of a child a `Child` handle owns from under it, and a public signal
--- guard would be a second one beside `Child.guard`'s.
local function test_the_process_calls_are_off_the_public_table()
  local public: {string: any} = sys as {string: any} -- cast: to look a member up by name
  local raw: {string: any} = process as {string: any} -- cast: to look a member up by name
  for _, name in ipairs({ "spawn", "waitpid", "subreaper", "relaunch", "pipe",
      "set_nonblocking", "poll", "ignore_sigpipe", "landlock_ruleset",
      "guard_child_signals", "unguard_child_signals", "cancelled_child_signal" }) do
    assert(public[name] == nil, "cosmic.sys." .. name .. " is public")
    assert(type(raw[name]) == "function", name .. " is not in the raw process table")
  end
  for _, name in ipairs({ "digest", "hmac" }) do
    assert(public[name] == nil, "cosmic.sys." .. name .. " is public")
    assert(type((hash as {string: any})[name]) == "function", name .. " is not raw hash's")
  end
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

--- A tree's digest changes with any entry beneath it: its contents
--- where asked for, and otherwise what `lstat` says of it -- a name
--- added, removed or renamed, and even a file rewritten with its old size
--- and modification time put back, whose change time moved. A link is
--- digested as its target's name, unfollowed, one whose target holds a
--- newline included; a FIFO beneath it is special, as is a tree too deep
--- to see all of, and /dev/null is not.
local function test_a_tree_digest_follows_everything_beneath_it(tmp: string)
  local tree = tmp .. "/tree"
  assert(sys.mkdir(tree, 0x1ed))
  assert(sys.mkdir(tree .. "/sub", 0x1ed))
  local fd = create(tree .. "/sub/f")
  assert(sys.write(fd, "one") == 3)
  sys.close(fd)
  assert(sys.symlink("sub/f", tree .. "/link"))
  local contents = assert(sys.tree_digest(tree, true))
  local stamps = assert(sys.tree_digest(tree, false))
  assert(#contents.digest == 64 and not contents.special and not stamps.special)
  assert(contents.digest ~= stamps.digest)
  assert(assert(sys.tree_digest(tree, true)).digest == contents.digest, "the same tree")
  assert(assert(sys.tree_digest(tree .. "/", false)).digest == stamps.digest,
    "a trailing slash names the same tree")
  -- A kernel whose change times are coarse would not see a rewrite
  -- made at once; this one waits long enough to.
  local before = assert(sys.stat(tree .. "/sub/f"))
  assert(sys.nanosleep(50000000))
  fd = create(tree .. "/sub/f")
  assert(sys.write(fd, "two") == 3)
  sys.close(fd)
  assert(sys.utimensat(tree .. "/sub/f", nil, nil, before.mtime, before.mtime_ns))
  local rewritten = assert(sys.tree_digest(tree, true))
  assert(rewritten.digest ~= contents.digest, "contents rewritten")
  local restamped = assert(sys.tree_digest(tree, false))
  assert(restamped.digest ~= stamps.digest, "a change time moved")
  assert(sys.rename(tree .. "/sub/f", tree .. "/sub/g"))
  assert(assert(sys.tree_digest(tree, false)).digest ~= restamped.digest, "a name renamed")
  assert(sys.rename(tree .. "/sub/g", tree .. "/sub/f"))
  assert(sys.unlink(tree .. "/link"))
  assert(sys.symlink("elsewhere", tree .. "/link"))
  local relinked = assert(sys.tree_digest(tree, true))
  assert(relinked.digest ~= rewritten.digest, "a link retargeted")
  -- A link's target is digested whole, so one holding a newline and the
  -- line that would follow cannot pass for a tree holding that entry.
  local forged, honest = tmp .. "/forged", tmp .. "/honest"
  assert(sys.mkdir(forged, 0x1ed))
  assert(sys.mkdir(honest, 0x1ed))
  local b = create(honest .. "/b")
  assert(sys.write(b, "hi") == 2)
  sys.close(b)
  assert(sys.symlink("x", honest .. "/a"))
  local line = assert(sys.tree_digest(honest, true)).digest
  assert(sys.symlink("x\n2:/bf" .. line, forged .. "/a"))
  assert(assert(sys.tree_digest(forged, true)).digest ~= line)
  -- Deeper than the walk looks, the tree is special: what lies below
  -- goes unseen.
  local deep = tmp .. "/deep"
  assert(sys.mkdir(deep, 0x1ed))
  local at = deep
  for _ = 1, 130 do
    at = at .. "/d"
    assert(sys.mkdir(at, 0x1ed))
  end
  assert(assert(sys.tree_digest(deep, false)).special, "a tree too deep to see")
  local fifo = assert(process.spawn("/bin/sh", { "sh", "-c", "mkfifo " .. tree .. "/sub/fifo" },
    nil, nil, nil, nil, nil, false))
  assert(assert(process.waitpid(fifo, false)).code == 0)
  assert(assert(sys.tree_digest(tree, true)).special, "a FIFO answers from past the tree")
  assert(not assert(sys.tree_digest("/dev/null", false)).special)
  local missing, _, errno = sys.tree_digest(tmp .. "/missing", false)
  assert(missing == nil and errno == sys.ENOENT)
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

local function test_umask_withholds_bits_and_answers_the_last(tmp: string)
  local before = sys.umask(0x3f)
  local ok, failure = pcall(function(): boolean
    local fd = assert(sys.open(tmp .. "/made", sys.O_WRONLY | sys.O_CREAT, 0x1ff))
    assert(sys.close(fd))
    assert(assert(sys.stat(tmp .. "/made")).mode & 0x1ff == 0x1c0)
    return sys.umask(0x12) == 0x3f
  end)
  sys.umask(before)
  if not ok then error(failure) end
  assert(failure, "umask did not answer the mask it replaced")
  assert(not pcall(sys.umask, -1))
  assert(not pcall(sys.umask, 0x200))
end

local function test_entropy_and_ftruncate_answer_their_contracts(tmp: string)
  local bytes, trouble = sys.entropy(16)
  assert(bytes ~= nil and #bytes == 16, trouble)
  local fd = assert(sys.open(tmp .. "/f", sys.O_WRONLY | sys.O_CREAT, 0x1a4))
  assert(sys.ftruncate(fd, 7))
  assert(sys.close(fd))
  assert(assert(sys.stat(tmp .. "/f")).size == 7)
  local ok, why, errno = sys.ftruncate(fd, 0)
  assert(not ok and why ~= "" and errno == sys.EBADF, why)
end

--- A failure's message is the table's (core/errnos.c), not libc's: a
--- symbolic link loop reads "Symbolic link loop" on every OS, where
--- macOS's strerror says "Too many levels of symbolic links".
local function test_a_failure_s_message_is_the_same_words_on_every_os(tmp: string)
  assert(sys.symlink(tmp .. "/b", tmp .. "/a"))
  assert(sys.symlink(tmp .. "/a", tmp .. "/b"))
  local fd, message, number = sys.open(tmp .. "/a", sys.O_RDONLY, 0)
  assert(fd == nil)
  assert(message == "Symbolic link loop", message)
  assert(sys.errno_name(number) == "ELOOP", tostring(sys.errno_name(number)))
  assert(sys.errno_message(number) == message)
end

--- An errno's name is the one <errno.h> gives it, whatever this OS
--- numbers it; a number the table holds no entry for has none.
local function test_an_errno_is_named_as_errno_h_names_it()
  for _, name in ipairs({ "ENOENT", "EEXIST", "EACCES", "EINTR", "EAGAIN", "ENOTEMPTY",
      "EXDEV", "EOPNOTSUPP", "EPERM", "ENOSPC", "EINVAL" }) do
    local number = (sys as {string:any})[name] as integer
    assert(sys.errno_name(number) == name, name .. " is named " ..
      tostring(sys.errno_name(number)))
  end
  assert(sys.errno_name(0) == nil and sys.errno_name(-1) == nil)
  assert(sys.errno_message(-1) == "No error information")
  assert(not pcall(sys.errno_name, "ENOENT" as integer), "a name is not a number")
end
