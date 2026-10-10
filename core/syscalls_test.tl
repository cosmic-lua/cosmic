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

local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Relay = require("cosmic.relay")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local type raw_hash = require("cosmic.internal.hash")
local type raw_process = require("cosmic.internal.process")
local stand_in = require("build.stand_in")

--- What the syscall table is tested on: /proc. A stand-in program
--- (build/stand_in.tl) is what a child here runs, reading nothing of the system's. The cases
--- that start this program itself to run a chunk, or unveil a child's
--- root -- which a worker that declares neither `lua` nor `nests`
--- cannot (see core/syscalls_tool_test.tl) -- are
--- core/syscalls_tool_test.tl's, and the one that reads the program's
--- own path core/artifact_fd_tool_test.tl's.
Test.policy{
  profiles = { "proc" },
  loopback = { "127.0.0.1" },
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

--- The file at `path`, or "" where it cannot be read.
local function read_file(path: string): string
  return (Fs.read(path)) or ""
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

--- `fd_status` shows O_NONBLOCK as `set_nonblocking` sets it, so a caller can
--- put back what it found, and a closed descriptor fails with its errno.
local function test_fd_status_shows_what_set_nonblocking_set(tmp: string)
  local fd = assert(sys.open(tmp .. "/mode", sys.O_CREAT | sys.O_RDWR, 420))
  assert((assert(sys.fd_status(fd))) & sys.O_NONBLOCK == 0)
  assert(sys.set_nonblocking(fd, true))
  assert((assert(sys.fd_status(fd))) & sys.O_NONBLOCK ~= 0)
  assert(sys.set_nonblocking(fd, false))
  assert((assert(sys.fd_status(fd))) & sys.O_NONBLOCK == 0)
  assert(sys.close(fd))
  local flags, why, errno = sys.fd_status(fd)
  assert(flags == nil and why ~= "" and errno == sys.EBADF, tostring(why))
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
--- rather than lumped together as "other". No test reaches "block", or
--- a device in a listing: a worker is given no block device, and no
--- directory of the system's to list.
local function test_stat_names_a_socket_a_fifo_and_a_device(tmp: string)
  if unix_socket.skipped(tmp) then return end
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
--- a socket file where `socket` says, and a link to each of the first two
--- and to nothing.
local function linked_directory(tmp: string, socket: boolean): string
  local d = tmp .. "/d"
  assert(sys.mkdir(d))
  sys.close(create(d .. "/file"))
  assert(sys.mkdir(d .. "/sub"))
  assert(sys.mkfifo(d .. "/fifo"))
  if socket then socket_file(d .. "/socket") end
  assert(sys.symlink("file", d .. "/to_file"))
  assert(sys.symlink("sub", d .. "/to_dir"))
  assert(sys.symlink("missing", d .. "/dangling"))
  return d
end

--- Checks readdir's answer for [`linked_directory`].
local function names_links_as_links(entries: {string:sys.Kind}, what: string, socket: boolean)
  assert(entries["file"] == "file" and entries["sub"] == "dir", what)
  assert(entries["fifo"] == "fifo", what .. ": a named pipe: " .. tostring(entries["fifo"]))
  if socket then
    assert(entries["socket"] == "socket", what .. ": a socket file: " .. tostring(entries["socket"]))
  end
  assert(entries["to_file"] == "link", what .. ": a link to a file: " .. tostring(entries["to_file"]))
  assert(entries["to_dir"] == "link", what .. ": a link to a directory: " .. tostring(entries["to_dir"]))
  assert(entries["dangling"] == "link", what .. ": a dangling link: " .. tostring(entries["dangling"]))
end

local function test_readdir_names_a_link_as_a_link_whatever_it_leads_to(tmp: string)
  names_links_as_links(assert(sys.readdir(linked_directory(tmp, false))), "readdir", false)
end

--- A socket file in a listing is named a socket.
local function test_readdir_names_a_socket_file_a_socket(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local d = linked_directory(tmp, true)
  names_links_as_links(assert(sys.readdir(d)), "readdir", true)
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

--- A child has a descriptor table of its own, though it starts on this
--- process's memory on Linux: the descriptors closed and moved to hand
--- its program the ones asked for, and a later step that fails, leave
--- every one of this process's as it was.
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

--- A descriptor this process holds open across exec reaches a child
--- only where the child is handed it: one below the highest handed and
--- one above it are closed there, and one handed as its own number is
--- open.
local function test_a_child_is_handed_only_the_descriptors_asked_for(tmp: string)
  local probe = probe_in(tmp)
  local report = create(tmp .. "/report")
  local below, handed, kept, above = 110, 120, 121, 130
  for _, fd in ipairs({ below, handed, kept, above }) do
    failed_with(sys.EBADF, sys.fd_flags(fd))
    assert(sys.dup2(report, fd))
    assert(not closed_on_exec(fd))
  end
  local pid = assert(process.spawn(probe, { probe, "fd-closed " .. below .. "; fd-closed " ..
      above .. "; write-fd " .. handed .. " handed; write-fd " .. kept .. " kept" },
    nil, nil, nil, nil, nil, false, { [handed] = report, [kept] = kept }))
  local status = assert(process.waitpid(pid, false))
  assert(status.code == 0, tostring(status.code))
  assert(assert(sys.pread(report, 64, 0)) == "handed\nkept\n")
  for _, fd in ipairs({ below, handed, kept, above, report }) do sys.close(fd) end
end

--- A program named by a relative path is found from the directory its
--- child is given, absolute or relative, as exec in that directory
--- finds it.
local function test_a_relative_program_is_found_from_the_child_s_directory(tmp: string)
  assert(sys.mkdir(tmp .. "/bin", 0x1c0))
  assert(stand_in.place(probe_in(tmp), tmp .. "/bin/probe"))
  local function status_of(path: string, cwd: string): integer
    local pid = assert(process.spawn(path, { path, "exit 3" }, nil, cwd, nil, nil, nil, false))
    return assert(process.waitpid(pid, false)).code
  end
  assert(status_of("probe", tmp .. "/bin") == 3)
  assert(status_of("./probe", tmp .. "/bin") == 3)
  assert(status_of("bin/probe", tmp) == 3)
  local before = assert(sys.getcwd())
  assert(sys.chdir(tmp))
  -- Put the directory back before anything below can raise: every test
  -- after this one runs in this same process.
  local pid, trouble = process.spawn("../bin/probe", { "probe", "exit 3" }, nil, "bin", nil,
    nil, nil, false)
  sys.chdir(before)
  assert(pid ~= nil, trouble)
  assert(assert(process.waitpid(pid, false)).code == 3)
end

--- Two descriptors handed crosswise, each the other's number, reach the
--- child each at the number asked: neither move overwrites the source
--- the other reads.
local function test_descriptors_handed_crosswise_are_each_where_asked(tmp: string)
  local probe = probe_in(tmp)
  local first, second = 140, 141
  local files: {integer: integer} = {}
  for _, fd in ipairs({ first, second }) do
    failed_with(sys.EBADF, sys.fd_flags(fd))
    files[fd] = create(tmp .. "/" .. fd)
    assert(sys.dup2(files[fd], fd))
  end
  local pid = assert(process.spawn(probe, { probe, "write-fd " .. first .. " first; write-fd " ..
      second .. " second" }, nil, nil, nil, nil, nil, false, { [first] = second, [second] = first }))
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(assert(sys.pread(files[first], 64, 0)) == "second\n")
  assert(assert(sys.pread(files[second], 64, 0)) == "first\n")
  for fd, file in pairs(files) do
    sys.close(fd)
    sys.close(file)
  end
end

--- A child is put in a process group of its own only where asked.
local function test_a_child_s_process_group_is_its_own_where_asked(tmp: string)
  local probe = probe_in(tmp)
  local own = assert(sys.getpgid(0))
  for _, grouped in ipairs({ true, false }) do
    local pid = assert(process.spawn(probe, { probe, "sleep 10000" }, nil, nil, nil, nil, nil,
      grouped))
    local group = assert(sys.getpgid(pid))
    assert(sys.kill(pid, sys.SIGKILL))
    assert(assert(process.waitpid(pid, false)).signal == sys.SIGKILL)
    assert(group == (grouped and pid or own), tostring(group))
  end
end

--- A program that cannot be executed fails the start with exec's own
--- errno.
local function test_a_start_fails_with_the_errno_exec_failed_with(tmp: string)
  local plain = tmp .. "/plain"
  sys.close(create(plain))
  failed_with(sys.EACCES, process.spawn(plain, { plain }, nil, nil, nil, nil, nil, false))
  failed_with(sys.ENOENT, process.spawn(tmp .. "/missing", { "missing" }, nil, nil, nil, nil,
    nil, false))
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

--- The features `cpu_features` can answer, by machine.
local KNOWN_FEATURES <const>: {string:{string:boolean}} = {
  x86_64 = { aes = true, pclmulqdq = true, sse4_1 = true, ssse3 = true },
  aarch64 = { aes = true, asimd = true, crc32 = true, pmull = true },
  arm64 = { aes = true, asimd = true, crc32 = true, pmull = true },
}

--- `cpu_features` names each feature this processor has, of those it
--- can answer for its machine, once and in byte order, as
--- /proc/cpuinfo's "flags" or "Features" does where the worker has one
--- to read: its own procfs, a sandbox's, has none.
local function test_cpu_features_are_named_as_proc_cpuinfo_names_them()
  local names = assert(sys.uname())
  local known = KNOWN_FEATURES[names.machine] or {}
  local features = sys.cpu_features()
  for i, name in ipairs(features) do
    assert(known[name], names.machine .. " answers " .. name)
    assert(i == 1 or features[i - 1] < name, "not in byte order, or twice: " .. name)
  end
  local cpuinfo = read_file("/proc/cpuinfo")
  if cpuinfo == "" then return end
  local listed: {string:boolean} = {}
  for line in cpuinfo:gmatch("[^\n]+") do
    local flags = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (flags or ""):gmatch("%S+") do listed[flag] = true end
  end
  local expected: {string} = {}
  for name in pairs(known) do
    if listed[name] then expected[#expected + 1] = name end
  end
  table.sort(expected)
  assert(table.concat(features, " ") == table.concat(expected, " "),
    "cpu_features answers " .. table.concat(features, " ") .. ", /proc/cpuinfo lists " ..
      table.concat(expected, " "))
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
  assert(#names.release > 0, "release is nonempty")
  -- Stable across a call: this is the running host, not a moving target.
  local again = assert(sys.uname())
  assert(again.sysname == names.sysname and again.machine == names.machine and again.release == names.release)
end

--- On Darwin `getifaddrs` lists the loopback interface's 127.0.0.1/8 and
--- every address in numeric form with no zone, a link-local one without
--- the interface index the kernel writes into its second group; elsewhere
--- it fails ENOSYS.
local function test_getifaddrs_lists_the_loopback_on_darwin_and_fails_enosys_elsewhere()
  local listed, why, errno = sys.getifaddrs()
  if assert(sys.uname()).sysname ~= "Darwin" then
    assert(listed == nil and why ~= "" and errno == sys.ENOSYS, tostring(why))
    return
  end
  assert(listed ~= nil, why)
  local loopback = false
  for _, entry in ipairs(listed) do
    local shown = entry.name .. " " .. entry.address .. "/" .. entry.prefix
    assert(#entry.name > 0 and (entry.family == "ipv4" or entry.family == "ipv6"), shown)
    local bytes = Relay.Address.parse(entry.address)
    assert(bytes ~= nil and #bytes == (entry.family == "ipv4" and 4 or 16), shown)
    assert(entry.prefix >= 0 and entry.prefix <= #bytes * 8, shown)
    if #bytes == 16 and bytes[1] == 0xfe and bytes[2] & 0xc0 == 0x80 then
      assert(bytes[3] == 0 and bytes[4] == 0, "a link-local address keeps its scope: " .. shown)
    end
    if entry.address == "127.0.0.1" then
      assert(entry.loopback and entry.up and entry.prefix == 8 and entry.family == "ipv4", shown)
      loopback = true
    end
  end
  assert(loopback, "127.0.0.1 is listed")
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

--- The real group and the supplementary groups are those Linux's
--- /proc/self/status lists (its Gid line's first, its Groups line, each
--- in its own order); where there is no such file, each is at least an
--- id.
local function test_getgid_and_getgroups_answer_the_groups_the_process_runs_with()
  local gid = sys.getgid()
  local groups = assert(sys.getgroups())
  assert(math.type(gid) == "integer" and gid >= 0, tostring(gid))
  for _, group in ipairs(groups) do
    assert(math.type(group) == "integer" and group >= 0, tostring(group))
  end
  local status = read_file("/proc/self/status")
  if status == "" then return end
  assert(status:match("\nGid:%s+(%d+)") == tostring(gid), status)
  local listed: {string} = {}
  for group in (status:match("\nGroups:([^\n]*)") or ""):gmatch("%d+") do
    listed[#listed + 1] = group
  end
  local answered: {string} = {}
  for i, group in ipairs(groups) do answered[i] = tostring(group) end
  assert(table.concat(answered, " ") == table.concat(listed, " "),
    table.concat(answered, " ") .. " | " .. table.concat(listed, " "))
end

--- `setrlimit` holds the process to a soft limit `getrlimit` then
--- answers, which it can raise again to the hard one; it refuses a soft
--- limit above a finite hard one, and a negative limit, a resource past
--- an int or not a resource at all. Where the hard one is none, as
--- macOS's RLIMIT_NOFILE's is, a soft one of none is the system's to
--- refuse or to bound (macOS may do either), so it is only given back.
local function test_setrlimit_holds_the_process_to_what_getrlimit_answers()
  local limits = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  assert(limits.soft > 0 and limits.soft <= limits.hard, limits.soft .. " " .. limits.hard)
  local lower = limits.soft - 1
  assert(sys.setrlimit(sys.RLIMIT_NOFILE, lower, limits.hard))
  local lowered = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  assert(lowered.soft == lower and lowered.hard == limits.hard, lowered.soft .. " " .. lowered.hard)
  assert(sys.setrlimit(sys.RLIMIT_NOFILE, limits.soft, limits.hard))
  assert(assert(sys.getrlimit(sys.RLIMIT_NOFILE)).soft == limits.soft)
  if limits.hard ~= math.maxinteger then
    failed_with(sys.EINVAL, sys.setrlimit(sys.RLIMIT_NOFILE, limits.hard + 1, limits.hard))
    assert(assert(sys.getrlimit(sys.RLIMIT_NOFILE)).soft == limits.soft, "a refusal moved it")
  else
    local unbounded, why, errno = sys.setrlimit(sys.RLIMIT_NOFILE, math.maxinteger, limits.hard)
    assert(unbounded or errno == sys.EINVAL, why)
    assert(sys.setrlimit(sys.RLIMIT_NOFILE, limits.soft, limits.hard))
  end
  failed_with(sys.EINVAL, sys.getrlimit(99999))
  failed_with(sys.EINVAL, sys.setrlimit(99999, 1, 1))
  raises(sys.setrlimit, sys.RLIMIT_NOFILE, -1, limits.hard)
  raises(sys.setrlimit, sys.RLIMIT_NOFILE, limits.soft, -1)
  raises(sys.getrlimit, (1 << 32) + sys.RLIMIT_NOFILE)
  raises(sys.setrlimit, (1 << 32) + sys.RLIMIT_NOFILE, limits.soft, limits.hard)
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

--- Off Linux, listing a process's children has no implementation.
local function test_children_is_not_implemented_off_linux()
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("Linux has the children implementation")
  end
  local found, why, errno = process.children()
  assert(found == nil and errno == sys.ENOSYS, why)
end

--- Of a /proc/<pid>/uid_map or gid_map's text, whether it maps `id`
--- inside: what `maps_id` is checked against.
local function listed_in_map(text: string, id: integer): boolean
  for line in text:gmatch("[^\n]+") do
    local inside, _, count = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    local first, many = math.tointeger(tonumber(inside)), math.tointeger(tonumber(count))
    if first ~= nil and many ~= nil and id >= first and id < first + many then return true end
  end
  return false
end

--- `maps_id` answers whether this process's user namespace maps an id
--- as a user and as a group, as its maps list them: false with EINVAL
--- where either does not; off Linux, ENOSYS. An id no namespace can
--- map, -1 or past 32 bits, raises.
local function test_maps_id_answers_as_the_namespace_maps_list()
  local names = assert(sys.uname())
  local users, groups = read_file("/proc/self/uid_map"), read_file("/proc/self/gid_map")
  for _, id in ipairs({ 0, 1, sys.getuid(), 65532, 65534, 4294967294 }) do
    local ok, why, errno = process.maps_id(id)
    if names.sysname ~= "Linux" then
      assert(not ok and errno == sys.ENOSYS, why)
    elseif listed_in_map(users, id) and listed_in_map(groups, id) then
      assert(ok, id .. ": " .. tostring(why))
    else
      failed(ok, why, errno)
      assert(errno == sys.EINVAL, id .. ": " .. tostring(why))
    end
  end
  raises(process.maps_id, -1)
  raises(process.maps_id, 4294967295)
end

--- `may_map_ids` answers whether this process is root holding
--- CAP_SETGID (6), CAP_SETUID (7) and CAP_SETFCAP (31) in effect, as
--- /proc/self/status says: false with EPERM where it is not; off Linux,
--- ENOSYS.
local function test_may_map_ids_answers_as_the_status_says()
  local ok, why, errno = process.may_map_ids()
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then
    assert(not ok and errno == sys.ENOSYS, why)
    return
  end
  local status = read_file("/proc/self/status")
  local effective = assert(status:match("\nUid:%s+%d+%s+(%d+)"), status)
  local caps = assert(math.tointeger(tonumber(assert(status:match("\nCapEff:%s+(%x+)")):sub(-8), 16)))
  local root = effective == "0" and (caps >> 6) & 1 == 1 and (caps >> 7) & 1 == 1 and
    (caps >> 31) & 1 == 1
  if root then
    assert(ok, why)
  else
    failed(ok, why, errno)
    assert(errno == sys.EPERM, why)
  end
end

--- `own_proc` answers whether a sandbox gets a procfs of its own here:
--- true, or false with the errno the kernel refused one with -- as it
--- does a worker a Landlock ruleset holds, which may mount nothing --
--- and off Linux, ENOSYS. That a sandbox then gets what it says is
--- build/confine_test.tl's.
local function test_own_proc_answers_or_says_why_not()
  local ok, why, errno = process.own_proc()
  if assert(sys.uname()).sysname ~= "Linux" then
    assert(not ok and errno == sys.ENOSYS, why)
  elseif not ok then
    failed(ok, why, errno)
  end
end

--- `sandbox_platform` answers true on Linux, the one platform with a
--- sandbox, whatever this host refuses of it, and false with ENOSYS
--- elsewhere.
local function test_sandbox_platform_answers_true_on_linux_alone()
  local ok, why, errno = process.sandbox_platform()
  if assert(sys.uname()).sysname == "Linux" then
    assert(ok == true and why == nil, why)
  else
    failed(ok, why, errno)
    assert(errno == sys.ENOSYS, why)
  end
end

--- Where the platform has no sandbox, a Landlock ruleset, a hold on what
--- may run and a pledge are each refused, with the errno the platform
--- answers. On Linux, whatever this host refuses of the sandbox, they are
--- the tests of core/syscalls_landlock_test.tl and core/syscalls_pledge_test.tl,
--- which require it: so this returns there, and only the platforms without
--- one answer.
local function test_a_sandbox_the_platform_lacks_is_refused(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local probe = probe_in(tmp)
  local ruleset, trouble, errno = process.landlock_ruleset({ probe }, {})
  assert(ruleset == nil and (errno == sys.ENOSYS or errno == sys.EOPNOTSUPP or errno == sys.EPERM),
    tostring(trouble))
  local held, hold_trouble, hold_errno = process.landlock_restrict_execute({ tmp })
  assert(not held and (hold_errno == sys.ENOSYS or hold_errno == sys.EOPNOTSUPP or
    hold_errno == sys.EPERM), tostring(hold_trouble))
  for _, promises in ipairs({ {}, { "unix", "inet" } }) do
    local pid, why, pledge_errno = process.spawn(probe, { probe }, nil, nil, nil, nil, nil,
      false, nil, { pledge = promises })
    assert(pid == nil and pledge_errno == sys.ENOSYS, tostring(why))
  end
end

--- A promise no one keeps is refused before anything starts, on every
--- platform.
local function test_a_pledge_no_one_keeps_is_refused_before_a_start(tmp: string)
  local probe = probe_in(tmp)
  local refused = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil,
    false, nil, { pledge = { "fly" } })
  assert(not refused, "a promise no one keeps is refused")
end

--- The calls that start and reap a child, and hold this process's
--- signals while it does, are the raw process table's, and not the
--- public [`cosmic.sys`]'s: a public `waitpid(-1)` would take the status
--- of a child a `Child` handle owns from under it, and a public signal
--- guard would be a second one beside [`Signal.guard`]'s. `poll` and
--- `set_nonblocking`, which wait on any descriptor, are the public
--- table's alone.
local function test_the_process_calls_are_off_the_public_table()
  local public: {string: any} = sys as {string: any} -- cast: to look a member up by name
  local raw: {string: any} = process as {string: any} -- cast: to look a member up by name
  for _, name in ipairs({ "spawn", "waitpid", "subreaper", "sandbox_inits", "children", "maps_id",
      "may_map_ids", "own_proc", "sandbox_platform", "relaunch", "pipe",
      "ignore_sigpipe", "landlock_ruleset", "landlock_abi", "exit_watch",
      "landlock_restrict_execute",
      "guard_child_signals", "unguard_child_signals", "child_signal_read", "child_signal_fd" }) do
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

--- A hangup and a descriptor not open are answered in every entry of a
--- descriptor given twice, whatever each asked for.
local function test_poll_answers_a_hangup_and_a_closed_descriptor_in_every_entry()
  local ends = assert(process.pipe())
  sys.close(ends.writer)
  local closed = assert(sys.dup(ends.reader))
  sys.close(closed)
  local revents = assert(sys.poll({ ends.reader, ends.reader, closed, closed },
    { sys.POLLIN, sys.POLLOUT, sys.POLLIN, sys.POLLOUT }, 0))
  sys.close(ends.reader)
  local said = table.concat(revents as {number}, " ") -- cast: an integer is a number
  assert(revents[1] & sys.POLLHUP ~= 0 and revents[2] & sys.POLLHUP ~= 0, said)
  assert(revents[3] & sys.POLLNVAL ~= 0 and revents[4] & sys.POLLNVAL ~= 0, said)
end

--- `poll` watches as many descriptors as the kernel lets a process
--- watch, past the 1024 it was once held to, and -1 is left unwatched.
--- Each is a distinct copy of one pipe's reading end, since a descriptor
--- given more than once goes to the kernel once. RLIMIT_NOFILE's soft
--- limit is raised for them first where it is lower (1024 under
--- systemd's default, 256 on macOS), and put back after; a hard limit
--- too low to raise it to fails the test.
--- Closes `fds` and puts RLIMIT_NOFILE's `limits` back when it leaves
--- scope, so a failed assertion leaves neither behind for the next test.
local record Restored
  fds: {integer}
  limits: sys.Limits
  metamethod __close: function(Restored)
end

local restored_mt: metatable<Restored> = {
  __close = function(r: Restored)
    for _, fd in ipairs(r.fds) do sys.close(fd) end
    assert(sys.setrlimit(sys.RLIMIT_NOFILE, r.limits.soft, r.limits.hard))
  end,
}

local function test_poll_watches_past_a_thousand_descriptors()
  local wanted <const> = 1100
  local limits = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  local held <close> = setmetatable({ fds = {}, limits = limits } as Restored, restored_mt)
  -- Room for the copies beside whatever the worker holds open already.
  local room = math.min(wanted + 256, limits.hard)
  if limits.soft < room then assert(sys.setrlimit(sys.RLIMIT_NOFILE, room, limits.hard)) end
  local ends = assert(process.pipe())
  held.fds[1], held.fds[2] = ends.reader, ends.writer
  assert(sys.write(ends.writer, "x") == 1)
  local fds: {integer} = {}
  local events: {integer} = {}
  local trouble: string
  while #fds < wanted do
    local copy: integer
    copy, trouble = sys.dup(ends.reader)
    if copy == nil then break end
    fds[#fds + 1] = copy
    held.fds[#held.fds + 1] = copy
    events[#events + 1] = sys.POLLIN
  end
  assert(#fds == wanted, #fds .. " copies under a hard limit of " .. limits.hard ..
      ": " .. tostring(trouble))
  fds[#fds + 1] = -1
  events[#events + 1] = sys.POLLIN
  assert(not pcall(sys.poll, { -2 }, { sys.POLLIN }, 0), "a descriptor below -1 raises")
  local revents, failure = sys.poll(fds, events, 0)
  assert(revents ~= nil, failure)
  assert(#revents == wanted + 1, "one answer per descriptor, not " .. #revents)
  for i = 1, wanted do
    assert(revents[i] & sys.POLLIN ~= 0, "descriptor " .. i .. " answered " .. revents[i])
  end
  assert(revents[wanted + 1] == 0, "an unwatched descriptor answered " .. revents[wanted + 1])
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
--- (build.confine's `runtime_paths`): one without it is skipped, which
--- only the running worker can tell; macOS has no /dev/full, so there is
--- nothing to check and no requirement names Linux alone.
local function test_a_tree_digest_of_dev_full_is_not_special()
  if sys.stat("/dev/full") == nil then
    if assert(sys.uname()).sysname == "Linux" then Test.skip("this worker has no /dev/full") end
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

--- `flock_kind` says whether a flock and an fcntl lock -- SQLite's --
--- exclude each other: with an exclusive flock held through one open of
--- a file, SQLite's write lock through another is taken where they are
--- "apart" and refused where they are "shared". A descriptor not open
--- fails, EBADF.
local function test_flock_kind_says_whether_a_flock_excludes_an_fcntl_lock(tmp: string)
  local path = tmp .. "/lock.db"
  local fd = assert(sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x180))
  local kind, trouble = sys.flock_kind(fd)
  assert(kind == "apart" or kind == "shared", trouble)
  assert(sys.flock(fd, "exclusive"))
  local db = assert(Sqlite.open(path, { writable = true }))
  -- Asked once: a connection waits a minute for a lock by default.
  assert(db:exec("PRAGMA busy_timeout = 0"))
  local taken, why = db:exec("BEGIN IMMEDIATE")
  assert(taken == (kind == "apart"), kind .. ": " .. tostring(why))
  assert(db:close())
  assert(sys.close(fd))
  local none, said, errno = sys.flock_kind(fd)
  failed(none, said, errno)
  assert(errno == sys.EBADF, said)
end

--- Whether the wake pipe of the open guards has a byte to read.
local function woken(fd: integer): boolean
  local revents = assert(sys.poll({ fd }, { sys.POLLIN }, 0))
  return revents[1] & sys.POLLIN ~= 0
end

--- Guards nest. A signal moves the stamp every guard reads and wakes
--- the pipe; the handler stays until the last guard closes, which
--- closes the pipe. Closing the inner guard hands the waits to the
--- outer, which has not read the signal the inner did: a lock's wait
--- ends at it then, though it did not under the inner guard.
local function test_signal_guards_nest_and_the_outer_sees_what_the_inner_read(tmp: string)
  local unit = process.SIGNAL_STAMP_UNIT
  local path = tmp .. "/lock"
  local first = assert(sys.open(path, sys.O_RDONLY | sys.O_CREAT, 0x180))
  local second = assert(sys.open(path, sys.O_RDONLY, 0))
  assert(sys.flock(first, "exclusive"))
  local outer = assert(process.guard_child_signals())
  local fd = process.child_signal_fd()
  assert(fd >= 0 and not woken(fd))
  local inner = assert(process.guard_child_signals())
  assert(inner == outer and process.child_signal_fd() == fd)
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  assert(woken(fd), "a caught signal left the pipe unreadable")
  local seen = process.child_signal_read(true)
  assert(seen > outer and seen % unit == sys.SIGTERM, tostring(seen))
  local ok, why, errno = sys.flock(second, "exclusive", 50)
  assert(not ok and sys.errno_name(errno) == "ETIMEDOUT", why)
  assert(process.unguard_child_signals(outer) == seen)
  assert(process.child_signal_fd() == fd, "an inner close closed the pipe")
  ok, why, errno = sys.flock(second, "exclusive", -1)
  assert(not ok and errno == sys.EINTR, why)
  -- Still caught, not acted on: the process outlives it.
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local later = process.child_signal_read(true)
  assert(later // unit == seen // unit + 1 and later % unit == sys.SIGINT, tostring(later))
  assert(process.unguard_child_signals(0) == later)
  assert(process.child_signal_fd() == -1)
  assert(process.unguard_child_signals(0) == later, "a close with none open closes nothing")
  assert(sys.close(first))
  assert(sys.close(second))
end

--- An inner guard sees nothing of a signal caught before it opened: a
--- lock's wait under it runs to its timeout.
local function test_an_inner_signal_guard_sees_no_earlier_signal(tmp: string)
  local path = tmp .. "/lock"
  local first = assert(sys.open(path, sys.O_RDONLY | sys.O_CREAT, 0x180))
  local second = assert(sys.open(path, sys.O_RDONLY, 0))
  assert(sys.flock(first, "exclusive"))
  local outer = assert(process.guard_child_signals())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local inner = assert(process.guard_child_signals())
  assert(inner > outer)
  local ok, why, errno = sys.flock(second, "exclusive", 50)
  assert(not ok and sys.errno_name(errno) == "ETIMEDOUT", why)
  assert(process.unguard_child_signals(outer))
  assert(process.unguard_child_signals(0))
  assert(sys.close(first))
  assert(sys.close(second))
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
  local caught = assert(process.unguard_child_signals(0))
  assert(caught % process.SIGNAL_STAMP_UNIT == sys.SIGINT, tostring(caught))
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

--- Full storage flush is an explicit Darwin operation, not an alias for
--- fsync elsewhere. The file remains the caller's on either outcome.
local function test_full_fsync_has_native_or_unsupported_effect_shape(tmp: string)
  local fd = create(tmp .. "/full-flush")
  assert(sys.write(fd, "data"))
  local ok, trouble, errno = sys.full_fsync(fd)
  local names = assert(sys.uname())
  if names.sysname == "Darwin" then
    assert(ok == true and trouble == nil and errno == nil, tostring(trouble))
  else
    assert(ok == false, "unsupported full flush must not report success")
    failed_with(sys.ENOSYS, ok, trouble, errno)
  end
  assert(sys.fstat(fd), "full_fsync closed its caller's descriptor")
  assert(Fs.fsync(fd), "ordinary Fs.fsync remains available")
  assert(sys.close(fd))
  local closed, why, number = sys.full_fsync(fd)
  assert(closed == false, "a closed descriptor must not be flushed")
  failed_with(names.sysname == "Darwin" and sys.EBADF or sys.ENOSYS, closed, why, number)
end

--- Descriptor validation precedes platform dispatch, including on hosts
--- that do not implement the operation.
local function test_full_fsync_validates_its_descriptor()
  raises(sys.full_fsync, {})
  raises(sys.full_fsync, 1.5)
  raises(sys.full_fsync, 1 << 40)
end

--- The raw boundary validates both IDs independently of Child.Options.
local function test_spawn_credentials_reject_incomplete_and_reserved_ids()
  for index, credentials in ipairs({
      {}, { user = 1 }, { group = 1 }, { user = 0, group = 1 },
      { user = 1, group = -1 }, { user = 4294967295, group = 1 },
      { user = 1.5, group = 1 } as raw_process.Credentials,
  } as {raw_process.Credentials}) do
    local ok, why = pcall(process.spawn, "/never-started", { "/never-started" },
      nil, nil, nil, nil, nil, false, nil, nil, credentials)
    assert(not ok and tostring(why):find("credentials", 1, true), tostring(index) .. ": " .. tostring(why))
  end
  local ok, why = pcall(process.spawn, "/never-started", { "/never-started" },
    nil, nil, nil, nil, nil, false, nil, { offline = true }, { user = 1, group = 1 })
  assert(not ok and tostring(why):find("credentials exclude", 1, true), tostring(why))
end

--- Even when the platform or caller cannot set credentials, refusal
--- retains spawn's runtime-error shape and never executes the target.
local function test_spawn_credentials_runtime_refusal(tmp: string)
  local probe = probe_in(tmp)
  local marker = tmp .. "/credential-exec"
  local pid, trouble, errno = process.spawn(probe, { probe, "append " .. marker .. " wrong" },
    nil, tmp .. "/absent", nil, nil, nil, false, nil, nil, { user = 65532, group = 65532 })
  failed(pid, trouble, errno)
  assert(not Fs.exists(marker))
end

--- What spawn raises for `sandbox` taken as a raw table, malformed.
local function refused_sandbox(fields: {string:any}): string
  local ok, trouble = pcall(process.spawn, "/missing", { "/missing" }, nil, nil,
    nil, nil, nil, false, nil, fields as raw_process.Sandbox) -- cast: malformed input exercises raw validation
  assert(not ok, "spawn took a malformed sandbox")
  return tostring(trouble)
end

local function test_a_policys_sandbox_fields_are_checked_before_a_start()
  local function says(trouble: string, text: string)
    assert(trouble:find(text, 1, true), trouble)
  end
  says(refused_sandbox({ strict = "yes" }), "strict must be a boolean")
  says(refused_sandbox({ proc = 1 }), "proc must be a boolean")
  says(refused_sandbox({ proc = true, unveil = { reads = { "/" } } }),
    "proc and unveil exclude each other")
  says(refused_sandbox({ sockets = { "inet" } }), "sockets require promises")
  says(refused_sandbox({ promises = {}, sockets = { "packet" } }), "a socket family is")
  says(refused_sandbox({ promises = {}, sockets = { "inet" } }), "sockets require offline")
  says(refused_sandbox({ relay = { fd = 3 } }), "relay requires offline")
  says(refused_sandbox({ relay = 3 }), "relay must be a table")
  says(refused_sandbox({ relay = {}, offline = true }), "relay's fd must be a descriptor")
  says(refused_sandbox({ relay = { fd = -1 }, offline = true }), "relay's fd is out of range")
  says(refused_sandbox({ relay = { fd = 2 }, offline = true }), "relay's fd is out of range")
  says(refused_sandbox({ relay = { fd = 3, ports = { 4000, 4000 } }, offline = true }),
    "a relay's two ports differ")
  says(refused_sandbox({ relay = { fd = 3, ports = { 1 } }, offline = true }),
    "relay's ports are two ports")
  says(refused_sandbox({ relay = { fd = 3, ports = { 1, "x" } }, offline = true }),
    "a relay port is an integer")
  says(refused_sandbox({ relay = { fd = 3, ports = { 0, 1 } }, offline = true }),
    "a relay port is 1 to 65535")
  says(refused_sandbox({ relay = { fd = 3, ports = { 1, 65536 } }, offline = true }),
    "a relay port is 1 to 65535")
  says(refused_sandbox({ unveil = { tmp = 4096 } }), "unveil's tmp requires strict")
  says(refused_sandbox({ promises = {}, sockets = "inet" }), "sockets must be a list")
  says(refused_sandbox({ unveil = { tmp = 0 } }), "unveil's tmp is a size in bytes")
  says(refused_sandbox({ unveil = { tmp = "big" } }), "unveil's tmp is a size in bytes")
  says(refused_sandbox({ unveil = { tmp_exec = 1 } }), "unveil's tmp_exec must be a boolean")
  says(refused_sandbox({ unveil = { tmp_exec = true } }), "unveil's tmp_exec requires tmp")
end

local function test_unveils_binds_are_checked_before_a_start()
  local function says(binds: any, text: string)
    local trouble = refused_sandbox({ unveil = { binds = binds } })
    assert(trouble:find(text, 1, true), trouble)
  end
  says("/x", "unveil's binds must be a list")
  says({ "/x" }, "a bind is a table")
  says({ { path = "x" } }, "a bind's path must be absolute")
  says({ { path = "/x", at = "relative" } }, "a bind is at an absolute name")
  says({ { path = "/x", at = "/" } }, "a bind is at an absolute name")
  says({ { path = "/x", at = "/.old/y" } }, "no name beneath /.old")
  says({ { path = "/x", at = "/y" }, { path = "/z", at = "/y" } }, "two paths are bound at one name")
end

local function test_noexec_scratch_requires_a_boolean_and_unveiling()
  local invalid: {any} = { "yes", 1, {} }
  for _, value in ipairs(invalid) do
    local sandbox: raw_process.Sandbox = {}
    local fields = sandbox as {string:any} -- cast: malformed input exercises raw validation
    fields.noexec_scratch = value
    local ok, trouble = pcall(process.spawn, "/missing", { "/missing" }, nil, nil,
      nil, nil, nil, false, nil, sandbox)
    assert(not ok and tostring(trouble):find("noexec_scratch must be a boolean", 1, true),
      tostring(trouble))
  end
  local ok, trouble = pcall(process.spawn, "/missing", { "/missing" }, nil, nil,
    nil, nil, nil, false, nil, { noexec_scratch = true })
  assert(not ok and tostring(trouble):find("noexec_scratch requires unveil", 1, true),
    tostring(trouble))
end
