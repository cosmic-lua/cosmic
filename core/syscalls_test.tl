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
local Test = require("cosmic.test")
local type raw_hash = require("cosmic.internal.hash")
local type raw_process = require("cosmic.internal.process")
local observations = require("build.filesystem_observations")

-- TODO: name these host paths per platform once a declaration can
-- (a `host` entry for Linux and one for macOS, or a path the sandbox
-- resolves): /etc (a link to /private/etc) and /proc (absent) differs on macOS, where the audit would find these
-- reads undeclared; only Linux enforces declarations for now.
--- What the syscall table is tested on: the system's own directories, the
--- whole environment, processes it holds and the program itself.
Test.needs{
  host = { "/etc", "/proc", "/usr" },
  env = { "*" },
  processes = true,
  tool = true,
}

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

--- Whether the run holds this host to confining a process: with
--- COSMIC_SANDBOX=must (see build.filesystem_observations'
--- `must_confine`), a sandbox the kernel refuses -- no Landlock, no
--- pledge, no unveiling -- fails its test here rather than passing it
--- unchecked.
-- TODO: count each sandbox test that returns early here as skipped, in
-- the run's summary beside ran, stood and assumed, once build/test.tl's
-- tally has a skipped verdict: today, without COSMIC_SANDBOX=must, a
-- host that cannot sandbox passes them as though it had checked them.
local function sandbox_required(): boolean
  return sys.getenv("COSMIC_SANDBOX") == "must"
end

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
  -- Setting a time is a change of status, which no call can set back:
  -- the change time is the present's, not the modification time given.
  local before = assert(sys.clock_gettime(sys.CLOCK_REALTIME)) // 1000000000 - 1
  assert(sys.utimensat(path, nil, nil, 7, 8))
  st = assert(sys.stat(path))
  assert(st.mtime == 7 and st.ctime >= before and st.ctime_ns >= 0 and
    st.ctime_ns < 1000000000, st.ctime .. "." .. st.ctime_ns)
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

--- A directory under `tmp` holding a file, a directory, and a link to
--- each and to nothing.
local function linked_directory(tmp: string): string
  local d = tmp .. "/d"
  assert(sys.mkdir(d))
  sys.close(create(d .. "/file"))
  assert(sys.mkdir(d .. "/sub"))
  assert(sys.symlink("file", d .. "/to_file"))
  assert(sys.symlink("sub", d .. "/to_dir"))
  assert(sys.symlink("missing", d .. "/dangling"))
  return d
end

--- Checks readdir's answer for `linked_directory`.
local function names_links_as_links(entries: {string:string}, what: string)
  assert(entries["file"] == "file" and entries["sub"] == "dir", what)
  assert(entries["to_file"] == "link", what .. ": a link to a file: " .. tostring(entries["to_file"]))
  assert(entries["to_dir"] == "link", what .. ": a link to a directory: " .. tostring(entries["to_dir"]))
  assert(entries["dangling"] == "link", what .. ": a dangling link: " .. tostring(entries["dangling"]))
end

local function test_readdir_names_a_link_as_a_link_whatever_it_leads_to(tmp: string)
  names_links_as_links(assert(sys.readdir(linked_directory(tmp))), "readdir")
end

--- An entry whose type the filesystem leaves unknown is asked with an
--- lstat, which answers a link as one too: the checked core's fault
--- point makes each entry in turn unknown.
local function test_readdir_names_an_entry_of_unknown_type_as_lstat_does(tmp: string)
  if testing.configuration ~= "sanitized" then return end
  local d = linked_directory(tmp)
  for skip = 0, 4 do
    testing.fail_at("readdir_d_type", skip)
    local entries = assert(sys.readdir(d))
    assert(not testing.fail_at(), "entry " .. skip .. " never reached readdir_d_type")
    names_links_as_links(entries, "entry " .. skip .. " of unknown type")
  end
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

--- Whether `fd` is closed on exec, as the descriptor's own flags say.
local function closed_on_exec(fd: integer): boolean
  local flags = assert(sys.fd_flags(fd))
  return flags & sys.FD_CLOEXEC ~= 0
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
  assert(closed_on_exec(copy), "a copy is closed on exec")

  local path = tmp .. "/out"
  local file = create(path)
  local saved = assert(sys.dup(1))
  local redirected, trouble = pcall(function(): string
    assert(sys.dup2(file, 1))
    assert(not closed_on_exec(1), "a descriptor dup2 made is left open across exec")
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
  failed_with(sys.EBADF, sys.fd_flags(copy))
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
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no Landlock ruleset: " .. trouble)
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

--- A process held to running what is beneath some paths runs a program
--- beneath them and no other -- one written after the hold included --
--- and what it starts is held too; it still reads and writes as before.
--- The hold is for good, so it is taken last: this test's worker ends
--- with the test. Where there is no Landlock, taking one says so.
local function test_a_process_held_to_running_some_paths_runs_nothing_else(tmp: string)
  local system: {string} = {}
  for _, dir in ipairs({ "/bin", "/usr", "/lib", "/lib64" }) do
    if sys.stat(dir) ~= nil then system[#system + 1] = dir end
  end
  local script = tmp .. "/run"
  local fd = create(script)
  assert(sys.write(fd, "#!/bin/sh\nexit 0\n") == 17)
  sys.close(fd)
  assert(sys.chmod(script, 493)) -- 0o755
  local function status_of(path: string, argv: {string}): integer | string
    local pid, trouble = process.spawn(path, argv, nil, tmp, nil, nil, nil, false)
    if pid == nil then return trouble end
    return assert(process.waitpid(pid, false)).code
  end
  assert(status_of(script, { "run" }) == 0, "the script runs before the hold")
  -- Beneath a path given, a file may still move to another directory.
  local given = tmp .. "/given"
  assert(sys.mkdir(given, 0x1c0) and sys.mkdir(given .. "/a", 0x1c0) and
    sys.mkdir(given .. "/b", 0x1c0))
  sys.close(create(given .. "/a/f"))
  system[#system + 1] = given
  local held, trouble, errno = process.landlock_restrict_execute(system)
  if not held then
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no Landlock: " .. trouble)
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    return
  end
  assert(status_of("/bin/sh", { "sh", "-c", "exit 3" }) == 3, "a program beneath them runs")
  assert(status_of(script, { "run" }) ~= 0, "a program elsewhere ran")
  -- What it starts is held too: the shell may not run the script.
  assert(status_of("/bin/sh", { "sh", "-c", script .. " || exit 7" }) == 7)
  assert(sys.rename(given .. "/a/f", given .. "/b/f"))
  -- Reading and writing are as they were.
  local written = create(tmp .. "/after")
  assert(sys.write(written, "w") == 1)
  sys.close(written)
  local reading = assert(sys.open(script, sys.O_RDONLY))
  assert(sys.read(reading, 2) == "#!")
  sys.close(reading)
  local bad, _ = pcall(process.landlock_restrict_execute, { 1 } as {string})
  assert(not bad, "a path that is no string is refused")
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
      assert(not sandbox_required() or sandbox == nil,
        "COSMIC_SANDBOX=must, but no pledge: " .. trouble)
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
    local ok, trouble, errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, nil, nil,
      nil, nil, false, nil, { pledge = {} })
    if ok == nil then
      assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no pledge: " .. trouble)
      assert(errno == sys.ENOSYS)
    else
      process.waitpid(ok, false)
    end
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

--- A child starts on this process's memory rather than a copy of it,
--- but with a descriptor table of its own: the descriptors it closes and
--- moves to hand its program the ones asked for, and a later step that
--- fails, leave every one of this process's as it was.
local function test_a_child_s_descriptors_are_its_own(tmp: string)
  local held: {integer} = {}
  local target = 0
  for i = 1, 4 do
    held[i] = create(tmp .. "/held" .. i)
    if held[i] > target then target = held[i] end
  end
  -- Handed above all of them, so the child closes every one on its way.
  target = target + 2
  local report = create(tmp .. "/report")
  local pid = assert(process.spawn("/bin/sh", { "sh", "-c", "echo mapped > /dev/fd/" .. target },
    nil, nil, nil, nil, nil, false, { [target] = report }))
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(assert(sys.pread(report, 64, 0)) == "mapped\n")
  failed_with(sys.ENOENT, process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, tmp .. "/missing",
    nil, nil, nil, false, { [target] = report }))
  for _, fd in ipairs(held) do
    assert(sys.fstat(fd) ~= nil, "a descriptor the child closed is still open here")
    sys.close(fd)
  end
  assert(sys.fstat(report) ~= nil)
  sys.close(report)
end

--- Every signal is blocked while a child starts, so none runs a handler
--- of this process's in the memory the two share; its program starts
--- with this process's own mask all the same, catching nothing, and
--- ignoring nothing this process does not.
local function test_a_child_starts_with_this_process_s_signal_mask(tmp: string)
  local status = sys.open("/proc/self/status", sys.O_RDONLY)
  if status == nil then return end -- no /proc to ask
  local own = assert(sys.read(status, 65536))
  sys.close(status)
  local output = create(tmp .. "/status")
  local pid = assert(process.spawn("/bin/cat", { "cat", "/proc/self/status" },
    nil, nil, nil, output, nil, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  local child = assert(sys.pread(output, 65536, 0))
  sys.close(output)
  local function mask(text: string, name: string): integer
    return math.tointeger(tonumber(assert(text:match(name .. ":%s*(%x+)")), 16)) as integer
  end
  assert(mask(child, "SigBlk") == mask(own, "SigBlk"), child)
  -- This process was started by one too, so a mask its start leaked
  -- would be its own as well: SIGTERM (15), which nothing that starts a
  -- test blocks, would be blocked in both.
  assert(mask(own, "SigBlk") & (1 << 14) == 0, own)
  assert(mask(child, "SigCgt") == 0, child)
  assert(mask(child, "SigIgn") & ~mask(own, "SigIgn") == 0, child)
end

--- SIGPIPE, which cosmic ignores for itself when it writes to a child's
--- pipe, is handed a spawned program at its default: a program that
--- writes to a closed pipe ends as it would started from a shell.
local function test_a_child_starts_with_sigpipe_at_its_default(tmp: string)
  assert(process.ignore_sigpipe())
  local function ignored(text: string): integer
    return math.tointeger(tonumber(assert(text:match("SigIgn:%s*(%x+)"), text), 16)) as integer
  end
  local status = sys.open("/proc/self/status", sys.O_RDONLY)
  if status == nil then return end -- no /proc to ask
  local own = assert(sys.read(status, 65536))
  sys.close(status)
  local bit = 1 << (sys.SIGPIPE - 1)
  assert(ignored(own) & bit ~= 0, own)
  local output = create(tmp .. "/status")
  local pid = assert(process.spawn("/bin/cat", { "cat", "/proc/self/status" },
    nil, nil, nil, output, nil, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  local child = assert(sys.pread(output, 65536, 0))
  sys.close(output)
  assert(ignored(child) & bit == 0, child)
end

--- An unveiled child has a root of its own holding only the paths it was
--- given, at their own names once resolved: a path outside them is not
--- there to stat, one given to read is read-only -- but /proc, a procfs
--- of its own pid namespace, whose processes' entries it may write, and
--- which has no /proc/sys; or, where the kernel refuses one, the host's,
--- read-only whole -- one given to write is written, it keeps no capability, and an offline one
--- has no network but a loopback. An empty unveiling leaves it nothing,
--- not even a program to run. Where unprivileged namespaces are refused,
--- spawning one says so.
local function test_an_unveiled_child_has_only_what_it_was_given(tmp: string)
  local standard = { "/bin", "/usr", "/lib", "/lib64", "/etc", "/proc" }
  local shell = sys.realpath("/bin/sh")
  local reachable = false
  for _, dir in ipairs(standard) do
    if shell ~= nil and shell:sub(1, #dir + 1) == dir .. "/" then reachable = true end
  end
  if not reachable then
    -- A /bin/sh from elsewhere (/nix/store): none to run unveiled.
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but /bin/sh is " ..
      tostring(shell) .. ", beneath none of the paths this test unveils")
    return
  end
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
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no unveiling: " .. trouble)
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
  -- Whether a file is writable, by opening it to append, which writes
  -- nothing: busybox's `test -w` judges by the mode alone, not the mount.
  local second = create(tmp .. "/second")
  local again = assert(process.spawn("/bin/sh", { "sh", "-c",
    "test -e /dev/fd/0 && echo fd; stat -c %a " .. assert(sys.realpath(private)) ..
    "; ls -A /tmp | grep -c . ; echo t > /tmp/f && cat /tmp/f; " ..
    "test -e /proc/sys && echo host-proc || echo own-proc; " ..
    "(: >> /proc/self/uid_map) 2>/dev/null && echo own-writable || echo own-read-only; " ..
    "(: >> /proc/sys/vm/swappiness) 2>/dev/null || echo sys-read-only" },
    nil, "/", nil, second, second, false, nil,
    { unveil = { reads = mirrored }, offline = true }))
  assert(assert(process.waitpid(again, false)).code == 0)
  local seen = assert(sys.pread(second, 4096, 0))
  sys.close(second)
  -- And a /tmp of its own, empty but for the paths given beneath the
  -- host's, which it can write to; /proc its own, whose processes'
  -- entries it writes, so it can confine a child in turn; or, where the
  -- kernel refuses it one, the host's, read-only whole.
  -- And a /tmp of its own, empty but for the paths given beneath the
  -- host's -- each at the name it resolves to, and, given through a
  -- link, the link -- which it can write to; /proc its own, whose
  -- processes' entries it writes, so it can confine a child in turn;
  -- or, where the kernel refuses it one, the host's, read-only whole.
  local under_tmp: {string:boolean} = {}
  for _, path in ipairs(mirrored) do
    for _, name in ipairs({ path, (assert(sys.realpath(path))) }) do
      local top = name:match("^/tmp/([^/]+)")
      if top ~= nil then under_tmp[top] = true end
    end
  end
  local given_under_tmp = 0
  for _ in pairs(under_tmp) do given_under_tmp = given_under_tmp + 1 end
  local common = "fd\n700\n" .. tostring(given_under_tmp) .. "\nt\n"
  local own = observations.own_proc_given()
  assert(seen == common .. (own and "own-proc\nown-writable\n" or "host-proc\nown-read-only\n") ..
    "sys-read-only\n", seen)
  local nothing, _, nothing_errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, tmp,
    nil, nil, nil, false, nil, { unveil = { reads = {}, writes = {} } })
  assert(nothing == nil and nothing_errno == sys.ENOENT, "an empty unveiling leaves no program")
  assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { "relative" } } }), "an unveiled path must be absolute")
end

--- The system's own paths a confined /bin/sh needs, each where this
--- host has it, /proc and /dev/null among them; nil where /bin/sh is beneath none of
--- them (a /nix/store one), which fails the test under
--- COSMIC_SANDBOX=must.
local function shell_reads(): {string} | nil
  local reads: {string} = {}
  local shell = sys.realpath("/bin/sh")
  local reachable = false
  for _, dir in ipairs({ "/bin", "/usr", "/lib", "/lib64", "/etc", "/proc", "/dev/null" }) do
    if sys.stat(dir) ~= nil then
      reads[#reads + 1] = dir
      if shell ~= nil and shell:sub(1, #dir + 1) == dir .. "/" then reachable = true end
    end
  end
  if reachable then return reads end
  assert(not sandbox_required(), "COSMIC_SANDBOX=must, but /bin/sh is " .. tostring(shell) ..
    ", beneath none of the paths this test unveils")
  return nil
end

--- Starts `script` in /bin/sh confined to `reads`, offline unless
--- `online`, in /, with `output` its standard output and error: its pid,
--- or nil where the kernel will not confine it, which fails the test
--- under COSMIC_SANDBOX=must.
local function start_confined(reads: {string}, script: string, output: integer,
                              online?: boolean): integer | nil
  local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c", script }, nil, "/", nil,
    output, output, false, nil, { unveil = { reads = reads }, offline = not online })
  if pid ~= nil then return pid end
  assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no unveiling: " .. trouble)
  assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
    errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
  return nil
end

--- Runs `script` as `start_confined` starts it, its output in `tmp`: its
--- status and what it printed, or nil where the kernel will not confine
--- it.
local function run_confined(tmp: string, reads: {string}, script: string,
                            online?: boolean): raw_process.ChildStatus | nil, string
  local report = create(tmp .. "/report")
  local pid = start_confined(reads, script, report, online)
  local status: raw_process.ChildStatus | nil = nil
  if pid ~= nil then status = assert(process.waitpid(pid, false)) end
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  return status, said
end

--- A path given with a name in `at` is bound there, and not at its own
--- name: a tree given at /tree is read, and written where given to
--- write, at /tree alone, so what a child sees of it names nothing of
--- where the host keeps it -- its working directory there answers
--- /tree -- and a directory bound at /tmp is its /tmp, which it has none
--- of its own beside. A name that is not absolute and plain, is /, or
--- is given for a path not unveiled, is refused.
local function test_an_unveiled_path_is_bound_at_the_name_given(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local tree, scratch = tmp .. "/checkout", tmp .. "/scratch"
  for _, dir in ipairs({ tree, tree .. "/sub", scratch }) do assert(sys.mkdir(dir, 0x1c0)) end
  local written = create(tree .. "/sub/f")
  assert(sys.write(written, "in") == 2)
  sys.close(written)
  local real_tree = assert(sys.realpath(tree))
  local given: {string} = { tree }
  for _, path in ipairs(reads) do given[#given + 1] = path end
  local report = create(tmp .. "/report")
  local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c",
    "cat sub/f; echo; pwd; test -e " .. real_tree .. " && echo own-name || echo no-own-name; " ..
    "echo w > /tmp/g && echo tmp-written; (echo x > sub/g) 2>/dev/null || echo tree-read-only" },
    nil, "/tree", nil, report, report, false, nil,
    { unveil = { reads = given, writes = { scratch }, at = { [tree] = "/tree", [scratch] = "/tmp" } },
      offline = true })
  if pid == nil then
    sys.close(report)
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no unveiling: " .. trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "in\n/tree\nno-own-name\ntmp-written\ntree-read-only\n", said)
  -- What it wrote at /tmp is in the directory bound there.
  local fd = assert(sys.open(scratch .. "/g", sys.O_RDONLY))
  assert(sys.read(fd, 16) == "w\n")
  sys.close(fd)
  for _, bad in ipairs({ "relative", "/", "/a/../b", "/a/" }) do
    assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
      { unveil = { reads = { tree }, at = { [tree] = bad } } }), "bound at " .. bad)
  end
  assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree }, at = { [scratch] = "/tmp" } } }), "at a path not unveiled")
  -- A name placed beneath a path bound from the host goes through no
  -- link there: one leading out, or climbing, refuses the start rather
  -- than make a file where the link leads.
  local victim = tmp .. "/victim"
  assert(sys.mkdir(victim, 0x1c0))
  assert(sys.symlink(victim, tree .. "/out"))
  assert(sys.symlink("../victim", tree .. "/up"))
  for _, placed in ipairs({ "/tree/out/new.txt", "/tree/up/new.txt", "/tree/out" }) do
    local escaped, _, escaped_errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, "/",
      nil, nil, nil, false, nil, { unveil = { reads = { tree, tree .. "/sub/f", table.unpack(reads) },
        at = { [tree] = "/tree", [tree .. "/sub/f"] = placed } }, offline = true })
    if escaped ~= nil then process.waitpid(escaped, false) end
    assert(escaped == nil, "placed through a link at " .. placed)
    assert(sys.errno_name(escaped_errno) == "ELOOP" or (not sandbox_required() and
      (escaped_errno == sys.ENOSYS or escaped_errno == sys.EPERM or escaped_errno == sys.EACCES or
        escaped_errno == sys.EINVAL or escaped_errno == sys.ENOSPC)), tostring(escaped_errno))
  end
  assert(sys.stat(victim .. "/new.txt") == nil, "a file was made through the link")
  -- Two paths bound at one name, or a name beneath the old root's, are
  -- refused as arguments.
  assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree, scratch }, at = { [tree] = "/x", [scratch] = "/x" } } }))
  assert(not pcall(process.spawn, "/bin/sh", { "sh" }, nil, nil, nil, nil, nil, false, nil,
    { unveil = { reads = { tree }, at = { [tree] = "/.old/x" } } }))
  -- The host's /proc bound at another name is the host's state, and
  -- mounted read-only, given to write as it may be.
  local without_proc: {string} = {}
  for _, path in ipairs(reads) do
    if path ~= "/proc" then without_proc[#without_proc + 1] = path end
  end
  local proc_report = create(tmp .. "/proc-report")
  local proc_pid = process.spawn("/bin/sh", { "sh", "-c",
    "grep -q ' /host-proc ro[, ]' /host-proc/self/mountinfo && echo read-only || echo writable" },
    nil, "/", nil, proc_report, proc_report, false, nil,
    { unveil = { reads = without_proc, writes = { "/proc" }, at = { ["/proc"] = "/host-proc" } },
      offline = true })
  if proc_pid ~= nil then
    assert(assert(process.waitpid(proc_pid, false)).code == 0)
    local proc_said = assert(sys.pread(proc_report, 4096, 0))
    assert(proc_said == "read-only\n", proc_said)
  else
    -- It started above, so it starts here, as it would anywhere.
    error("the host's /proc could not be bound at another name")
  end
  sys.close(proc_report)
end

--- An unveiled child is pid 2 of a pid namespace of its own, beneath the
--- sandbox's init, pid 1: it cannot signal a process outside it, of its
--- own user as it may be -- here a shell of this process's, which it
--- tries to kill -- and its /proc, a procfs of that namespace, lists
--- its init, itself and what it starts, and nothing else; where the
--- kernel refuses a procfs of its own (a container masking parts of its
--- /proc), it is the host's, which shows the host's processes, though
--- it cannot signal them.
local function test_an_unveiled_child_sees_and_signals_only_its_own_processes(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local outside = assert(process.spawn("/bin/sh", { "sh", "-c", "sleep 30" }, nil, nil, nil,
    nil, nil, false))
  local status, said = run_confined(tmp, reads, "echo $$; kill -KILL " .. tostring(outside) ..
    " 2>/dev/null && echo killed || echo spared; test -e /proc/" .. tostring(outside) ..
    " && echo seen || echo unseen; cat /proc/1/comm; ls /proc | tr '\\n' ' '")
  -- Still running, not a zombie, which a signal of 0 would find too.
  local alive = assert(process.waitpid(outside, true)).pid == 0
  if alive then
    assert(sys.kill(outside, sys.SIGKILL))
    assert(process.waitpid(outside, false))
  end
  if status == nil then return end
  assert(status.code == 0, said)
  assert(alive, "the confined child killed a process outside it: " .. said)
  local lines: {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(lines[1] == "2" and lines[2] == "spared", said)
  if lines[4] ~= "cosmic-init" then
    assert(not observations.own_proc_given(), "no procfs of its own: " .. said)
    return -- the host's /proc
  end
  assert(lines[3] == "unseen", said)
  local listed: {integer:boolean} = {}
  for entry in (lines[5] or ""):gmatch("%S+") do
    local number = math.tointeger(tonumber(entry))
    if number ~= nil then
      listed[number] = true
      assert(number <= 8, "a process not its own in its /proc: " .. said)
    else
      assert(entry == "self" or entry == "thread-self", "more than its processes: " .. said)
    end
  end
  assert(listed[1] and listed[2], said)
end

--- An unveiled child's status is its program's, as an unconfined one's
--- is -- its exit code, a signal it sent itself, one from outside it
--- does not catch -- which it would not be as its pid namespace's pid 1,
--- to which a signal it does not catch is not delivered. When it ends,
--- what it left running in its namespace ends too: a background sleep
--- holding its output open lets that pipe end at once. And an orphan in
--- it is the init's to reap, left no zombie -- which only a procfs of
--- its own shows: where the kernel refuses one, its /proc is the
--- host's, whose zombies are not its namespace's, and that is not checked.
local function test_an_unveiled_child_s_status_is_its_program_s(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local exited = run_confined(tmp, reads, "exit 7")
  if exited == nil then return end
  assert(exited.code == 7 and exited.signal == -1)
  -- Its init is gone with it once the wait answers: no child of this
  -- process is one any more, and none is left a zombie.
  assert(#process.sandbox_inits() == 0, "an init outlived the wait for its program")
  local children = sys.open("/proc/thread-self/children", sys.O_RDONLY)
  if children ~= nil then
    local listed = sys.read(children, 65536) or ""
    sys.close(children)
    for number in listed:gmatch("%d+") do
      local comm = sys.open("/proc/" .. number .. "/comm", sys.O_RDONLY)
      if comm ~= nil then
        local name = sys.read(comm, 64)
        sys.close(comm)
        assert(name ~= "cosmic-init\n", "an init is still a child: " .. number)
      end
    end
  end
  local own = assert(run_confined(tmp, reads, "kill -TERM $$; exit 3"))
  assert(own.code == -1 and own.signal == sys.SIGTERM, "a signal of its own: " .. own.code)
  local quiet = create(tmp .. "/quiet")
  local sleeping = assert(start_confined(reads, "exec sleep 30", quiet))
  sys.close(quiet)
  assert(sys.kill(sleeping, sys.SIGTERM))
  local ended = assert(process.waitpid(sleeping, false))
  assert(ended.code == -1 and ended.signal == sys.SIGTERM,
    "a signal from outside: " .. tostring(ended.code))
  local ends = assert(process.pipe())
  local left = assert(start_confined(reads, "sleep 30 & echo started", ends.writer))
  sys.close(ends.writer)
  assert(assert(process.waitpid(left, false)).code == 0)
  assert(process.set_nonblocking(ends.reader, true))
  local read = ""
  local closed = false
  local by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 10 * 1000000000
  while not closed and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    assert(process.poll({ ends.reader }, { process.POLLIN }, 100))
    local data, _, errno = sys.read(ends.reader, 4096)
    if data == "" then closed = true
    elseif data ~= nil then read = read .. data
    else assert(errno == sys.EAGAIN, "read: " .. tostring(errno)) end
  end
  sys.close(ends.reader)
  assert(read == "started\n" and closed, "what it left running outlived it: " .. read)
  local status, said = run_confined(tmp, reads, "sh -c 'sleep 0.1 &'; sleep 1; " ..
    "cat /proc/1/comm; cat /proc/[0-9]*/stat | grep -c ') Z '; true")
  assert(status ~= nil and status.code == 0, said)
  -- Only a procfs of its own shows its namespace's zombies alone.
  if observations.own_proc_given() then assert(said == "cosmic-init\n0\n", said) end
end

--- The files of a confined child's /proc it may open to write, each its
--- own processes' alone or its own session's, as /proc/<pid>/<name> or
--- /proc/<pid>/task/<tid>/<name>:
local own_writable: {string:string} = {
  -- A user namespace's maps and its setgroups, written once by a
  -- process mapping the namespace it made: how it confines one of its own.
  uid_map = "maps its own user namespace", gid_map = "maps its own user namespace",
  projid_map = "maps its own user namespace", setgroups = "its own user namespace's",
  -- What the kernel does to the process itself.
  oom_adj = "its own OOM score", oom_score_adj = "its own OOM score",
  coredump_filter = "what of its own memory a core dump holds",
  clear_refs = "its own pages' referenced bits", sched = "its own scheduling statistics",
  timerslack_ns = "its own timer slack", comm = "its own name",
  mem = "its own memory, which only a process that may ptrace it opens",
  timens_offsets = "the time namespace its own children would start in",
  ["fail-nth"] = "fault injection in its own calls",
  ["make-it-fail"] = "fault injection in its own calls",
  -- Its session's: one of the sandbox's own, since the program and its
  -- init each start one (core/syscalls.c's `run_program`).
  autogroup = "its own session's autogroup",
  -- Its audit login id: its own process's, but one the host's audit log
  -- names it by, which the kernel lets it set while it is unset (and
  -- only with CAP_AUDIT_CONTROL once set) -- a gap core/syscalls.c's
  -- `place_proc` leaves a TODO for.
  loginuid = "its own, though the host's audit log reads it",
}

--- A confined child can change no state of the host's through its /proc:
--- walking the whole of it, every file that opens to write -- appending,
--- which writes nothing -- is one of its own processes' (`own_writable`,
--- or the security module's attributes of the process, attr/*), and none
--- is outside a process's directory, since its /proc is a procfs of its
--- own pid namespace, holding nothing of the host's. Where the kernel
--- refuses it one, its /proc is the host's, read-only whole, and nothing
--- opens -- but a device a container's runtime bound over an entry
--- (/dev/null, masking /proc/kcore and the like), which a read-only mount
--- does not hold, and which is no file of the host's state: `find`
--- takes it for the file it hides, so each is looked at again (`test -f`).
local function test_a_confined_child_can_write_no_host_state_through_its_proc(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  -- Offline and online: an online child's /proc/<pid>/net is its
  -- parent's network namespace's.
  for _, online in ipairs({ false, true }) do
    local status, said = run_confined(tmp, reads, "find /proc -type f 2>/dev/null | " ..
      "while read f; do test -f \"$f\" && (: >> \"$f\") 2>/dev/null && echo \"$f\"; done; " ..
      "echo done", online)
    if status == nil then return end
    assert(status.code == 0 and said:sub(-5) == "done\n", said)
    local own = observations.own_proc_given()
    local opened = 0
    for path in said:gmatch("([^\n]+)\n") do
      if path ~= "done" then
        opened = opened + 1
        assert(own, "a file of the host's /proc opens to write: " .. path)
        local rest = path:match("^/proc/[%w-]+/task/%d+/(.+)$") or
          path:match("^/proc/%d+/(.+)$") or path:match("^/proc/self/(.+)$") or
          path:match("^/proc/thread%-self/(.+)$")
        assert(rest ~= nil, "a file outside a process's directory opens to write: " .. path)
        assert(own_writable[rest] ~= nil or rest:match("^attr/") ~= nil,
          "a file not the process's own opens to write: " .. path)
      end
    end
    -- Its own maps, at least, where it can confine one of its own.
    assert(not own or opened > 0, said)
  end
end

--- The setsid program where this host has one, or nil.
local function setsid_program(): string | nil
  for _, path in ipairs({ "/usr/bin/setsid", "/bin/setsid", "/usr/sbin/setsid" }) do
    if sys.stat(path) ~= nil then return path end
  end
  return nil
end

--- Runs `chunk`, with `...` after it, in this program, in a session of
--- its own (`setsid`), in `tmp`: what it printed, or nil where the host
--- has no setsid program.
local function in_own_session(tmp: string, chunk: string, ...: string): string | nil
  local setsid = setsid_program()
  if setsid == nil then return nil end
  local report = create(tmp .. "/session")
  local argv: {string} = { setsid, assert(sys.executable()), "-e", chunk }
  for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
  local pid = assert(process.spawn(setsid, argv, nil, tmp, nil, report, report, false))
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 65536, 0))
  sys.close(report)
  assert(status.code == 0, said)
  return said
end

--- What a chunk run by `in_own_session` starts a confined child with:
--- the raw process table, and the paths a shell needs, from `...`.
local session_preamble <const> = [==[
local sys = require("cosmic.sys")
local process
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then process = extra end
end
local reads = {}
for path in (...):gmatch("[^:]+") do reads[#reads + 1] = path end
local function read(path)
  local fd = sys.open(path, sys.O_RDONLY)
  if fd == nil then return "" end
  local text = sys.read(fd, 4096) or ""
  sys.close(fd)
  return text
end
]==]

--- A confined child's autogroup is its own session's, not its parent's:
--- the nice it sets through its init's /proc/1/autogroup, and then
--- through /proc/self/autogroup, leaves its parent's session's as it
--- was. The init's is written first, and its own a fifth of a second
--- later: without CAP_SYS_ADMIN the kernel lets autogroups be reniced
--- once a tenth of a second, the whole system over (EAGAIN). /proc/1 is
--- open to the child only where it runs as root (its init is
--- undumpable, so owned by the namespace's root), so that half is
--- checked only in a run as root -- not CI's, which runs unprivileged,
--- nor ci/run-local's, as nobody. Run in a session of this test's own,
--- so a failure changes nothing of the runner's. Where the kernel has
--- no autogroup, or the host no setsid program, there is nothing to
--- check.
local function test_a_confined_child_s_autogroup_is_not_its_parent_s(tmp: string)
  local reads = shell_reads()
  if reads == nil or sys.stat("/proc/self/autogroup") == nil then return end
  local said = in_own_session(tmp, session_preamble .. [==[
local before = read("/proc/self/autogroup")
local pid, trouble = process.spawn("/bin/sh", { "sh", "-c",
  "(echo 19 > /proc/1/autogroup) 2>/dev/null && echo init-set; sleep 0.2; " ..
  "echo 19 > /proc/self/autogroup; sed 's/.* nice /own nice /' /proc/self/autogroup" },
  nil, "/", nil, nil, nil, false, nil, { unveil = { reads = reads }, offline = true })
if pid == nil then print("refused " .. trouble) return 0 end
process.waitpid(pid, false)
print(before == read("/proc/self/autogroup") and "kept" or "changed: " .. before)
return 0
]==], table.concat(reads, ":"))
  if said == nil or said:find("^refused ") then return end
  -- It set its own, where its /proc is its own and so writable, and, as
  -- root, its init's.
  assert(said:find("kept\n$") ~= nil, said)
  local own = observations.own_proc_given()
  assert(not own or said:find("own nice 19\n", 1, true) ~= nil, said)
  assert(not own or sys.getuid() ~= 0 or said:find("init-set\n", 1, true) ~= nil, said)
end

--- A confined child ends when the process that started it does, killed
--- or ended by a signal from a terminal, not left running on its own:
--- its init ends with its parent, and its namespace with the init. This
--- process takes the orphans, as a subreaper, so no one but the kernel
--- ends them: `cosmic test`'s runner, a subreaper itself, would end any
--- that reached it as strays, and pass this with the init's end undone.
local function test_a_confined_child_ends_with_its_parent(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local adopting = process.subreaper()
  if not adopting then return end -- no subreaper to be (not Linux)
  local cosmic = assert(sys.executable())
  local report = create(tmp .. "/parent")
  local parent = assert(process.spawn(cosmic, { "cosmic", "-e", session_preamble .. [==[
local pid, trouble = process.spawn("/bin/sh", { "sh", "-c", "exec sleep 30" }, nil, "/", nil,
  nil, nil, false, nil, { unveil = { reads = reads }, offline = true })
print(pid or "refused " .. trouble)
sys.nanosleep(30 * 1000000000)
]==], table.concat(reads, ":") }, nil, tmp, nil, report, report, false))
  local said = ""
  local by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 30 * 1000000000
  while not said:find("\n") and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    assert(sys.nanosleep(10 * 1000000))
    said = assert(sys.pread(report, 4096, 0))
  end
  sys.close(report)
  assert(sys.kill(parent, sys.SIGKILL))
  assert(process.waitpid(parent, false))
  if said:find("^refused ") then
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but: " .. said)
    return
  end
  local child = assert(math.tointeger(tonumber(said:match("^(%d+)\n"))), said)
  -- This process adopted it: it ends by the kernel's SIGKILL, its
  -- namespace's end, within seconds, where it would sleep on for 30.
  local ended: raw_process.ChildStatus | nil = nil
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while ended == nil and assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = assert(process.waitpid(child, true))
    if status.pid == child then ended = status else assert(sys.nanosleep(10 * 1000000)) end
  end
  if ended == nil then assert(sys.kill(child, sys.SIGKILL)) end
  -- The rest it adopted: the init, ended with its parent.
  by = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) + 5 * 1000000000
  while assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) < by do
    local status = process.waitpid(-1, true)
    if status == nil then break end
    if status.pid == 0 then assert(sys.nanosleep(10 * 1000000)) end
  end
  assert(ended ~= nil, "the confined child outlived its parent")
  assert(ended.signal == sys.SIGKILL, "ended by " .. tostring(ended.signal))
end

--- /proc given to write is no more the host's to change than given to
--- read: a procfs of the child's own is writable, and holds no /proc/sys;
--- where the kernel refuses one, the host's is bound read-only all the
--- same, and so is a path beneath it given to write -- where this
--- process has one: in a sandbox of its own (a sandboxed `cosmic test`
--- worker's), its /proc has no /proc/sys to give.
local function test_proc_given_to_write_changes_nothing_of_the_host_s(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local without: {string} = {}
  for _, path in ipairs(reads) do
    if path ~= "/proc" then without[#without + 1] = path end
  end
  local writes: {string} = { "/proc" }
  if sys.stat("/proc/sys/kernel") ~= nil then writes[2] = "/proc/sys/kernel" end
  local report = create(tmp .. "/written")
  local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c",
    "(: >> /proc/sys/vm/swappiness) 2>/dev/null && echo sys-writable || echo sys-read-only; " ..
    "(: >> /proc/sys/kernel/hostname) 2>/dev/null && echo name-writable || echo name-read-only" },
    nil, "/", nil, report, report, false, nil,
    { unveil = { reads = without, writes = writes }, offline = true })
  if pid == nil then
    sys.close(report)
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no unveiling: " .. trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  assert(assert(process.waitpid(pid, false)).code == 0)
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(said == "sys-read-only\nname-read-only\n", said)
end

--- Starting and waiting for a confined child costs milliseconds, not the
--- second `waitpid` gives a sandbox's init to end once its program has
--- (core/syscalls.c's `end_sandbox_init`): a run of `cosmic test` that
--- confines each of its processes, as build/shared_verdicts_test.tl's
--- nested runs do, would pay that second for every one. Each of a few
--- runs of a confined /bin/sh that exits at once takes well under half
--- a second, and leaves no init behind.
local function test_a_confined_child_is_started_and_waited_for_quickly(tmp: string)
  local reads = shell_reads()
  if reads == nil then return end
  local slowest = 0
  for _ = 1, 5 do
    local started = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC))
    local status = run_confined(tmp, reads, "true")
    if status == nil then return end
    local took = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) - started
    assert(status.code == 0)
    assert(#process.sandbox_inits() == 0, "an init outlived the wait for its program")
    if took > slowest then slowest = took end
  end
  assert(slowest < 500 * 1000000, "a confined start and wait took " ..
    tostring(slowest // 1000000) .. " ms")
end

--- An offline child's loopback is up, as a host's is: the kernel gives
--- lo its 127.0.0.1 only when lo comes up, so the child's own routing
--- table (/proc/self/net is the reader's network namespace) holds that
--- address as a local route. The child is this program, reading it.
-- TODO: connect to a closed port of 127.0.0.1 and hold the child to
-- ECONNREFUSED, not ENETUNREACH, once cosmic.sys can open a socket or
-- core/http.c answers a failed request with CURLINFO_OS_ERRNO: curl's own
-- message words the two alike.
local function test_an_offline_child_s_loopback_is_up(tmp: string)
  local report = create(tmp .. "/report")
  local cosmic = assert(sys.executable())
  local pid, trouble, errno = process.spawn(cosmic, { "cosmic", "-e",
    "local t = assert(require('cosmic.fs').read('/proc/self/net/fib_trie')) " ..
    "print(t:find('127.0.0.1', 1, true) and 'up' or 'down')" },
    nil, tmp, nil, report, report, false, nil, { offline = true })
  if pid == nil then
    sys.close(report)
    assert(not sandbox_required(), "COSMIC_SANDBOX=must, but no network namespace: " .. trouble)
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return
  end
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(status.code == 0 and said == "up\n", said)
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
  failed_with(sys.EINVAL, sys.access(nul, 0))
  failed_with(sys.EINVAL, sys.mkfifo(tmp .. "/pipe\0x"))
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

--- The inits of the sandboxes this process started and has not seen
--- the end of: a list of pids, on every system, empty where none runs --
--- as on one with no sandbox, or once a sandbox's program is reaped.
local function test_sandbox_inits_lists_the_inits_still_running()
  local before = process.sandbox_inits()
  assert(type(before) == "table")
  for _, pid in ipairs(before) do assert(math.type(pid) == "integer" and pid > 0) end
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then assert(#before == 0) end
end

--- The calls that start and reap a child, and hold this process's
--- signals while it does, are the raw process table's, and not the
--- public `cosmic.sys`'s: a public `waitpid(-1)` would take the status
--- of a child a `Child` handle owns from under it, and a public signal
--- guard would be a second one beside `Child.guard`'s.
local function test_the_process_calls_are_off_the_public_table()
  local public: {string: any} = sys as {string: any} -- cast: to look a member up by name
  local raw: {string: any} = process as {string: any} -- cast: to look a member up by name
  for _, name in ipairs({ "spawn", "waitpid", "subreaper", "sandbox_inits", "relaunch", "pipe",
      "set_nonblocking", "poll", "ignore_sigpipe", "landlock_ruleset",
      "landlock_restrict_execute",
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

--- An entry the walk is refused -- a file it may not read, a directory
--- it may not list -- is digested by its permissions and owner, and the
--- tree is not special for it: no process with no more privilege than
--- the walk's could learn more of it. Where this process may read
--- everything (root, holding CAP_DAC_OVERRIDE), there is nothing to
--- refuse it.
local function test_a_tree_digest_of_what_it_is_refused_is_not_special(tmp: string)
  local tree = tmp .. "/refused"
  assert(sys.mkdir(tree, 0x1ed))
  assert(sys.mkdir(tree .. "/closed", 0x1ed))
  local fd = create(tree .. "/secret")
  assert(sys.write(fd, "one") == 3)
  sys.close(fd)
  assert(sys.chmod(tree .. "/secret", 0))
  assert(sys.chmod(tree .. "/closed", 0))
  local opened, _ = sys.open(tree .. "/secret", sys.O_RDONLY, 0)
  if opened ~= nil then
    sys.close(opened)
    assert(sys.chmod(tree .. "/closed", 0x1ed))
    return
  end
  local refused = assert(sys.tree_digest(tree, true))
  assert(not refused.special and not assert(sys.tree_digest(tree, false)).special)
  assert(sys.chmod(tree .. "/secret", 0x100))
  assert(assert(sys.tree_digest(tree, true)).digest ~= refused.digest, "its permissions moved")
  assert(sys.chmod(tree .. "/closed", 0x1ed))
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
  local named: {{string | integer}} = {
    { "ENOENT", sys.ENOENT }, { "EEXIST", sys.EEXIST }, { "EACCES", sys.EACCES },
    { "EINTR", sys.EINTR }, { "EAGAIN", sys.EAGAIN }, { "ENOTEMPTY", sys.ENOTEMPTY },
    { "EXDEV", sys.EXDEV }, { "EOPNOTSUPP", sys.EOPNOTSUPP }, { "EPERM", sys.EPERM },
    { "ENOSPC", sys.ENOSPC }, { "EINVAL", sys.EINVAL },
  }
  for _, pair in ipairs(named) do
    local name, number = pair[1], pair[2]
    if name is string and number is integer then
      assert(sys.errno_name(number) == name, name .. " is named " ..
        tostring(sys.errno_name(number)))
    end
  end
  assert(sys.errno_name(0) == nil and sys.errno_name(-1) == nil)
  assert(sys.errno_message(-1) == "No error information")
  assert(not pcall(sys.errno_name, "ENOENT" as integer), "a name is not a number")
end

--- Every errno a macOS call can fail with is named and worded, those
--- musl has no words for among them: a spawned file of the wrong
--- architecture fails with EBADARCH, not "No error information".
local function test_the_errnos_only_macos_has_are_named_there()
  local uname = assert(sys.uname())
  if uname.sysname ~= "Darwin" then
    return
  end
  local names: {string:string} = {}
  for number = 1, 4095 do
    local name = sys.errno_name(number)
    if name ~= nil then
      names[name] = sys.errno_message(number)
    end
  end
  for _, name in ipairs({ "EBADARCH", "EBADEXEC", "EBADMACHO", "ESHLIBVERS", "EAUTH",
      "ENEEDAUTH", "EDEVERR", "EPWROFF", "ENOATTR", "EFTYPE", "EQFULL" }) do
    assert(names[name] ~= nil and names[name] ~= "No error information", name .. " is unnamed")
  end
end

--- `access` asks with this process's own ids: it may read and write a
--- file it made, run it only once an execute bit it holds is set, and
--- a missing path or a mode outside R_OK, W_OK and X_OK fails or raises.
local function test_access_asks_what_this_process_may_do(tmp: string)
  local path = tmp .. "/file"
  sys.close(create(path))
  assert(sys.access(path, 0))
  assert(sys.access(path, sys.R_OK | sys.W_OK))
  failed_with(sys.EACCES, sys.access(path, sys.X_OK))
  assert(sys.chmod(path, 0x1c0))
  assert(sys.access(path, sys.X_OK))
  assert(sys.access(tmp, sys.X_OK), "a directory it may search")
  failed_with(sys.ENOENT, sys.access(tmp .. "/missing", 0))
  raises(sys.access, path, 0x100)
end

--- `mkfifo` makes a named pipe, which `lstat` calls "other" and a
--- second make refuses; opened with O_NONBLOCK, its reading end opens
--- with no writer rather than waiting for one.
local function test_mkfifo_makes_a_named_pipe(tmp: string)
  local path = tmp .. "/pipe"
  assert(sys.mkfifo(path, 0x180))
  local st = assert(sys.lstat(path))
  assert(st.kind == "other" and st.mode & 0x1ff == 0x180, st.kind)
  failed_with(sys.EEXIST, sys.mkfifo(path))
  local reader = assert(sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK))
  assert(sys.read(reader, 64) == "")
  sys.close(reader)
end

--- O_NOFOLLOW refuses a link where the path ends, and opens the file it
--- would have led to.
local function test_o_nofollow_refuses_a_final_link(tmp: string)
  local path = tmp .. "/file"
  sys.close(create(path))
  assert(sys.symlink("file", tmp .. "/link"))
  failed(sys.open(tmp .. "/link", sys.O_RDONLY | sys.O_NOFOLLOW))
  sys.close((assert(sys.open(path, sys.O_RDONLY | sys.O_NOFOLLOW))))
end
