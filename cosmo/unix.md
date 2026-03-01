# unix

Type declarations for the `unix` module.

## Types

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
  read: function(self: Memory, offset?: number, bytes?: number): string
  --  Writes bytes to memory region.
  --  `offset` is the starting byte index to which memory is copied,
  --  which defaults to zero.
  --  If `bytes` is none or nil, then an implicit nil-terminator
  --  will be included after your `data` so things like json can
  --  be easily serialized to shared memory.
  --  This operation happens atomically. Each shared mapping has a
  --  single lock which is used to synchronize reads and writes to
  --  that specific map. To make it scale, create additional maps.
  write: function(self: Memory, data: string, offset?: number, bytes?: number)
  --  Loads word from memory region.
  --  This operation is atomic and has relaxed barrier semantics.
  load: function(self: Memory, word_index: number): number
  --  Stores word from memory region.
  --  This operation is atomic and has relaxed barrier semantics.
  store: function(self: Memory, word_index: number, value: number)
  --  Exchanges value.
  --  This sets word at `word_index` to `value` and returns the value
  --  previously held in by the word.
  --  This operation is atomic and provides the same memory barrier
  --  semantics as the aligned x86 LOCK XCHG instruction.
  xchg: function(self: Memory, word_index: number, value: number): number
  --  Compares and exchanges value.
  --  This inspects the word at `word_index` and if its value is the same
  --  as `old` then it'll be replaced by the value `new`, in which case
  --  `true, old` shall be returned. If a different value was held at
  --  word, then `false` shall be returned along with the word.
  --  This operation happens atomically and provides the same memory
  --  barrier semantics as the aligned x86 LOCK CMPXCHG instruction.
  cmpxchg: function(self: Memory, word_index: number, old: number, new: number): boolean, number
  --  Fetches then adds value.
  --  This method modifies the word at `word_index` to contain the sum of
  --  value and the `value` paremeter. This method then returns the value
  --  as it existed before the addition was performed.
  --  This operation is atomic and provides the same memory barrier
  --  semantics as the aligned x86 LOCK XADD instruction.
  fetch_add: function(self: Memory, word_index: number, value: number): number
  --  Fetches and bitwise ands value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_and: function(self: Memory, word_index: number, value: number): number
  --  Fetches and bitwise ors value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_or: function(self: Memory, word_index: number, value: number): number
  --  Fetches and bitwise xors value.
  --  This operation happens atomically and provides the same memory
  --  barrier ordering semantics as its x86 implementation.
  fetch_xor: function(self: Memory, word_index: number, value: number): number
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
  wait: function(self: Memory, word_index: number, expect: number, abs_deadline?: number, nanos?: number): number
  --  Wakes other processes waiting on word.
  --  This method may be used to signal or broadcast to waiters. The
  --  `count` specifies the number of processes that should be woken,
  --  which defaults to `INT_MAX`.
  --  The return value is the number of processes that were actually woken
  --  as a result of the system call. No failure conditions are defined.
  wake: function(self: Memory, index: number, count?: number): number
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
  close: function(self: Dir): boolean
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
  read: function(self: Dir): string, number, number, number
  --  Returns `EOPNOTSUPP` if using a `/zip/...` path or if using Windows NT.
  fd: function(self: Dir): number
  tell: function(self: Dir): number
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
  utime: function(self: Rusage): number, number
  --  It's always the case that `0 ≤ nanos < 1e9`.
  --  On Windows NT this is collected from GetProcessTimes().
  stime: function(self: Rusage): number, number
  --  On Windows NT this is collected from
  --  `NtProcessMemoryCountersEx::PeakWorkingSetSize / 1024`.
  maxrss: function(self: Rusage): number
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as `unix.CLK_TCK`.  Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  Currently only available on FreeBSD and NetBSD.
  idrss: function(self: Rusage): number
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as unix.CLK_TCK.  Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  Currently only available on FreeBSD and NetBSD.
  ixrss: function(self: Rusage): number
  --  If you chart memory usage over the lifetime of your process, then
  --  this would be the space filled in beneath the chart. The frequency
  --  of kernel scheduling is defined as `unix.CLK_TCK`. Each time a tick
  --  happens, the kernel samples your process's memory usage, by adding
  --  it to this value. You can derive the average consumption from this
  --  value by computing how many ticks are in `utime + stime`.
  --  This is only applicable to redbean if its built with MODE=tiny,
  --  because redbean likes to allocate its own deterministic stack.
  --  Currently only available on FreeBSD and NetBSD.
  isrss: function(self: Rusage): number
  --  This number indicates how many times redbean was preempted by the
  --  kernel to `memcpy()` a 4096-byte page. This is one of the tradeoffs
  --  `fork()` entails. This number is usually tinier, when your binaries
  --  are tinier.
  --  Not available on Windows NT.
  minflt: function(self: Rusage): number
  --  Returns number of major page faults.
  --  This number indicates how many times redbean was preempted by the
  --  kernel to perform i/o. For example, you might have used `mmap()` to
  --  load a large file into memory lazily.
  --  On Windows NT this is `NtProcessMemoryCountersEx::PageFaultCount`.
  majflt: function(self: Rusage): number
  --  Operating systems like to reserve hard disk space to back their RAM
  --  guarantees, like using a gold standard for fiat currency. When your
  --  system is under heavy memory load, swap operations may happen while
  --  redbean is working. This number keeps track of them.
  --  Not available on Linux, Windows NT.
  nswap: function(self: Rusage): number
  --  On Windows NT this is `NtIoCounters::ReadOperationCount`.
  inblock: function(self: Rusage): number
  --  On Windows NT this is `NtIoCounters::WriteOperationCount`.
  oublock: function(self: Rusage): number
  --  Not available on Linux, Windows NT.
  msgsnd: function(self: Rusage): number
  --  Not available on Linux, Windows NT.
  msgrcv: function(self: Rusage): number
  --  Not available on Linux.
  nsignals: function(self: Rusage): number
  --  This number is a good thing. It means your redbean finished its work
  --  quickly enough within a time slice that it was able to give back the
  --  remaining time to the system.
  nvcsw: function(self: Rusage): number
  --  This number is a bad thing. It means your redbean was preempted by a
  --  higher priority process after failing to finish its work, within the
  --  allotted time slice.
  nivcsw: function(self: Rusage)
end
```

### Stat

 File metadata and attributes.
 Contains file size, permissions, ownership, and timestamps.
 `unix.Stat` objects are created by `stat()` or `fstat()`.
 Use `unix.S_ISDIR()`, `unix.S_ISREG()`, etc. to check file type from mode.

```teal
local record Stat
  size: function(self: Stat): number
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
  mode: function(self: Stat): number
  uid: function(self: Stat): number
  gid: function(self: Stat): number
  --  File birth time.
  --  This field should be accurate on Apple, Windows, and BSDs. On Linux
  --  this is the minimum of atim/mtim/ctim. On Windows NT nanos is only
  --  accurate to hectonanoseconds.
  --  Here's an example of how you might print a file timestamp:
  --  st = assert(unix.stat('/etc/passwd'))
  --  unixts, nanos = st:birthtim()
  --  year,mon,mday,hour,min,sec,gmtoffsec = unix.localtime(unixts)
  --  Write('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.9d%+.2d%.2d % {
  --  year, mon, mday, hour, min, sec, nanos,
  --  gmtoffsec / (60 * 60), math.abs(gmtoffsec) % 60})
  birthtim: function(self: Stat): number, number
  mtim: function(self: Stat): number, number
  --  Please note that file systems are sometimes mounted with `noatime`
  --  out of concern for i/o performance. Linux also provides `O_NOATIME`
  --  as an option for open().
  --  On Windows NT this is the same as birth time.
  atim: function(self: Stat): number, number
  --  Means time file status was last changed on UNIX.
  --  On Windows NT this is the same as birth time.
  ctim: function(self: Stat): number, number
  --  This provides some indication of how much physical storage a file
  --  actually consumes. For example, for small file systems, your system
  --  might report this number as being 8, which means 4096 bytes.
  blocks: function(self: Stat): number
  --  This field might be of assistance in computing optimal i/o sizes.
  --  Please note this field has no relationship to blocks, as the latter
  --  is fixed at a 512 byte size.
  blksize: function(self: Stat): number
  --  This can be used to detect some other process used `rename()` to swap
  --  out a file underneath you, so you can do a refresh. redbean does it
  --  during each main process heartbeat for its own use cases.
  --  On Windows NT this is set to `NtByHandleFileInformation::FileIndex`.
  ino: function(self: Stat): number
  --  On Windows NT this is set to `NtByHandleFileInformation::VolumeSerialNumber`.
  dev: function(self: Stat): number
  --  This value may be set to `0` or `-1` for files that aren't devices,
  --  depending on the operating system. `unix.major()` and `unix.minor()`
  --  may be used to extract the device numbers.
  rdev: function(self: Stat): number
  nlink: function(self: Stat): any
  gen: function(self: Stat): any
  flags: function(self: Stat): any
end
```

### Statfs

 Filesystem statistics returned by statfs() and fstatfs().

```teal
local record Statfs
  --  Returns filesystem type identifier.
  type: function(self: Statfs): number
  --  Returns optimal transfer block size.
  bsize: function(self: Statfs): number
  --  Returns total data blocks in filesystem.
  blocks: function(self: Statfs): number
  --  Returns free blocks in filesystem.
  bfree: function(self: Statfs): number
  --  Returns free blocks available to unprivileged user.
  bavail: function(self: Statfs): number
  --  Returns total file nodes in filesystem.
  files: function(self: Statfs): number
  --  Returns free file nodes in filesystem.
  ffree: function(self: Statfs): number
  --  Returns filesystem ID as two numbers.
  fsid: function(self: Statfs): number, number
  --  Returns maximum length of filenames.
  namelen: function(self: Statfs): number
  --  Returns fragment size.
  frsize: function(self: Statfs): number
  --  Returns mount flags.
  flags: function(self: Statfs): number
end
```

### Sigset

```teal
local record Sigset
  --  Adds signal to bitset.
  add: function(self: Sigset, sig: number)
  --  Removes signal from bitset.
  remove: function(self: Sigset, sig: number)
  --  Sets all bits in signal bitset to `true`.
  fill: function(self: Sigset)
  --  Sets all bits in signal bitset to `false`.
  clear: function(self: Sigset)
  contains: function(self: Sigset, sig: number): boolean
  __repr: function(self: Sigset): string
  __tostring: function(self: Sigset): string
end
```

### Termios

 Terminal I/O settings.
 Contains terminal mode flags and control characters.
 `unix.Termios` tables are returned by `tcgetattr()` and passed to `tcsetattr()`.

```teal
local record Termios
  --  Input mode flags (e.g., BRKINT, ICRNL, IGNBRK).
  iflag: number
  --  Output mode flags (e.g., OPOST, ONLCR).
  oflag: number
  --  Control mode flags (e.g., CS8, CREAD, CLOCAL).
  cflag: number
  --  Local mode flags (e.g., ECHO, ICANON, ISIG).
  lflag: number
  --  Control characters array (indexed 1..NCCS).
  cc: {number}
  --  Input baud rate.
  ispeed: number
  --  Output baud rate.
  ospeed: number
end
```

### Errno

 Error information from system calls.
 Provides detailed error codes and human-readable descriptions.
 This object is returned by system calls that fail. We prefer returning
 an object because for many system calls, an error is part of their normal
 operation. For example, it's often desirable to use the `errno()` method
 when performing a `read()` to check for EINTR.

```teal
local record Errno
  --  The error number is always different for different platforms. On
  --  UNIX systems, error numbers occupy the range [1,127] in practice.
  --  The System V ABI reserves numbers as high as 4095. On Windows NT,
  --  error numbers can go up to 65535.
  errno: function(self: Errno): number
  --  On UNIX systems this is always 0. On Windows NT this will normally
  --  be the same as `errno(). Because Windows defines so many error codes,
  --  there's oftentimes a multimapping between its error codes and System
  --  Five. In those cases, this value reflects the `GetLastError()` result
  --  at the time the error occurred.
  winerr: function(self: Errno): number
  --  For example, this might return `"EINTR"`.
  name: function(self: Errno): string
  --  For example, this might return `"read"` if `read()` was what failed.
  call: function(self: Errno): string
  --  For example, this might return `"Interrupted system call"`.
  doc: function(self: Errno): string
  --  Different information components are delimited by slash.
  --  For example, this might return `"EINTR/4/Interrupted system call"`.
  --  On Windows NT this will include additional information about the
  --  Windows error (including FormatMessage() output) if the WIN32 error
  --  differs from the System Five error code.
  __tostring: function(self: Errno): string
end
```

### unix Constants

Constants defined in the unix module.

```teal
local record unix Constants
  AF_INET: number
  AF_UNIX: number
  AF_UNSPEC: number
  ARG_MAX: number
  AT_EACCES: number
  AT_FDCWD: number
  AT_SYMLINK_NOFOLLOW: number
  BUFSIZ: number
  CLK_TCK: number
  CLOCK_REALTIME: number
  CLOCK_MONOTONIC: number
  CLOCK_BOOTTIME: number
  CLOCK_MONOTONIC_RAW: number
  CLOCK_REALTIME_COARSE: number
  CLOCK_MONOTONIC_COARSE: number
  CLOCK_THREAD_CPUTIME_ID: number
  CLOCK_PROCESS_CPUTIME_ID: number
  DT_BLK: number
  DT_CHR: number
  DT_DIR: number
  DT_FIFO: number
  DT_LNK: number
  DT_REG: number
  DT_SOCK: number
  DT_UNKNOWN: number
  E2BIG: number
  EACCES: number
  EADDRINUSE: number
  EADDRNOTAVAIL: number
  EAFNOSUPPORT: number
  EAGAIN: number
  EALREADY: number
  EBADF: number
  EBADFD: number
  EBADMSG: number
  EBUSY: number
  ECANCELED: number
  ECHILD: number
  ECONNABORTED: number
  ECONNREFUSED: number
  ECONNRESET: number
  EDEADLK: number
  EDESTADDRREQ: number
  EDOM: number
  EDQUOT: number
  EEXIST: number
  EFAULT: number
  EFBIG: number
  EHOSTDOWN: number
  EHOSTUNREACH: number
  EIDRM: number
  EILSEQ: number
  EINPROGRESS: number
  EINTR: number
  EINVAL: number
  EIO: number
  EISCONN: number
  EISDIR: number
  ELOOP: number
  EMFILE: number
  EMLINK: number
  EMSGSIZE: number
  ENAMETOOLONG: number
  ENETDOWN: number
  ENETRESET: number
  ENETUNREACH: number
  ENFILE: number
  ENOBUFS: number
  ENODATA: number
  ENODEV: number
  ENOENT: number
  ENOEXEC: number
  ENOLCK: number
  ENOMEM: number
  ENOMSG: number
  ENONET: number
  ENOPROTOOPT: number
  ENOSPC: number
  ENOSYS: number
  ENOTBLK: number
  ENOTCONN: number
  ENOTDIR: number
  ENOTEMPTY: number
  ENOTRECOVERABLE: number
  ENOTSOCK: number
  ENOTSUP: number
  ENOTTY: number
  ENXIO: number
  EOPNOTSUPP: number
  EOVERFLOW: number
  EOWNERDEAD: number
  EPERM: number
  EPFNOSUPPORT: number
  EPIPE: number
  EPROTO: number
  EPROTONOSUPPORT: number
  EPROTOTYPE: number
  ERANGE: number
  EREMOTE: number
  ERESTART: number
  EROFS: number
  ESHUTDOWN: number
  ESOCKTNOSUPPORT: number
  ESPIPE: number
  ESRCH: number
  ESTALE: number
  ETIME: number
  ETIMEDOUT: number
  ETOOMANYREFS: number
  ETXTBSY: number
  EUSERS: number
  EXDEV: number
  FD_CLOEXEC: number
  F_GETFD: number
  F_GETFL: number
  F_OK: number
  F_RDLCK: number
  F_SETFD: number
  F_SETFL: number
  F_SETLK: number
  F_SETLKW: number
  F_UNLCK: number
  F_WRLCK: number
  IPPROTO_ICMP: number
  IPPROTO_IP: number
  IPPROTO_RAW: number
  IPPROTO_TCP: number
  IPPROTO_UDP: number
  IP_HDRINCL: number
  IP_MTU: number
  IP_TOS: number
  IP_TTL: number
  ITIMER_PROF: number
  ITIMER_REAL: number
  ITIMER_VIRTUAL: number
  LOG_ALERT: number
  LOG_CRIT: number
  LOG_DEBUG: number
  LOG_EMERG: number
  LOG_ERR: number
  LOG_INFO: number
  LOG_NOTICE: number
  LOG_WARNING: number
  MSG_DONTROUTE: number
  MSG_MORE: number
  MSG_NOSIGNAL: number
  MSG_OOB: number
  MSG_PEEK: number
  MSG_WAITALL: number
  NAME_MAX: number
  NSIG: number
  O_RDONLY: number
  O_WRONLY: number
  O_RDWR: number
  O_CREAT: number
  O_TRUNC: number
  O_CLOEXEC: number
  O_EXCL: number
  O_APPEND: number
  O_NONBLOCK: number
  O_DIRECT: number
  O_DIRECTORY: number
  O_TMPFILE: number
  O_NOFOLLOW: number
  O_UNLINK: number
  O_DSYNC: number
  O_RSYNC: number
  O_SYNC: number
  O_NOATIME: number
  O_ACCMODE: number
  O_EXEC: number
  O_NOCTTY: number
  PATH_MAX: number
  PLEDGE_PENALTY_KILL_THREAD: number
  PLEDGE_PENALTY_KILL_PROCESS: number
  PLEDGE_PENALTY_RETURN_EPERM: number
  PLEDGE_STDERR_LOGGING: number
  PIPE_BUF: number
  POLLERR: number
  POLLHUP: number
  POLLIN: number
  POLLNVAL: number
  POLLOUT: number
  POLLPRI: number
  POLLRDBAND: number
  POLLRDHUP: number
  POLLRDNORM: number
  POLLWRBAND: number
  POLLWRNORM: number
  RLIMIT_AS: number
  RLIMIT_CPU: number
  RLIMIT_FSIZE: number
  RLIMIT_NOFILE: number
  RLIMIT_NPROC: number
  RLIMIT_RSS: number
  PRIO_PROCESS: number
  PRIO_PGRP: number
  PRIO_USER: number
  RUSAGE_BOTH: number
  RUSAGE_CHILDREN: number
  RUSAGE_SELF: number
  RUSAGE_THREAD: number
  R_OK: number
  SA_NOCLDSTOP: number
  SA_NOCLDWAIT: number
  SA_NODEFER: number
  SA_RESETHAND: number
  SA_RESTART: number
  SEEK_CUR: number
  SEEK_END: number
  SEEK_SET: number
  SHUT_RD: number
  SHUT_WR: number
  SHUT_RDWR: number
  SIGABRT: number
  SIGALRM: number
  SIGBUS: number
  SIGCHLD: number
  SIGCONT: number
  SIGEMT: number
  SIGFPE: number
  SIGHUP: number
  SIGILL: number
  SIGINFO: number
  SIGINT: number
  SIGIO: number
  SIGKILL: number
  SIGPIPE: number
  SIGPROF: number
  SIGPWR: number
  SIGQUIT: number
  SIGRTMAX: number
  SIGRTMIN: number
  SIGSEGV: number
  SIGSTKFLT: number
  SIGSTOP: number
  SIGSYS: number
  SIGTERM: number
  SIGTRAP: number
  SIGTSTP: number
  SIGTTIN: number
  SIGTTOU: number
  SIGURG: number
  SIGUSR1: number
  SIGUSR2: number
  SIGVTALRM: number
  SIGWINCH: number
  SIGXCPU: number
  SIGXFSZ: number
  SIG_BLOCK: number
  SIG_DFL: number
  SIG_IGN: number
  SIG_SETMASK: number
  SIG_UNBLOCK: number
  SOCK_CLOEXEC: number
  SOCK_DGRAM: number
  SOCK_NONBLOCK: number
  SOCK_RAW: number
  SOCK_RDM: number
  SOCK_SEQPACKET: number
  SOCK_STREAM: number
  SOL_IP: number
  SOL_SOCKET: number
  SOL_TCP: number
  SOL_UDP: number
  SO_ACCEPTCONN: number
  SO_BROADCAST: number
  SO_DEBUG: number
  SO_DONTROUTE: number
  SO_ERROR: number
  SO_KEEPALIVE: number
  SO_LINGER: number
  SO_RCVBUF: number
  SO_RCVLOWAT: number
  SO_RCVTIMEO: number
  SO_REUSEADDR: number
  SO_REUSEPORT: number
  SO_SNDBUF: number
  SO_SNDLOWAT: number
  SO_SNDTIMEO: number
  SO_TYPE: number
  TCP_CORK: number
  TCP_DEFER_ACCEPT: number
  TCP_FASTOPEN: number
  TCP_FASTOPEN_CONNECT: number
  TCP_KEEPCNT: number
  TCP_KEEPIDLE: number
  TCP_KEEPINTVL: number
  TCP_MAXSEG: number
  TCP_NODELAY: number
  TCP_NOTSENT_LOWAT: number
  TCP_QUICKACK: number
  TCP_SAVED_SYN: number
  TCP_SAVE_SYN: number
  TCP_SYNCNT: number
  TCP_WINDOW_CLAMP: number
  UTIME_NOW: number
  UTIME_OMIT: number
  WNOHANG: number
  WUNTRACED: number
  WCONTINUED: number
  W_OK: number
  X_OK: number
  BRKINT: number
  CLOCAL: number
  CREAD: number
  CS5: number
  CS6: number
  CS7: number
  CS8: number
  CSIZE: number
  CSTOPB: number
  ECHO: number
  ECHOE: number
  ECHOK: number
  ECHONL: number
  HUPCL: number
  ICANON: number
  ICRNL: number
  IEXTEN: number
  IGNBRK: number
  IGNCR: number
  IGNPAR: number
  INLCR: number
  INPCK: number
  ISIG: number
  ISTRIP: number
  IXANY: number
  IXOFF: number
  IXON: number
  NCCS: number
  NOFLSH: number
  OCRNL: number
  ONLCR: number
  ONLRET: number
  ONOCR: number
  OPOST: number
  PARENB: number
  PARMRK: number
  PARODD: number
  TCSADRAIN: number
  TCSAFLUSH: number
  TCSANOW: number
  TOSTOP: number
  VEOF: number
  VEOL: number
  VERASE: number
  VINTR: number
  VKILL: number
  VMIN: number
  VQUIT: number
  VSTART: number
  VSTOP: number
  VTIME: number
end
```

## Functions

### open

```teal
function open(path: string, flags: number, mode?: number, dirfd?: number): number
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
- `flags` (number)
- `mode` (number)
- `dirfd` (number)

**Returns:**

- number

### close

```teal
function close(fd: number): boolean
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

- `fd` (number)

**Returns:**

- boolean

### read

```teal
function read(fd: number, bufsiz?: number, offset?: number): string
```

 Reads from file descriptor.
 This function returns empty string on end of file. The exception is
 if `bufsiz` is zero, in which case an empty returned string means
 the file descriptor works.

**Parameters:**

- `fd` (number)
- `bufsiz` (number)
- `offset` (number)

**Returns:**

- string

### write

```teal
function write(fd: number, data: string, offset?: number): number
```

 Writes to file descriptor.

**Parameters:**

- `fd` (number)
- `data` (string)
- `offset` (number)

**Returns:**

- number

### exit

```teal
function exit(exitcode?: number)
```

 Invokes `_Exit(exitcode)` on the process. This will immediately
 halt the current process. Memory will be freed. File descriptors
 will be closed. Any open connections it owns will be reset. This
 function never returns.

**Parameters:**

- `exitcode` (number)

### environ

```teal
function environ(): {string}
```

 Returns raw environment variables.
 Returns an integer-indexed array of "KEY=VALUE" strings, one per
 environment variable.  The result can be passed directly to
 execve(), execvpe(), spawn(), or child.spawn()'s env option.
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
function setenv(name?: any, value?: any, overwrite?: any)
```

 Sets environment variable.
 This wraps the C `setenv()` function to allow Lua scripts to set
 environment variables.
 @overload fun(name: string, value: string, overwrite?: boolean): nil, error: unix.Errno

**Parameters:**

- `name` (string) - environment variable name
- `value` (string) - value to set
- `overwrite?` (boolean) - if false, won't overwrite existing variables (defaults to true)

**Returns:**

- true

### unsetenv

```teal
function unsetenv(name?: any)
```

 Unsets environment variable.
 This wraps the C `unsetenv()` function to allow Lua scripts to remove
 environment variables.
 @overload fun(name: string): nil, error: unix.Errno

**Parameters:**

- `name` (string) - environment variable name to unset

**Returns:**

- true

### clearenv

```teal
function clearenv()
```

 Clears all environment variables.
 This wraps the C `clearenv()` function to allow Lua scripts to remove
 all environment variables at once.
 @overload fun(): nil, error: unix.Errno

**Returns:**

- true

### getlogin

```teal
function getlogin()
```

 Gets login name of current user.
 This wraps the C `getlogin()` function to retrieve the login name
 associated with the current session.
 @overload fun(): nil, error: unix.Errno

**Returns:**

- string - login name

### fork

```teal
function fork(): number | number
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

- number | number

### commandv

```teal
function commandv(prog: string): string
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

- string

### execve

```teal
function execve(prog: string, args: {string}, env: {string}): nil, Errno
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
- Errno

### execvp

```teal
function execvp(prog: string, argv?: {string}): nil, Errno
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
- Errno

### execvpe

```teal
function execvpe(prog: string, argv: {string}, envp?: {string}): nil, Errno
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
- Errno

### fexecve

```teal
function fexecve(fd: number, argv: {string}, envp?: {string}): nil, Errno
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

- `fd` (number)
- `argv` ({string})
- `envp` ({string})

**Returns:**

- nil
- Errno

### spawn

```teal
function spawn(prog: string, argv: {string}, envp?: {string}): number
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

- number

### spawnp

```teal
function spawnp(prog: string, argv: {string}, envp?: {string}): number
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

- number

### dup

```teal
function dup(oldfd: number, newfd?: number, flags?: number, lowest?: number): number
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

- `oldfd` (number)
- `newfd` (number)
- `flags` (number)
- `lowest` (number)

**Returns:**

- number

### pipe

```teal
function pipe(flags?: number): number, number
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
 data, err = unix.read(reader)
 if data then
 if data ~= "" then
 Write(data)
 else
 break
 end
 elseif err:errno() ~= EINTR then
 Log(kLogWarn, tostring(err))
 break
 end
 end
 assert(unix.close(reader))
 assert(unix.wait())
 end

**Parameters:**

- `flags` (number)

**Returns:**

- number
- number

### wait

```teal
function wait(pid?: number, options?: number): number, number, Rusage
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
 pid, status = unix.wait(-1, unix.WNOHANG)
 if pid then
 if unix.WIFEXITED(status) then
 print('child', pid, 'exited with',
 unix.WEXITSTATUS(status))
 elseif unix.WIFSIGNALED(status) then
 print('child', pid, 'crashed with',
 unix.strsignal(unix.WTERMSIG(status)))
 end
 elseif status:errno() == unix.ECHILD then
 Log(kLogDebug, 'no more zombies')
 break
 else
 Log(kLogWarn, tostring(err))
 break
 end
 end

**Parameters:**

- `pid` (number)
- `options` (number)

**Returns:**

- number
- number
- Rusage

### WIFEXITED

```teal
function WIFEXITED(wstatus: number): boolean
```

 Returns `true` if process exited cleanly.

**Parameters:**

- `wstatus` (number)

**Returns:**

- boolean

### WEXITSTATUS

```teal
function WEXITSTATUS(wstatus: number): number
```

 Returns code passed to exit() assuming `WIFEXITED(wstatus)` is true.

**Parameters:**

- `wstatus` (number)

**Returns:**

- number

### WIFSIGNALED

```teal
function WIFSIGNALED(wstatus: number): boolean
```

 Returns `true` if process terminated due to a signal.

**Parameters:**

- `wstatus` (number)

**Returns:**

- boolean

### WTERMSIG

```teal
function WTERMSIG(wstatus: number): number
```

 Returns signal that caused process to terminate assuming
 `WIFSIGNALED(wstatus)` is `true`.

**Parameters:**

- `wstatus` (number)

**Returns:**

- number

### getpid

```teal
function getpid(): number
```

 Returns process id of current process.
 This function does not fail.

**Returns:**

- number

### getppid

```teal
function getppid(): number
```

 Returns process id of parent process.
 This function does not fail.

**Returns:**

- number

### kill

```teal
function kill(pid: number, sig: number): boolean
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

- `pid` (number)
- `sig` (number)

**Returns:**

- boolean

### killpg

```teal
function killpg(pgrp: number, sig: number): boolean
```

 Sends signal to process group.
 This is similar to `kill()` but sends the signal to all processes
 in the specified process group.
 `pgrp` is the process group id. If 0, sends to the calling process's
 process group.
 `sig` can be any signal value (e.g., `SIGTERM`, `SIGKILL`, etc.).

**Parameters:**

- `pgrp` (number)
- `sig` (number)

**Returns:**

- boolean

### raise

```teal
function raise(sig: number): number
```

 Triggers signal in current process.
 This is pretty much the same as `kill(getpid(), sig)`.

**Parameters:**

- `sig` (number)

**Returns:**

- number

### access

```teal
function access(path: string, how: number, flags?: number, dirfd?: number): boolean
```

 Checks if effective user of current process has permission to access file.
 - `AT_SYMLINK_NOFOLLOW`: do not follow symbolic links.

**Parameters:**

- `path` (string)
- `how` (number)
- `flags` (number)
- `dirfd` (number)

**Returns:**

- boolean

### mkdir

```teal
function mkdir(path: string, mode?: number, dirfd?: number): boolean
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
- `mode` (number)
- `dirfd` (number)

**Returns:**

- boolean

### makedirs

```teal
function makedirs(path: string, mode?: number): boolean
```

 Unlike mkdir() this convenience wrapper will automatically create
 parent parent directories as needed. If the directory already exists
 then, unlike mkdir() which returns EEXIST, the makedirs() function
 will return success.
 `path` is the path of the directory you wish to create.
 `mode` is octal permission bits, e.g. `0755`.

**Parameters:**

- `path` (string)
- `mode` (number)

**Returns:**

- boolean

### mkdtemp

```teal
function mkdtemp(template: string): string
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

- string

### mkstemp

```teal
function mkstemp(template: string): number, string
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

- number
- string

### chdir

```teal
function chdir(path: string): boolean
```

 Changes current directory to `path`.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### unlink

```teal
function unlink(path: string, dirfd?: number): boolean
```

 Removes file at `path`.
 If `path` refers to a symbolic link, the link is removed.
 Returns `EISDIR` if `path` refers to a directory. See `rmdir()`.

**Parameters:**

- `path` (string)
- `dirfd` (number)

**Returns:**

- boolean

### rmdir

```teal
function rmdir(path: string, dirfd?: number): boolean
```

 Removes empty directory at `path`.
 Returns `ENOTDIR` if `path` isn't a directory, or a path component
 in `path` exists yet wasn't a directory.

**Parameters:**

- `path` (string)
- `dirfd` (number)

**Returns:**

- boolean

### rename

```teal
function rename(oldpath: string, newpath: string, olddirfd: number, newdirfd: number): boolean
```

 Renames file or directory.

**Parameters:**

- `oldpath` (string)
- `newpath` (string)
- `olddirfd` (number)
- `newdirfd` (number)

**Returns:**

- boolean

### link

```teal
function link(existingpath: string, newpath: string, flags: number, olddirfd: number, newdirfd: number): boolean
```

 Creates hard link, so your underlying inode has two names.

**Parameters:**

- `existingpath` (string)
- `newpath` (string)
- `flags` (number)
- `olddirfd` (number)
- `newdirfd` (number)

**Returns:**

- boolean

### symlink

```teal
function symlink(target: string, linkpath: string, newdirfd?: number): boolean
```

 Creates symbolic link.
 On Windows NT a symbolic link is called a "reparse point" and can
 only be created from an administrator account. Your redbean will
 automatically request the appropriate permissions.

**Parameters:**

- `target` (string)
- `linkpath` (string)
- `newdirfd` (number)

**Returns:**

- boolean

### readlink

```teal
function readlink(path: string, dirfd?: number): string
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
- `dirfd` (number)

**Returns:**

- string

### realpath

```teal
function realpath(path: string): string
```

 Returns absolute path of filename, with `.` and `..` components
 removed, and symlinks will be resolved.

**Parameters:**

- `path` (string)

**Returns:**

- string

### utimensat

```teal
function utimensat(path: string, asecs: number, ananos: number, msecs: number, mnanos: number, dirfd?: number, flags?: number): number
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
- `asecs` (number)
- `ananos` (number)
- `msecs` (number)
- `mnanos` (number)
- `dirfd` (number)
- `flags` (number)

**Returns:**

- number

### futimens

```teal
function futimens(fd: number, asecs: number, ananos: number, msecs: number, mnanos: number): number
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

- `fd` (number)
- `asecs` (number)
- `ananos` (number)
- `msecs` (number)
- `mnanos` (number)

**Returns:**

- number

### chown

```teal
function chown(path: string, uid: number, gid: number, flags?: number, dirfd?: number): boolean
```

 Changes user and group on file.
 Returns `ENOSYS` on Windows NT.

**Parameters:**

- `path` (string)
- `uid` (number)
- `gid` (number)
- `flags` (number)
- `dirfd` (number)

**Returns:**

- boolean

### chmod

```teal
function chmod(path: string, mode: number, flags?: number, dirfd?: number): boolean
```

 Changes mode bits on file.
 On Windows NT the chmod system call only changes the read-only
 status of a file.

**Parameters:**

- `path` (string)
- `mode` (number)
- `flags` (number)
- `dirfd` (number)

**Returns:**

- boolean

### getcwd

```teal
function getcwd(): string
```

 Returns current working directory.
 On Windows NT, this function transliterates `\` to `/` and
 furthermore prefixes `//?/` to WIN32 DOS-style absolute paths,
 thereby assisting with simple absolute filename checks in addition
 to enabling one to exceed the traditional 260 character limit.

**Returns:**

- string

### rmrf

```teal
function rmrf(path: string): boolean
```

 Recursively removes filesystem path.
 Like `unix.makedirs()` this function isn't actually a system call but
 rather is a Libc convenience wrapper. It's intended to be equivalent
 to using the UNIX shell's `rm -rf path` command.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### fcntl

```teal
function fcntl(fd: number, cmd: number, ...: any): any
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
 └─→ nil, unix.Errno
 Returns file descriptor flags.
 The returned `flags` may include any of:
 - `unix.FD_CLOEXEC` if `fd` was opened with `unix.O_CLOEXEC`.
 Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_SETFD, flags:int)
 ├─→ true
 └─→ nil, unix.Errno
 Sets file descriptor flags.
 `flags` may include any of:
 - `unix.FD_CLOEXEC` to re-open `fd` with `unix.O_CLOEXEC`.
 Returns `EBADF` if `fd` isn't open.
 unix.fcntl(fd:int, unix.F_GETFL)
 ├─→ flags:int
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
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

- `fd` (number)
- `cmd` (number)
- `...` (any)

**Returns:**

- any

### getsid

```teal
function getsid(pid: number): number
```

 Gets session id.

**Parameters:**

- `pid` (number)

**Returns:**

- number

### getpgrp

```teal
function getpgrp(): number
```

 Gets process group id.

**Returns:**

- number

### setpgrp

```teal
function setpgrp(): number
```

 Sets process group id. This is the same as `setpgid(0,0)`.

**Returns:**

- number

### setpgid

```teal
function setpgid(pid: number, pgid: number): boolean
```

 Sets process group id the modern way.

**Parameters:**

- `pid` (number)
- `pgid` (number)

**Returns:**

- boolean

### getpgid

```teal
function getpgid(pid: number)
```

 Gets process group id the modern way.

**Parameters:**

- `pid` (number)

### setsid

```teal
function setsid(): number
```

 Sets session id.
 This function can be used to create daemons.
 Fails with `ENOSYS` on Windows NT.

**Returns:**

- number

### daemon

```teal
function daemon(nochdir?: boolean, noclose?: boolean): boolean
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

- boolean

### getuid

```teal
function getuid(): number
```

 Gets real user id.
 On Windows this system call is polyfilled by running `GetUserNameW()`
 through Knuth's multiplicative hash.
 This function does not fail.

**Returns:**

- number

### getgid

```teal
function getgid(): number
```

 Sets real group id.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- number

### geteuid

```teal
function geteuid(): number
```

 Gets effective user id.
 For example, if your redbean is a setuid binary, then getuid() will
 return the uid of the user running the program, and geteuid() shall
 return zero which means root, assuming that's the file owning user.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- number

### getegid

```teal
function getegid(): number
```

 Gets effective group id.
 On Windows this system call is polyfilled as getuid().
 This function does not fail.

**Returns:**

- number

### chroot

```teal
function chroot(path: string): boolean
```

 Changes root directory.
 Returns `ENOSYS` on Windows NT.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### setuid

```teal
function setuid(uid: number): boolean
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

- `uid` (number)

**Returns:**

- boolean

### setfsuid

```teal
function setfsuid(uid: number): boolean
```

 Sets user id for file system ops.

**Parameters:**

- `uid` (number)

**Returns:**

- boolean

### setgid

```teal
function setgid(gid: number): boolean
```

 Sets group id.
 Returns `ENOSYS` on Windows NT if `gid` isn't `getgid()`.

**Parameters:**

- `gid` (number)

**Returns:**

- boolean

### setresuid

```teal
function setresuid(real: number, effective: number, saved: number): boolean
```

 Sets real, effective, and saved user ids.
 If any of the above parameters are -1, then it's a no-op.
 Returns `ENOSYS` on Windows NT.
 Returns `ENOSYS` on Macintosh and NetBSD if `saved` isn't -1.

**Parameters:**

- `real` (number)
- `effective` (number)
- `saved` (number)

**Returns:**

- boolean

### setresgid

```teal
function setresgid(real: number, effective: number, saved: number): boolean
```

 Sets real, effective, and saved group ids.
 If any of the above parameters are -1, then it's a no-op.
 Returns `ENOSYS` on Windows NT.
 Returns `ENOSYS` on Macintosh and NetBSD if `saved` isn't -1.

**Parameters:**

- `real` (number)
- `effective` (number)
- `saved` (number)

**Returns:**

- boolean

### umask

```teal
function umask(newmask: number): number
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

- `newmask` (number)

**Returns:**

- number

### syslog

```teal
function syslog(priority: number, msg: string)
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

- `priority` (number)
- `msg` (string)

### clock_gettime

```teal
function clock_gettime(clock?: number): number, number
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

- `clock` (number)

**Returns:**

- number
- number

### nanosleep

```teal
function nanosleep(seconds: number, nanos?: number): number, number
```

 Sleeps with nanosecond precision.
 Returns `EINTR` if a signal was received while waiting.

**Parameters:**

- `seconds` (number)
- `nanos` (number)

**Returns:**

- number
- number

### sync

```teal
function sync()
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

### fsync

```teal
function fsync(fd: number): boolean
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

**Parameters:**

- `fd` (number)

**Returns:**

- boolean

### fdatasync

```teal
function fdatasync(fd: number): boolean
```

 These functions are used to make programs slower by asking the
 operating system to flush data to the physical medium.

**Parameters:**

- `fd` (number)

**Returns:**

- boolean

### lseek

```teal
function lseek(fd: number, offset: number, whence?: number): number
```

 Seeks to file position.
 `whence` can be one of:
 - `SEEK_SET`: Sets the file position to `offset` [default]
 - `SEEK_CUR`: Sets the file position to `position + offset`
 - `SEEK_END`: Sets the file position to `filesize + offset`
 Returns the new position relative to the start of the file.

**Parameters:**

- `fd` (number)
- `offset` (number)
- `whence` (number)

**Returns:**

- number

### truncate

```teal
function truncate(path: string, length?: number): boolean
```

 Reduces or extends underlying physical medium of file.
 If file was originally larger, content >length is lost.

**Parameters:**

- `path` (string)
- `length` (number)

**Returns:**

- boolean

### ftruncate

```teal
function ftruncate(fd: number, length?: number): boolean
```

 Reduces or extends underlying physical medium of open file.
 If file was originally larger, content >length is lost.

**Parameters:**

- `fd` (number)
- `length` (number)

**Returns:**

- boolean

### socket

```teal
function socket(family?: number, type?: number, protocol?: number): number
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

- `family` (number)
- `type` (number)
- `protocol` (number)

**Returns:**

- number

### socketpair

```teal
function socketpair(family?: number, type?: number, protocol?: number): number, number
```

 Creates bidirectional pipe.
 - `SOCK_STREAM`
 - `SOCK_DGRAM`
 - `SOCK_SEQPACKET`
 You may bitwise OR any of the following into `type`:
 - `SOCK_CLOEXEC`
 - `SOCK_NONBLOCK`

**Parameters:**

- `family` (number)
- `type` (number)
- `protocol` (number)

**Returns:**

- number
- number

### bind

```teal
function bind(fd: number, ip?: number, port?: number): boolean
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

- `fd` (number)
- `ip` (number)
- `port` (number)

**Returns:**

- boolean

### siocgifconf

```teal
function siocgifconf(): any
```

 Returns list of network adapter addresses.

**Returns:**

- any

### getsockopt

```teal
function getsockopt(fd: number, level: number, optname: number): number
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, value:bool)
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, value:int)
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, secs:int[, nanos:int])
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER, secs:int, enabled:bool)
 ├─→ true
 └─→ nil, unix.Errno
 This `SO_LINGER` parameter can be used to make close() a blocking
 call. Normally when the kernel returns immediately when it receives
 close(). Sometimes it's desirable to have extra assurance on errors
 happened, even if it comes at the cost of performance.
 unix.setsockopt(serverfd:int, unix.SOL_TCP, unix.TCP_SAVE_SYN, enabled:int)
 ├─→ true
 └─→ nil, unix.Errno
 unix.getsockopt(clientfd:int, unix.SOL_TCP, unix.TCP_SAVED_SYN)
 ├─→ syn_packet_bytes:str
 └─→ nil, unix.Errno
 This `TCP_SAVED_SYN` option may be used to retrieve the bytes of the
 TCP SYN packet that the client sent when the connection for `fd` was
 opened. In order for this to work, `TCP_SAVE_SYN` must have been set
 earlier on the listening socket. This is Linux-only. You can use the
 `OnServerListen` hook to enable SYN saving in your Redbean. When the
 `TCP_SAVE_SYN` option isn't used, this may return empty string.

**Parameters:**

- `fd` (number)
- `level` (number)
- `optname` (number)

**Returns:**

- number

### setsockopt

```teal
function setsockopt(fd: number, level: number, optname: number, value: boolean | number): boolean
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, value:bool)
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, value:int)
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, level:int, optname:int, secs:int[, nanos:int])
 ├─→ true
 └─→ nil, unix.Errno
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
 └─→ nil, unix.Errno
 unix.setsockopt(fd:int, unix.SOL_SOCKET, unix.SO_LINGER, secs:int, enabled:bool)
 ├─→ true
 └─→ nil, unix.Errno
 This `SO_LINGER` parameter can be used to make close() a blocking
 call. Normally when the kernel returns immediately when it receives
 close(). Sometimes it's desirable to have extra assurance on errors
 happened, even if it comes at the cost of performance.
 unix.setsockopt(serverfd:int, unix.SOL_TCP, unix.TCP_SAVE_SYN, enabled:int)
 ├─→ true
 └─→ nil, unix.Errno
 unix.getsockopt(clientfd:int, unix.SOL_TCP, unix.TCP_SAVED_SYN)
 ├─→ syn_packet_bytes:str
 └─→ nil, unix.Errno
 This `TCP_SAVED_SYN` option may be used to retrieve the bytes of the
 TCP SYN packet that the client sent when the connection for `fd` was
 opened. In order for this to work, `TCP_SAVE_SYN` must have been set
 earlier on the listening socket. This is Linux-only. You can use the
 `OnServerListen` hook to enable SYN saving in your Redbean. When the
 `TCP_SAVE_SYN` option isn't used, this may return empty string.

**Parameters:**

- `fd` (number)
- `level` (number)
- `optname` (number)
- `value` (boolean | number)

**Returns:**

- boolean

### poll

```teal
function poll(fds: {number: number}, timeoutms?: number): {number: number}
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

- `fds` ({number: number})
- `timeoutms` (number)

**Returns:**

- {number: number}

### gethostname

```teal
function gethostname(): string
```

 Returns hostname of system.

**Returns:**

- string

### listen

```teal
function listen(fd: number, backlog?: number): boolean
```

 Begins listening for incoming connections on a socket.

**Parameters:**

- `fd` (number)
- `backlog` (number)

**Returns:**

- boolean

### accept

```teal
function accept(serverfd: number, flags?: number): number, number, number
```

 Accepts new client socket descriptor for a listening tcp socket.
 `flags` may have any combination (using bitwise OR) of:
 - `SOCK_CLOEXEC`
 - `SOCK_NONBLOCK`

**Parameters:**

- `serverfd` (number)
- `flags` (number)

**Returns:**

- number
- number
- number

### connect

```teal
function connect(fd: number, ip: number, port: number): boolean
```

 Connects a TCP socket to a remote host.
 With TCP this is a blocking operation. For a UDP socket it simply
 remembers the intended address so that `send()` or `write()` may be used
 rather than `sendto()`.

**Parameters:**

- `fd` (number)
- `ip` (number)
- `port` (number)

**Returns:**

- boolean

### getsockname

```teal
function getsockname(fd: number): number, number
```

 Retrieves the local address of a socket.

**Parameters:**

- `fd` (number)

**Returns:**

- number
- number

### getpeername

```teal
function getpeername(fd: number): number, number
```

 Retrieves the remote address of a socket.
 This operation will either fail on `AF_UNIX` sockets or return an
 empty string.

**Parameters:**

- `fd` (number)

**Returns:**

- number
- number

### recv

```teal
function recv(fd: number, bufsiz?: number, flags?: number): string
```

 - `MSG_WAITALL`
 - `MSG_DONTROUTE`
 - `MSG_PEEK`
 - `MSG_OOB`

**Parameters:**

- `fd` (number)
- `bufsiz` (number)
- `flags` (number)

**Returns:**

- string

### recvfrom

```teal
function recvfrom(fd: number, bufsiz?: number, flags?: number): string, number, number
```

 - `MSG_WAITALL`
 - `MSG_DONTROUTE`
 - `MSG_PEEK`
 - `MSG_OOB`

**Parameters:**

- `fd` (number)
- `bufsiz` (number)
- `flags` (number)

**Returns:**

- string
- number
- number

### send

```teal
function send(fd: number, data: string, flags?: number): number
```

 This is the same as `write` except it has a `flags` argument
 that's intended for sockets.
 - `MSG_NOSIGNAL`: Don't SIGPIPE on EOF
 - `MSG_OOB`: Send stream data through out of bound channel
 - `MSG_DONTROUTE`: Don't go through gateway (for diagnostics)
 - `MSG_MORE`: Manual corking to belay nodelay (0 on non-Linux)

**Parameters:**

- `fd` (number)
- `data` (string)
- `flags` (number)

**Returns:**

- number

### sendto

```teal
function sendto(fd: number, data: string, ip: number, port: number, flags?: number): number
```

 This is useful for sending messages over UDP sockets to specific
 addresses.
 - `MSG_OOB`
 - `MSG_DONTROUTE`
 - `MSG_NOSIGNAL`

**Parameters:**

- `fd` (number)
- `data` (string)
- `ip` (number)
- `port` (number)
- `flags` (number)

**Returns:**

- number

### shutdown

```teal
function shutdown(fd: number, how: number): boolean
```

 Partially closes socket.
 - `SHUT_RD`: sends a tcp half close for reading
 - `SHUT_WR`: sends a tcp half close for writing
 - `SHUT_RDWR`
 This system call currently has issues on Macintosh, so portable code
 should log rather than assert failures reported by `shutdown()`.

**Parameters:**

- `fd` (number)
- `how` (number)

**Returns:**

- boolean

### sigprocmask

```teal
function sigprocmask(how: number, newmask: Sigset): Sigset
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

- `how` (number)
- `newmask` (Sigset)

**Returns:**

- Sigset

### sigaction

```teal
function sigaction(sig: number, handler?: function | number, flags?: number, mask?: Sigset): function | number, number, Sigset
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
 ok, err = unix.sigsuspend(oldmask)
 assert(not ok)
 assert(err:errno() == unix.EINTR)
 assert(gotsigusr1)
 assert(unix.sigprocmask(unix.SIG_SETMASK, oldmask))
 It's a good idea to not do too much work in a signal handler.

**Parameters:**

- `sig` (number)
- `handler` (function | number)
- `flags` (number)
- `mask` (Sigset)

**Returns:**

- function | number
- number
- Sigset

### sigsuspend

```teal
function sigsuspend(mask?: Sigset): nil, Errno
```

 Waits for signal to be delivered.
 The signal mask is temporarily replaced with `mask` during this system call.

**Parameters:**

- `mask` (Sigset)

**Returns:**

- nil
- Errno

### setitimer

```teal
function setitimer(which: number, intervalsec: number, intervalns: number, valuesec: number, valuens: number): number, number, number, number
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

- `which` (number)
- `intervalsec` (number)
- `intervalns` (number)
- `valuesec` (number)
- `valuens` (number)

**Returns:**

- number
- number
- number
- number

### strsignal

```teal
function strsignal(sig: number): string
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

- `sig` (number)

**Returns:**

- string

### setrlimit

```teal
function setrlimit(resource: number, soft: number, hard?: number): boolean
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
 should work on all platforms except Windows.
 If a limit isn't supported by the host platform, it'll be set to
 127. On most platforms these limits are enforced by the kernel and
 as such are inherited by subprocesses.

**Parameters:**

- `resource` (number)
- `soft` (number)
- `hard` (number)

**Returns:**

- boolean

### getrlimit

```teal
function getrlimit(resource: number): number, number
```

 Returns information about resource limits for current process.

**Parameters:**

- `resource` (number)

**Returns:**

- number
- number

### nice

```teal
function nice(inc: number): number
```

 Adjusts the nice value (scheduling priority) of the calling process.
 The nice value ranges from -20 (highest priority) to 19 (lowest priority).
 Only privileged processes can lower the nice value (increase priority).
 `inc` is added to the current nice value. Positive values decrease
 priority, negative values increase it.
 Returns the new nice value on success. Note that -1 is a valid return
 value, so errors must be detected by checking the second return value.

**Parameters:**

- `inc` (number)

**Returns:**

- number

### getpriority

```teal
function getpriority(which: number, who: number): number
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

- `which` (number)
- `who` (number)

**Returns:**

- number

### setpriority

```teal
function setpriority(which: number, who: number, prio: number): boolean
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

- `which` (number)
- `who` (number)
- `prio` (number)

**Returns:**

- boolean

### getrusage

```teal
function getrusage(who?: number): Rusage
```

 Returns information about resource usage for current process, e.g.
 >: unix.getrusage()
 {utime={0, 53644000}, maxrss=44896, minflt=545, oublock=24, nvcsw=9}
 - `RUSAGE_SELF`: current process
 - `RUSAGE_THREAD`: current thread
 - `RUSAGE_CHILDREN`: not supported on Windows NT
 - `RUSAGE_BOTH`: not supported on non-Linux

**Parameters:**

- `who` (number)

**Returns:**

- Rusage

### pledge

```teal
function pledge(promises?: string, execpromises?: string, mode?: number): boolean
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
- `mode` (number)

**Returns:**

- boolean

### unveil

```teal
function unveil(path: string, permissions: string): boolean
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

- boolean

### gmtime

```teal
function gmtime(unixts: number): number, number, number, number, number, number, number, number, number, number, string
```

 Breaks down UNIX timestamp into Zulu Time numbers.

**Parameters:**

- `unixts` (number)

**Returns:**

- number
- number
- number
- number
- number
- number
- number
- number
- number
- number
- string

### localtime

```teal
function localtime(unixts: number): number, number, number, number, number, number, number, number, number, number, string
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

- `unixts` (number)

**Returns:**

- number
- number
- number
- number
- number
- number
- number
- number
- number
- number
- string

### stat

```teal
function stat(path: string, flags?: number, dirfd?: number): Stat
```

 Gets information about file or directory.
 - `AT_SYMLINK_NOFOLLOW`: do not follow symbolic links.

**Parameters:**

- `path` (string)
- `flags` (number)
- `dirfd` (number)

**Returns:**

- Stat

### S_ISDIR

```teal
function S_ISDIR(mode: number): boolean
```

 Tests if file mode represents a directory.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISREG

```teal
function S_ISREG(mode: number): boolean
```

 Tests if file mode represents a regular file.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISLNK

```teal
function S_ISLNK(mode: number): boolean
```

 Tests if file mode represents a symbolic link.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISBLK

```teal
function S_ISBLK(mode: number): boolean
```

 Tests if file mode represents a block device.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISCHR

```teal
function S_ISCHR(mode: number): boolean
```

 Tests if file mode represents a character device.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISFIFO

```teal
function S_ISFIFO(mode: number): boolean
```

 Tests if file mode represents a FIFO/pipe.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### S_ISSOCK

```teal
function S_ISSOCK(mode: number): boolean
```

 Tests if file mode represents a socket.

**Parameters:**

- `mode` (number)

**Returns:**

- boolean

### fstat

```teal
function fstat(fd: number): Stat
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

- `fd` (number)

**Returns:**

- Stat

### statfs

```teal
function statfs(path: string): Statfs
```

 Gets filesystem statistics for a path.
 Returns information about the filesystem containing the specified file.

**Parameters:**

- `path` (string)

**Returns:**

- Statfs

### fstatfs

```teal
function fstatfs(fd: number): Statfs
```

 Gets filesystem statistics from a file descriptor.
 Returns information about the filesystem containing the open file.

**Parameters:**

- `fd` (number)

**Returns:**

- Statfs

### major

```teal
function major(dev: number): number
```

 Extracts major device number from a device ID.
 Use with stat():dev() or stat():rdev() to identify device types.

**Parameters:**

- `dev` (number)

**Returns:**

- number

### minor

```teal
function minor(dev: number): number
```

 Extracts minor device number from a device ID.
 Use with stat():dev() or stat():rdev() to identify specific devices.

**Parameters:**

- `dev` (number)

**Returns:**

- number

### opendir

```teal
function opendir(path: string): Dir
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

- Dir

### fdopendir

```teal
function fdopendir(fd?: any): function, Dir
```

 Opens directory for listing its contents, via an fd.
 The returned `unix.Dir` takes ownership of the file descriptor
 and will close it automatically when garbage collected.

**Parameters:**

- `fd` (integer) - should be created by `open(path, O_RDONLY|O_DIRECTORY)`.

**Returns:**

- function
- Dir

### isatty

```teal
function isatty(fd: number): boolean
```

 Returns true if file descriptor is a teletypewriter. Otherwise nil
 with an Errno object holding one of the following values:
 - `ENOTTY` if `fd` is valid but not a teletypewriter
 - `EBADF` if `fd` isn't a valid file descriptor.
 - `EPERM` if pledge() is used without `tty` in lenient mode
 No other error numbers are possible.

**Parameters:**

- `fd` (number)

**Returns:**

- boolean

### tiocgwinsz

```teal
function tiocgwinsz(fd: number): number, number
```

**Parameters:**

- `fd` (number)

**Returns:**

- number
- number

### tcgetattr

```teal
function tcgetattr(fd: number): Termios, Errno
```

 Gets the parameters associated with the terminal.
 Returns a Termios table containing terminal attributes on success.
 The returned table contains:
 - `iflag`: input mode flags (BRKINT, ICRNL, etc.)
 - `oflag`: output mode flags (OPOST, ONLCR, etc.)
 - `cflag`: control mode flags (CS8, CREAD, etc.)
 - `lflag`: local mode flags (ECHO, ICANON, ISIG, etc.)
 - `cc`: array of control characters (indexed 1..NCCS)
 - `ispeed`: input baud rate
 - `ospeed`: output baud rate
 Common use: disable echo for password input.
     local tio = unix.tcgetattr(0)
     local old_lflag = tio.lflag
     tio.lflag = tio.lflag & ~unix.ECHO
     unix.tcsetattr(0, unix.TCSANOW, tio)
     local password = io.read()
     tio.lflag = old_lflag
     unix.tcsetattr(0, unix.TCSANOW, tio)

**Parameters:**

- `fd` (number)

**Returns:**

- Termios
- Errno

### tcsetattr

```teal
function tcsetattr(fd: number, action: number, termios: Termios): boolean, Errno
```

 Sets the parameters associated with the terminal.
 `action` specifies when the changes take effect:
 - `TCSANOW`: changes occur immediately
 - `TCSADRAIN`: changes occur after all output is transmitted
 - `TCSAFLUSH`: changes occur after all output is transmitted,
   and all input that has been received but not read is discarded
 `termios` is a table with the same fields as returned by tcgetattr().

**Parameters:**

- `fd` (number)
- `action` (number)
- `termios` (Termios)

**Returns:**

- boolean
- Errno

### tmpfd

```teal
function tmpfd(): number
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

- number

### sched_yield

```teal
function sched_yield()
```

 Relinquishes scheduled quantum.

### mapshared

```teal
function mapshared(size: number): Memory
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

- `size` (number)

**Returns:**

- Memory

### Sigset

```teal
function Sigset(sig: number, ...: number): Sigset
```

 Signal set for blocking, unblocking, and waiting on signals.
 Used with `unix.sigprocmask()`, `unix.sigaction()`, and `unix.sigsuspend()`.
 The unix.Sigset class defines a mutable bitset that may currently
 contain 128 entries. See `unix.NSIG` to find out how many signals
 your operating system actually supports.
 Constructs new signal bitset object.

**Parameters:**

- `sig` (number)
- `...` (number)

**Returns:**

- Sigset
