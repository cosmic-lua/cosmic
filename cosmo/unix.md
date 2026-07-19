# unix

Type declarations for the `unix` module.

## Types

### Uname

 Fields reported by uname(2).

```teal
local record Uname
  sysname: string
  nodename: string
  release: string
  version: string
  machine: string
  domainname: string
end
```

### Termios

```teal
local record Termios
  --  Input mode flags (e.g. `unix.BRKINT`, `unix.ICRNL`).
  iflag: integer
  --  Output mode flags (e.g. `unix.OPOST`, `unix.ONLCR`).
  oflag: integer
  --  Control mode flags (e.g. `unix.CS8`, `unix.CREAD`).
  cflag: integer
  --  Local mode flags (e.g. `unix.ECHO`, `unix.ICANON`).
  lflag: integer
  --  Control characters array (indexed 1 to `unix.NCCS`).
  cc: {integer}
  --  Input baud rate.
  ispeed: integer
  --  Output baud rate.
  ospeed: integer
end
```

### Memory

 Shared memory for inter-process communication.
 Provides atomic operations and wait/wake primitives for synchronization.
 unix.Memory encapsulates memory that's shared across fork() and
 this module provides the fundamental synchronization primitives.
 Redbean memory maps may be used in two ways:
 1. as an array of bytes a.k.a. a string
 2. as an array of words a.k.a. integers
 They're aliased, union, or overlapped views of the same memory.
 For example if you write a string to your memory region, you'll
 be able to read it back as an integer.
 Reads, writes, and word operations will throw an exception if a
 memory boundary error or overflow occurs.

```teal
local record Memory
  --  The starting byte index from which memory is copied, which defaults to zero.
  --  If `bytes` is none or nil, then the nul-terminated string at
  --  `offset` is returned. You may specify `bytes` to safely read
  --  binary data.
  --  This operation happens atomically. Each shared mapping has a
  --  single lock which is used to synchronize reads and writes to
  --  that specific map. To make it scale, create additional maps.
  read: function(self: Memory, offset?: integer, bytes?: integer): string
  --  Writes bytes to memory region.
  --  `offset` is the starting byte index to which memory is copied,
  --  which defaults to zero.
  --  If `bytes` is none or nil, then an implicit nil-terminator
  --  will be included after your `data` so things like json can
  --  be easily serialized to shared memory.
  --  This operation happens atomically. Each shared mapping has a
  --  single lock which is used to synchronize reads and writes to
  --  that specific map. To make it scale, create additional maps.
  write: function(self: Memory, data: string, offset?: integer, bytes?: integer)
  --  Loads word from memory region.
  --  This operation is atomic and has relaxed barrier semantics.
  load: function(self: Memory, word_index: integer): integer
  --  Stores word from memory region.
  --  This operation is atomic and has relaxed barrier semantics.
  store: function(self: Memory, word_index: integer, value: integer)
  --  Exchanges value.
  --  This sets word at `word_index` to `value` and returns the value
  --  previously held in by the word.
  --  This operation is atomic and provides the same memory barrier
  --  semantics as the aligned x86 LOCK XCHG instruction.
  xchg: function(self: Memory, word_index: integer, value: integer): integer
  --  Compares and exchanges value.
  --  This inspects the word at `word_index` and if its value is the same
  --  as `old` then it'll be replaced by the value `new`, in which case
  --  `true, old` shall be returned. If a different value was held at
  --  word, then `false` shall be returned along with the word.
  --  This operation happens atomically and provides the same memory
  --  barrier semantics as the aligned x86 LOCK CMPXCHG instruction.
  cmpxchg: function(self: Memory, word_index: integer, old: integer, new: integer): boolean, integer
  --  Fetches then adds value.
  --  This method modifies the word at `word_index` to contain the sum of
  --  value and the `value` paremeter. This method then returns the value
  --  as it existed before the addition was performed.
  --  This operation is atomic and provides the same memory barrier
  --  semantics as the aligned x86 LOCK XADD instruction.
  fetch_add: function(self: Memory, word_index: integer, value: integer): integer
  --  Fetches and bitwise ands value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_and: function(self: Memory, word_index: integer, value: integer): integer
  --  Fetches and bitwise ors value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_or: function(self: Memory, word_index: integer, value: integer): integer
  --  Fetches and bitwise xors value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_xor: function(self: Memory, word_index: integer, value: integer): integer
  --  Waits for word to have a different value.
  --  This method asks the kernel to suspend the process until either the
  --  absolute deadline expires or we're woken up by another process that
  --  calls `unix.Memory:wake()`.
  --  The `expect` parameter is used only upon entry to synchronize the
  --  transition to kernelspace. The kernel doesn't actually poll the
  --  memory location. It uses `expect` to make sure the process doesn't
  --  get added to the wait list unless it's sure that it needs to wait,
  --  since the kernel can only control the ordering of wait / wake calls
  --  across processes.
  --  Futex words are 32-bit. Although words are stored as 64-bit integers,
  --  wait / wake only ever inspect the low 32 bits, so `expect` must fit in
  --  an int32 and the word you wait on must hold only int32 values. If the
  --  word at `word_index` has any of its high 32 bits set when you call
  --  wait, this method raises an error rather than silently comparing a
  --  truncated value (e.g. a stored 2^32+1 must not masquerade as 1).
  --  The default behavior is to wait until the heat death of the universe
  --  if necessary. You may alternatively specify an absolute deadline. If
  --  it's less than or equal to the value returned by clock_gettime, then
  --  this routine is non-blocking. Otherwise we'll block at most until
  --  the current time reaches the absolute deadline.
  --  Futexes are currently supported on Linux, FreeBSD, OpenBSD. On other
  --  platforms this method calls sched_yield() and will either (1) return
  --  unix.EINTR if a deadline is specified, otherwise (2) 0 is returned.
  --  This means futexes will *work* on Windows, Mac, and NetBSD but they
  --  won't be scalable in terms of CPU usage when many processes wait on
  --  one process that holds a lock for a long time. In the future we may
  --  polyfill futexes in userspace for these platforms to improve things
  --  for folks who've adopted this api. If lock scalability is something
  --  you need on Windows and MacOS today, then consider fcntl() which is
  --  well-supported on all supported platforms but requires using files.
  --  Please test your use case though, because it's kind of an edge case
  --  to have the scenario above, and chances are this op will work fine.
  --  `EINTR` if a signal is delivered while waiting on deadline. Callers
  --  should use futexes inside a loop that is able to cope with spurious
  --  wakeups. We don't actually guarantee the value at word has in fact
  --  changed when this returns.
  --  `EAGAIN` is raised if, upon entry, the word at `word_index` had a
  --  different value than what's specified at `expect`.
  --  `ETIMEDOUT` is raised when the absolute deadline expires.
  wait: function(self: Memory, word_index: integer, expect: integer, abs_deadline?: integer, nanos?: integer): integer | nil, string | nil, Errno | nil
  --  Wakes other processes waiting on word.
  --  This method may be used to signal or broadcast to waiters. The
  --  `count` specifies the number of processes that should be woken,
  --  which defaults to `INT_MAX`.
  --  The return value is the number of processes that were actually woken
  --  as a result of the system call. No failure conditions are defined.
  wake: function(self: Memory, index: integer, count?: integer): integer
  --  Releases the shared-memory mapping immediately, instead of waiting
  --  for the garbage collector to do it. Idempotent: repeat calls are
  --  no-ops. After unmap, calling any other method on this object raises
  --  an error rather than touching the freed memory.
  unmap: function(self: Memory): boolean
end
```

### Dir

 Directory handle for reading directory entries.
 `unix.Dir` objects are created by `opendir()` or `fdopendir()`.

```teal
local record Dir
  --  Closes directory stream object and associated its file descriptor.
  --  This is called automatically by the garbage collector.
  --  This may be called multiple times.
  close: function(self: Dir): boolean | nil, string | nil, Errno | nil
  --  Reads entry from directory stream.
  --  Returns `nil` if there are no more entries.
  --  On error, `nil` will be returned and `errno` will be non-nil.
  --  `kind` can be any of:
  --  - `DT_REG`: file is a regular file
  --  - `DT_DIR`: file is a directory
  --  - `DT_BLK`: file is a block device
  --  - `DT_LNK`: file is a symbolic link
  --  - `DT_CHR`: file is a character device
  --  - `DT_FIFO`: file is a named pipe
  --  - `DT_SOCK`: file is a named socket
  --  - `DT_UNKNOWN`
  --  Note: This function also serves as the `__call` metamethod, so that
  --  `unix.Dir` objects may be used as a for loop iterator.
  read: function(self: Dir): string | nil, integer, integer, integer
  --  Returns `EOPNOTSUPP` if using a `/zip/...` path or if using Windows NT.
  fd: function(self: Dir): integer | nil, string | nil, Errno | nil
  tell: function(self: Dir): integer | nil, string | nil, Errno | nil
  --  Resets stream back to beginning.
  rewind: function(self: Dir)
end
```

### Rusage

 Process resource usage statistics.
 Contains CPU time, memory usage, I/O, and context switch counters.
 `unix.Rusage` objects are created by `wait()` or `getrusage()`.

```teal
local record Rusage
  --  It's always the case that `0 ≤ nanos < 1e9`.
  --  On Windows NT this is collected from GetProcessTimes().
  utime: function(self: Rusage): integer, integer
  --  It's always the case that `0 ≤ nanos < 1e9`.
  --  On Windows NT this is collected from GetProcessTimes().
  stime: function(self: Rusage): integer, integer
  --  On Windows NT this is collected from
  --  `NtProcessMemoryCountersEx::PeakWorkingSetSize / 1024`.
  maxrss: function(self: Rusage): integer
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as `unix.CLK_TCK`.  Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  Currently only available on FreeBSD and NetBSD.
  idrss: function(self: Rusage): integer
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as unix.CLK_TCK.  Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  Currently only available on FreeBSD and NetBSD.
  ixrss: function(self: Rusage): integer
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as `unix.CLK_TCK`. Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  This is only applicable to redbean if its built with MODE=tiny,
  --  because redbean likes to allocate its own deterministic stack.
  --  Currently only available on FreeBSD and NetBSD.
  isrss: function(self: Rusage): integer
  --  This number indicates how many times redbean was preempted by the
  --  kernel to `memcpy()` a 4096-byte page. This is one of the tradeoffs
  --  `fork()` entails. This number is usually tinier, when your binaries
  --  are tinier.
  --  Not available on Windows NT.
  minflt: function(self: Rusage): integer
  --  Returns number of major page faults.
  --  This number indicates how many times redbean was preempted by the
  --  kernel to perform i/o. For example, you might have used `mmap()` to
  --  load a large file into memory lazily.
  --  On Windows NT this is `NtProcessMemoryCountersEx::PageFaultCount`.
  majflt: function(self: Rusage): integer
  --  Operating systems like to reserve hard disk space to back their RAM
  --  guarantees, like using a gold standard for fiat currency. When your
  --  system is under heavy memory load, swap operations may happen while
  --  redbean is working. This number keeps track of them.
  --  Not available on Linux, Windows NT.
  nswap: function(self: Rusage): integer
  --  On Windows NT this is `NtIoCounters::ReadOperationCount`.
  inblock: function(self: Rusage): integer
  --  On Windows NT this is `NtIoCounters::WriteOperationCount`.
  oublock: function(self: Rusage): integer
  --  Not available on Linux, Windows NT.
  msgsnd: function(self: Rusage): integer
  --  Not available on Linux, Windows NT.
  msgrcv: function(self: Rusage): integer
  --  Not available on Linux.
  nsignals: function(self: Rusage): integer
  --  This number is a good thing. It means your redbean finished its work
  --  quickly enough within a time slice that it was able to give back the
  --  remaining time to the system.
  nvcsw: function(self: Rusage): integer
  --  This number is a bad thing. It means your redbean was preempted by a
  --  higher priority process after failing to finish its work, within the
  --  allotted time slice.
  nivcsw: function(self: Rusage): integer
end
```

### Stat

 File metadata and attributes.
 Contains file size, permissions, ownership, and timestamps.
 `unix.Stat` objects are created by `stat()` or `fstat()`.
 Use `unix.S_ISDIR()`, `unix.S_ISREG()`, etc. to check file type from mode.

```teal
local record Stat
  size: function(self: Stat): integer
  --  Contains file type and permissions.
  --  For example, `0010644` is what you might see for a file and
  --  `0040755` is what you might see for a directory.
  --  To determine the file type:
  --  - `unix.S_ISREG(st:mode())` means regular file
  --  - `unix.S_ISDIR(st:mode())` means directory
  --  - `unix.S_ISLNK(st:mode())` means symbolic link
  --  - `unix.S_ISCHR(st:mode())` means character device
  --  - `unix.S_ISBLK(st:mode())` means block device
  --  - `unix.S_ISFIFO(st:mode())` means fifo or pipe
  --  - `unix.S_ISSOCK(st:mode())` means socket
  mode: function(self: Stat): integer
  uid: function(self: Stat): integer
  gid: function(self: Stat): integer
  --  File birth time.
  --  This field should be accurate on Apple, Windows, and BSDs. On Linux
  --  this is the minimum of atim/mtim/ctim. On Windows NT nanos is only
  --  accurate to hectonanoseconds.
  --  Here's an example of how you might print a file timestamp:
  --    st = assert(unix.stat('/etc/passwd'))
  --    unixts, nanos = st:birthtim()
  --    year,mon,mday,hour,min,sec,gmtoffsec = unix.localtime(unixts)
  --    Write('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.9d%+.2d%.2d % {
  --             year, mon, mday, hour, min, sec, nanos,
  --             gmtoffsec / (60 * 60), math.abs(gmtoffsec) % 60})
  birthtim: function(self: Stat): integer, integer
  mtim: function(self: Stat): integer, integer
  --  Please note that file systems are sometimes mounted with `noatime`
  --  out of concern for i/o performance. Linux also provides `O_NOATIME`
  --  as an option for open().
  --  On Windows NT this is the same as birth time.
  atim: function(self: Stat): integer, integer
  --  Means time file status was last changed on UNIX.
  --  On Windows NT this is the same as birth time.
  ctim: function(self: Stat): integer, integer
  --  This provides some indication of how much physical storage a file
  --  actually consumes. For example, for small file systems, your system
  --  might report this number as being 8, which means 4096 bytes.
  blocks: function(self: Stat): integer
  --  This field might be of assistance in computing optimal i/o sizes.
  --  Please note this field has no relationship to blocks, as the latter
  --  is fixed at a 512 byte size.
  blksize: function(self: Stat): integer
  --  This can be used to detect some other process used `rename()` to swap
  --  out a file underneath you, so you can do a refresh. redbean does it
  --  during each main process heartbeat for its own use cases.
  --  On Windows NT this is set to `NtByHandleFileInformation::FileIndex`.
  ino: function(self: Stat): integer
  --  On Windows NT this is set to `NtByHandleFileInformation::VolumeSerialNumber`.
  dev: function(self: Stat): integer
  --  This value may be set to `0` or `-1` for files that aren't devices,
  --  depending on the operating system. `unix.major()` and `unix.minor()`
  --  may be used to extract the device numbers.
  rdev: function(self: Stat): integer
  nlink: function(self: Stat): integer
  gen: function(self: Stat): integer
  flags: function(self: Stat): integer
end
```

### Statfs

 Filesystem statistics returned by `statfs()` and `fstatfs()`.

```teal
local record Statfs
  --  Returns filesystem type identifier.
  type: function(self: Statfs): integer
  --  Returns optimal transfer block size.
  bsize: function(self: Statfs): integer
  --  Returns total data blocks in filesystem.
  blocks: function(self: Statfs): integer
  --  Returns free blocks in filesystem.
  bfree: function(self: Statfs): integer
  --  Returns free blocks available to unprivileged user.
  bavail: function(self: Statfs): integer
  --  Returns total file nodes in filesystem.
  files: function(self: Statfs): integer
  --  Returns free file nodes in filesystem.
  ffree: function(self: Statfs): integer
  --  Returns filesystem ID as two numbers.
  fsid: function(self: Statfs): integer, integer
  --  Returns maximum length of filenames.
  namelen: function(self: Statfs): integer
  --  Returns fragment size.
  frsize: function(self: Statfs): integer
  --  Returns mount flags.
  flags: function(self: Statfs): integer
  --  Returns the owner of the mount.
  owner: function(self: Statfs): integer
  --  Returns the filesystem type name, e.g. "ext4".
  fstypename: function(self: Statfs): string
end
```

### Sigset

```teal
local record Sigset
  --  Adds signal to bitset.
  add: function(self: Sigset, sig: integer)
  --  Removes signal from bitset.
  remove: function(self: Sigset, sig: integer)
  --  Sets all bits in signal bitset to `true`.
  fill: function(self: Sigset)
  --  Sets all bits in signal bitset to `false`.
  clear: function(self: Sigset)
  contains: function(self: Sigset, sig: integer): boolean
  __repr: function(self: Sigset): string
  __tostring: function(self: Sigset): string
end
```

### unix Constants

Constants defined in the unix module.

```teal
local record unix Constants
  --  @type integer
  AF_INET: integer
  --  @type integer
  AF_UNIX: integer
  --  @type integer
  AF_UNSPEC: integer
  --  @type integer Returns maximum length of arguments for new processes.
  --  This is the character limit when calling `execve()`. It's the sum of
  --  the lengths of `argv` and `envp` including any nul terminators and
  --  pointer arrays. For example to see how much your shell `envp` uses
  --      $ echo $(($(env | wc -c) + 1 + ($(env | wc -l) + 1) * 8))
  --      758
  --  POSIX mandates this be 4096 or higher. On Linux this it's 128*1024.
  --  On Windows NT it's 32767*2 because CreateProcess lpCommandLine and
  --  environment block are separately constrained to 32,767 characters.
  --  Most other systems define this limit much higher.
  ARG_MAX: integer
  --  @type integer
  AT_EACCESS: integer
  --  @type integer
  AT_FDCWD: integer
  --  @type integer
  AT_SYMLINK_NOFOLLOW: integer
  --  @type integer Returns default buffer size.
  --  The UNIX module does not perform any buffering between calls.
  --  Each time a read or write is performed via the UNIX API your redbean
  --  will allocate a buffer of this size by default. This current default
  --  would be 4096 across platforms.
  BUFSIZ: integer
  --  @type integer Returns the scheduler frequency.
  --  This is granularity at which the kernel does work. For example, the
  --  Linux kernel normally operates at 100hz so its CLK_TCK will be 100.
  --  This value is useful for making sense out of unix.Rusage data.
  CLK_TCK: integer
  --  @type integer
  CLOCK_REALTIME: integer
  --  @type integer
  CLOCK_MONOTONIC: integer
  --  @type integer
  CLOCK_BOOTTIME: integer
  --  @type integer
  CLOCK_MONOTONIC_RAW: integer
  --  @type integer
  CLOCK_REALTIME_COARSE: integer
  --  @type integer
  CLOCK_MONOTONIC_COARSE: integer
  CLOCK_THREAD_CPUTIME_ID: integer
  --  @type integer
  CLOCK_PROCESS_CPUTIME_ID: integer
  --  @type integer
  DT_BLK: integer
  --  @type integer
  DT_CHR: integer
  --  @type integer
  DT_DIR: integer
  --  @type integer
  DT_FIFO: integer
  --  @type integer
  DT_LNK: integer
  --  @type integer
  DT_REG: integer
  --  @type integer
  DT_SOCK: integer
  --  @type integer
  DT_UNKNOWN: integer
  --  @type integer Argument list too long.
  --  Raised by `execve`, `sched_setattr`.
  E2BIG: integer
  --  @type integer Permission denied.
  --  Raised by `access`, `bind`, `chdir`, `chmod`, `chown`, `chroot`,
  --  `clock_getres`, `connect`, `execve`, `fcntl`, `getpriority`,
  --  `link`, `mkdir`, `mknod`, `mmap`, `mprotect`, `msgctl`, `open`,
  --  `prctl`, `ptrace`, `readlink`, `rename`, `rmdir`, `semget`,
  --  `send`, `setpgid`, `socket`, `stat`, `symlink`, `truncate`,
  --  `unlink`, `uselib`, `utime`, `utimensat`.
  EACCES: integer
  --  @type integer Address already in use. Raised by `bind`, `connect`, `listen`.
  EADDRINUSE: integer
  --  @type integer Address not available. Raised by `bind`, `connect`.
  EADDRNOTAVAIL: integer
  --  @type integer Address family not supported. Raised by `connect`, `socket`, `socketpair`.
  EAFNOSUPPORT: integer
  --  @type integer
  --  Resource temporarily unavailable (e.g. SO_RCVTIMEO expired, too many
  --  processes, too much memory locked, read or write with O_NONBLOCK
  --  needs polling, etc.).
  --  Raised by `accept`, `connect`, `fcntl`, `fork`, `getrandom`,
  --  `mincore`, `mlock`, `mmap`, `mremap`, `poll`, `read`, `select`,
  --  `send`, `setresuid`, `setreuid`, `setuid`, `sigwaitinfo`,
  --  `splice`, `tee`, `timer_create`, `timerfd_create`, `tkill`,
  --  `write`,
  EAGAIN: integer
  --  @type integer Connection already in progress. Raised by `connect`, `send`.
  EALREADY: integer
  --  @type integer Bad file descriptor; cf. EBADFD.
  --  Raised by `accept`, `access`, `bind`, `chdir`, `chmod`, `chown`,
  --  `close`, `connect`, `copy_file_range`, `dup`, `fcntl`, `flock`,
  --  `fsync`, `futimesat`, `opendir`, `getpeername`, `getsockname`,
  --  `getsockopt`, `ioctl`, `link`, `listen`, `lseek`, `mkdir`,
  --  `mknod`, `mmap`, `open`, `prctl`, `read`, `readahead`,
  --  `readlink`, `recv`, `rename`, `select`, `send`, `shutdown`,
  --  `splice`, `stat`, `symlink`, `sync`, `sync_file_range`,
  --  `timerfd_create`, `truncate`, `unlink`, `utimensat`, `write`.
  EBADF: integer
  --  @type integer
  EBADFD: integer
  --  @type integer
  EBADMSG: integer
  --  @type integer Device or resource busy.
  --  Raised by dup, fcntl, msync, prctl, ptrace, rename,
  --  rmdir.
  EBUSY: integer
  --  @type integer
  ECANCELED: integer
  --  @type integer No child process.
  --  Raised by `wait`, `waitpid`, `waitid`, `wait3`, `wait4`.
  ECHILD: integer
  --  @type integer Connection reset before accept. Raised by `accept`.
  ECONNABORTED: integer
  --  @type integer System-imposed limit on the number of threads was encountered.
  --  Raised by connect, listen, recv.
  ECONNREFUSED: integer
  ECONNRESET: integer
  --  @type integer Resource deadlock avoided.
  --  Raised by `fcntl`.
  EDEADLK: integer
  --  @type integer Destination address required. Raised by `send`, `write`.
  EDESTADDRREQ: integer
  --  @type integer
  EDOM: integer
  --  @type integer Disk quota exceeded.
  --  Raised by link, mkdir, mknod, open, rename, symlink,
  --  write.
  EDQUOT: integer
  --  @type integer File exists.
  --  Raised by `link`, `mkdir`, `mknod`, `mmap`, `open`, `rename`,
  --  `rmdir`, `symlink`.
  EEXIST: integer
  --  @type integer
  EFAULT: integer
  --  @type integer File too large.
  --  Raised by `copy_file_range`, `open`, `truncate`, `write`.
  EFBIG: integer
  --  @type integer Inappropriate file type or format.
  EFTYPE: integer
  --  @type integer Host is down. Raised by `accept`.
  EHOSTDOWN: integer
  --  @type integer Host is unreachable. Raised by `accept`.
  EHOSTUNREACH: integer
  --  @type integer Memory page has hardware error.
  EHWPOISON: integer
  --  @type integer Identifier removed. Raised by `msgctl`.
  EIDRM: integer
  --  @type integer
  EILSEQ: integer
  --  @type integer
  EINPROGRESS: integer
  --  @type integer The greatest of all errnos; crucial for building real time reliable software.
  --  Raised by `accept`, `clock_nanosleep`, `close`, `connect`, `dup`, `fcntl`,
  --  `flock`, `getrandom`, `nanosleep`, `open`, `pause`, `poll`, `ptrace`, `read`, `recv`,
  --  `select`, `send`, `sigsuspend`, `sigwaitinfo`, `truncate`, `wait`, `write`.
  EINTR: integer
  --  @type integer Invalid argument.
  --  Raised by [pretty much everything].
  EINVAL: integer
  --  @type integer
  --  Raised by `access`, `acct`, `chdir`, `chmod`, `chown`, `chroot`, `close`,
  --  `copy_file_range`, `execve`, `fallocate`, `fsync`, `ioperm`, `link`, `madvise`,
  --  `mbind`, `pciconfig_read`, `ptrace`, `read`, `readlink`, `sendfile`, `statfs`,
  --  `symlink`, `sync_file_range`, `truncate`, `unlink`, `write`.
  EIO: integer
  EISCONN: integer
  --  @type integer Is a directory.
  --  Raised by `copy_file_range`, `execve`, `open`, `read`, `rename`, `truncate`,
  --  `unlink`.
  EISDIR: integer
  --  @type integer Too many levels of symbolic links.
  --  Raised by access, bind, chdir, chmod, chown, chroot, execve, link,
  --  mkdir, mknod, open, readlink, rename, rmdir, stat, symlink,
  --  truncate, unlink, utimensat.
  ELOOP: integer
  --  @type integer Wrong medium type. Raised by `mount`.
  EMEDIUMTYPE: integer
  --  @type integer Too many open files.
  --  Raised by `accept`, `dup`, `execve`, `fanotify_init`, `fcntl`,
  --  `open`, `pipe`, `socket`, `socketpair`, `timerfd_create`.
  EMFILE: integer
  --  @type integer Too many links;
  --  Raised by `link`, `mkdir`, `rename`.
  EMLINK: integer
  --  @type integer Message too long. Raised by `send`.
  EMSGSIZE: integer
  --  @type integer Multihop attempted.
  EMULTIHOP: integer
  --  @type integer Filename too long. Cosmopolitan Libc currently defines `PATH_MAX` as
  --  1024 characters. On UNIX that limit should only apply to system call
  --  wrappers like realpath. On Windows NT it's observed by all system
  --  calls that accept a pathname.
  --  Raised by `access`, `bind`, `chdir`, `chmod`, `chown`, `chroot`,
  --  `execve`, `gethostname`, `link`, `mkdir`, `mknod`, `open`,
  --  `readlink`, `rename`, `rmdir`, `stat`, `symlink`, `truncate`,
  --  `unlink`, `utimensat`.
  ENAMETOOLONG: integer
  --  @type integer Network is down. Raised by `accept`.
  ENETDOWN: integer
  --  @type integer Connection reset by network.
  ENETRESET: integer
  --  @type integer Host is unreachable. Raised by `accept`, `connect`.
  ENETUNREACH: integer
  --  @type integer Too many open files in system.
  --  Raised by `accept`, `execve`, `mmap`, `open`, `pipe`, `socket`,
  --  `socketpair`, `swapon`, `timerfd_create`, `uselib`,
  --  `userfaultfd`.
  ENFILE: integer
  --  @type integer No buffer space available;
  --  Raised by `getpeername`, `getsockname`, `send`.
  ENOBUFS: integer
  --  @type integer No message is available in xsi stream or named pipe is being closed;
  --  no data available; barely in posix; returned by ioctl; very close in
  --  spirit to EPIPE?
  ENODATA: integer
  --  @type integer No such device.
  --  Raised by `arch_prctl`, `mmap`, `open`, `prctl`, `timerfd_create`.
  ENODEV: integer
  --  @type integer No such file or directory.
  --  Raised by `access`, `bind`, `chdir`, `chmod`, `chown`, `chroot`,
  --  `clock_getres`, `execve`, `opendir`, `link`, `mkdir`, `mknod`,
  --  `open`, `readlink`, `rename`, `rmdir`, `stat`, `swapon`,
  --  `symlink`, `truncate`, `unlink`, `utime`, `utimensat`.
  ENOENT: integer
  --  @type integer Exec format error. Raised by `execve`, `uselib`.
  ENOEXEC: integer
  --  @type integer No locks available. Raised by `fcntl`, `flock`.
  ENOLCK: integer
  --  @type integer Link has been severed.
  ENOLINK: integer
  --  @type integer No medium found. Raised by `mount`.
  ENOMEDIUM: integer
  --  @type integer
  ENOMEM: integer
  --  @type integer Raised by `msgop`.
  ENOMSG: integer
  --  @type integer
  ENONET: integer
  --  @type integer Protocol not available. Raised by `getsockopt`, `accept`.
  ENOPROTOOPT: integer
  --  @type integer No space left on device.
  --  Raised by `copy_file_range`, `fsync`, `link`, `mkdir`, `mknod`,
  --  `open`, `rename`, `symlink`, `sync_file_range`, `write`.
  ENOSPC: integer
  --  @type integer Out of streams resources.
  ENOSR: integer
  --  @type integer Device not a stream.
  ENOSTR: integer
  --  @type integer System call not available on this platform. On
  --      Windows this is raised by `chroot`, `setuid`, `setgid`,
  --      `getsid`, `setsid`, and others we're doing our best to
  --      document.
  ENOSYS: integer
  --  @type integer Block device required. Raised by `umount`.
  ENOTBLK: integer
  --  @type integer Socket is not connected.
  --  Raised by `getpeername`, `recv`, `send`, `shutdown`.
  ENOTCONN: integer
  --  @type integer Not a directory. This means that a directory
  --      component in a supplied path *existed* but wasn't a
  --      directory. For example, if you try to `open("foo/bar")` and
  --      `foo` is a regular file, then `ENOTDIR` will be returned.
  --  Raised by `open`, `access`, `chdir`, `chroot`, `execve`, `link`,
  --  `mkdir`, `mknod`, `opendir`, `readlink`, `rename`, `rmdir`,
  --  `stat`, `symlink`, `truncate`, `unlink`, `utimensat`, `bind`,
  --  `chmod`, `chown`, `fcntl`, `futimesat`.
  ENOTDIR: integer
  --  @type integer Directory not empty. Raised by `rmdir`.
  ENOTEMPTY: integer
  --  @type integer
  ENOTRECOVERABLE: integer
  --  @type integer Not a socket.
  --  Raised by `accept`, `bind`, `connect`, `getpeername`,
  --  `getsockname`, `getsockopt`, `listen`, `recv`, `send`,
  --  `shutdown`.
  ENOTSOCK: integer
  --  @type integer Operation not supported.
  --  Raised by `chmod`, `clock_getres`, `clock_nanosleep`,
  --  `timer_create`.
  ENOTSUP: integer
  --  @type integer Inappropriate i/o control operation. Raised by `ioctl`.
  ENOTTY: integer
  --  @type integer No such device or address. Raised by `lseek`, `open`, `prctl`.
  ENXIO: integer
  --  @type integer Socket operation not supported.
  --  Raised by accept, listen, mmap, prctl, readv, send,
  --  socketpair.
  EOPNOTSUPP: integer
  --  @type integer Raised by `copy_file_range`, `fanotify_init`, `lseek`, `mmap`,
  --  `open`, `stat`, `statfs`
  EOVERFLOW: integer
  --  @type integer
  EOWNERDEAD: integer
  --  @type integer Operation not permitted.
  --  Raised by `accept`, `chmod`, `chown`, `chroot`,
  --  `copy_file_range`, `execve`, `fallocate`, `fanotify_init`,
  --  `fcntl`, `futex`, `get_robust_list`, `getdomainname`,
  --  `getgroups`, `gethostname`, `getpriority`, `getrlimit`,
  --  `getsid`, `gettimeofday`, `idle`, `init_module`, `io_submit`,
  --  `ioctl_console`, `ioctl_ficlonerange`, `ioctl_fideduperange`,
  --  `ioperm`, `iopl`, `ioprio_set`, `keyctl`, `kill`, `link`,
  --  `lookup_dcookie`, `madvise`, `mbind`, `membarrier`,
  --  `migrate_pages`, `mkdir`, `mknod`, `mlock`, `mmap`, `mount`,
  --  `move_pages`, `msgctl`, `nice`, `open`, `open_by_handle_at`,
  --  `pciconfig_read`, `perf_event_open`, `pidfd_getfd`,
  --  `pidfd_send_signal`, `pivot_root`, `prctl`, `process_vm_readv`,
  --  `ptrace`, `quotactl`, `reboot`, `rename`, `request_key`,
  --  `rmdir`, `rt_sigqueueinfo`, `sched_setaffinity`,
  --  `sched_setattr`, `sched_setparam`, `sched_setscheduler`,
  --  `seteuid`, `setfsgid`, `setfsuid`, `setgid`, `setns`, `setpgid`,
  --  `setresuid`, `setreuid`, `setsid`, `setuid`, `setup`,
  --  `setxattr`, `sigaltstack`, `spu_create`, `stime`, `swapon`,
  --  `symlink`, `syslog`, `truncate`, `unlink`, `utime`, `utimensat`,
  --  `write`.
  EPERM: integer
  --  @type integer Protocol family not supported.
  EPFNOSUPPORT: integer
  --  @type integer Broken pipe.
  --  Returned by `write`, `send`. This happens when you try
  --  to write data to a subprocess via a pipe but the reader end has
  --  already closed, possibly because the process died. Normally i/o
  --  routines only return this if `SIGPIPE` doesn't kill the process.
  --  Unlike default UNIX programs, redbean currently ignores `SIGPIPE` by
  --  default, so this error code is a distinct possibility when pipes or
  --  sockets are being used.
  EPIPE: integer
  --  @type integer Raised by `accept`, `connect`, `socket`, `socketpair`.
  EPROTO: integer
  --  @type integer Protocol not supported. Raised by `socket`, `socketpair`.
  EPROTONOSUPPORT: integer
  --  @type integer Protocol wrong type for socket. Raised by `connect`.
  EPROTOTYPE: integer
  --  @type integer Result too large.
  --  Raised by `prctl`.
  ERANGE: integer
  --  @type integer
  EREMOTE: integer
  --  @type integer
  ERESTART: integer
  --  @type integer Operation not possible due to RF-kill.
  ERFKILL: integer
  --  @type integer Read-only filesystem.
  --  Raised by access, bind, chmod, chown, link, mkdir, mknod, open,
  --  rename, rmdir, symlink, truncate, unlink, utime, utimensat.
  EROFS: integer
  --  @type integer Cannot send after transport endpoint shutdown; note that shutdown write is an `EPIPE`.
  ESHUTDOWN: integer
  --  @type integer Socket type not supported.
  ESOCKTNOSUPPORT: integer
  --  @type integer Invalid seek.
  --  Raised by `lseek`, `splice`, `sync_file_range`.
  ESPIPE: integer
  --  @type integer No such process.
  --  Raised by `getpriority`, `getrlimit`, `getsid`, `ioprio_set`, `kill`, `setpgid`, `tkill`, `utimensat`.
  ESRCH: integer
  --  @type integer
  ESTALE: integer
  --  @type integer Timer expired. Raised by `connect`.
  ETIME: integer
  --  @type integer Connection timed out. Raised by `connect`.
  ETIMEDOUT: integer
  --  @type integer Too many references: cannot splice. Raised by `sendmsg`.
  ETOOMANYREFS: integer
  --  @type integer Won't open executable that's executing in write mode.
  --  Raised by access, copy_file_range, execve, mmap, open, truncate.
  ETXTBSY: integer
  --  @type integer
  EUSERS: integer
  --  @type integer Improper link.
  --  Raised by copy_file_range, link, rename.
  EXDEV: integer
  --  @type integer
  FD_CLOEXEC: integer
  --  @type integer
  F_GETFD: integer
  --  @type integer
  F_GETFL: integer
  --  @type integer
  F_GETLK: integer
  --  @type integer
  F_OK: integer
  --  @type integer
  F_RDLCK: integer
  --  @type integer
  F_SETFD: integer
  --  @type integer
  F_SETFL: integer
  --  @type integer
  F_SETLK: integer
  --  @type integer
  F_SETLKW: integer
  --  @type integer
  F_UNLCK: integer
  --  @type integer
  F_WRLCK: integer
  --  @type integer
  IPPROTO_ICMP: integer
  --  @type integer
  IPPROTO_IP: integer
  --  @type integer
  IPPROTO_RAW: integer
  --  @type integer
  IPPROTO_TCP: integer
  --  @type integer
  IPPROTO_UDP: integer
  --  @type integer
  IP_ADD_MEMBERSHIP: integer
  --  @type integer
  IP_DROP_MEMBERSHIP: integer
  --  @type integer
  IP_HDRINCL: integer
  --  @type integer
  IP_MTU: integer
  --  @type integer
  IP_MULTICAST_IF: integer
  --  @type integer
  IP_MULTICAST_LOOP: integer
  --  @type integer
  IP_MULTICAST_TTL: integer
  --  @type integer
  IP_OPTIONS: integer
  --  @type integer
  IP_PKTINFO: integer
  --  @type integer
  IP_RECVTOS: integer
  --  @type integer
  IP_RECVTTL: integer
  --  @type integer
  IP_TOS: integer
  --  @type integer
  IP_TTL: integer
  --  @type integer
  ITIMER_PROF: integer
  --  @type integer
  ITIMER_REAL: integer
  --  @type integer
  ITIMER_VIRTUAL: integer
  --  @type integer
  LOG_ALERT: integer
  --  @type integer
  LOG_CRIT: integer
  --  @type integer
  LOG_DEBUG: integer
  --  @type integer
  LOG_EMERG: integer
  --  @type integer
  LOG_ERR: integer
  --  @type integer
  LOG_INFO: integer
  --  @type integer
  LOG_NOTICE: integer
  --  @type integer
  LOG_WARNING: integer
  --  @type integer
  MSG_CTRUNC: integer
  --  @type integer
  MSG_DONTROUTE: integer
  --  @type integer
  MSG_DONTWAIT: integer
  --  @type integer
  MSG_NOSIGNAL: integer
  --  @type integer
  MSG_OOB: integer
  --  @type integer
  MSG_PEEK: integer
  --  @type integer
  MSG_TRUNC: integer
  --  @type integer
  MSG_WAITALL: integer
  --  @type integer  Returns maximum length of file path component.
  --  POSIX requires this be at least 14. Most operating systems define it
  --  as 255. It's a good idea to not exceed 253 since that's the limit on
  --  DNS labels.
  NAME_MAX: integer
  --  @type integer Returns maximum number of signals supported by underlying system.
  --  The limit for unix.Sigset is 128 to support FreeBSD, but most
  --  operating systems define this much lower, like 32. This constant
  --  reflects the value chosen by the underlying operating system.
  NSIG: integer
  --  @type integer open for reading (default)
  O_RDONLY: integer
  --  @type integer open for writing
  O_WRONLY: integer
  --  @type integer open for reading and writing
  O_RDWR: integer
  --  @type integer create file if it doesn't exist
  O_CREAT: integer
  --  @type integer automatic `ftruncate(fd, 0)` if exists
  O_TRUNC: integer
  --  @type integer automatic `close()` upon `execve()`
  O_CLOEXEC: integer
  --  @type integer exclusive access (see below)
  O_EXCL: integer
  --  @type integer open file for append only
  O_APPEND: integer
  --  @type integer asks read/write to fail with EAGAIN rather than block
  O_NONBLOCK: integer
  --  @type integer it's complicated (not supported on Apple and OpenBSD)
  O_DIRECT: integer
  --  @type integer useful for stat'ing (hint on UNIX but required on NT)
  O_DIRECTORY: integer
  --  @type integer fail if it's a symlink (zero on Windows)
  O_NOFOLLOW: integer
  --  @type integer automatically delete file upon close()
  O_UNLINK: integer
  --  @type integer open a path reference only, without read/write access
  --  (Linux only; fails with EINVAL elsewhere). Usable with landlock
  --  rule paths and *at() calls even when the path itself is unreadable.
  O_PATH: integer
  --  @type integer it's complicated (zero on non-Linux/Apple)
  O_DSYNC: integer
  --  @type integer synchronize i/o operations appropriately
  O_SYNC: integer
  --  @type integer don't record access time (zero on non-Linux)
  O_NOATIME: integer
  --  @type integer
  O_ACCMODE: integer
  --  @type integer
  O_NOCTTY: integer
  --  @type integer Returns maximum length of file path.
  --  This applies to a complete path being passed to system calls.
  --  POSIX.1 XSI requires this be at least 1024 so that's what most
  --  platforms support. On Windows NT, the limit is technically 260
  --  characters. Your redbean works around that by prefixing `//?/`
  --  to your paths as needed. On Linux this limit will be 4096, but
  --  that won't be the case for functions such as realpath that are
  --  implemented at the C library level; however such functions are
  --  the exception rather than the norm, and report `enametoolong()`,
  --  when exceeding the libc limit.
  PATH_MAX: integer
  --  the default on Linux. It's effectively the same as killing the
  --  process, since redbean has no threads. The termination signal
  --  can't be caught and will be either `SIGSYS` or `SIGABRT`.
  --  Consider enabling stderr logging below so you'll know why your
  --  program failed. Otherwise check the system log.
  PLEDGE_PENALTY_KILL_THREAD: integer
  --  This is always the case on OpenBSD.
  PLEDGE_PENALTY_KILL_PROCESS: integer
  --  instead of killing. This is a gentler solution that allows code to
  --  display a friendly warning. Please note this may lead to weird
  --  behaviors if the software being sandboxed is lazy about checking
  --  error results.
  PLEDGE_PENALTY_RETURN_EPERM: integer
  --  know which promises are needed whenever violations occur. Without
  --  this, violations will be logged to `dmesg` on Linux if the penalty
  --  is to kill the process. You would then need to manually look up
  --  the system call number and then cross reference it with the
  --  cosmopolitan libc `pledge()` documentation. You can also use
  --  `strace -ff` which is easier. This is ignored OpenBSD, which
  --  already has a good system log. Turning on stderr logging (which
  --  uses SECCOMP trapping) also means that the `unix.WTERMSIG()` on
  --  your killed processes will always be `unix.SIGABRT` on both Linux
  --  and OpenBSD. Otherwise, Linux prefers to raise `unix.SIGSYS`.
  PLEDGE_STDERR_LOGGING: integer
  --  @type integer Returns maximum size at which pipe i/o is guaranteed atomic.
  --  POSIX requires this be at least 512. Linux is more generous and
  --  allows 4096. On Windows NT this is currently 4096, and it's the
  --  parameter redbean passes to `CreateNamedPipe()`.
  PIPE_BUF: integer
  --  @type integer
  POLLERR: integer
  --  @type integer
  POLLHUP: integer
  --  @type integer
  POLLIN: integer
  --  @type integer
  POLLNVAL: integer
  --  @type integer
  POLLOUT: integer
  --  @type integer
  POLLPRI: integer
  --  @type integer
  POLLRDBAND: integer
  --  @type integer
  POLLRDHUP: integer
  --  @type integer
  POLLRDNORM: integer
  --  @type integer
  POLLWRBAND: integer
  --  @type integer
  POLLWRNORM: integer
  --  @type integer
  RLIMIT_AS: integer
  --  @type integer
  RLIMIT_CPU: integer
  --  @type integer
  RLIMIT_FSIZE: integer
  --  @type integer
  RLIMIT_NOFILE: integer
  --  @type integer
  RLIMIT_NPROC: integer
  --  @type integer
  RLIMIT_RSS: integer
  --  @type integer getpriority/setpriority: target is a process id
  PRIO_PROCESS: integer
  --  @type integer getpriority/setpriority: target is a process group id
  PRIO_PGRP: integer
  --  @type integer getpriority/setpriority: target is a user id
  PRIO_USER: integer
  --  @type integer sysconf: maximum length of arguments to exec()
  SC_ARG_MAX: integer
  --  @type integer sysconf: maximum simultaneous processes per user id
  SC_CHILD_MAX: integer
  --  @type integer sysconf: clock ticks per second
  SC_CLK_TCK: integer
  --  @type integer sysconf: maximum number of open files per process
  SC_OPEN_MAX: integer
  --  @type integer sysconf: size of a memory page in bytes
  SC_PAGESIZE: integer
  --  @type integer sysconf: number of processors configured
  SC_NPROCESSORS_CONF: integer
  --  @type integer sysconf: number of processors currently online
  SC_NPROCESSORS_ONLN: integer
  --  @type integer termios input mode flags (Termios.iflag)
  BRKINT: integer
  ICRNL: integer
  IGNBRK: integer
  IGNCR: integer
  IGNPAR: integer
  INLCR: integer
  INPCK: integer
  ISTRIP: integer
  IXANY: integer
  IXOFF: integer
  IXON: integer
  PARMRK: integer
  --  @type integer termios output mode flags (Termios.oflag)
  OPOST: integer
  OCRNL: integer
  ONLCR: integer
  ONLRET: integer
  ONOCR: integer
  --  @type integer termios control mode flags (Termios.cflag)
  CLOCAL: integer
  CREAD: integer
  CS5: integer
  CS6: integer
  CS7: integer
  CS8: integer
  CSIZE: integer
  CSTOPB: integer
  HUPCL: integer
  PARENB: integer
  PARODD: integer
  --  @type integer termios local mode flags (Termios.lflag)
  ECHO: integer
  ECHOE: integer
  ECHOK: integer
  ECHONL: integer
  ICANON: integer
  IEXTEN: integer
  ISIG: integer
  NOFLSH: integer
  TOSTOP: integer
  --  @type integer termios control-character indices (Termios.cc)
  VEOF: integer
  VEOL: integer
  VERASE: integer
  VINTR: integer
  VKILL: integer
  VMIN: integer
  VQUIT: integer
  VSTART: integer
  VSTOP: integer
  VTIME: integer
  NCCS: integer
  --  @type integer tcsetattr() action values
  TCSANOW: integer
  TCSADRAIN: integer
  TCSAFLUSH: integer
  --  @type integer network interface ioctls (siocgifconf/ifreq)
  IFNAMSIZ: integer
  IFF_ALLMULTI: integer
  IFF_AUTOMEDIA: integer
  IFF_BROADCAST: integer
  IFF_DEBUG: integer
  IFF_DYNAMIC: integer
  IFF_LOOPBACK: integer
  IFF_MASTER: integer
  IFF_MULTICAST: integer
  IFF_NOARP: integer
  IFF_NOTRAILERS: integer
  IFF_POINTOPOINT: integer
  IFF_PORTSEL: integer
  IFF_PROMISC: integer
  IFF_RUNNING: integer
  IFF_SLAVE: integer
  IFF_UP: integer
  SIOCGIFADDR: integer
  SIOCGIFBRDADDR: integer
  SIOCGIFDSTADDR: integer
  SIOCGIFFLAGS: integer
  SIOCGIFINDEX: integer
  SIOCGIFMETRIC: integer
  SIOCGIFMTU: integer
  SIOCGIFNAME: integer
  SIOCGIFNETMASK: integer
  SIOCSIFADDR: integer
  SIOCSIFBRDADDR: integer
  SIOCSIFDSTADDR: integer
  SIOCSIFFLAGS: integer
  SIOCSIFMETRIC: integer
  SIOCSIFMTU: integer
  SIOCSIFNETMASK: integer
  --  @type integer unshare()/setns() namespace flags
  CLONE_NEWCGROUP: integer
  CLONE_NEWIPC: integer
  CLONE_NEWNET: integer
  CLONE_NEWNS: integer
  CLONE_NEWPID: integer
  CLONE_NEWTIME: integer
  CLONE_NEWUSER: integer
  CLONE_NEWUTS: integer
  --  @type integer landlock access-rights bits (landlock_add_rule)
  LANDLOCK_ACCESS_FS_EXECUTE: integer
  LANDLOCK_ACCESS_FS_WRITE_FILE: integer
  LANDLOCK_ACCESS_FS_READ_FILE: integer
  LANDLOCK_ACCESS_FS_READ_DIR: integer
  LANDLOCK_ACCESS_FS_REMOVE_DIR: integer
  LANDLOCK_ACCESS_FS_REMOVE_FILE: integer
  LANDLOCK_ACCESS_FS_MAKE_CHAR: integer
  LANDLOCK_ACCESS_FS_MAKE_DIR: integer
  LANDLOCK_ACCESS_FS_MAKE_REG: integer
  LANDLOCK_ACCESS_FS_MAKE_SOCK: integer
  LANDLOCK_ACCESS_FS_MAKE_FIFO: integer
  LANDLOCK_ACCESS_FS_MAKE_BLOCK: integer
  LANDLOCK_ACCESS_FS_MAKE_SYM: integer
  LANDLOCK_ACCESS_FS_REFER: integer
  LANDLOCK_ACCESS_FS_TRUNCATE: integer
  LANDLOCK_CREATE_RULESET_VERSION: integer
  LANDLOCK_RULE_PATH_BENEATH: integer
  --  @type integer prctl() options
  PR_CAPBSET_DROP: integer
  PR_CAPBSET_READ: integer
  PR_GET_CHILD_SUBREAPER: integer
  PR_GET_DUMPABLE: integer
  PR_GET_KEEPCAPS: integer
  PR_GET_NAME: integer
  PR_GET_NO_NEW_PRIVS: integer
  PR_GET_PDEATHSIG: integer
  PR_SET_CHILD_SUBREAPER: integer
  PR_SET_DUMPABLE: integer
  PR_SET_KEEPCAPS: integer
  PR_SET_NAME: integer
  PR_SET_NO_NEW_PRIVS: integer
  PR_SET_PDEATHSIG: integer
  --  @type integer Linux capability bits (prctl PR_CAPBSET_*, capget/capset).
  CAP_AUDIT_CONTROL: integer
  CAP_AUDIT_READ: integer
  CAP_AUDIT_WRITE: integer
  CAP_BLOCK_SUSPEND: integer
  CAP_BPF: integer
  CAP_CHECKPOINT_RESTORE: integer
  CAP_CHOWN: integer
  CAP_DAC_OVERRIDE: integer
  CAP_DAC_READ_SEARCH: integer
  CAP_FOWNER: integer
  CAP_FSETID: integer
  CAP_IPC_LOCK: integer
  CAP_IPC_OWNER: integer
  CAP_KILL: integer
  CAP_LAST_CAP: integer
  CAP_LEASE: integer
  CAP_LINUX_IMMUTABLE: integer
  CAP_MAC_ADMIN: integer
  CAP_MAC_OVERRIDE: integer
  CAP_MKNOD: integer
  CAP_NET_ADMIN: integer
  CAP_NET_BIND_SERVICE: integer
  CAP_NET_BROADCAST: integer
  CAP_NET_RAW: integer
  CAP_PERFMON: integer
  CAP_SETFCAP: integer
  CAP_SETGID: integer
  CAP_SETPCAP: integer
  CAP_SETUID: integer
  CAP_SYSLOG: integer
  CAP_SYS_ADMIN: integer
  CAP_SYS_BOOT: integer
  CAP_SYS_CHROOT: integer
  CAP_SYS_MODULE: integer
  CAP_SYS_NICE: integer
  CAP_SYS_PACCT: integer
  CAP_SYS_PTRACE: integer
  CAP_SYS_RAWIO: integer
  CAP_SYS_RESOURCE: integer
  CAP_SYS_TIME: integer
  CAP_SYS_TTY_CONFIG: integer
  CAP_WAKE_ALARM: integer
  --  @type integer mount()/umount2() flags
  MS_BIND: integer
  MS_DIRSYNC: integer
  MS_LAZYTIME: integer
  MS_MANDLOCK: integer
  MS_MOVE: integer
  MS_NOATIME: integer
  MS_NODEV: integer
  MS_NODIRATIME: integer
  MS_NOEXEC: integer
  MS_NOSUID: integer
  MS_POSIXACL: integer
  MS_PRIVATE: integer
  MS_RDONLY: integer
  MS_REC: integer
  MS_RELATIME: integer
  MS_REMOUNT: integer
  MS_SHARED: integer
  MS_SILENT: integer
  MS_SLAVE: integer
  MS_STRICTATIME: integer
  MS_SYNCHRONOUS: integer
  MS_UNBINDABLE: integer
  MNT_DETACH: integer
  MNT_EXPIRE: integer
  MNT_FORCE: integer
  UMOUNT_NOFOLLOW: integer
  --  @type integer statvfs f_flag bits (unix.Statfs / statvfs)
  ST_APPEND: integer
  ST_IMMUTABLE: integer
  ST_MANDLOCK: integer
  ST_NOATIME: integer
  ST_NODEV: integer
  ST_NODIRATIME: integer
  ST_NOEXEC: integer
  ST_NOSUID: integer
  ST_RDONLY: integer
  ST_RELATIME: integer
  ST_SYNCHRONOUS: integer
  ST_WRITE: integer
  --  @type integer
  RUSAGE_BOTH: integer
  --  @type integer
  RUSAGE_CHILDREN: integer
  --  @type integer
  RUSAGE_SELF: integer
  --  @type integer
  RUSAGE_THREAD: integer
  --  @type integer
  R_OK: integer
  --  @type integer
  SA_NOCLDSTOP: integer
  --  @type integer
  SA_NOCLDWAIT: integer
  --  @type integer
  SA_NODEFER: integer
  --  @type integer
  SA_RESETHAND: integer
  --  @type integer
  SA_RESTART: integer
  --  @type integer
  SEEK_CUR: integer
  --  @type integer
  SEEK_END: integer
  --  @type integer
  SEEK_SET: integer
  SHUT_RD: integer
  SHUT_WR: integer
  SHUT_RDWR: integer
  --  @type integer Process aborted.
  SIGABRT: integer
  --  @type integer Sent by setitimer().
  SIGALRM: integer
  --  @type integer Valid memory access that went beyond underlying end of file.
  SIGBUS: integer
  --  @type integer Child process exited or terminated and is now a zombie (unless this
  --  is `SIG_IGN` or `SA_NOCLDWAIT`) or child process stopped due to terminal
  --  i/o or profiling/debugging (unless you used `SA_NOCLDSTOP`)
  SIGCHLD: integer
  --  @type integer Child process resumed from profiling/debugging.
  SIGCONT: integer
  --  @type integer Illegal math.
  SIGFPE: integer
  --  @type integer Terminal hangup or daemon reload; auto-broadcasted to process group.
  SIGHUP: integer
  --  @type integer Illegal instruction.
  SIGILL: integer
  --  @type integer Terminal CTRL-C keystroke.
  SIGINT: integer
  --  @type integer Terminate with extreme prejudice.
  SIGKILL: integer
  --  @type integer Write to closed file descriptor.
  SIGPIPE: integer
  --  @type integer Profiling timer expired.
  SIGPROF: integer
  --  @type integer Terminal CTRL-\ keystroke.
  SIGQUIT: integer
  --  @type integer Invalid memory access.
  SIGSEGV: integer
  --  @type integer Child process stopped due to profiling/debugging.
  SIGSTOP: integer
  --  @type integer
  SIGSYS: integer
  --  @type integer Terminate.
  SIGTERM: integer
  --  @type integer INT3 instruction.
  SIGTRAP: integer
  --  @type integer Terminal CTRL-Z keystroke.
  SIGTSTP: integer
  --  @type integer Terminal input for background process.
  SIGTTIN: integer
  --  @type integer Terminal input for background process.
  SIGTTOU: integer
  --  @type integer
  SIGURG: integer
  --  @type integer Do whatever you want.
  SIGUSR1: integer
  --  @type integer Do whatever you want.
  SIGUSR2: integer
  --  @type integer Virtual alarm clock.
  SIGVTALRM: integer
  --  @type integer Terminal resized.
  SIGWINCH: integer
  --  @type integer CPU time limit exceeded.
  SIGXCPU: integer
  --  @type integer File size limit exceeded.
  SIGXFSZ: integer
  --  @type integer
  SIG_BLOCK: integer
  --  @type integer
  SIG_DFL: integer
  --  @type integer
  SIG_IGN: integer
  --  @type integer
  SIG_SETMASK: integer
  --  @type integer
  SIG_UNBLOCK: integer
  --  @type integer
  SOCK_CLOEXEC: integer
  --  @type integer
  SOCK_DGRAM: integer
  --  @type integer
  SOCK_NONBLOCK: integer
  --  @type integer
  SOCK_RAW: integer
  --  @type integer
  SOCK_RDM: integer
  --  @type integer
  SOCK_SEQPACKET: integer
  --  @type integer
  SOCK_STREAM: integer
  --  @type integer
  SOL_IP: integer
  --  @type integer
  SOL_SOCKET: integer
  --  @type integer
  SOL_TCP: integer
  --  @type integer
  SOL_UDP: integer
  --  @type integer
  SO_ACCEPTCONN: integer
  --  @type integer
  SO_BROADCAST: integer
  --  @type integer
  SO_DEBUG: integer
  --  @type integer
  SO_DONTROUTE: integer
  --  @type integer
  SO_ERROR: integer
  --  @type integer
  SO_KEEPALIVE: integer
  --  @type integer
  SO_LINGER: integer
  --  @type integer
  SO_NOSIGPIPE: integer
  --  @type integer
  SO_OOBINLINE: integer
  --  @type integer
  SO_RCVBUF: integer
  --  @type integer
  SO_RCVLOWAT: integer
  --  @type integer
  SO_RCVTIMEO: integer
  --  @type integer
  SO_REUSEADDR: integer
  --  @type integer
  SO_REUSEPORT: integer
  --  @type integer
  SO_SNDBUF: integer
  --  @type integer
  SO_SNDLOWAT: integer
  --  @type integer
  SO_SNDTIMEO: integer
  --  @type integer
  SO_TYPE: integer
  --  @type integer
  TCP_CORK: integer
  --  @type integer
  TCP_DEFER_ACCEPT: integer
  --  @type integer
  TCP_FASTOPEN: integer
  --  @type integer
  TCP_FASTOPEN_CONNECT: integer
  --  @type integer
  TCP_KEEPCNT: integer
  --  @type integer
  TCP_KEEPIDLE: integer
  --  @type integer
  TCP_KEEPINTVL: integer
  --  @type integer
  TCP_MAXSEG: integer
  --  @type integer
  TCP_NODELAY: integer
  --  @type integer
  TCP_NOTSENT_LOWAT: integer
  --  @type integer
  TCP_QUICKACK: integer
  --  @type integer
  TCP_SAVED_SYN: integer
  --  @type integer
  TCP_SAVE_SYN: integer
  --  @type integer
  TCP_SYNCNT: integer
  --  @type integer
  TCP_WINDOW_CLAMP: integer
  --  @type integer
  UTIME_NOW: integer
  --  @type integer
  UTIME_OMIT: integer
  --  @type integer
  WNOHANG: integer
  --  @type integer
  WUNTRACED: integer
  --  @type integer Report continued child processes.
  WCONTINUED: integer
  --  @type integer
  W_OK: integer
  --  @type integer
  X_OK: integer
end
```

## Functions

### open

```teal
function open(path: string, flags: integer, mode?: integer, dirfd?: integer): integer | nil, string | nil, Errno | nil
```

 Opens file.
 Returns a file descriptor integer that needs to be closed, e.g.
     fd = assert(unix.open("/etc/passwd", unix.O_RDONLY))
     print(unix.read(fd))
     unix.close(fd)
 `flags` should have one of:
 - `O_RDONLY`:     open for reading (default)
 - `O_WRONLY`:     open for writing
 - `O_RDWR`:       open for reading and writing
 The following values may also be OR'd into `flags`:
  - `O_CREAT`      create file if it doesn't exist
  - `O_TRUNC`      automatic ftruncate(fd,0) if exists
  - `O_CLOEXEC`    automatic close() upon execve()
  - `O_EXCL`       exclusive access (see below)
  - `O_APPEND`     open file for append only
  - `O_NONBLOCK`   asks read/write to fail with EAGAIN rather than block
  - `O_DIRECTORY`  useful for stat'ing (hint on UNIX but required on NT)
  - `O_NOFOLLOW`   fail if it's a symlink (zero on Windows)
  - `O_UNLINK`     automatically delete file upon close()
  - `O_SYNC`       makes file operations synchronize appropriately
  - `O_RSYNC`      synchronize read() operations
  - `O_DSYNC`      synchronize write() operations
  - `O_DIRECT`     it's complicated (not supported on Apple and OpenBSD)
  - `O_NOATIME`    don't record access time (zero on non-Linux)
  There are three regular combinations for the above flags:
  - `O_RDONLY`: Opens existing file for reading. If it doesn't exist
    then nil is returned and errno will be `ENOENT` (or in some other
    cases `ENOTDIR`).
  - `O_WRONLY|O_CREAT|O_TRUNC`: Creates file. If it already exists,
    then the existing copy is destroyed and the opened file will
    start off with a length of zero. This is the behavior of the
    traditional creat() system call.
  - `O_WRONLY|O_CREAT|O_EXCL`: Create file only if doesn't exist
    already. If it does exist then `nil` is returned along with
    `errno` set to `EEXIST`.
 `dirfd` defaults to to `unix.AT_FDCWD` and may optionally be set to
 a directory file descriptor to which `path` is relative.
 Returns `ENOENT` if `path` doesn't exist.
 Returns `ENOTDIR` if `path` contained a directory component that
 wasn't a directory
 .

**Parameters:**

- `path` (string)
- `flags` (integer)
- `mode` (integer)
- `dirfd` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### close

```teal
function close(fd: integer): boolean | nil, string | nil, Errno | nil
```

 Closes file descriptor.
 This function should never be called twice for the same file
 descriptor, regardless of whether or not an error happened. The file
 descriptor is always gone after close is called. So it technically
 always succeeds, but that doesn't mean an error should be ignored.
 For example, on NFS a close failure could indicate data loss.
 Closing does not mean that scheduled i/o operations have been
 completed. You'd need to use fsync() or fdatasync() beforehand to
 ensure that. You shouldn't need to do that normally, because our
 close implementation guarantees a consistent view, since on systems
 where it isn't guaranteed (like Windows) close will implicitly sync.
 File descriptors are automatically closed on exit().
 Returns `EBADF` if `fd` wasn't valid.
 Returns `EINTR` possibly maybe.
 Returns `EIO` if an i/o error occurred.

**Parameters:**

- `fd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### read

```teal
function read(fd: integer, bufsiz?: integer, offset?: integer): string | nil, string | nil, Errno | nil
```

 Reads from file descriptor.
 This function returns empty string on end of file. The exception is
 if `bufsiz` is zero, in which case an empty returned string means
 the file descriptor works.

**Parameters:**

- `fd` (integer)
- `bufsiz` (integer)
- `offset` (integer)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### write

```teal
function write(fd: integer, data: string, offset?: integer): integer | nil, string | nil, Errno | nil
```

 Writes to file descriptor.

**Parameters:**

- `fd` (integer)
- `data` (string)
- `offset` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### exit

```teal
function exit(exitcode?: integer)
```

 Invokes `_Exit(exitcode)` on the process. This will immediately
 halt the current process. Memory will be freed. File descriptors
 will be closed. Any open connections it owns will be reset. This
 function never returns.

**Parameters:**

- `exitcode` (integer)

### environ

```teal
function environ(): {string}
```

 Returns raw environment variables.
 This allocates and constructs the C/C++ `environ` variable as a Lua
 table consisting of string keys and string values.
 This data structure preserves casing. On Windows NT, by convention,
 environment variable keys are treated in a case-insensitive way. It
 is the responsibility of the caller to consider this.
 This data structure preserves valueless variables. It's possible on
 both UNIX and Windows to have an environment variable without an
 equals, even though it's unusual.
 This data structure preserves duplicates. For example, on Windows,
 there's some irregular uses of environment variables such as how the
 command prompt inserts multiple environment variables with empty
 string as keys, for its internal bookkeeping.

**Returns:**

- {string}

### setenv

```teal
function setenv(name: string, value: string, overwrite?: boolean): boolean | nil, string | nil, Errno | nil
```

 Sets environment variable.
 This wraps the C `setenv()` function to allow Lua scripts to set
 environment variables.

**Parameters:**

- `name` (string)
- `value` (string)
- `overwrite` (boolean)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### unsetenv

```teal
function unsetenv(name: string): boolean | nil, string | nil, Errno | nil
```

 Unsets environment variable.
 This wraps the C `unsetenv()` function to allow Lua scripts to remove
 environment variables.

**Parameters:**

- `name` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### clearenv

```teal
function clearenv(): boolean | nil, string | nil, Errno | nil
```

 Clears all environment variables.
 This wraps the C `clearenv()` function to allow Lua scripts to remove
 all environment variables at once.

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getlogin

```teal
function getlogin(): string | nil, string | nil, Errno | nil
```

 Gets login name of current user.
 This wraps the C `getlogin()` function to retrieve the login name
 associated with the current session.

**Returns:**

- string | nil
- string | nil
- Errno | nil

### fork

```teal
function fork(): integer | nil, string | nil, Errno | nil
```

 Creates a new process mitosis style.
 This system call returns twice. The parent process gets the nonzero
 pid. The child gets zero.
 Here's a simple usage example of creating subprocesses, where we
 fork off a child worker from a main process hook callback to do some
 independent chores, such as sending an HTTP request back to redbean.
    -- as soon as server starts, make a fetch to the server
    -- then signal redbean to shutdown when fetch is complete
    local onServerStart = function()
       if assert(unix.fork()) == 0 then
          local ok, headers, body = Fetch('http://127.0.0.1:8080/test')
          unix.kill(unix.getppid(), unix.SIGTERM)
          unix.exit(0)
       end
    end
    OnServerStart = onServerStart
 We didn't need to use `wait()` here, because (a) we want redbean to go
 back to what it was doing before as the `Fetch()` completes, and (b)
 redbean's main process already has a zombie collector. However it's
 a moot point, since once the fetch is done, the child process then
 asks redbean to gracefully shutdown by sending SIGTERM its parent.
 This is actually a situation where we *must* use fork, because the
 purpose of the main redbean process is to call accept() and create
 workers. So if we programmed redbean to use the main process to send
 a blocking request to itself instead, then redbean would deadlock
 and never be able to accept() the client.
 While deadlocking is an extreme example, the truth is that latency
 issues can crop up for the same reason that just cause jitter
 instead, and as such, can easily go unnoticed. For example, if you
 do soemething that takes longer than a few milliseconds from inside
 your redbean heartbeat, then that's a few milliseconds in which
 redbean is no longer concurrent, and tail latency is being added to
 its ability to accept new connections. fork() does a great job at
 solving this.
 If you're not sure how long something will take, then when in doubt,
 fork off a process. You can then report its completion to something
 like SQLite. Redbean makes having lots of processes cheap. On Linux
 they're about as lightweight as what heavyweight environments call
 greenlets. You can easily have 10,000 Redbean workers on one PC.
 Here's some benchmarks for fork() performance across platforms:
    Linux 5.4 fork      l:     97,200𝑐    31,395𝑛𝑠  [metal]
    FreeBSD 12 fork     l:    236,089𝑐    78,841𝑛𝑠  [vmware]
    Darwin 20.6 fork    l:    295,325𝑐    81,738𝑛𝑠  [metal]
    NetBSD 9 fork       l:  5,832,027𝑐 1,947,899𝑛𝑠  [vmware]
    OpenBSD 6.8 fork    l: 13,241,940𝑐 4,422,103𝑛𝑠  [vmware]
    Windows10 fork      l: 18,802,239𝑐 6,360,271𝑛𝑠  [metal]
 One of the benefits of using `fork()` is it creates an isolation
 barrier between the different parts of your app. This can lead to
 enhanced reliability and security. For example, redbean uses fork so
 it can wipe your ssl keys from memory before handing over control to
 request handlers that process untrusted input. It also ensures that
 if your Lua app crashes, it won't take down the server as a whole.
 Hence it should come as no surprise that `fork()` would go slower on
 operating systems that have more security features. So depending on
 your use case, you can choose the operating system that suits you.

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### commandv

```teal
function commandv(prog: string): string | nil, string | nil, Errno | nil
```

 Performs `$PATH` lookup of executable.
     unix = require 'unix'
     prog = assert(unix.commandv('ls'))
     unix.execve(prog, {prog, '-hal', '.'}, {'PATH=/bin'})
     unix.exit(127)
 If `prog` is an absolute path, then it's returned as-is. If `prog`
 contains slashes then it's not path searched either and will be
 returned if it exists. On Windows, it's recommended that you install
 programs from cosmos to c:/bin/ without any .exe or .com suffix, so
 they can be discovered like they would on UNIX. If you want to find
 a program like notepad on the $PATH using this function, then you
 need to specify "notepad.exe" so it includes the extension.

**Parameters:**

- `prog` (string)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### execve

```teal
function execve(prog: string, args: {string}, env: {string}): nil, string | nil, Errno | nil
```

 Exits current process, replacing it with a new instance of the
 specified program. `prog` needs to be an absolute path, see
 commandv(). `env` defaults to to the current `environ`. Here's
 a basic usage example:
     unix.execve("/bin/ls", {"/bin/ls", "-hal"}, {"PATH=/bin"})
     unix.exit(127)
 `prog` needs to be the resolved pathname of your executable. You
 can use commandv() to search your `PATH`.
 `args` is a string list table. The first element in `args`
 should be `prog`. Values are coerced to strings. This parameter
 defaults to `{prog}`.
 `env` is a string list table. Values are coerced to strings. No
 ordering requirement is imposed. By convention, each string has its
 key and value divided by an equals sign without spaces. If this
 parameter is not specified, it'll default to the C/C++ `environ`
 variable which is inherited from the shell that launched redbean.
 It's the responsibility of the user to supply a sanitized environ
 when spawning untrusted processes.
 `execve()` is normally called after `fork()` returns `0`. If that isn't
 the case, then your redbean worker will be destroyed.
 This function never returns on success.
 `EAGAIN` is returned if you've enforced a max number of
 processes using `setrlimit(RLIMIT_NPROC)`.

**Parameters:**

- `prog` (string)
- `args` ({string})
- `env` ({string})

**Returns:**

- nil
- string | nil
- Errno | nil

### execvp

```teal
function execvp(prog: string, argv?: {string}): nil, string | nil, Errno | nil
```

 Executes program with PATH search.
 Unlike `execve()`, this function searches for `prog` in the
 directories listed in the `PATH` environment variable.
 If `argv` is not provided, it defaults to `{prog}`.
 This function never returns on success.

**Parameters:**

- `prog` (string)
- `argv` ({string})

**Returns:**

- nil
- string | nil
- Errno | nil

### execvpe

```teal
function execvpe(prog: string, argv: {string}, envp?: {string}): nil, string | nil, Errno | nil
```

 Executes program with PATH search and custom environment.
 Like `execvp()` but also allows specifying a custom environment.
 `envp` is a string list table where each string is typically
 in the form `"KEY=value"`. If not specified, inherits the
 current environment.
 This function never returns on success.

**Parameters:**

- `prog` (string)
- `argv` ({string})
- `envp` ({string})

**Returns:**

- nil
- string | nil
- Errno | nil

### fexecve

```teal
function fexecve(fd: integer, argv: {string}, envp?: {string}): nil, string | nil, Errno | nil
```

 Executes program from file descriptor.
 This allows executing a program that has already been opened,
 which can be useful for executing programs that have been
 verified or for executing APE (Actually Portable Executable)
 binaries.
 `fd` is an open file descriptor pointing to an executable.
 `argv` is the argument vector passed to the program.
 `envp` is the environment. If not specified, inherits the
 current environment.
 This function never returns on success.

**Parameters:**

- `fd` (integer)
- `argv` ({string})
- `envp` ({string})

**Returns:**

- nil
- string | nil
- Errno | nil

### spawn

```teal
function spawn(prog: string, argv: {string}, envp?: {string}): integer | nil, string | nil, Errno | nil
```

 Spawns a new process.
 Unlike `fork()` + `execve()`, this uses `posix_spawn()` which
 can be more efficient on some platforms.
 `prog` must be an explicit path to the executable.
 `argv` is the argument vector passed to the program.
 `envp` is the environment. If not specified, inherits the
 current environment.
 Returns the child process id on success.

**Parameters:**

- `prog` (string)
- `argv` ({string})
- `envp` ({string})

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### spawnp

```teal
function spawnp(prog: string, argv: {string}, envp?: {string}): integer | nil, string | nil, Errno | nil
```

 Spawns a new process with PATH search.
 Like `spawn()` but searches for `prog` in the directories
 listed in the `PATH` environment variable.
 Returns the child process id on success.

**Parameters:**

- `prog` (string)
- `argv` ({string})
- `envp` ({string})

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### dup

```teal
function dup(oldfd: integer, newfd?: integer, flags?: integer, lowest?: integer): integer | nil, string | nil, Errno | nil
```

 Duplicates file descriptor.
 `newfd` may be specified to choose a specific number for the new
 file descriptor. If it's already open, then the preexisting one will
 be silently closed. `EINVAL` is returned if `newfd` equals `oldfd`.
 `flags` can have `O_CLOEXEC` which means the returned file
 descriptors will be automatically closed upon execve().
 `lowest` defaults to zero and defines the lowest numbered file
 descriptor that's acceptable to use. If `newfd` is specified then
 `lowest` is ignored. For example, if you wanted to duplicate
 standard input, then:
     stdin2 = assert(unix.dup(0, nil, unix.O_CLOEXEC, 3))
 Will ensure that, in the rare event standard output or standard
 error are closed, you won't accidentally duplicate standard input to
 those numbers.

**Parameters:**

- `oldfd` (integer)
- `newfd` (integer)
- `flags` (integer)
- `lowest` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### pipe

```teal
function pipe(flags?: integer): integer | nil, integer, string | nil, Errno | nil
```

 Creates fifo which enables communication between processes.
 - `O_CLOEXEC`: Automatically close file descriptor upon execve()
 - `O_NONBLOCK`: Request `EAGAIN` be raised rather than blocking
 - `O_DIRECT`: Enable packet mode w/ atomic reads and writes, so long
   as they're no larger than `PIPE_BUF` (guaranteed to be 512+ bytes)
   with support limited to Linux, Windows NT, FreeBSD, and NetBSD.
 Returns two file descriptors: one for reading and one for writing.
 Here's an example of how pipe(), fork(), dup(), etc. may be used
 to serve an HTTP response containing the output of a subprocess.
     local unix = require "unix"
     ls = assert(unix.commandv("ls"))
     reader, writer = assert(unix.pipe())
     if assert(unix.fork()) == 0 then
        unix.close(1)
        unix.dup(writer)
        unix.close(writer)
        unix.close(reader)
        unix.execve(ls, {ls, "-Shal"})
        unix.exit(127)
     else
        unix.close(writer)
        SetHeader('Content-Type', 'text/plain')
        while true do
           data, err, errno = unix.read(reader)
           if data then
              if data ~= "" then
                 Write(data)
              else
                 break
              end
           elseif errno ~= EINTR then
              Log(kLogWarn, err)
              break
           end
        end
        assert(unix.close(reader))
        assert(unix.wait())
     end

**Parameters:**

- `flags` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### wait

```teal
function wait(pid?: integer, options?: integer): integer | nil, integer, Rusage, string | nil, Errno | nil
```

 Waits for subprocess to terminate.
 `pid` defaults to `-1` which means any child process. Setting
 `pid` to `0` is equivalent to `-getpid()`. If `pid < -1` then
 that means wait for any pid in the process group `-pid`. Then
 lastly if `pid > 0` then this waits for a specific process id
 Options may have `WNOHANG` which means don't block, check for
 the existence of processes that are already dead (technically
 speaking zombies) and if so harvest them immediately.
 Returns the process id of the child that terminated. In other
 cases, the returned `pid` is nil and `errno` is non-nil.
 The returned `wstatus` contains information about the process
 exit status. It's a complicated integer and there's functions
 that can help interpret it. For example:
     -- wait for zombies
     -- traditional technique for SIGCHLD handlers
     while true do
        pid, status, errno = unix.wait(-1, unix.WNOHANG)
        if pid then
           if unix.WIFEXITED(status) then
              print('child', pid, 'exited with',
                    unix.WEXITSTATUS(status))
           elseif unix.WIFSIGNALED(status) then
              print('child', pid, 'crashed with',
                    unix.strsignal(unix.WTERMSIG(status)))
           end
        elseif errno == unix.ECHILD then
           Log(kLogDebug, 'no more zombies')
           break
        else
           Log(kLogWarn, status)
           break
        end
     end

**Parameters:**

- `pid` (integer)
- `options` (integer)

**Returns:**

- integer | nil
- integer
- Rusage
- string | nil
- Errno | nil

### WIFEXITED

```teal
function WIFEXITED(wstatus: integer): boolean
```

 Returns `true` if process exited cleanly.

**Parameters:**

- `wstatus` (integer)

**Returns:**

- boolean

### WEXITSTATUS

```teal
function WEXITSTATUS(wstatus: integer): integer
```

 Returns code passed to exit() assuming `WIFEXITED(wstatus)` is true.

**Parameters:**

- `wstatus` (integer)

**Returns:**

- integer

### WIFSIGNALED

```teal
function WIFSIGNALED(wstatus: integer): boolean
```

 Returns `true` if process terminated due to a signal.

**Parameters:**

- `wstatus` (integer)

**Returns:**

- boolean

### WTERMSIG

```teal
function WTERMSIG(wstatus: integer): integer
```

 Returns signal that caused process to terminate assuming
 `WIFSIGNALED(wstatus)` is `true`.

**Parameters:**

- `wstatus` (integer)

**Returns:**

- integer

### getpid

```teal
function getpid(): integer
```

 Returns process id of current process.
 This function does not fail.

**Returns:**

- integer

### getppid

```teal
function getppid(): integer
```

 Returns process id of parent process.
 This function does not fail.

**Returns:**

- integer

### kill

```teal
function kill(pid: integer, sig: integer): boolean | nil, string | nil, Errno | nil
```

 Sends signal to process(es).
 The impact of this action can be terminating the process, or
 interrupting it to request something happen.
 `pid` can be:
 - `pid > 0` signals one process by id
 - `== 0`    signals all processes in current process group
 - `-1`      signals all processes possible (except init)
 - `< -1`    signals all processes in -pid process group
 `sig` can be:
 - `0`       checks both if pid exists and we can signal it
 - `SIGINT`  sends ctrl-c keyboard interrupt
 - `SIGQUIT` sends backtrace and exit signal
 - `SIGTERM` sends shutdown signal
 - etc.
 Windows NT only supports the kill() signals required by the ANSI C89
 standard, which are `SIGINT` and `SIGQUIT`. All other signals on the
 Windows platform that are sent to another process via kill() will be
 treated like `SIGKILL`.

**Parameters:**

- `pid` (integer)
- `sig` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### killpg

```teal
function killpg(pgrp: integer, sig: integer): boolean | nil, string | nil, Errno | nil
```

 Sends signal to process group.
 This is similar to `kill()` but sends the signal to all processes
 in the specified process group.
 `pgrp` is the process group id. If 0, sends to the calling process's
 process group.
 `sig` can be any signal value (e.g., `SIGTERM`, `SIGKILL`, etc.).

**Parameters:**

- `pgrp` (integer)
- `sig` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### raise

```teal
function raise(sig: integer): integer | nil, string | nil, Errno | nil
```

 Triggers signal in current process.
 This is pretty much the same as `kill(getpid(), sig)`.

**Parameters:**

- `sig` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### access

```teal
function access(path: string, how: integer, flags?: integer, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Checks if effective user of current process has permission to access file.
 - `AT_SYMLINK_NOFOLLOW`: do not follow symbolic links.

**Parameters:**

- `path` (string)
- `how` (integer)
- `flags` (integer)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### mkdir

```teal
function mkdir(path: string, mode?: integer, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Makes directory.
 `path` is the path of the directory you wish to create.
 `mode` is octal permission bits, e.g. `0755`.
 Fails with `EEXIST` if `path` already exists, whether it be a
 directory or a file.
 Fails with `ENOENT` if the parent directory of the directory you
 want to create doesn't exist. For making `a/really/long/path/`
 consider using makedirs() instead.
 Fails with `ENOTDIR` if a parent directory component existed that
 wasn't a directory.
 Fails with `EACCES` if the parent directory doesn't grant write
 permission to the current user.
 Fails with `ENAMETOOLONG` if the path is too long.

**Parameters:**

- `path` (string)
- `mode` (integer)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### makedirs

```teal
function makedirs(path: string, mode?: integer): boolean | nil, string | nil, Errno | nil
```

 Unlike mkdir() this convenience wrapper will automatically create
 parent parent directories as needed. If the directory already exists
 then, unlike mkdir() which returns EEXIST, the makedirs() function
 will return success.
 `path` is the path of the directory you wish to create.
 `mode` is octal permission bits, e.g. `0755`.

**Parameters:**

- `path` (string)
- `mode` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### mkdtemp

```teal
function mkdtemp(template: string): string | nil, string | nil, Errno | nil
```

 Creates a temporary directory with a unique name.
 `template` must end with "XXXXXX" which will be replaced with random
 characters to create a unique directory name.
 Returns the path of the created directory.
 Example:
     local tmpdir = unix.mkdtemp("/tmp/myapp_XXXXXX")
     -- tmpdir is now something like "/tmp/myapp_a3b2c1"

**Parameters:**

- `template` (string)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### mkstemp

```teal
function mkstemp(template: string): integer | nil, string, string | nil, Errno | nil
```

 Creates a temporary file with a unique name.
 `template` must end with "XXXXXX" which will be replaced with random
 characters to create a unique filename.
 Returns both the file descriptor and the path of the created file.
 The file is opened for reading and writing.
 Example:
     local fd, path = unix.mkstemp("/tmp/myapp_XXXXXX")
     unix.write(fd, "hello")
     unix.close(fd)
     unix.unlink(path)

**Parameters:**

- `template` (string)

**Returns:**

- integer | nil
- string
- string | nil
- Errno | nil

### chdir

```teal
function chdir(path: string): boolean | nil, string | nil, Errno | nil
```

 Changes current directory to `path`.

**Parameters:**

- `path` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### unlink

```teal
function unlink(path: string, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Removes file at `path`.
 If `path` refers to a symbolic link, the link is removed.
 Returns `EISDIR` if `path` refers to a directory. See `rmdir()`.

**Parameters:**

- `path` (string)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### rmdir

```teal
function rmdir(path: string, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Removes empty directory at `path`.
 Returns `ENOTDIR` if `path` isn't a directory, or a path component
 in `path` exists yet wasn't a directory.

**Parameters:**

- `path` (string)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### rename

```teal
function rename(oldpath: string, newpath: string, olddirfd: integer, newdirfd: integer): boolean | nil, string | nil, Errno | nil
```

 Renames file or directory.

**Parameters:**

- `oldpath` (string)
- `newpath` (string)
- `olddirfd` (integer)
- `newdirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### link

```teal
function link(existingpath: string, newpath: string, flags: integer, olddirfd: integer, newdirfd: integer): boolean | nil, string | nil, Errno | nil
```

 Creates hard link, so your underlying inode has two names.

**Parameters:**

- `existingpath` (string)
- `newpath` (string)
- `flags` (integer)
- `olddirfd` (integer)
- `newdirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### symlink

```teal
function symlink(target: string, linkpath: string, newdirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Creates symbolic link.
 On Windows NT a symbolic link is called a "reparse point" and can
 only be created from an administrator account. Your redbean will
 automatically request the appropriate permissions.

**Parameters:**

- `target` (string)
- `linkpath` (string)
- `newdirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### readlink

```teal
function readlink(path: string, dirfd?: integer): string | nil, string | nil, Errno | nil
```

 Reads contents of symbolic link.
 Note that broken links are supported on all platforms. A symbolic
 link can contain just about anything. It's important to not assume
 that `content` will be a valid filename.
 On Windows NT, this function transliterates `\` to `/` and
 furthermore prefixes `//?/` to WIN32 DOS-style absolute paths,
 thereby assisting with simple absolute filename checks in addition
 to enabling one to exceed the traditional 260 character limit.

**Parameters:**

- `path` (string)
- `dirfd` (integer)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### realpath

```teal
function realpath(path: string): string | nil, string | nil, Errno | nil
```

 Returns absolute path of filename, with `.` and `..` components
 removed, and symlinks will be resolved.

**Parameters:**

- `path` (string)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### utimensat

```teal
function utimensat(path: string, asecs: integer, ananos: integer, msecs: integer, mnanos: integer, dirfd?: integer, flags?: integer): integer | nil, string | nil, Errno | nil
```

 Changes access and/or modified timestamps on file.
 `path` is a string with the name of the file.
 The `asecs` and `ananos` parameters set the access time. If they're
 none or nil, the current time will be used.
 The `msecs` and `mnanos` parameters set the modified time. If
 they're none or nil, the current time will be used.
 The nanosecond parameters (`ananos` and `mnanos`) must be on the
 interval [0,1000000000) or `unix.EINVAL` is raised. On XNU this is
 truncated to microsecond precision. On Windows NT, it's truncated to
 hectonanosecond precision. These nanosecond parameters may also be
 set to one of the following special values:
 - `unix.UTIME_NOW`: Fill this timestamp with current time. This
 feature is not available on old versions of Linux, e.g. RHEL5.
 - `unix.UTIME_OMIT`: Do not alter this timestamp. This feature is
 not available on old versions of Linux, e.g. RHEL5.
 `dirfd` is a file descriptor integer opened with `O_DIRECTORY`
 that's used for relative path names. It defaults to `unix.AT_FDCWD`.
 `flags` may have have any of the following flags bitwise or'd
 - `AT_SYMLINK_NOFOLLOW`: Do not follow symbolic links. This makes it
 possible to edit the timestamps on the symbolic link itself,
 rather than the file it points to.

**Parameters:**

- `path` (string)
- `asecs` (integer)
- `ananos` (integer)
- `msecs` (integer)
- `mnanos` (integer)
- `dirfd` (integer)
- `flags` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### futimens

```teal
function futimens(fd: integer, asecs: integer, ananos: integer, msecs: integer, mnanos: integer): integer | nil, string | nil, Errno | nil
```

 Changes access and/or modified timestamps on file descriptor.
 `fd` is the file descriptor of a file opened with `unix.open`.
 The `asecs` and `ananos` parameters set the access time. If they're
 none or nil, the current time will be used.
 The `msecs` and `mnanos` parameters set the modified time. If
 they're none or nil, the current time will be used.
 The nanosecond parameters (`ananos` and `mnanos`) must be on the
 interval [0,1000000000) or `unix.EINVAL` is raised. On XNU this is
 truncated to microsecond precision. On Windows NT, it's truncated to
 hectonanosecond precision. These nanosecond parameters may also be
 set to one of the following special values:
 - `unix.UTIME_NOW`: Fill this timestamp with current time.
 - `unix.UTIME_OMIT`: Do not alter this timestamp.
 This system call is currently not available on very old versions of
 Linux, e.g. RHEL5.

**Parameters:**

- `fd` (integer)
- `asecs` (integer)
- `ananos` (integer)
- `msecs` (integer)
- `mnanos` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### chown

```teal
function chown(path: string, uid: integer, gid: integer, flags?: integer, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Changes user and group on file.
 Returns `ENOSYS` on Windows NT.

**Parameters:**

- `path` (string)
- `uid` (integer)
- `gid` (integer)
- `flags` (integer)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### chmod

```teal
function chmod(path: string, mode: integer, flags?: integer, dirfd?: integer): boolean | nil, string | nil, Errno | nil
```

 Changes mode bits on file.
 On Windows NT the chmod system call only changes the read-only
 status of a file.

**Parameters:**

- `path` (string)
- `mode` (integer)
- `flags` (integer)
- `dirfd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getcwd

```teal
function getcwd(): string | nil, string | nil, Errno | nil
```

 Returns current working directory.
 On Windows NT, this function transliterates `\` to `/` and
 furthermore prefixes `//?/` to WIN32 DOS-style absolute paths,
 thereby assisting with simple absolute filename checks in addition
 to enabling one to exceed the traditional 260 character limit.

**Returns:**

- string | nil
- string | nil
- Errno | nil

### rmrf

```teal
function rmrf(path: string): boolean | nil, string | nil, Errno | nil
```

 Recursively removes filesystem path.
 Like `unix.makedirs()` this function isn't actually a system call but
 rather is a Libc convenience wrapper. It's intended to be equivalent
 to using the UNIX shell's `rm -rf path` command.

**Parameters:**

- `path` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### fcntl

```teal
function fcntl(fd: integer, cmd: FcntlCmd, ...: any): any | nil, string | nil, Errno | nil
```

 Manipulates file descriptor.
 `cmd` may be one of:
 - `unix.F_GETFD` Returns file descriptor flags.
 - `unix.F_SETFD` Sets file descriptor flags.
 - `unix.F_GETFL` Returns file descriptor status flags.
 - `unix.F_SETFL` Sets file descriptor status flags.
 - `unix.F_SETLK` Acquires lock on file interval.
 - `unix.F_SETLKW` Waits for lock on file interval.
 - `unix.F_GETLK` Acquires information about lock.
 unix.fcntl(fd:int, unix.F_GETFD)
     ├─→ flags:int
     └─→ nil, string, integer
   Returns file descriptor flags.
   The returned `flags` may include any of:
   - `unix.FD_CLOEXEC` if `fd` was opened with `unix.O_CLOEXEC`.
   Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_SETFD, flags:int)
     ├─→ true
     └─→ nil, string, integer
   Sets file descriptor flags.
   `flags` may include any of:
   - `unix.FD_CLOEXEC` to re-open `fd` with `unix.O_CLOEXEC`.
   Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_GETFL)
     ├─→ flags:int
     └─→ nil, string, integer
   Returns file descriptor status flags.
   `flags & unix.O_ACCMODE` includes one of:
   - `O_RDONLY`
   - `O_WRONLY`
   - `O_RDWR`
   Examples of values `flags & ~unix.O_ACCMODE` may include:
   - `O_NONBLOCK`
   - `O_APPEND`
   - `O_SYNC`
   - `O_NOATIME` on Linux
   - `O_DIRECT` on Linux/FreeBSD/NetBSD/Windows
   Examples of values `flags & ~unix.O_ACCMODE` won't include:
   - `O_CREAT`
   - `O_TRUNC`
   - `O_EXCL`
   - `O_NOCTTY`
   Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_SETFL, flags:int)
     ├─→ true
     └─→ nil, string, integer
   Changes file descriptor status flags.
   Examples of values `flags` may include:
   - `O_NONBLOCK`
   - `O_APPEND`
   - `O_SYNC`
   - `O_NOATIME` on Linux
   - `O_DIRECT` on Linux/FreeBSD/NetBSD/Windows
   These values should be ignored:
   - `O_RDONLY`, `O_WRONLY`, `O_RDWR`
   - `O_CREAT`, `O_TRUNC`, `O_EXCL`
   - `O_NOCTTY`
   Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_SETLK[, type[, start[, len[, whence]]]])
 unix.fcntl(fd:int, unix.F_SETLKW[, type[, start[, len[, whence]]]])
     ├─→ true
     └─→ nil, string, integer
   Acquires lock on file interval.
   POSIX Advisory Locks allow multiple processes to leave voluntary
   hints to each other about which portions of a file they're using.
   The command may be:
   - `F_SETLK` to acquire lock if possible
   - `F_SETLKW` to wait for lock if necessary
   `fd` is file descriptor of open() file.
   `type` may be one of:
   - `F_RDLCK` for read lock (default)
   - `F_WRLCK` for read/write lock
   - `F_UNLCK` to unlock
   `start` is 0-indexed byte offset into file. The default is zero.
   `len` is byte length of interval. Zero is the default and it means
   until the end of the file.
   `whence` may be one of:
   - `SEEK_SET` start from beginning (default)
   - `SEEK_CUR` start from current position
   - `SEEK_END` start from end
   Returns `EAGAIN` if lock couldn't be acquired. POSIX says this
   theoretically could also be `EACCES` but we haven't seen this
   behavior on any of our supported platforms.
   Returns `EBADF` if `fd` wasn't open.
 unix.fcntl(fd:int, unix.F_GETLK[, type[, start[, len[, whence]]]])
     ├─→ unix.F_UNLCK
     ├─→ type, start, len, whence, pid
     └─→ nil, string, integer
   Acquires information about POSIX advisory lock on file.
   This function accepts the same parameters as fcntl(F_SETLK) and
   tells you if the lock acquisition would be successful for a given
   range of bytes. If locking would have succeeded, then F_UNLCK is
   returned. If the lock would not have succeeded, then information
   about a conflicting lock is returned.
   Returned `type` may be `F_RDLCK` or `F_WRLCK`.
   Returned `pid` is the process id of the current lock owner.
   This function is currently not supported on Windows.
   Returns `EBADF` if `fd` wasn't open.

**Parameters:**

- `fd` (integer)
- `cmd` (FcntlCmd)
- `...` (any)

**Returns:**

- any | nil
- string | nil
- Errno | nil

### getsid

```teal
function getsid(pid: integer): integer | nil, string | nil, Errno | nil
```

 Gets session id.

**Parameters:**

- `pid` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### getpgrp

```teal
function getpgrp(): integer | nil, string | nil, Errno | nil
```

 Gets process group id.

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### setpgrp

```teal
function setpgrp(): integer | nil, string | nil, Errno | nil
```

 Sets process group id. This is the same as `setpgid(0,0)`.

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### setpgid

```teal
function setpgid(pid: integer, pgid: integer): boolean | nil, string | nil, Errno | nil
```

 Sets process group id the modern way.

**Parameters:**

- `pid` (integer)
- `pgid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getpgid

```teal
function getpgid(pid: integer): integer | nil, string | nil, Errno | nil
```

 Gets process group id the modern way.

**Parameters:**

- `pid` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### setsid

```teal
function setsid(): integer | nil, string | nil, Errno | nil
```

 Sets session id.
 This function can be used to create daemons.
 Fails with `ENOSYS` on Windows NT.

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### daemon

```teal
function daemon(nochdir?: boolean, noclose?: boolean): boolean | nil, string | nil, Errno | nil
```

 Daemonizes the current process.
 This function performs the standard Unix daemonization steps:
 forks, creates a new session, and optionally changes directory
 and redirects standard file descriptors.
 `nochdir` if true, the current working directory is not changed
 to `/`. Defaults to false (will change to `/`).
 `noclose` if true, stdin/stdout/stderr are not redirected to
 `/dev/null`. Defaults to false (will redirect to `/dev/null`).
 This is a convenience wrapper that combines `fork()`, `setsid()`,
 and related operations.

**Parameters:**

- `nochdir` (boolean)
- `noclose` (boolean)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getuid

```teal
function getuid(): integer
```

 Gets real user id.
 On Windows this system call is polyfilled by running `GetUserNameW()`
 through Knuth's multiplicative hash.
 This function does not fail.

**Returns:**

- integer

### getgid

```teal
function getgid(): integer
```

 Sets real group id.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- integer

### geteuid

```teal
function geteuid(): integer
```

 Gets effective user id.
 For example, if your redbean is a setuid binary, then getuid() will
 return the uid of the user running the program, and geteuid() shall
 return zero which means root, assuming that's the file owning user.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- integer

### getegid

```teal
function getegid(): integer
```

 Gets effective group id.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- integer

### chroot

```teal
function chroot(path: string): boolean | nil, string | nil, Errno | nil
```

 Changes root directory.
 Returns `ENOSYS` on Windows NT.

**Parameters:**

- `path` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setuid

```teal
function setuid(uid: integer): boolean | nil, string | nil, Errno | nil
```

 Sets user id.
 One use case for this function is dropping root privileges. Should
 you ever choose to run redbean as root and decide not to use the
 `-G` and `-U` flags, you can replicate that behavior in the Lua
 processes you spawn as follows:
    ok, err = unix.setgid(1000)  -- check your /etc/groups
    if not ok then Log(kLogFatal, tostring(err)) end
    ok, err = unix.setuid(1000)  -- check your /etc/passwd
    if not ok then Log(kLogFatal, tostring(err)) end
 If your goal is to relinquish privileges because redbean is a setuid
 binary, then things are more straightforward:
    ok, err = unix.setgid(unix.getgid())
    if not ok then Log(kLogFatal, tostring(err)) end
    ok, err = unix.setuid(unix.getuid())
    if not ok then Log(kLogFatal, tostring(err)) end
 See also the setresuid() function and be sure to refer to your local
 system manual about the subtleties of changing user id in a way that
 isn't restorable.
 Returns `ENOSYS` on Windows NT if `uid` isn't `getuid()`.

**Parameters:**

- `uid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setfsuid

```teal
function setfsuid(uid: integer): boolean | nil, string | nil, Errno | nil
```

 Sets user id for file system ops.

**Parameters:**

- `uid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setfsgid

```teal
function setfsgid(gid: integer): boolean | nil, string | nil, Errno | nil
```

 Sets group id for file system ops.

**Parameters:**

- `gid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setgid

```teal
function setgid(gid: integer): boolean | nil, string | nil, Errno | nil
```

 Sets group id.
 Returns `ENOSYS` on Windows NT if `gid` isn't `getgid()`.

**Parameters:**

- `gid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setresuid

```teal
function setresuid(real: integer, effective: integer, saved: integer): boolean | nil, string | nil, Errno | nil
```

 Sets real, effective, and saved user ids.
 If any of the above parameters are -1, then it's a no-op.
 Returns `ENOSYS` on Windows NT.
 Returns `ENOSYS` on Macintosh and NetBSD if `saved` isn't -1.

**Parameters:**

- `real` (integer)
- `effective` (integer)
- `saved` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setresgid

```teal
function setresgid(real: integer, effective: integer, saved: integer): boolean | nil, string | nil, Errno | nil
```

 Sets real, effective, and saved group ids.
 If any of the above parameters are -1, then it's a no-op.
 Returns `ENOSYS` on Windows NT.
 Returns `ENOSYS` on Macintosh and NetBSD if `saved` isn't -1.

**Parameters:**

- `real` (integer)
- `effective` (integer)
- `saved` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### umask

```teal
function umask(newmask: integer): integer
```

 Sets file permission mask and returns the old one.
 This is used to remove bits from the `mode` parameter of functions
 like open() and mkdir(). The masks typically used are 027 and 022.
 Those masks ensure that, even if a file is created with 0666 bits,
 it'll be turned into 0640 or 0644 so that users other than the owner
 can't modify it.
 To read the mask without changing it, try doing this:
     mask = unix.umask(027)
     unix.umask(mask)
 On Windows NT this is a no-op and `mask` is returned.
 This function does not fail.

**Parameters:**

- `newmask` (integer)

**Returns:**

- integer

### sysconf

```teal
function sysconf(name: integer): integer | nil, string | nil, Errno | nil
```

 Queries a configurable system limit or value.
 `name` selects which value to return, e.g.
     unix.sysconf(unix.SC_NPROCESSORS_ONLN)  -- online cpu count
     unix.sysconf(unix.SC_PAGESIZE)          -- mmap() page size
     unix.sysconf(unix.SC_CLK_TCK)           -- clock ticks per second
 Returns `nil` with an `EINVAL` errno when `name` isn't recognized.

**Parameters:**

- `name` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### uname

```teal
function uname(): Uname | nil, string | nil, Errno | nil
```

 Returns identity of the current operating system.
 Example:
     local u = assert(unix.uname())
     print(u.sysname, u.release, u.machine)

**Returns:**

- Uname | nil
- string | nil
- Errno | nil

### syslog

```teal
function syslog(priority: integer, msg: string)
```

 Generates a log message, which will be distributed by syslogd.
 `priority` is a bitmask containing the facility value and the level
 value. If no facility value is ORed into priority, then the default
 value set by openlog() is used. If set to NULL, the program name is
 used. Level is one of `LOG_EMERG`, `LOG_ALERT`, `LOG_CRIT`,
 `LOG_ERR`, `LOG_WARNING`, `LOG_NOTICE`, `LOG_INFO`, `LOG_DEBUG`.
 This function currently works on Linux, Windows, and NetBSD. On
 WIN32 it uses the ReportEvent() facility.

**Parameters:**

- `priority` (integer)
- `msg` (string)

### clock_gettime

```teal
function clock_gettime(clock?: integer): integer | nil, integer, string | nil, Errno | nil
```

 Returns nanosecond precision timestamp from system, e.g.
    >: unix.clock_gettime()
    1651137352      774458779
    >: Benchmark(unix.clock_gettime)
    126     393     571     1
 `clock` can be any one of of:
 - `CLOCK_REALTIME` returns a wall clock timestamp represented in
   nanoseconds since the UNIX epoch (~1970). It'll count time in the
   suspend state. This clock is subject to being smeared by various
   adjustments made by NTP. These timestamps can have unpredictable
   discontinuous jumps when clock_settime() is used. Therefore this
   clock is the default clock for everything, even pthread condition
   variables. Cosmopoiltan guarantees this clock will never raise
   `EINVAL` and also guarantees `CLOCK_REALTIME == 0` will always be
   the case. On Windows this maps to GetSystemTimePreciseAsFileTime().
   On platforms with vDSOs like Linux, Windows, and MacOS ARM64 this
   should take about 20 nanoseconds.
 - `CLOCK_MONOTONIC` returns a timestamp with an unspecified epoch,
   that should be when the system was powered on. These timestamps
   shouldn't go backwards. Timestamps shouldn't count time spent in
   the sleep, suspend, and hibernation states. These timestamps won't
   be impacted by clock_settime(). These timestamps may be impacted by
   frequency adjustments made by NTP. Cosmopoiltan guarantees this
   clock will never raise `EINVAL`. MacOS and BSDs use the word
   "uptime" to describe this clock. On Windows this maps to
   QueryUnbiasedInterruptTimePrecise().
 - `CLOCK_BOOTTIME` is a monotonic clock returning a timestamp with an
   unspecified epoch, that should be relative to when the host system
   was powered on. These timestamps shouldn't go backwards. Timestamps
   should also include time spent in a sleep, suspend, or hibernation
   state. These timestamps aren't impacted by clock_settime(), but
   they may be impacted by frequency adjustments made by NTP. This
   clock will raise an `EINVAL` error on extremely old Linux distros
   like RHEL5. MacOS and BSDs use the word "monotonic" to describe
   this clock. On Windows this maps to QueryInterruptTimePrecise().
 - `CLOCK_MONOTONIC_RAW` returns a timestamp from an unspecified
   epoch. These timestamps don't count time spent in the sleep,
   suspend, and hibernation states. Unlike `CLOCK_MONOTONIC` this
   clock is guaranteed to not be impacted by frequency adjustments or
   discontinuous jumps caused by clock_settime(). Providing this level
   of assurances may make this clock slower than the normal monotonic
   clock. Furthermore this clock may cause `EINVAL` to be raised if
   running on a host system that doesn't provide those guarantees,
   e.g. OpenBSD and MacOS on AMD64.
 - `CLOCK_REALTIME_COARSE` is the same as `CLOCK_REALTIME` except
   it'll go faster if the host OS provides a cheaper way to read the
   wall time. Please be warned that coarse can be really coarse.
   Rather than nano precision, you're looking at `CLK_TCK` precision,
   which can lag as far as 30 milliseconds behind or possibly more.
   Cosmopolitan may fallback to `CLOCK_REALTIME` if a faster less
   accurate clock isn't provided by the system. This clock will raise
   an `EINVAL` error on extremely old Linux distros like RHEL5.
 - `CLOCK_MONOTONIC_COARSE` is the same as `CLOCK_MONOTONIC` except
   it'll go faster if the host OS provides a cheaper way to read the
   unbiased time. Please be warned that coarse can be really coarse.
   Rather than nano precision, you're looking at `CLK_TCK` precision,
   which can lag as far as 30 milliseconds behind or possibly more.
   Cosmopolitan may fallback to `CLOCK_REALTIME` if a faster less
   accurate clock isn't provided by the system. This clock will raise
   an `EINVAL` error on extremely old Linux distros like RHEL5.
 - `CLOCK_PROCESS_CPUTIME_ID` returns the amount of time this process
   was actively scheduled. This is similar to getrusage() and clock().
   Cosmopoiltan guarantees this clock will never raise `EINVAL`.
 - `CLOCK_THREAD_CPUTIME_ID` returns the amount of time this thread
   was actively scheduled. This is similar to getrusage() and clock().
   Cosmopoiltan guarantees this clock will never raise `EINVAL`.
 Returns `EINVAL` if clock isn't supported on platform.
 This function only fails if `clock` is invalid.
 This function goes fastest on Linux and Windows.

**Parameters:**

- `clock` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### nanosleep

```teal
function nanosleep(seconds: integer, nanos?: integer): integer | nil, integer, string | nil, Errno | nil
```

 Sleeps with nanosecond precision.
 Returns `EINTR` if a signal was received while waiting.

**Parameters:**

- `seconds` (integer)
- `nanos` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### sync

```teal
function sync()
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

### fsync

```teal
function fsync(fd: integer): boolean | nil, string | nil, Errno | nil
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

**Parameters:**

- `fd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### fdatasync

```teal
function fdatasync(fd: integer): boolean | nil, string | nil, Errno | nil
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

**Parameters:**

- `fd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### lseek

```teal
function lseek(fd: integer, offset: integer, whence?: integer): integer | nil, string | nil, Errno | nil
```

 Seeks to file position.
 `whence` can be one of:
 - `SEEK_SET`: Sets the file position to `offset` [default]
 - `SEEK_CUR`: Sets the file position to `position + offset`
 - `SEEK_END`: Sets the file position to `filesize + offset`
 Returns the new position relative to the start of the file.

**Parameters:**

- `fd` (integer)
- `offset` (integer)
- `whence` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### truncate

```teal
function truncate(path: string, length?: integer): boolean | nil, string | nil, Errno | nil
```

 Reduces or extends underlying physical medium of file.
 If file was originally larger, content >length is lost.

**Parameters:**

- `path` (string)
- `length` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### ftruncate

```teal
function ftruncate(fd: integer, length?: integer): boolean | nil, string | nil, Errno | nil
```

 Reduces or extends underlying physical medium of open file.
 If file was originally larger, content >length is lost.

**Parameters:**

- `fd` (integer)
- `length` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### socket

```teal
function socket(family?: integer, type?: integer, protocol?: integer): integer | nil, string | nil, Errno | nil
```

 - `AF_INET`: Creates Internet Protocol Version 4 (IPv4) socket.
 - `AF_UNIX`: Creates local UNIX domain socket. On the New Technology
 this requires Windows 10 and only works with `SOCK_STREAM`.
 - `SOCK_STREAM`
 - `SOCK_DGRAM`
 - `SOCK_RAW`
 - `SOCK_RDM`
 - `SOCK_SEQPACKET`
 You may bitwise OR any of the following into `type`:
 - `SOCK_CLOEXEC`
 - `SOCK_NONBLOCK`
 - `0` to let kernel choose [default]
 - `IPPROTO_TCP`
 - `IPPROTO_UDP`
 - `IPPROTO_RAW`
 - `IPPROTO_IP`
 - `IPPROTO_ICMP`

**Parameters:**

- `family` (integer)
- `type` (integer)
- `protocol` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### socketpair

```teal
function socketpair(family?: integer, type?: integer, protocol?: integer): integer | nil, integer, string | nil, Errno | nil
```

 Creates bidirectional pipe.
 - `SOCK_STREAM`
 - `SOCK_DGRAM`
 - `SOCK_SEQPACKET`
 You may bitwise OR any of the following into `type`:
 - `SOCK_CLOEXEC`
 - `SOCK_NONBLOCK`

**Parameters:**

- `family` (integer)
- `type` (integer)
- `protocol` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### bind

```teal
function bind(fd: integer, ip?: integer, port?: integer): boolean | nil, string | nil, Errno | nil
```

  Binds socket.
  `ip` and `port` are in host endian order. For example, if you
  wanted to listen on `1.2.3.4:31337` you could do any of these
      unix.bind(sock, 0x01020304, 31337)
      unix.bind(sock, ParseIp('1.2.3.4'), 31337)
      unix.bind(sock, 1 << 24 | 0 << 16 | 0 << 8 | 1, 31337)
  `ip` and `port` both default to zero. The meaning of bind(0, 0)
  is to listen on all interfaces with a kernel-assigned ephemeral
  port number, that can be retrieved and used as follows:
      sock = assert(unix.socket())  -- create ipv4 tcp socket
      assert(unix.bind(sock))       -- all interfaces ephemeral port
      ip, port = assert(unix.getsockname(sock))
      print("listening on ip", FormatIp(ip), "port", port)
      assert(unix.listen(sock))
      while true do
         client, clientip, clientport = assert(unix.accept(sock))
         print("got client ip", FormatIp(clientip), "port", clientport)
         unix.close(client)
      end
  Further note that calling `unix.bind(sock)` is equivalent to not
  calling bind() at all, since the above behavior is the default.

**Parameters:**

- `fd` (integer)
- `ip` (integer)
- `port` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### siocgifconf

```teal
function siocgifconf(): any, string | nil, Errno | nil
```

 Returns list of network adapter addresses.

**Returns:**

- any
- string | nil
- Errno | nil

### getsockopt

```teal
function getsockopt(fd: integer, level: integer, optname: integer): integer | nil, string | nil, Errno | nil
```

 Tunes networking parameters.
 `level` and `optname` may be one of the following pairs. The ellipses
 type signature above changes depending on which options are used.
 `optname` is the option feature magic number. The constants for
 these will be set to `0` if the option isn't supported on the host
 platform.
 Raises `ENOPROTOOPT` if your `level` / `optname` combination isn't
 valid, recognized, or supported on the host platform.
 Raises `ENOTSOCK` if `fd` is valid but isn't a socket.
 Raises `EBADF` if `fd` isn't valid.
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ value:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, value:bool)
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_TYPE`
 - `SOL_SOCKET`, `SO_DEBUG`
 - `SOL_SOCKET`, `SO_ACCEPTCONN`
 - `SOL_SOCKET`, `SO_BROADCAST`
 - `SOL_SOCKET`, `SO_REUSEADDR`
 - `SOL_SOCKET`, `SO_REUSEPORT`
 - `SOL_SOCKET`, `SO_KEEPALIVE`
 - `SOL_SOCKET`, `SO_DONTROUTE`
 - `SOL_TCP`, `TCP_NODELAY`
 - `SOL_TCP`, `TCP_CORK`
 - `SOL_TCP`, `TCP_QUICKACK`
 - `SOL_TCP`, `TCP_FASTOPEN_CONNECT`
 - `SOL_TCP`, `TCP_DEFER_ACCEPT`
 - `SOL_IP`, `IP_HDRINCL`
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ value:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, value:int)
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_SNDBUF`
 - `SOL_SOCKET`, `SO_RCVBUF`
 - `SOL_SOCKET`, `SO_RCVLOWAT`
 - `SOL_SOCKET`, `SO_SNDLOWAT`
 - `SOL_TCP`, `TCP_KEEPIDLE`
 - `SOL_TCP`, `TCP_KEEPINTVL`
 - `SOL_TCP`, `TCP_FASTOPEN`
 - `SOL_TCP`, `TCP_KEEPCNT`
 - `SOL_TCP`, `TCP_MAXSEG`
 - `SOL_TCP`, `TCP_SYNCNT`
 - `SOL_TCP`, `TCP_NOTSENT_LOWAT`
 - `SOL_TCP`, `TCP_WINDOW_CLAMP`
 - `SOL_IP`, `IP_TOS`
 - `SOL_IP`, `IP_MTU`
 - `SOL_IP`, `IP_TTL`
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ secs:int, nsecs:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, secs:int[, nanos:int])
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_RCVTIMEO`: If this option is specified then
   your stream socket will have a read() / recv() timeout. If the
   specified interval elapses without receiving data, then EAGAIN
   shall be returned by read. If this option is used on listening
   sockets, it'll be inherited by accepted sockets. Your redbean
   already does this for GetClientFd() based on the `-t` flag.
 - `SOL_SOCKET`, `SO_SNDTIMEO`: This is the same as `SO_RCVTIMEO`
   but it applies to the write() / send() functions.
 unix.getsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER)
     ├─→ seconds:int, enabled:bool
     └─→ nil, string, integer
 unix.setsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER, secs:int, enabled:bool)
     ├─→ true
     └─→ nil, string, integer
 This `SO_LINGER` parameter can be used to make close() a blocking
 call. Normally when the kernel returns immediately when it receives
 close(). Sometimes it's desirable to have extra assurance on errors
 happened, even if it comes at the cost of performance.
 unix.setsockopt(serverfd:int, unix.SOL_TCP, unix.TCP_SAVE_SYN, enabled:int)
     ├─→ true
     └─→ nil, string, integer
 unix.getsockopt(clientfd:int, unix.SOL_TCP, unix.TCP_SAVED_SYN)
     ├─→ syn_packet_bytes:str
     └─→ nil, string, integer
 This `TCP_SAVED_SYN` option may be used to retrieve the bytes of the
 TCP SYN packet that the client sent when the connection for `fd` was
 opened. In order for this to work, `TCP_SAVE_SYN` must have been set
 earlier on the listening socket. This is Linux-only. You can use the
 `OnServerListen` hook to enable SYN saving in your Redbean. When the
 `TCP_SAVE_SYN` option isn't used, this may return empty string.

**Parameters:**

- `fd` (integer)
- `level` (integer)
- `optname` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### setsockopt

```teal
function setsockopt(fd: integer, level: integer, optname: integer, value: boolean | integer): boolean | nil, string | nil, Errno | nil
```

 Tunes networking parameters.
 `level` and `optname` may be one of the following pairs. The ellipses
 type signature above changes depending on which options are used.
 `optname` is the option feature magic number. The constants for
 these will be set to `0` if the option isn't supported on the host
 platform.
 Raises `ENOPROTOOPT` if your `level` / `optname` combination isn't
 valid, recognized, or supported on the host platform.
 Raises `ENOTSOCK` if `fd` is valid but isn't a socket.
 Raises `EBADF` if `fd` isn't valid.
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ value:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, value:bool)
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_TYPE`
 - `SOL_SOCKET`, `SO_DEBUG`
 - `SOL_SOCKET`, `SO_ACCEPTCONN`
 - `SOL_SOCKET`, `SO_BROADCAST`
 - `SOL_SOCKET`, `SO_REUSEADDR`
 - `SOL_SOCKET`, `SO_REUSEPORT`
 - `SOL_SOCKET`, `SO_KEEPALIVE`
 - `SOL_SOCKET`, `SO_DONTROUTE`
 - `SOL_TCP`, `TCP_NODELAY`
 - `SOL_TCP`, `TCP_CORK`
 - `SOL_TCP`, `TCP_QUICKACK`
 - `SOL_TCP`, `TCP_FASTOPEN_CONNECT`
 - `SOL_TCP`, `TCP_DEFER_ACCEPT`
 - `SOL_IP`, `IP_HDRINCL`
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ value:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, value:int)
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_SNDBUF`
 - `SOL_SOCKET`, `SO_RCVBUF`
 - `SOL_SOCKET`, `SO_RCVLOWAT`
 - `SOL_SOCKET`, `SO_SNDLOWAT`
 - `SOL_TCP`, `TCP_KEEPIDLE`
 - `SOL_TCP`, `TCP_KEEPINTVL`
 - `SOL_TCP`, `TCP_FASTOPEN`
 - `SOL_TCP`, `TCP_KEEPCNT`
 - `SOL_TCP`, `TCP_MAXSEG`
 - `SOL_TCP`, `TCP_SYNCNT`
 - `SOL_TCP`, `TCP_NOTSENT_LOWAT`
 - `SOL_TCP`, `TCP_WINDOW_CLAMP`
 - `SOL_IP`, `IP_TOS`
 - `SOL_IP`, `IP_MTU`
 - `SOL_IP`, `IP_TTL`
 unix.getsockopt(fd:int, level:int, optname:int)
     ├─→ secs:int, nsecs:int
     └─→ nil, string, integer
 unix.setsockopt(fd:int, level:int, optname:int, secs:int[, nanos:int])
     ├─→ true
     └─→ nil, string, integer
 - `SOL_SOCKET`, `SO_RCVTIMEO`: If this option is specified then
   your stream socket will have a read() / recv() timeout. If the
   specified interval elapses without receiving data, then EAGAIN
   shall be returned by read. If this option is used on listening
   sockets, it'll be inherited by accepted sockets. Your redbean
   already does this for GetClientFd() based on the `-t` flag.
 - `SOL_SOCKET`, `SO_SNDTIMEO`: This is the same as `SO_RCVTIMEO`
   but it applies to the write() / send() functions.
 unix.getsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER)
     ├─→ seconds:int, enabled:bool
     └─→ nil, string, integer
 unix.setsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER, secs:int, enabled:bool)
     ├─→ true
     └─→ nil, string, integer
 This `SO_LINGER` parameter can be used to make close() a blocking
 call. Normally when the kernel returns immediately when it receives
 close(). Sometimes it's desirable to have extra assurance on errors
 happened, even if it comes at the cost of performance.
 unix.setsockopt(serverfd:int, unix.SOL_TCP, unix.TCP_SAVE_SYN, enabled:int)
     ├─→ true
     └─→ nil, string, integer
 unix.getsockopt(clientfd:int, unix.SOL_TCP, unix.TCP_SAVED_SYN)
     ├─→ syn_packet_bytes:str
     └─→ nil, string, integer
 This `TCP_SAVED_SYN` option may be used to retrieve the bytes of the
 TCP SYN packet that the client sent when the connection for `fd` was
 opened. In order for this to work, `TCP_SAVE_SYN` must have been set
 earlier on the listening socket. This is Linux-only. You can use the
 `OnServerListen` hook to enable SYN saving in your Redbean. When the
 `TCP_SAVE_SYN` option isn't used, this may return empty string.

**Parameters:**

- `fd` (integer)
- `level` (integer)
- `optname` (integer)
- `value` (boolean | integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### poll

```teal
function poll(fds: {integer: integer}, timeoutms?: integer): {integer: integer} | nil, string | nil, Errno | nil
```

 Checks for events on a set of file descriptors.
 The table of file descriptors to poll uses sparse integer keys. Any
 pairs with non-integer keys will be ignored. Pairs with negative
 keys are ignored by poll(). The returned table will be a subset of
 the supplied file descriptors.
 `events` and `revents` may be any combination (using bitwise OR) of:
 - `POLLIN` (events, revents): There is data to read.
 - `POLLOUT` (events, revents): Writing is now possible, although may
 still block if available space in a socket or pipe is exceeded
 (unless `O_NONBLOCK` is set).
 - `POLLPRI` (events, revents): There is some exceptional condition
 (for example, out-of-band data on a TCP socket).
 - `POLLRDHUP` (events, revents): Stream socket peer closed
 connection, or shut down writing half of connection.
 - `POLLERR` (revents): Some error condition.
 - `POLLHUP` (revents): Hang up. When reading from a channel such as
 a pipe or a stream socket, this event merely indicates that the
 peer closed its end of the channel.
 - `POLLNVAL` (revents): Invalid request.
 If this is set to -1 then that means block as long as it takes until there's an
 event or an interrupt. If the timeout expires, an empty table is returned.

**Parameters:**

- `fds` ({integer: integer})
- `timeoutms` (integer)

**Returns:**

- {integer: integer} | nil
- string | nil
- Errno | nil

### gethostname

```teal
function gethostname(): string | nil, string | nil, Errno | nil
```

 Returns hostname of system.

**Returns:**

- string | nil
- string | nil
- Errno | nil

### sethostname

```teal
function sethostname(name: string): boolean | nil, string | nil, Errno | nil
```

 Sets hostname of system.
 Requires CAP_SYS_ADMIN on Linux (or root on BSDs); returns `EPERM`
 otherwise. Not supported on Windows, where it returns `ENOSYS`.

**Parameters:**

- `name` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### listen

```teal
function listen(fd: integer, backlog?: integer): boolean | nil, string | nil, Errno | nil
```

 Begins listening for incoming connections on a socket.

**Parameters:**

- `fd` (integer)
- `backlog` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### accept

```teal
function accept(serverfd: integer, flags?: integer): integer | nil, integer, integer, string | nil, Errno | nil
```

 Accepts new client socket descriptor for a listening tcp socket.
 `flags` may have any combination (using bitwise OR) of:
 - `SOCK_CLOEXEC`
 - `SOCK_NONBLOCK`

**Parameters:**

- `serverfd` (integer)
- `flags` (integer)

**Returns:**

- integer | nil
- integer
- integer
- string | nil
- Errno | nil

### connect

```teal
function connect(fd: integer, ip: integer, port: integer): boolean | nil, string | nil, Errno | nil
```

  Connects a TCP socket to a remote host.
  With TCP this is a blocking operation. For a UDP socket it simply
  remembers the intended address so that `send()` or `write()` may be used
  rather than `sendto()`.

**Parameters:**

- `fd` (integer)
- `ip` (integer)
- `port` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getsockname

```teal
function getsockname(fd: integer): integer | nil, integer, string | nil, Errno | nil
```

 Retrieves the local address of a socket.

**Parameters:**

- `fd` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### getpeername

```teal
function getpeername(fd: integer): integer | nil, integer, string | nil, Errno | nil
```

 Retrieves the remote address of a socket.
 This operation will either fail on `AF_UNIX` sockets or return an
 empty string.

**Parameters:**

- `fd` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### recv

```teal
function recv(fd: integer, bufsiz?: integer, flags?: integer): string | nil, string | nil, Errno | nil
```

 - `MSG_WAITALL`
 - `MSG_DONTROUTE`
 - `MSG_PEEK`
 - `MSG_OOB`

**Parameters:**

- `fd` (integer)
- `bufsiz` (integer)
- `flags` (integer)

**Returns:**

- string | nil
- string | nil
- Errno | nil

### recvfrom

```teal
function recvfrom(fd: integer, bufsiz?: integer, flags?: integer): string | nil, integer, integer, string | nil, Errno | nil
```

 - `MSG_WAITALL`
 - `MSG_DONTROUTE`
 - `MSG_PEEK`
 - `MSG_OOB`

**Parameters:**

- `fd` (integer)
- `bufsiz` (integer)
- `flags` (integer)

**Returns:**

- string | nil
- integer
- integer
- string | nil
- Errno | nil

### send

```teal
function send(fd: integer, data: string, flags?: integer, offset?: integer): integer | nil, string | nil, Errno | nil
```

 This is the same as `write` except it has a `flags` argument
 that's intended for sockets.
 - `MSG_NOSIGNAL`: Don't SIGPIPE on EOF
 - `MSG_OOB`: Send stream data through out of bound channel
 - `MSG_DONTROUTE`: Don't go through gateway (for diagnostics)
 - `MSG_MORE`: Manual corking to belay nodelay (0 on non-Linux)

**Parameters:**

- `fd` (integer)
- `data` (string)
- `flags` (integer)
- `offset` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### sendto

```teal
function sendto(fd: integer, data: string, ip: integer, port: integer, flags?: integer): integer | nil, string | nil, Errno | nil
```

 This is useful for sending messages over UDP sockets to specific
 addresses.
 - `MSG_OOB`
 - `MSG_DONTROUTE`
 - `MSG_NOSIGNAL`

**Parameters:**

- `fd` (integer)
- `data` (string)
- `ip` (integer)
- `port` (integer)
- `flags` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### shutdown

```teal
function shutdown(fd: integer, how: integer): boolean | nil, string | nil, Errno | nil
```

 Partially closes socket.
 - `SHUT_RD`: sends a tcp half close for reading
 - `SHUT_WR`: sends a tcp half close for writing
 - `SHUT_RDWR`
 This system call currently has issues on Macintosh, so portable code
 should log rather than assert failures reported by `shutdown()`.

**Parameters:**

- `fd` (integer)
- `how` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### sigprocmask

```teal
function sigprocmask(how: integer, newmask: Sigset): Sigset | nil, string | nil, Errno | nil
```

 Manipulates bitset of signals blocked by process.
 - `SIG_BLOCK`: applies `mask` to set of blocked signals using bitwise OR
 - `SIG_UNBLOCK`: removes bits in `mask` from set of blocked signals
 - `SIG_SETMASK`: replaces process signal mask with `mask`
 `mask` is a unix.Sigset() object (see section below).
 For example, to temporarily block `SIGTERM` and `SIGINT` so critical
 work won't be interrupted, sigprocmask() can be used as follows:
   newmask = unix.Sigset(unix.SIGTERM)
   oldmask = assert(unix.sigprocmask(unix.SIG_BLOCK, newmask))
   -- do something...
   assert(unix.sigprocmask(unix.SIG_SETMASK, oldmask))

**Parameters:**

- `how` (integer)
- `newmask` (Sigset)

**Returns:**

- Sigset | nil
- string | nil
- Errno | nil

### sigaction

```teal
function sigaction(sig: integer, handler?: function | integer, flags?: integer, mask?: Sigset): function | integer | nil, integer, Sigset, string | nil, Errno | nil
```

 - `unix.SIGINT`
 - `unix.SIGQUIT`
 - `unix.SIGTERM`
 - etc.
 - Lua function
 - `unix.SIG_IGN`
 - `unix.SIG_DFL`
 - `unix.SA_RESTART`: Enables BSD signal handling semantics. Normally
 i/o entrypoints check for pending signals to deliver. If one gets
 delivered during an i/o call, the normal behavior is to cancel the
 i/o operation and return -1 with `EINTR` in errno. If you use the
 `SA_RESTART` flag then that behavior changes, so that any function
 that's been annotated with @restartable will not return `EINTR`
 and will instead resume the i/o operation. This makes coding
 easier but it can be an anti-pattern if not used carefully, since
 poor usage can easily result in latency issues. It also requires
 one to do more work in signal handlers, so special care needs to
 be given to which C library functions are @asyncsignalsafe.
 - `unix.SA_RESETHAND`: Causes signal handler to be single-shot. This
 means that, upon entry of delivery to a signal handler, it's reset
 to the `SIG_DFL` handler automatically. You may use the alias
 `SA_ONESHOT` for this flag, which means the same thing.
 - `unix.SA_NODEFER`: Disables the reentrancy safety check on your signal
 handler. Normally that's a good thing, since for instance if your
 `SIGSEGV` signal handler happens to segfault, you're going to want
 your process to just crash rather than looping endlessly. But in
 some cases it's desirable to use `SA_NODEFER` instead, such as at
 times when you wish to `longjmp()` out of your signal handler and
 back into your program. This is only safe to do across platforms
 for non-crashing signals such as `SIGCHLD` and `SIGINT`. Crash
 handlers should use Xed instead to recover execution, because on
 Windows a `SIGSEGV` or `SIGTRAP` crash handler might happen on a
 separate stack and/or a separate thread. You may use the alias
 `SA_NOMASK` for this flag, which means the same thing.
 - `unix.SA_NOCLDWAIT`: Changes `SIGCHLD` so the zombie is gone and
 you can't call wait() anymore; similar but may still deliver the
 SIGCHLD.
 - `unix.SA_NOCLDSTOP`: Lets you set `SIGCHLD` handler that's only
 notified on exit/termination and not notified on `SIGSTOP`,
 `SIGTSTP`, `SIGTTIN`, `SIGTTOU`, or `SIGCONT`.
 Example:
     function OnSigUsr1(sig)
         gotsigusr1 = true
     end
     gotsigusr1 = false
     oldmask = assert(unix.sigprocmask(unix.SIG_BLOCK, unix.Sigset(unix.SIGUSR1)))
     assert(unix.sigaction(unix.SIGUSR1, OnSigUsr1))
     assert(unix.raise(unix.SIGUSR1))
     assert(not gotsigusr1)
     ok, err, errno = unix.sigsuspend(oldmask)
     assert(not ok)
     assert(errno == unix.EINTR)
     assert(gotsigusr1)
     assert(unix.sigprocmask(unix.SIG_SETMASK, oldmask))
 When `handler` is a Lua function, it is dispatched *deferred* rather than
 from the raw signal context: the real signal handler only records the
 signal and the Lua function is then invoked at the next Lua VM instruction
 boundary, in normal execution context. This is required because the Lua VM
 is not async-signal-safe -- running Lua from a true signal handler that
 interrupted the VM mid-allocation or mid-GC can corrupt the heap. A
 consequence is that a blocking syscall interrupted by the signal still
 returns `EINTR` immediately (so `sigsuspend`/poll wakeups are preserved),
 but the Lua handler body runs a moment later once the VM resumes. Integer
 handlers (e.g. `unix.SIG_IGN`, `unix.SIG_DFL`, or a raw function pointer)
 are installed directly and are not deferred.
 It's a good idea to not do too much work in a signal handler.

**Parameters:**

- `sig` (integer)
- `handler` (function | integer)
- `flags` (integer)
- `mask` (Sigset)

**Returns:**

- function | integer | nil
- integer
- Sigset
- string | nil
- Errno | nil

### sigsuspend

```teal
function sigsuspend(mask?: Sigset): nil, string | nil, Errno | nil
```

 Waits for signal to be delivered.
 The signal mask is temporarily replaced with `mask` during this system call.

**Parameters:**

- `mask` (Sigset)

**Returns:**

- nil
- string | nil
- Errno | nil

### sigpending

```teal
function sigpending(): Sigset | nil, string | nil, Errno | nil
```

 Returns the set of signals pending delivery to the calling process
 that are currently blocked.

**Returns:**

- Sigset | nil
- string | nil
- Errno | nil

### setitimer

```teal
function setitimer(which: integer, intervalsec: integer, intervalns: integer, valuesec: integer, valuens: integer): integer | nil, integer, integer, integer, string | nil, Errno | nil
```

 Causes `SIGALRM` signals to be generated at some point(s) in the
 future. The `which` parameter should be `ITIMER_REAL`.
 Here's an example of how to create a 400 ms interval timer:
     ticks = 0
     assert(unix.sigaction(unix.SIGALRM, function(sig)
        print('tick no. %d' % {ticks})
        ticks = ticks + 1
     end))
     assert(unix.setitimer(unix.ITIMER_REAL, 0, 400e6, 0, 400e6))
     while true do
        unix.sigsuspend()
     end
 Here's how you'd do a single-shot timeout in 1 second:
     unix.sigaction(unix.SIGALRM, MyOnSigAlrm, unix.SA_RESETHAND)
     unix.setitimer(unix.ITIMER_REAL, 0, 0, 1, 0)

**Parameters:**

- `which` (integer)
- `intervalsec` (integer)
- `intervalns` (integer)
- `valuesec` (integer)
- `valuens` (integer)

**Returns:**

- integer | nil
- integer
- integer
- integer
- string | nil
- Errno | nil

### strsignal

```teal
function strsignal(sig: integer): string
```

 Turns platform-specific `sig` code into its symbolic name.
 For example:
     >: unix.strsignal(9)
     "SIGKILL"
     >: unix.strsignal(unix.SIGKILL)
     "SIGKILL"
 Please note that signal numbers are normally different across
 supported platforms, and the constants should be preferred.

**Parameters:**

- `sig` (integer)

**Returns:**

- string

### setrlimit

```teal
function setrlimit(resource: integer, soft: integer, hard?: integer): boolean | nil, string | nil, Errno | nil
```

 Changes resource limit.
 - `RLIMIT_AS` limits the size of the virtual address space. This
 will work on all platforms. It's emulated on XNU and Windows which
 means it won't propagate across execve() currently.
 - `RLIMIT_CPU` causes `SIGXCPU` to be sent to the process when the
 soft limit on CPU time is exceeded, and the process is destroyed
 when the hard limit is exceeded. It works everywhere but Windows
 where it should be possible to poll getrusage() with setitimer().
 - `RLIMIT_FSIZE` causes `SIGXFSZ` to sent to the process when the
 soft limit on file size is exceeded and the process is destroyed
 when the hard limit is exceeded. It works everywhere but Windows.
 - `RLIMIT_NPROC` limits the number of simultaneous processes and it
 should work on all platforms except Windows. Please be advised it
 limits the process, with respect to the activities of the user id
 as a whole.
 - `RLIMIT_NOFILE` limits the number of open file descriptors and it
 should work on all platforms except Windows (TODO).
 If a limit isn't supported by the host platform, it'll be set to
 127. On most platforms these limits are enforced by the kernel and
 as such are inherited by subprocesses.

**Parameters:**

- `resource` (integer)
- `soft` (integer)
- `hard` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getrlimit

```teal
function getrlimit(resource: integer): integer | nil, integer, string | nil, Errno | nil
```

 Returns information about resource limits for current process.

**Parameters:**

- `resource` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### nice

```teal
function nice(inc: integer): integer | nil, string | nil, Errno | nil
```

 Adjusts the nice value (scheduling priority) of the calling process.
 The nice value ranges from -20 (highest priority) to 19 (lowest priority).
 Only privileged processes can lower the nice value (increase priority).
 `inc` is added to the current nice value. Positive values decrease
 priority, negative values increase it.
 Returns the new nice value on success. Note that -1 is a valid return
 value, so errors must be detected by checking the second return value.

**Parameters:**

- `inc` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### verynice

```teal
function verynice()
```

 Lowers the calling process to the lowest scheduling priority.
 On Linux this additionally requests the idle scheduling policy and a
 best-effort idle i/o priority. This function does not fail.

### getpriority

```teal
function getpriority(which: integer, who: integer): integer | nil, string | nil, Errno | nil
```

 Gets the scheduling priority of a process, process group, or user.
 `which` specifies what `who` refers to:
 - `PRIO_PROCESS`: `who` is a process id (0 = calling process)
 - `PRIO_PGRP`: `who` is a process group id (0 = calling process group)
 - `PRIO_USER`: `who` is a user id (0 = calling user)
 Returns the priority value (nice value) which ranges from -20 to 19.
 Note that -1 is a valid return value, so errors must be detected by
 checking the second return value.

**Parameters:**

- `which` (integer)
- `who` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### setpriority

```teal
function setpriority(which: integer, who: integer, prio: integer): boolean | nil, string | nil, Errno | nil
```

 Sets the scheduling priority of a process, process group, or user.
 `which` specifies what `who` refers to:
 - `PRIO_PROCESS`: `who` is a process id (0 = calling process)
 - `PRIO_PGRP`: `who` is a process group id (0 = calling process group)
 - `PRIO_USER`: `who` is a user id (0 = calling user)
 `prio` is the new priority value (nice value), ranging from -20
 (highest priority) to 19 (lowest priority). Only privileged processes
 can set negative priority values.

**Parameters:**

- `which` (integer)
- `who` (integer)
- `prio` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### getrusage

```teal
function getrusage(who?: integer): Rusage | nil, string | nil, Errno | nil
```

 Returns information about resource usage for current process, e.g.
     >: unix.getrusage()
     {utime={0, 53644000}, maxrss=44896, minflt=545, oublock=24, nvcsw=9}
 - `RUSAGE_SELF`: current process
 - `RUSAGE_THREAD`: current thread
 - `RUSAGE_CHILDREN`: not supported on Windows NT
 - `RUSAGE_BOTH`: not supported on non-Linux

**Parameters:**

- `who` (integer)

**Returns:**

- Rusage | nil
- string | nil
- Errno | nil

### pledge

```teal
function pledge(promises?: string, execpromises?: string, mode?: integer): boolean | nil, string | nil, Errno | nil
```

 Restrict system operations.
 This can be used to sandbox your redbean workers. It allows finer
 customization compared to the `-S` flag.
 Pledging causes most system calls to become unavailable. On Linux the
 disabled calls will return EPERM whereas OpenBSD kills the process.
 Using pledge is irreversible. On Linux it causes PR_SET_NO_NEW_PRIVS
 to be set on your process.
 By default exit and exit_group are always allowed. This is useful
 for processes that perform pure computation and interface with the
 parent via shared memory.
 Once pledge is in effect, the chmod functions (if allowed) will not
 permit the sticky/setuid/setgid bits to change. Linux will EPERM here
 and OpenBSD should ignore those three bits rather than crashing.
 User and group IDs also can't be changed once pledge is in effect.
 OpenBSD should ignore the chown functions without crashing. Linux
 will just EPERM.
 Memory functions won't permit creating executable code after pledge.
 Restrictions on origin of SYSCALL instructions will become enforced
 on Linux (cf. msyscall) after pledge too, which means the process
 gets killed if SYSCALL is used outside the .privileged section. One
 exception is if the "exec" group is specified, in which case these
 restrictions need to be loosened.
 This list has been curated to focus on the
 system calls for which this module provides wrappers. See the
 Cosmopolitan Libc pledge() documentation for a comprehensive and
 authoritative list of raw system calls. Having the raw system call
 list may be useful if you're executing foreign programs.
 ### stdio
 Allows read, write, send, recv, recvfrom, close, clock_getres,
 clock_gettime, dup, fchdir, fstat, fsync, fdatasync, ftruncate,
 getdents, getegid, getrandom, geteuid, getgid, getgroups,
 getitimer, getpgid, getpgrp, getpid, hgetppid, getresgid,
 getresuid, getrlimit, getsid, gettimeofday, getuid, lseek,
 madvise, brk, mmap/mprotect (PROT_EXEC isn't allowed), msync,
 munmap, gethostname, nanosleep, pipe, pipe2, poll, setitimer,
 shutdown, sigaction, sigsuspend, sigprocmask, socketpair, umask,
 wait4, getrusage, ioctl(FIONREAD), ioctl(FIONBIO), ioctl(FIOCLEX),
 ioctl(FIONCLEX), fcntl(F_GETFD), fcntl(F_SETFD), fcntl(F_GETFL),
 fcntl(F_SETFL).
 ### rpath
 Allows chdir, getcwd, open, stat, fstat, access, readlink, chmod,
 chmod, fchmod.
 ### wpath
 Allows getcwd, open, stat, fstat, access, readlink, chmod, fchmod.
 ### cpath
 Allows rename, link, symlink, unlink, mkdir, rmdir.
 ### fattr
 Allows chmod, fchmod, utimensat, futimens.
 ### flock
 Allows flock, fcntl(F_GETLK), fcntl(F_SETLK), fcntl(F_SETLKW).
 ### tty
 Allows isatty, tiocgwinsz, tcgets, tcsets, tcsetsw, tcsetsf.
 ### inet
 Allows socket (AF_INET), listen, bind, connect, accept,
 getpeername, getsockname, setsockopt, getsockopt.
 ### unix
 Allows socket (AF_UNIX), listen, bind, connect, accept,
 getpeername, getsockname, setsockopt, getsockopt.
 ### dns
 Allows sendto, recvfrom, socket(AF_INET), connect.
 ### recvfd
 Allows recvmsg, recvmmsg.
 ### sendfd
 Allows sendmsg, sendmmsg.
 ### proc
 Allows fork, vfork, clone, kill, tgkill, getpriority, setpriority,
 setrlimit, setpgid, setsid.
 ### id
 Allows setuid, setreuid, setresuid, setgid, setregid, setresgid,
 setgroups, setrlimit, getpriority, setpriority.
 ### settime
 Allows settimeofday and clock_adjtime.
 ### unveil
 Allows unveil().
 ### exec
 Allows execve.
 If the executable in question needs a loader, then you will need
 "rpath prot_exec" too. With APE, security is strongest when you
 assimilate your binaries beforehand, using the --assimilate flag,
 or the o//tool/build/assimilate program. On OpenBSD this is
 mandatory.
 ### prot_exec
 Allows mmap(PROT_EXEC) and mprotect(PROT_EXEC).
 This may be needed to launch non-static non-native executables,
 such as non-assimilated APE binaries, or programs that link
 dynamic shared objects, i.e. most Linux distro binaries.
 In that case, this specifies the promises that'll apply once `execve()`
 happens. If this is `NULL` then the default is used, which is
 unrestricted. OpenBSD allows child processes to escape the sandbox
 (so a pledged OpenSSH server process can do things like spawn a root
 shell). Linux however requires monotonically decreasing privileges.
 This function will will perform some validation on Linux to make
 sure that `execpromises` is a subset of `promises`. Your libc
 wrapper for `execve()` will then apply its SECCOMP BPF filter later.
 Since Linux has to do this before calling `sys_execve()`, the executed
 process will be weakened to have execute permissions too.
 - `unix.PLEDGE_PENALTY_KILL_THREAD` causes the violating thread to
   be killed. This is the default on Linux. It's effectively the
   same as killing the process, since redbean has no threads. The
   termination signal can't be caught and will be either `SIGSYS`
   or `SIGABRT`. Consider enabling stderr logging below so you'll
   know why your program failed. Otherwise check the system log.
 - `unix.PLEDGE_PENALTY_KILL_PROCESS` causes the process and all
   its threads to be killed. This is always the case on OpenBSD.
 - `unix.PLEDGE_PENALTY_RETURN_EPERM` causes system calls to just
   return an `EPERM` error instead of killing. This is a gentler
   solution that allows code to display a friendly warning. Please
   note this may lead to weird behaviors if the software being
   sandboxed is lazy about checking error results.
 `mode` may optionally bitwise or the following flags:
 - `unix.PLEDGE_STDERR_LOGGING` enables friendly error message
   logging letting you know which promises are needed whenever
   violations occur. Without this, violations will be logged to
   `dmesg` on Linux if the penalty is to kill the process. You
   would then need to manually look up the system call number and
   then cross reference it with the cosmopolitan libc pledge()
   documentation. You can also use `strace -ff` which is easier.
   This is ignored OpenBSD, which already has a good system log.
   Turning on stderr logging (which uses SECCOMP trapping) also
   means that the `unix.WTERMSIG()` on your killed processes will
   always be `unix.SIGABRT` on both Linux and OpenBSD. Otherwise,
   Linux prefers to raise `unix.SIGSYS`.

**Parameters:**

- `promises` (string)
- `execpromises` (string)
- `mode` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### unveil

```teal
function unveil(path: string, permissions: string): boolean | nil, string | nil, Errno | nil
```

 Restricts filesystem operations, e.g.
    unix.unveil(".", "r");     -- current dir + children visible
    unix.unveil("/etc", "r");  -- make /etc readable too
    unix.unveil(nil, nil);     -- commit and lock policy
 Unveiling restricts a thread's view of the filesystem to a set of
 allowed paths with specific privileges.
 Once you start using unveil(), the entire file system is considered
 hidden. You then specify, by repeatedly calling unveil(), which paths
 should become unhidden. When you're finished, you call `unveil(nil,nil)`
 which commits your policy, after which further use is forbidden, in
 the current thread, as well as any threads or processes it spawns.
 There are some differences between unveil() on Linux versus OpenBSD.
 1. Build your policy and lock it in one go. On OpenBSD, policies take
  effect immediately and may evolve as you continue to call unveil()
  but only in a more restrictive direction. On Linux, nothing will
  happen until you call `unveil(nil,nil)` which commits and locks.
 2. Try not to overlap directory trees. On OpenBSD, if directory trees
  overlap, then the most restrictive policy will be used for a given
  file. On Linux overlapping may result in a less restrictive policy
  and possibly even undefined behavior.
 3. OpenBSD and Linux disagree on error codes. On OpenBSD, accessing
  paths outside of the allowed set raises ENOENT, and accessing ones
  with incorrect permissions raises EACCES. On Linux, both these
  cases raise EACCES.
 4. Unlike OpenBSD, Linux does nothing to conceal the existence of
  paths. Even with an unveil() policy in place, it's still possible
  to access the metadata of all files using functions like stat()
  and open(O_PATH), provided you know the path. A sandboxed process
  can always, for example, determine how many bytes of data are in
  /etc/passwd, even if the file isn't readable. But it's still not
  possible to use opendir() and go fishing for paths which weren't
  previously known.
 This system call is supported natively on OpenBSD and polyfilled on
 Linux using the Landlock LSM[1].
 - `r` makes `path` available for read-only path operations,
   corresponding to the pledge promise "rpath".
 - `w` makes `path` available for write operations, corresponding
   to the pledge promise "wpath".
 - `x` makes `path` available for execute operations,
   corresponding to the pledge promises "exec" and "execnative".
 - `c` allows `path` to be created and removed, corresponding to
   the pledge promise "cpath".

**Parameters:**

- `path` (string)
- `permissions` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### gmtime

```teal
function gmtime(unixts: integer): integer | nil, integer, integer, integer, integer, integer, integer, integer, integer, integer, string, string | nil, Errno | nil
```

 Breaks down UNIX timestamp into Zulu Time numbers.

**Parameters:**

- `unixts` (integer)

**Returns:**

- integer | nil
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- string
- string | nil
- Errno | nil

### localtime

```teal
function localtime(unixts: integer): integer | nil, integer, integer, integer, integer, integer, integer, integer, integer, integer, string, string | nil, Errno | nil
```

 Breaks down UNIX timestamp into local time numbers, e.g.
     >: unix.localtime(unix.clock_gettime())
     2022    4       28      2       14      22      -25200  4       117     1       "PDT"
 This follows the same API as `gmtime()` which has further details.
 Your redbean ships with a subset of the time zone database.
 - `/zip/usr/share/zoneinfo/Honolulu`   Z-10
 - `/zip/usr/share/zoneinfo/Anchorage`  Z -9
 - `/zip/usr/share/zoneinfo/GST`        Z -8
 - `/zip/usr/share/zoneinfo/Boulder`    Z -6
 - `/zip/usr/share/zoneinfo/Chicago`    Z -5
 - `/zip/usr/share/zoneinfo/New_York`   Z -4
 - `/zip/usr/share/zoneinfo/UTC`        Z +0
 - `/zip/usr/share/zoneinfo/GMT`        Z +0
 - `/zip/usr/share/zoneinfo/London`     Z +1
 - `/zip/usr/share/zoneinfo/Berlin`     Z +2
 - `/zip/usr/share/zoneinfo/Israel`     Z +3
 - `/zip/usr/share/zoneinfo/India`      Z +5
 - `/zip/usr/share/zoneinfo/Beijing`    Z +8
 - `/zip/usr/share/zoneinfo/Japan`      Z +9
 - `/zip/usr/share/zoneinfo/Sydney`     Z+10
 You can control which timezone is used using the `TZ` environment
 variable. If your time zone isn't included in the above list, you
 can simply copy it inside your redbean. The same is also the case
 for future updates to the database, which can be swapped out when
 needed, without having to recompile.

**Parameters:**

- `unixts` (integer)

**Returns:**

- integer | nil
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- integer
- string
- string | nil
- Errno | nil

### stat

```teal
function stat(path: string, flags?: integer, dirfd?: integer): Stat | nil, string | nil, Errno | nil
```

 Gets information about file or directory.
 - `AT_SYMLINK_NOFOLLOW`: do not follow symbolic links.

**Parameters:**

- `path` (string)
- `flags` (integer)
- `dirfd` (integer)

**Returns:**

- Stat | nil
- string | nil
- Errno | nil

### S_ISDIR

```teal
function S_ISDIR(mode: integer): boolean
```

 Tests if file mode represents a directory.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISREG

```teal
function S_ISREG(mode: integer): boolean
```

 Tests if file mode represents a regular file.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISLNK

```teal
function S_ISLNK(mode: integer): boolean
```

 Tests if file mode represents a symbolic link.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISBLK

```teal
function S_ISBLK(mode: integer): boolean
```

 Tests if file mode represents a block device.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISCHR

```teal
function S_ISCHR(mode: integer): boolean
```

 Tests if file mode represents a character device.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISFIFO

```teal
function S_ISFIFO(mode: integer): boolean
```

 Tests if file mode represents a FIFO/pipe.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### S_ISSOCK

```teal
function S_ISSOCK(mode: integer): boolean
```

 Tests if file mode represents a socket.

**Parameters:**

- `mode` (integer)

**Returns:**

- boolean

### fstat

```teal
function fstat(fd: integer): Stat | nil, string | nil, Errno | nil
```

 Gets information about opened file descriptor.
 `flags` may have any of:
 - `AT_SYMLINK_NOFOLLOW`: do not follow symbolic links.
 `dirfd` defaults to to `unix.AT_FDCWD` and may optionally be set to
 a directory file descriptor to which `path` is relative.
 A common use for `fstat()` is getting the size of a file. For example:
     fd = assert(unix.open("hello.txt", unix.O_RDONLY))
     st = assert(unix.fstat(fd))
     Log(kLogInfo, 'hello.txt is %d bytes in size' % {st:size()})
     unix.close(fd)

**Parameters:**

- `fd` (integer)

**Returns:**

- Stat | nil
- string | nil
- Errno | nil

### opendir

```teal
function opendir(path: string): Dir | nil, string | nil, Errno | nil
```

 Opens directory for listing its contents.
 For example, to print a simple directory listing:
     Write('<ul>\r\n')
     for name, kind, ino, off in assert(unix.opendir(dir)) do
         if name ~= '.' and name ~= '..' then
            Write('<li>%s\r\n' % {EscapeHtml(name)})
         end
     end
     Write('</ul>\r\n')

**Parameters:**

- `path` (string)

**Returns:**

- Dir | nil
- string | nil
- Errno | nil

### fdopendir

```teal
function fdopendir(fd: integer): Dir | nil, string | nil, Errno | nil
```

 Opens directory for listing its contents, via an fd.
 The returned `unix.Dir` takes ownership of the file descriptor
 and will close it automatically when garbage collected.

**Parameters:**

- `fd` (integer)

**Returns:**

- Dir | nil
- string | nil
- Errno | nil

### isatty

```teal
function isatty(fd: integer): boolean | nil, string | nil, Errno | nil
```

 Returns true if file descriptor is a teletypewriter. Otherwise nil
 with an Errno object holding one of the following values:
 - `ENOTTY` if `fd` is valid but not a teletypewriter
 - `EBADF` if `fd` isn't a valid file descriptor.
 - `EPERM` if pledge() is used without `tty` in lenient mode
 No other error numbers are possible.

**Parameters:**

- `fd` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### tiocgwinsz

```teal
function tiocgwinsz(fd: integer): integer | nil, integer, string | nil, Errno | nil
```

**Parameters:**

- `fd` (integer)

**Returns:**

- integer | nil
- integer
- string | nil
- Errno | nil

### tcgetattr

```teal
function tcgetattr(fd: integer): Termios | nil, string | nil, Errno | nil
```

 Gets terminal attributes.
 Returns a termios table containing the terminal I/O settings for the
 specified file descriptor. The table contains these fields:
 - `iflag`: Input mode flags (e.g., `unix.ICRNL`, `unix.IXON`)
 - `oflag`: Output mode flags (e.g., `unix.OPOST`, `unix.ONLCR`)
 - `cflag`: Control mode flags (e.g., `unix.CS8`, `unix.CREAD`)
 - `lflag`: Local mode flags (e.g., `unix.ECHO`, `unix.ICANON`)
 - `cc`: Array of control characters indexed 1 to `unix.NCCS`
 - `ispeed`: Input baud rate
 - `ospeed`: Output baud rate
 Example: reading a password without echoing:
     local tio = unix.tcgetattr(0)
     local old_lflag = tio.lflag
     tio.lflag = tio.lflag & ~unix.ECHO
     unix.tcsetattr(0, unix.TCSANOW, tio)
     local password = io.read()
     tio.lflag = old_lflag
     unix.tcsetattr(0, unix.TCSANOW, tio)

**Parameters:**

- `fd` (integer)

**Returns:**

- Termios | nil
- string | nil
- Errno | nil

### tcsetattr

```teal
function tcsetattr(fd: integer, action: integer, termios: Termios): boolean | nil, string | nil, Errno | nil
```

 Sets terminal attributes.
 Modifies the terminal I/O settings for the specified file descriptor
 using the provided termios table. The `action` parameter controls when
 the changes take effect:
 - `unix.TCSANOW`: Changes occur immediately
 - `unix.TCSADRAIN`: Changes occur after all output is transmitted
 - `unix.TCSAFLUSH`: Changes occur after output is transmitted and
   input is discarded
 The termios table should contain the same fields as returned by
 `unix.tcgetattr()`. Missing fields default to zero.

**Parameters:**

- `fd` (integer)
- `action` (integer)
- `termios` (Termios)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### tmpfd

```teal
function tmpfd(): integer | nil, string | nil, Errno | nil
```

 Returns file descriptor of open anonymous file.
 This creates a secure temporary file inside `$TMPDIR`. If it isn't
 defined, then `/tmp` is used on UNIX and GetTempPath() is used on
 the New Technology. This resolution of `$TMPDIR` happens once.
 Once close() is called, the returned file is guaranteed to be
 deleted automatically. On UNIX the file is unlink()'d before this
 function returns. On the New Technology it happens upon close().
 On the New Technology, temporary files created by this function
 should have better performance, because `kNtFileAttributeTemporary`
 asks the kernel to more aggressively cache and reduce i/o ops.

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### sched_yield

```teal
function sched_yield()
```

 Relinquishes scheduled quantum.

### unshare

```teal
function unshare(flags: integer): boolean | nil, string | nil, Errno | nil
```

 Disassociates parts of the caller's execution context, placing it
 into fresh namespace(s) specified by `flags` (bitwise OR of
 `unix.CLONE_NEW*` constants). Linux-only; returns ENOSYS elsewhere.

**Parameters:**

- `flags` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### setns

```teal
function setns(fd: integer, nstype?: integer): boolean | nil, string | nil, Errno | nil
```

 Reassociates the calling thread with the namespace referenced by
 `fd` (typically from `/proc/<pid>/ns/*`). `nstype`, if nonzero,
 must match a `unix.CLONE_NEW*` constant and asserts the kind of
 namespace. Linux-only; returns ENOSYS elsewhere.

**Parameters:**

- `fd` (integer)
- `nstype` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### mount

```teal
function mount(source?: string, target?: string, fstype?: string, flags?: integer, data?: string): boolean | nil, string | nil, Errno | nil
```

 Mounts a filesystem. `flags` is a bitwise OR of `unix.MS_*`
 constants; `data` is a filesystem-specific options string.

**Parameters:**

- `source` (string)
- `target` (string)
- `fstype` (string)
- `flags` (integer)
- `data` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### unmount

```teal
function unmount(target: string, flags?: integer): boolean | nil, string | nil, Errno | nil
```

 Unmounts a filesystem. On Linux this is the `umount2` syscall.
 `flags` may include `unix.MNT_FORCE`, `unix.MNT_DETACH`,
 `unix.MNT_EXPIRE`, `unix.UMOUNT_NOFOLLOW`.

**Parameters:**

- `target` (string)
- `flags` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### pivot_root

```teal
function pivot_root(new_root: string, put_old: string): boolean | nil, string | nil, Errno | nil
```

 Moves the root filesystem of the current mount namespace to
 `put_old` and makes `new_root` the new root. Usually paired with
 `chdir("/")` in the child. Requires a private mount namespace.

**Parameters:**

- `new_root` (string)
- `put_old` (string)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### prctl

```teal
function prctl(option: integer, arg2?: integer, arg3?: integer, arg4?: integer, arg5?: integer): integer | nil, string | nil, Errno | nil
```

 Performs an operation on the calling process. `option` is one of
 the `unix.PR_*` constants; remaining arguments are option-specific.
 Returns the integer result (0 for most setters).

**Parameters:**

- `option` (integer)
- `arg2` (integer)
- `arg3` (integer)
- `arg4` (integer)
- `arg5` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### capget

```teal
function capget(pid?: integer): integer | nil, integer, integer, string | nil, Errno | nil
```

 Returns the calling thread's (or `pid`'s) capability sets as
 64-bit bitmasks. Each bit position N corresponds to `unix.CAP_*`
 constant N. Linux-only.

**Parameters:**

- `pid` (integer)

**Returns:**

- integer | nil
- integer
- integer
- string | nil
- Errno | nil

### capset

```teal
function capset(effective: integer, permitted: integer, inheritable: integer, pid?: integer): boolean | nil, string | nil, Errno | nil
```

 Sets the calling thread's (or `pid`'s) capability sets. Each
 argument is a 64-bit bitmask of `1 << unix.CAP_*` bits. Linux-only.

**Parameters:**

- `effective` (integer)
- `permitted` (integer)
- `inheritable` (integer)
- `pid` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### ioctl

```teal
function ioctl(fd: integer, request: integer, arg?: integer | string): boolean | string | nil, string | nil, Errno | nil
```

 Generic device control. When `arg` is nil or absent, the ioctl is
 invoked with a null pointer. When `arg` is an integer, it's passed
 by value. When `arg` is a string, a mutable copy of the same size
 is passed to the kernel and the (possibly-modified) buffer of the
 same length is returned.

**Parameters:**

- `fd` (integer)
- `request` (integer)
- `arg` (integer | string)

**Returns:**

- boolean | string | nil
- string | nil
- Errno | nil

### landlock_create_ruleset

```teal
function landlock_create_ruleset(handled_access_fs?: integer, flags?: integer): integer | nil, string | nil, Errno | nil
```

 Landlock: create ruleset. With no args, returns the kernel's
 supported ABI version. With `handled_access_fs`, creates a new
 ruleset file descriptor that handles the given access categories
 (bitwise OR of `unix.LANDLOCK_ACCESS_FS_*`). Linux 5.13+.

**Parameters:**

- `handled_access_fs` (integer)
- `flags` (integer)

**Returns:**

- integer | nil
- string | nil
- Errno | nil

### landlock_add_rule

```teal
function landlock_add_rule(ruleset_fd: integer, parent_fd: integer, allowed: integer, flags?: integer): boolean | nil, string | nil, Errno | nil
```

 Landlock: add a PATH_BENEATH rule granting `allowed` access to the
 subtree rooted at `parent_fd` (opened with `unix.O_PATH`). `allowed`
 must be a subset of the ruleset's handled set.

**Parameters:**

- `ruleset_fd` (integer)
- `parent_fd` (integer)
- `allowed` (integer)
- `flags` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### landlock_restrict_self

```teal
function landlock_restrict_self(ruleset_fd: integer, flags?: integer): boolean | nil, string | nil, Errno | nil
```

 Landlock: apply the ruleset to the current thread (and its future
 children). Caller must set `PR_SET_NO_NEW_PRIVS` first or hold
 `CAP_SYS_ADMIN`. The restriction is irrevocable.

**Parameters:**

- `ruleset_fd` (integer)
- `flags` (integer)

**Returns:**

- boolean | nil
- string | nil
- Errno | nil

### mapshared

```teal
function mapshared(size: integer): Memory
```

 Creates interprocess shared memory mapping.
 This function allocates special memory that'll be inherited across
 fork in a shared way. By default all memory in Redbean is "private"
 memory that's only viewable and editable to the process that owns
 it. When unix.fork() happens, memory is copied appropriately so
 that changes to memory made in the child process, don't clobber
 the memory at those same addresses in the parent process. If you
 don't want that to happen, and you want the memory to be shared
 similar to how it would be shared if you were using threads, then
 you can use this function to achieve just that.
 The memory object this function returns may be accessed using its
 methods, which support atomics and futexes. It's very low-level.
 For example, you can use it to implement scalable mutexes:
     mem = unix.mapshared(8000 * 8)
     LOCK = 0 -- pick an arbitrary word index for lock
     -- From Futexes Are Tricky Version 1.1 § Mutex, Take 3;
     -- Ulrich Drepper, Red Hat Incorporated, June 27, 2004.
     function Lock()
         local ok, old = mem:cmpxchg(LOCK, 0, 1)
         if not ok then
             if old == 1 then
                 old = mem:xchg(LOCK, 2)
             end
             while old > 0 do
                 mem:wait(LOCK, 2)
                 old = mem:xchg(LOCK, 2)
             end
         end
     end
     function Unlock()
         old = mem:add(LOCK, -1)
         if old == 2 then
             mem:store(LOCK, 0)
             mem:wake(LOCK, 1)
         end
     end
 It's possible to accomplish the same thing as unix.mapshared()
 using files and unix.fcntl() advisory locks. However this goes
 significantly faster. For example, that's what SQLite does and
 we recommend using SQLite for IPC in redbean. But, if your app
 has thousands of forked processes fighting for a file lock you
 might need something lower level than file locks, to implement
 things like throttling. Shared memory is a good way to do that
 since there's nothing that's faster.
 The `size` parameter needs to be a multiple of 8. The returned
 memory is zero initialized. When allocating shared memory, you
 should try to get as much use out of it as possible, since the
 overhead of allocating a single shared mapping is 500 words of
 resident memory and 8000 words of virtual memory. It's because
 the Cosmopolitan Libc mmap() granularity is 2**16.
 This system call does not fail. An exception is instead thrown
 if sufficient memory isn't available.

**Parameters:**

- `size` (integer)

**Returns:**

- Memory

### major

```teal
function major(rdev: integer): integer
```

 Extracts the major device number from a device id such as `Stat:rdev()`.

**Parameters:**

- `rdev` (integer)

**Returns:**

- integer

### minor

```teal
function minor(rdev: integer): integer
```

 Extracts the minor device number from a device id such as `Stat:rdev()`.

**Parameters:**

- `rdev` (integer)

**Returns:**

- integer

### statfs

```teal
function statfs(path: string): Statfs | nil, string | nil, Errno | nil
```

 Gets filesystem statistics for the filesystem that contains `path`.

**Parameters:**

- `path` (string)

**Returns:**

- Statfs | nil
- string | nil
- Errno | nil

### fstatfs

```teal
function fstatfs(fd: integer): Statfs | nil, string | nil, Errno | nil
```

 Gets filesystem statistics via an open file descriptor.

**Parameters:**

- `fd` (integer)

**Returns:**

- Statfs | nil
- string | nil
- Errno | nil

### Sigset

```teal
function Sigset(sig: integer, ...: integer): Sigset
```

 Signal set for blocking, unblocking, and waiting on signals.
 Used with `unix.sigprocmask()`, `unix.sigaction()`, and `unix.sigsuspend()`.
 The unix.Sigset class defines a mutable bitset that may currently
 contain 128 entries. See `unix.NSIG` to find out how many signals
 your operating system actually supports.
 Constructs new signal bitset object.

**Parameters:**

- `sig` (integer)
- `...` (integer)

**Returns:**

- Sigset
