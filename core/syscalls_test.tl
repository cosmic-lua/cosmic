--- The syscall table's contract, binding by binding, as core/syscalls.h
--- states it: an argument no correct program passes raises, and a
--- failure a correct caller meets at runtime comes back as `nil` (for a
--- value) or `false` (for an effect), then the error, then the errno.
---
--- Each test calls the C through [`cosmic.sys`] directly rather than
--- through the typed modules above it, so a binding is held to its own
--- promise and not to whatever a wrapper makes of it; so too core/process.h's
--- calls and `digest` and `hmac`, through the raw tables the store hands
--- [`cosmic.child`] and [`cosmic.hash`]. [`sys.exit`] is the one binding with
--- no test here: it ends the process the test runs in.

local Net = require("cosmic.net")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")
local type raw_hash = require("cosmic.internal.hash")
local type raw_process = require("cosmic.internal.process")
local stand_in = require("build.stand_in")
local sandbox_skip = require("build.sandbox_skip")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What the syscall table is tested on: /proc and the whole
--- environment: a stand-in program (build/stand_in.tl) is
--- what a child here runs, reading nothing of the system's. The cases
--- that start this program itself, or read it, or unveil a child's root
--- -- which a worker that does not declare `tool` cannot (see
--- core/syscalls_tool_test.tl) -- are core/syscalls_tool_test.tl's.
Test.needs{
  host = { "/proc" },
  env = { "*" },
  network = { "127.0.0.1" },
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

--- Says a sandbox test is skipped ([`Test.skip`]) where this Linux host
--- refuses the sandbox it is about -- no Landlock, no pledge -- as it
--- returns early: the run counts it skipped rather than passed, and a
--- run held to sandboxing (COSMIC_SANDBOX=must among them) fails it.
--- Another platform has no such sandbox to check, and returns silently
--- (build.sandbox_skip).
local function unsandboxable(what: string, trouble: string)
  sandbox_skip.refused("the kernel gives no " .. what .. ": " .. tostring(trouble))
end

--- A stand-in program built under `tmp` (build/stand_in.tl), which runs
--- the script its first argument holds: a static executable that reads
--- only itself, so one confined needs nothing of the system's own.
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
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

--- Leaves a socket file at `path`: a listener's, moved there, so its
--- close -- which removes the file it made only while its name is
--- still that file -- leaves it.
local function socket_file(path: string)
  local listening = path .. ".listening"
  local listener = assert(Net.listen(Net.unix(listening)))
  assert(sys.rename(listening, path))
  assert(listener:close())
end

--- A socket file, a named pipe and a device are each named for what
--- they are, by the mode's type and the same words on every system,
--- rather than lumped together as "other".
local function test_stat_names_a_socket_a_fifo_and_a_device(tmp: string)
  local socket = tmp .. "/socket"
  socket_file(socket)
  local found = assert(sys.lstat(socket)).kind
  assert(found == "socket", found)
  assert(sys.mkfifo(tmp .. "/fifo"))
  found = assert(sys.stat(tmp .. "/fifo")).kind
  assert(found == "fifo", found)
  found = assert(sys.stat("/dev/null")).kind
  assert(found == "char", found)
  local fd = assert(sys.open("/dev/null", sys.O_RDONLY))
  local st = sys.fstat(fd)
  sys.close(fd)
  assert(st ~= nil and st.kind == "char")
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

--- chown sets a path's owner and group -- here to what they are, which
--- any owner may -- or leaves either at -1; an id past a 32-bit one's
--- range raises.
local function test_chown(tmp: string)
  sys.close(create(tmp .. "/a"))
  local own = assert(sys.stat(tmp .. "/a"))
  local changed, trouble = sys.chown(tmp .. "/a", own.uid, own.gid)
  assert(changed == true, trouble)
  assert(sys.chown(tmp .. "/a", -1, -1))
  local after = assert(sys.stat(tmp .. "/a"))
  assert(after.uid == own.uid and after.gid == own.gid)
  failed_with(sys.ENOENT, sys.chown(tmp .. "/missing", own.uid, own.gid))
  raises(sys.chown, tmp .. "/a", -2, own.gid)
  raises(sys.chown, tmp .. "/a", own.uid, 4294967295)
end

--- dumpable answers whether this process may be dumped, 0, 1 or 2,
--- and sets it to 0 or 1 first where asked; any other value raises. Off
--- Linux it is ENOSYS.
local function test_dumpable()
  local now, trouble, errno = sys.dumpable()
  if now == nil then
    assert(errno == sys.ENOSYS, trouble)
    return
  end
  assert(now == 0 or now == 1 or now == 2, tostring(now))
  if now ~= 2 then assert(sys.dumpable(now) == now) end
  raises(sys.dumpable, 2)
  raises(sys.dumpable, -1)
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

--- A directory under `tmp` holding a file, a directory, a named pipe,
--- a socket file, and a link to each of the first two and to nothing.
local function linked_directory(tmp: string): string
  local d = tmp .. "/d"
  assert(sys.mkdir(d))
  sys.close(create(d .. "/file"))
  assert(sys.mkdir(d .. "/sub"))
  assert(sys.mkfifo(d .. "/fifo"))
  socket_file(d .. "/socket")
  assert(sys.symlink("file", d .. "/to_file"))
  assert(sys.symlink("sub", d .. "/to_dir"))
  assert(sys.symlink("missing", d .. "/dangling"))
  return d
end

--- The entries of [`linked_directory`].
local LINKED_ENTRIES <const> = 7

--- Checks readdir's answer for [`linked_directory`].
local function names_links_as_links(entries: {string:string}, what: string)
  assert(entries["file"] == "file" and entries["sub"] == "dir", what)
  assert(entries["fifo"] == "fifo", what .. ": a named pipe: " .. tostring(entries["fifo"]))
  assert(entries["socket"] == "socket", what .. ": a socket file: " .. tostring(entries["socket"]))
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
  for skip = 0, LINKED_ENTRIES - 1 do
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
  local probe = probe_in(tmp)
  local reads: {string} = { inside, probe }
  local ruleset, trouble, errno = process.landlock_ruleset(reads, {})
  if ruleset == nil then
    -- No Landlock: not built in, turned off, or refused by a filter (a
    -- container's seccomp profile).
    unsandboxable("Landlock ruleset", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    return
  end
  local output = create(tmp .. "/said")
  local pid = assert(process.spawn(probe, { probe,
    "cat in/f; print; run " .. probe .. " cat out/f || print refused; " ..
    "append in/g x || print unwritten" },
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
  -- A free descriptor from 4 to 10, the child's own ending below it.
  local free = 10
  while free > 4 and sys.fstat(free) ~= nil do free = free - 1 end
  assert(sys.fstat(free) == nil, "no descriptor from 4 to 10 is free")
  assert(sys.dup2(writing, free))
  sys.close(writing)
  local own = tostring(free - 1)
  local wrote = assert(process.spawn(probe, { probe,
    "append w/f w && write-fd " .. own .. " w-written; append in/h x || write-fd " .. own .. " held" },
    nil, tmp, nil, nil, nil, false, { [free - 1] = report }, { ruleset = free }))
  sys.close(free)
  assert(assert(process.waitpid(wrote, false)).code == 0)
  local reported = assert(sys.pread(report, 4096, 0))
  sys.close(report)
  assert(reported == "w-written\nheld\n", reported)
  local fd = assert(sys.open(tmp .. "/w/f", sys.O_RDONLY))
  assert(sys.read(fd, 16) == "w\n")
  sys.close(fd)
  local bad, bad_trouble = process.landlock_ruleset({ tmp .. "/nowhere" }, {})
  assert(bad == nil and bad_trouble ~= "", "a path that is not there refuses the ruleset")
end

--- A ruleset holds files and not the network, on every kernel: a child
--- held to one reaches a listener of this process's over TCP on
--- loopback and over a unix socket file, as one held to none does.
local function test_a_landlock_ruleset_leaves_a_child_its_loopback(tmp: string)
  local probe = probe_in(tmp)
  local tcp = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ms = 5000 }))
  local socket = tmp .. "/s"
  local unix = assert(Net.listen(Net.unix(socket), { timeout_ms = 5000 }))
  local ruleset, trouble = process.landlock_ruleset({ probe }, {})
  if ruleset == nil then
    assert(tcp:close() and unix:close())
    unsandboxable("Landlock ruleset", trouble)
    return
  end
  local output = create(tmp .. "/said")
  local pid = assert(process.spawn(probe, { probe,
    "connect-tcp 127.0.0.1 " .. tostring(tcp.address.port) .. "; connect " .. socket },
    nil, tmp, nil, output, output, false, nil, { ruleset = ruleset }))
  sys.close(ruleset)
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(output, 4096, 0))
  sys.close(output)
  assert(status.code == 0 and said == "connected\nconnected\n", said)
  assert(assert(tcp:accept()):close())
  assert(assert(unix:accept()):close())
  assert(tcp:close() and unix:close())
end

--- A process held to running what is beneath some paths runs a program
--- beneath them and no other -- one written after the hold included --
--- and what it starts is held too; it still reads and writes as before.
--- The hold is for good, so it is taken last: this test's worker ends
--- with the test. Where there is no Landlock, taking one says so.
local function test_a_process_held_to_running_some_paths_runs_nothing_else(tmp: string)
  -- The program beneath a path given, and a copy of it beneath none.
  local built = probe_in(tmp)
  local probe, elsewhere = tmp .. "/bin/probe", tmp .. "/elsewhere/run"
  assert(sys.mkdir(tmp .. "/bin", 0x1c0) and sys.mkdir(tmp .. "/elsewhere", 0x1c0))
  assert(stand_in.place(built, probe))
  assert(stand_in.place(built, elsewhere))
  local function status_of(path: string, argv: {string}): integer | string
    local pid, trouble = process.spawn(path, argv, nil, tmp, nil, nil, nil, false)
    if pid == nil then return trouble end
    return assert(process.waitpid(pid, false)).code
  end
  assert(status_of(elsewhere, { elsewhere, "exit 0" }) == 0, "the copy runs before the hold")
  -- Beneath a path given, a file may still move to another directory.
  local given = tmp .. "/given"
  assert(sys.mkdir(given, 0x1c0) and sys.mkdir(given .. "/a", 0x1c0) and
    sys.mkdir(given .. "/b", 0x1c0))
  sys.close(create(given .. "/a/f"))
  local held, trouble, errno = process.landlock_restrict_execute({ tmp .. "/bin", given })
  if not held then
    unsandboxable("Landlock", trouble)
    assert(errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM, trouble)
    return
  end
  assert(status_of(probe, { probe, "exit 3" }) == 3, "a program beneath them runs")
  assert(status_of(elsewhere, { elsewhere, "exit 0" }) ~= 0, "a program elsewhere ran")
  -- What it starts is held too: the program may not run the copy.
  assert(status_of(probe, { probe, "run " .. elsewhere .. " || exit 7" }) == 7)
  assert(sys.rename(given .. "/a/f", given .. "/b/f"))
  -- So may one in a directory made after the hold, beneath none -- but
  -- not into one where it could be run, which it could not before.
  local later = tmp .. "/later"
  assert(sys.mkdir(later, 0x1c0) and sys.mkdir(later .. "/a", 0x1c0))
  sys.close(create(later .. "/f"))
  assert(sys.rename(later .. "/f", later .. "/a/f"))
  local moved, _, moved_errno = sys.rename(later .. "/a/f", given .. "/a/f")
  assert(not moved and moved_errno == sys.EXDEV, "a file moved to where it could be run")
  -- Reading and writing are as they were.
  local written = create(tmp .. "/after")
  assert(sys.write(written, "w") == 1)
  sys.close(written)
  local reading = assert(sys.open(elsewhere, sys.O_RDONLY))
  assert(sys.read(reading, 4) == "\x7fELF")
  sys.close(reading)
  local bad, _ = pcall(process.landlock_restrict_execute, { 1 } as {string})
  assert(not bad, "a path that is no string is refused")
end

--- A pledged child runs under a seccomp filter, and so does what it
--- starts; an unpledged one runs as this process does (under a filter
--- of its own when a container gives it one), and a promise no one keeps
--- is refused before anything starts. A socket of a family not promised
--- is refused (EPERM), where one promised is made and then refused its
--- connection.
local function test_a_pledge_holds_a_child_and_what_it_starts(tmp: string)
  local probe = probe_in(tmp)
  local refused = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil,
    false, nil, { pledge = { "fly" } })
  assert(not refused, "a promise no one keeps is refused")
  local function filtered(sandbox: raw_process.Sandbox | nil): string
    local output = create(tmp .. "/status")
    local pid, trouble, errno = process.spawn(probe, { probe,
      "status-field Seccomp; run " .. probe .. " status-field Seccomp" },
      nil, nil, nil, output, output, false, nil, sandbox)
    if pid == nil then
      sys.close(output)
      if sandbox ~= nil then unsandboxable("pledge", trouble) end
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
    local ok, trouble, errno = process.spawn(probe, { probe }, nil, nil, nil,
      nil, nil, false, nil, { pledge = {} })
    if ok == nil then
      unsandboxable("pledge", trouble)
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
  if pledged ~= "unsupported" then
    local function connected(promises: {string}): string
      local output = create(tmp .. "/connect")
      local pid = assert(process.spawn(probe, { probe, "connect " .. tmp .. "/none.sock" },
        nil, nil, nil, output, output, false, nil, { pledge = promises }))
      assert(assert(process.waitpid(pid, false)).code == 0)
      local said = assert(sys.pread(output, 4096, 0))
      sys.close(output)
      return said
    end
    local socket = tmp .. "/none.sock: "
    local unpromised = connected({})
    assert(unpromised == socket .. "Operation not permitted\n", unpromised)
    local promised = connected({ "unix" })
    assert(promised == socket .. "No such file or directory\n", promised)
  end
end

--- A child starts on this process's memory rather than a copy of it,
--- but with a descriptor table of its own: the descriptors it closes and
--- moves to hand its program the ones asked for, and a later step that
--- fails, leave every one of this process's as it was.
local function test_a_child_s_descriptors_are_its_own(tmp: string)
  local probe = probe_in(tmp)
  local held: {integer} = {}
  local target = 0
  for i = 1, 4 do
    held[i] = create(tmp .. "/held" .. i)
    if held[i] > target then target = held[i] end
  end
  -- Handed above all of them, so the child closes every one on its way.
  target = target + 2
  local report = create(tmp .. "/report")
  local pid = assert(process.spawn(probe, { probe, "append /dev/fd/" .. target .. " mapped" },
    nil, nil, nil, nil, nil, false, { [target] = report }))
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(assert(sys.pread(report, 64, 0)) == "mapped\n")
  failed_with(sys.ENOENT, process.spawn(probe, { probe }, nil, tmp .. "/missing",
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
  local probe = probe_in(tmp)
  local status = sys.open("/proc/self/status", sys.O_RDONLY)
  if status == nil then return end -- no /proc to ask
  local own = assert(sys.read(status, 65536))
  sys.close(status)
  local output = create(tmp .. "/status")
  local pid = assert(process.spawn(probe, { probe, "cat /proc/self/status" },
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
  local probe = probe_in(tmp)
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
  local pid = assert(process.spawn(probe, { probe, "cat /proc/self/status" },
    nil, nil, nil, output, nil, false))
  assert(assert(process.waitpid(pid, false)).code == 0)
  local child = assert(sys.pread(output, 65536, 0))
  sys.close(output)
  assert(ignored(child) & bit == 0, child)
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
  failed_with(sys.EINVAL, sys.chown(nul, -1, -1))
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
  -- execve, like spawn, refuses a NUL by raising, before it allocates;
  -- the program named is not there, so one that did not would fail
  -- rather than run it.
  local program = tmp .. "/program"
  raises(sys.execve, tmp .. "\0/program", { "program" }, {})
  raises(sys.execve, program, { "program", "-c\0x" }, {})
  raises(sys.execve, program, { "program" }, { A = "b\0c" })
  -- spawn refused a NUL before this rule existed, by raising, and
  -- [`cosmic.child`] relies on that; it never truncates either way.
  raises(process.spawn, tmp .. "\0/program", { "program" }, nil, nil, nil, nil, nil, false)
  raises(process.spawn, program, { "program" }, nil, tmp .. "\0x", nil, nil, nil, false)
  -- The file the truncated paths name is exactly as it was.
  local st = assert(sys.stat(file))
  assert(st.kind == "file" and st.mode & 511 == 420)
  assert(sys.stat(tmp .. "/moved") == nil and sys.lstat(tmp .. "/link") == nil)
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

--- A process's group is its own group's by pid as by 0; a pid no
--- process has is refused, and one no pid can be raises.
local function test_getpgid_names_a_process_group()
  local group = assert(sys.getpgid(0))
  assert(group > 0 and sys.getpgid(sys.getpid()) == group)
  failed_with(sys.ESRCH, sys.getpgid(2147483647))
  raises(sys.getpgid, -1)
  raises(sys.getpgid, 2147483648)
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

--- `children` lists the children of the thread that starts them, a
--- child still running among them and gone once reaped; off Linux there
--- is no such list, ENOSYS.
local function test_children_lists_a_running_child_until_it_is_reaped(tmp: string)
  local probe = probe_in(tmp)
  local ends = assert(process.pipe())
  local pid = assert(process.spawn(probe, { probe, "cat" }, nil, tmp, ends.reader, nil, nil, false))
  sys.close(ends.reader)
  local running, trouble, errno = process.children()
  sys.close(ends.writer)
  assert(assert(process.waitpid(pid, false)).code == 0)
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then
    assert(running == nil and errno == sys.ENOSYS, trouble)
    return
  end
  assert(running ~= nil, trouble)
  local listed = false
  for _, child in ipairs(running) do
    assert(math.type(child) == "integer" and child > 0)
    if child == pid then listed = true end
  end
  assert(listed, "the running child " .. pid .. " is not listed")
  for _, child in ipairs((assert(process.children()))) do
    assert(child ~= pid, "the reaped child " .. pid .. " is still listed")
  end
end

--- The calls that start and reap a child, and hold this process's
--- signals while it does, are the raw process table's, and not the
--- public [`cosmic.sys`]'s: a public `waitpid(-1)` would take the status
--- of a child a `Child` handle owns from under it, and a public signal
--- guard would be a second one beside [`Child.guard`]'s. `poll` and
--- `set_nonblocking`, which wait on any descriptor, are the public
--- table's alone.
local function test_the_process_calls_are_off_the_public_table()
  local public: {string: any} = sys as {string: any} -- cast: to look a member up by name
  local raw: {string: any} = process as {string: any} -- cast: to look a member up by name
  for _, name in ipairs({ "spawn", "waitpid", "subreaper", "sandbox_inits", "children", "relaunch", "pipe",
      "ignore_sigpipe", "landlock_ruleset",
      "landlock_restrict_execute",
      "guard_child_signals", "unguard_child_signals", "cancelled_child_signal" }) do
    assert(public[name] == nil, "cosmic.sys." .. name .. " is public")
    assert(type(raw[name]) == "function", name .. " is not in the raw process table")
  end
  for _, name in ipairs({ "poll", "set_nonblocking", "POLLIN", "POLLOUT", "POLLERR", "POLLHUP",
      "POLLNVAL" }) do
    assert(public[name] ~= nil, "cosmic.sys." .. name .. " is not public")
    assert(raw[name] == nil, name .. " is in the raw process table too")
  end
  for _, name in ipairs({ "digest", "hmac" }) do
    assert(public[name] == nil, "cosmic.sys." .. name .. " is public")
    assert(type((hash as {string: any})[name]) == "function", name .. " is not raw hash's")
  end
end

--- A descriptor given more than once answers in every entry, each
--- only the events that entry asked for, as Linux answers it: macOS
--- answers only one entry of such a descriptor, left to itself.
local function test_poll_answers_every_entry_of_a_descriptor_given_twice()
  local ends = assert(process.pipe())
  assert(sys.write(ends.writer, "x") == 1)
  local revents = assert(sys.poll(
    { ends.writer, ends.reader, ends.writer, -1, ends.reader, ends.writer },
    { sys.POLLIN, sys.POLLIN, sys.POLLOUT, sys.POLLIN, sys.POLLOUT, sys.POLLIN | sys.POLLOUT }, 0))
  sys.close(ends.reader)
  sys.close(ends.writer)
  local said = table.concat(revents as {number}, " ") -- cast: an integer is a number
  assert(#revents == 6, said)
  assert(revents[1] == 0, "a writing end asked to read: " .. said)
  assert(revents[2] & sys.POLLIN ~= 0 and revents[2] & sys.POLLOUT == 0, said)
  assert(revents[3] & sys.POLLOUT ~= 0 and revents[3] & sys.POLLIN == 0, said)
  assert(revents[4] == 0, "an unwatched entry: " .. said)
  assert(revents[5] == 0, "a reading end asked to write: " .. said)
  assert(revents[6] & sys.POLLOUT ~= 0 and revents[6] & sys.POLLIN == 0, said)
end

--- `poll` watches as many descriptors as the kernel lets a process
--- watch, past the 1024 it was once held to, and -1 is left unwatched.
--- The first entries are distinct descriptors, copies of one pipe's
--- reading end, since a descriptor given more than once goes to the
--- kernel once; the rest give that end again, and answer too. Where
--- RLIMIT_NOFILE's soft limit is lower (1024 under systemd's default,
--- 256 on macOS), the copies stop short of it, and so does the count
--- the kernel is given.
local function test_poll_watches_past_a_thousand_descriptors()
  local ends = assert(process.pipe())
  assert(sys.write(ends.writer, "x") == 1)
  local fds: {integer} = { ends.reader }
  local events: {integer} = { sys.POLLIN }
  local copies = 0
  while #fds < 1100 do
    local copy = sys.dup(ends.reader)
    if copy == nil then break end
    fds[#fds + 1] = copy
    events[#events + 1] = sys.POLLIN
    copies = copies + 1
  end
  while #fds < 1100 do
    fds[#fds + 1] = ends.reader
    events[#events + 1] = sys.POLLIN
  end
  fds[#fds + 1] = -1
  events[#events + 1] = sys.POLLIN
  assert(not pcall(sys.poll, { -2 }, { sys.POLLIN }, 0), "a descriptor below -1 raises")
  -- TODO: raise RLIMIT_NOFILE's soft limit past 1101 first, once
  -- cosmic.sys carries getrlimit and setrlimit, so a host with a low one
  -- gives the kernel past 1024 descriptors too.
  local revents, trouble = sys.poll(fds, events, 0)
  for i = 2, copies + 1 do sys.close(fds[i]) end
  sys.close(ends.reader)
  sys.close(ends.writer)
  assert(revents ~= nil, trouble)
  assert(#revents == 1101, "one answer per descriptor, not " .. #revents)
  for i = 1, 1100 do
    assert(revents[i] & sys.POLLIN ~= 0, "descriptor " .. i .. " answered " .. revents[i])
  end
  assert(revents[1101] == 0, "an unwatched descriptor answered " .. revents[1101])
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
  assert(sys.mkfifo(tree .. "/sub/fifo"))
  assert(assert(sys.tree_digest(tree, true)).special, "a FIFO answers from past the tree")
  assert(not assert(sys.tree_digest("/dev/null", false)).special)
  local missing, _, errno = sys.tree_digest(tmp .. "/missing", false)
  assert(missing == nil and errno == sys.ENOENT)
end

--- /dev/full answers every read with zeros and every write with ENOSPC,
--- so a tree holding it is not special. Every Linux worker is given it
--- (build.confine's `runtime_paths`): one without it is skipped, and
--- elsewhere there is nothing to check.
local function test_a_tree_digest_of_dev_full_is_not_special()
  if sys.stat("/dev/full") == nil then
    sandbox_skip.refused("this worker has no /dev/full")
    return
  end
  local walked = assert(sys.tree_digest("/dev/full", false))
  assert(not walked.special, "/dev/full answers from nothing past the tree")
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

--- A lock belongs to the open file: a second open of the same file is
--- refused an exclusive lock the first holds, whether it asks once or
--- waits, until the first unlocks or closes.
local function test_flock_excludes_another_open_until_released(tmp: string)
  local path = tmp .. "/lock"
  local first = assert(sys.open(path, sys.O_RDONLY | sys.O_CREAT, 0x180))
  local second = assert(sys.open(path, sys.O_RDONLY, 0))
  assert(sys.flock(first, "exclusive"))
  local ok, why, errno = sys.flock(second, "exclusive")
  assert(not ok and sys.errno_name(errno) == "ETIMEDOUT", why)
  ok, why, errno = sys.flock(second, "shared", 30)
  assert(not ok and sys.errno_name(errno) == "ETIMEDOUT", why)
  assert(sys.flock(first, "unlock"))
  assert(sys.flock(second, "shared"))
  assert(sys.flock(first, "shared"))
  ok, why, errno = sys.flock(first, "exclusive")
  assert(not ok and sys.errno_name(errno) == "ETIMEDOUT", why)
  assert(sys.close(second))
  assert(sys.flock(first, "exclusive", -1))
  local third = assert(sys.open(path, sys.O_RDONLY, 0))
  assert(sys.close(first))
  assert(sys.flock(third, "exclusive"))
  assert(sys.close(third))
  ok, why, errno = sys.flock(third, "exclusive")
  assert(not ok and why ~= "" and errno == sys.EBADF, why)
  raises(sys.flock, 0, "both")
  raises(sys.flock, 0, "exclusive", -2)
  raises(sys.flock, 0, "exclusive", 1 << 40)
end

--- One signal guard is open at a time: a second is refused with EBUSY,
--- the number cosmic.sys carries, until the first is closed.
local function test_a_second_signal_guard_is_busy()
  assert(process.guard_child_signals())
  local ok, why, errno = process.guard_child_signals()
  assert(process.unguard_child_signals())
  assert(not ok and errno == sys.EBUSY, why)
  assert(process.guard_child_signals())
  assert(process.unguard_child_signals())
end

--- A wait for a lock ends when a guard catches a signal, as every
--- other wait in the tree does, however long it had left.
local function test_flock_waiting_ends_on_a_caught_signal(tmp: string)
  local path = tmp .. "/lock"
  local first = assert(sys.open(path, sys.O_RDONLY | sys.O_CREAT, 0x180))
  local second = assert(sys.open(path, sys.O_RDONLY, 0))
  assert(sys.flock(first, "exclusive"))
  assert(process.guard_child_signals())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local ok, why, errno = sys.flock(second, "exclusive", -1)
  local caught = assert(process.unguard_child_signals())
  assert(caught == sys.SIGINT, tostring(caught))
  assert(not ok and errno == sys.EINTR, why)
  assert(sys.close(first))
  assert(sys.close(second))
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

--- `mkfifo` makes a named pipe, which `lstat` calls "fifo" and a
--- second make refuses; opened with O_NONBLOCK, its reading end opens
--- with no writer rather than waiting for one.
local function test_mkfifo_makes_a_named_pipe(tmp: string)
  local path = tmp .. "/pipe"
  assert(sys.mkfifo(path, 0x180))
  local st = assert(sys.lstat(path))
  assert(st.kind == "fifo" and st.mode & 0x1ff == 0x180, st.kind)
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
