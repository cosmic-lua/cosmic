--- Bounded child-process supervision with explicit argv, environment,
--- directory and descriptors. A child started with [`Child.start`]
--- keeps running if a signal ends this process, which then never closes
--- its handle -- unless a `sandbox` that unveils holds it, whose pid
--- namespace ends with this process. Only [`Child.run`] holds SIGINT
--- and SIGTERM for you. A supervisor takes a [`Child.guard`] and asks
--- `g:cancelled()` after each round of [`Child.wait_any`] or
--- `h:try_wait`, which do not read the guard. Once one is caught, it
--- closes its handles, ending their children, and calls `g:release()`
--- -- not `g:close()`, which delivers the signal again and so ends this
--- process -- before it prints its report and exits non-zero, as the
--- `supervisor` example in [`cosmic/child_example.tl`] does
--- (`cosmic docs Child.wait_any` shows it).
---
--- A child owns a new process group by default, and its Handle owns
--- that group: once a wait, a timeout, or a close has an answer, no
--- process of the group is left. Anything still running when the
--- child exits is sent SIGTERM, then SIGKILL, and on Linux this
--- process becomes a child subreaper the first time it starts a
--- group, so a descendant orphaned by the child's exit is reparented
--- here and reaped here too, even on a host whose PID 1 never reaps.
--- A descendant that leaves the group (`setsid`) leaves supervision
--- with it. Start a child with `process_group = false` for one meant
--- to outlive the call that started it. A child started with a
--- `sandbox` that unveils, or one the test runner confines, starts a
--- session, and so a group, of its own whatever `process_group` says, in
--- a pid namespace of its own that ends when it does: nothing it starts
--- outlives it there.
---
--- A child started with a [`cosmic.sandbox`] policy (`policy`) is held to
--- nothing but what the policy grants -- paths, system calls, environment,
--- resources -- or does not start.
---
--- Standard streams are inherited unless redirected: to a caller-owned
--- descriptor, to "null", or to "capture", which collects the stream in
--- memory -- the last `capture_limit` bytes of it -- into the Result.
--- `input` feeds bytes to stdin. Every captured stream and the input
--- are serviced by one `poll` loop while waiting, so neither side can
--- stall the other on a full pipe, and several handles can be waited on
--- together with [`Child.wait_any`]. Completion is the child's exit, never
--- end of file: a descendant that escaped the group and still holds a
--- captured pipe cannot hold up a wait.
---
--- In a task of [`Poll.run`], every wait here -- a handle's, a stream's,
--- [`Child.run`]'s, [`Child.wait_any`]'s, [`Child.end_strays`]'s -- waits
--- through the run, and the other tasks run meanwhile; elsewhere it
--- holds the thread. A child's exit wakes a wait once the kernel says
--- it has exited, where the platform gives a descriptor for that (a
--- pidfd on Linux, a kqueue on Darwin) -- a moment after the child's
--- last act, which its teardown and a busy host's scheduling lengthen
--- -- and is looked for every 10 ms elsewhere. A wait whose task is cancelled
--- answers nil (or false) and [`Poll.CANCELLED`], as [`cosmic.net`]'s
--- do, and leaves the child running, for its handle to end. Ending a
--- child in a cancelled task -- [`Child.run`]'s, a close, a timeout --
--- waits through the run all the same ([`Poll.shielded`]) until it is
--- done: a second or so for each child that ignores SIGTERM, most of it
--- waiting for its group to empty.
---
--- A stream redirected to "stream" is the caller's to read or write
--- while the child runs, through the handle's `stdout_stream`,
--- `stderr_stream` (each a [`cosmic.stream`] Reader) or `stdin_stream` (a
--- Writer). While one of them waits, it services the child's other
--- streams too, so reading stdout cannot stall on a child blocked
--- writing a full stderr, nor writing stdin on one blocked writing a
--- full stdout: what arrives on a streamed output meanwhile waits in
--- memory, up to `capture_limit` unread bytes of each, after which the
--- child is left to wait until the caller reads. Nothing streamed is
--- dropped, and nothing is kept for the Result.
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Address = require("cosmic.relay_address")
local RelayConfig = require("cosmic.relay_config")
local Rules = require("cosmic.sandbox")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local Stream = require("cosmic.stream")
local Clock = require("cosmic.clock")

local isatty = sys.isatty
-- What holds a child by a policy on macOS, taken as this module loads.
local Seatbelt = Rules.Seatbelt
local SandboxRelay = Rules.Relay

-- The calls that start, feed and reap a child, and hold this process's
-- signals while it does, live in the raw process table, under the
-- reserved `cosmic.internal.` namespace -- see cosmic/store.tl for
-- why this indirection exists. It is off the public surface so that
-- nothing but a handle reaps a child a handle owns: in an adopting
-- process `collect` reaps every child with `waitpid(-1)`, and a
-- public one would take a status from under it.
local type raw_process = require("cosmic.internal.process")

local handed: any = select(2, ...)
local raw: raw_process
if type(handed) == "table" then
  raw = handed as raw_process
else
  raw = require("cosmic.internal.process")
end

local record Result
  --- The child's exit status, or nil when a signal ended it.
  code: integer | nil
  --- The number of the signal that ended the child, or nil when it
  --- exited by itself.
  signal: integer | nil
  --- Whether the child exited with status 0 and was not ended for
  --- running past its timeout.
  ok: boolean
  --- Whether the child ran past a timeout -- its own
  --- [`Options.timeout_ns`], or [`Handle.wait`]'s -- and was ended for it.
  timed_out: boolean
  --- Captured stdout, when stdout was "capture".
  stdout: string | nil
  --- Captured stderr, when stderr was "capture".
  stderr: string | nil
  --- Every captured stream by the child's descriptor number, stdout and
  --- stderr included.
  captured: {integer:string}
  --- Whether any captured stream lost its beginning to `capture_limit`.
  truncated: boolean
end

--- The paths a sandbox gives a child ([`Sandbox.unveil`]), each
--- absolute; at most 256 in all.
local record Unveil
  --- The files and directories the child has, read-only.
  reads: {string}
  --- The ones it has to change too.
  writes: {string}
  --- For a path of `reads` or `writes`, by that path as given, the
  --- absolute name it is bound at in the child's root instead of its
  --- own: not /, and no link to it is made there. Nil for none.
  at: {string:string}
end

--- What a child, and every process it starts, is held to from its exec
--- on: Linux, where unprivileged user namespaces are allowed. Elsewhere,
--- or where the kernel refuses one, the start fails, with no fallback.
local record Sandbox
  --- What alone of the filesystem the child has: a root of its own
  --- holding these paths, each at the name it resolves to or the one
  --- `at` gives it, a /proc of its own pid namespace where /proc is
  --- given and the kernel allows one, and a /tmp of its own unless one
  --- is given -- and nothing else. The child is pid 2 of a pid namespace
  --- of its own, whose init ends when it does, ending whatever it left
  --- running there; and it leads a session, and so a process group, of
  --- its own whatever `process_group` says.
  unveil: Unveil
  --- With `unveil`, fresh writable scratch at /noexec, mounted noexec:
  --- files there cannot execute, including through aliases. Reading,
  --- interpreting or copying their bytes elsewhere is still allowed.
  --- No unveiled path or alias may occupy / or /noexec or beneath it.
  --- This option does not change ordinary /tmp policy. Unsupported
  --- creation fails.
  noexec_scratch: boolean
  --- A network namespace of its own, with nothing but a loopback.
  offline: boolean
  --- With `unveil` and `group`, the user the child runs as in place of
  --- this process's root, as an unprivileged caller's child runs, and
  --- so confines one of its own at any depth: this process must hold
  --- CAP_SETUID, CAP_SETGID and CAP_SETFCAP where it and `group` are
  --- mapped, and the start fails EPERM where it does not. Nil runs the
  --- child as this process's own user. Not 0.
  user: integer
  --- The group the child runs as with `user`, which each needs the
  --- other, with no supplementary group. Not 0.
  group: integer
end

--- Where a child's stdin comes from, beside a descriptor number.
local enum Stdin
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- A pipe the caller writes through the handle's `stdin_stream`.
  "stream"
end

--- Where a child's stdout goes, beside a descriptor number.
local enum Stdout
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- Memory, the last `capture_limit` bytes of it, for the Result.
  "capture"
  --- A pipe the caller reads through the handle's `stdout_stream`.
  "stream"
end

--- Where a child's stderr goes, beside a descriptor number.
local enum Stderr
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- Memory, for the Result, as stdout's.
  "capture"
  --- A pipe the caller reads through the handle's `stderr_stream`.
  "stream"
  --- Stdout's destination, capture or stream included.
  "stdout"
end

--- Where the network relay's decision lines go ([`Options.relay_log`]).
local enum RelayLog
  --- Nowhere.
  "null"
  --- This process's standard error.
  "inherit"
end

--- An ordinary-filesystem Linux launch under both nonzero IDs. All
--- real, effective and saved IDs are set, supplementary groups and
--- effective/permitted/inheritable/ambient capabilities are cleared,
--- and no_new_privs prevents privileged exec from restoring privilege.
--- The capability bounding set stays unchanged. Inherited cwd and
--- descriptors remain grants; an explicit cwd is checked after the
--- transition. Unsupported platforms fail before starting a child.
local record Credentials
  --- The user ID, from 1 through 4294967294.
  user: integer
  --- The group ID, from 1 through 4294967294.
  group: integer
end

local record Options
  --- The child's whole environment, by name: it replaces this process's
  --- rather than adding to it. Nil inherits this process's.
  env: {string:string}
  --- The directory the child starts in; nil for this process's own
  --- directory. An empty one raises.
  cwd: string
  --- A descriptor, or "inherit" (the default), "null" or "stream", whose
  --- Writer is the handle's `stdin_stream`. A pipe to stdin, this one
  --- or `input`'s, makes this process ignore SIGPIPE from then on, so a
  --- write to a child that has gone fails with EPIPE instead of ending
  --- it.
  stdin: integer | Stdin
  --- Bytes fed to the child's stdin, which is then closed. Excludes a
  --- `stdin` of its own.
  input: string
  --- A descriptor, or "inherit" (the default), "null", "capture" or
  --- "stream", which the handle's `stdout_stream` reads.
  stdout: integer | Stdout
  --- A descriptor, or "inherit" (the default), "null", "capture",
  --- "stream" (read by the handle's `stderr_stream`) or "stdout", which
  --- shares stdout's destination, capture or stream included.
  stderr: integer | Stderr
  --- More descriptors the child gets, by the number it sees them as
  --- (3 to 255): a descriptor of this process, or "capture". Every other
  --- descriptor above 2 is closed in the child.
  fds: {integer:integer | string}
  --- How many bytes of each captured stream are kept, the newest ones,
  --- and how many unread bytes of each streamed one are held before the
  --- child is left to wait for the caller to read; 16 MiB by default.
  capture_limit: integer
  --- Whether the child leads a new process group that its handle owns
  --- and ends with it; true by default. False for a child meant to
  --- outlive the call that started it.
  process_group: boolean
  --- How long the child may run, from its start, before it is ended as an
  --- expired [`Handle.wait`] ends it -- SIGTERM, a grace period, then
  --- SIGKILL, its group included -- its Result `timed_out`. Nil for no
  --- limit, not 0, which ends it at the first wait on it. [`Child.run`]'s
  --- wait ends the child at it. A started child is ended for it by
  --- whatever waits on it once it has passed: its handle's `wait` (with a
  --- timeout of its own or not), [`try_wait`], [`Child.wait_any`], or a
  --- read or write of its streams. A child that exited by itself before
  --- that is not `timed_out`. Nothing ends it while nothing waits on it,
  --- as no thread runs here but the caller's: it runs past the deadline
  --- until something waits, or its handle closes. [`Handle.drain`], which
  --- ends no process, does not end it either: a loop over it asks
  --- [`try_wait`] to have the deadline kept.
  timeout_ns: integer
  --- What the child is held to (see [`Sandbox`]); nil for nothing.
  sandbox: Sandbox
  --- A [`cosmic.sandbox`] policy the child is held to, met or the start
  --- fails (nil, and a message naming what is missing and how to give it).
  --- The policy is merged ([`Sandbox.merge`], which resolves its
  --- `profiles`), and then:
  ---
  --- - `grants` are the only paths the child reaches, by Landlock (by the
  ---   root alone under the `nest` promise), a relative one from `cwd`; the child's program, found on this
  ---   process's PATH when its name has no slash, and the interpreter it
  ---   names (`#!`, or an ELF's), need `r` and `x` grants: the "system"
  ---   profile gives them for the host's own programs.
  --- - `isolate` "file" runs the child in a root of its own holding only
  ---   the granted paths, each bound at its name (anything else is
  ---   ENOENT, not EACCES), read-only unless granted `w` or `c`, and a
  ---   writable one noexec unless granted `x`; a grant's `from` is the
  ---   host's path, bound at the grant's `path`, which only this has (a
  ---   `from` without it fails). The program's own file, its loader and
  ---   its directory (`cwd`, or this process's) must be granted, and it is
  ---   run by its real path. Beside them the root has a /proc of its own
  ---   (see `proc`), the links /dev/fd and /dev/stdin, /dev/stdout and
  ---   /dev/stderr into it, and, with `tmp`, a /tmp that is a tmpfs of 256
  ---   MiB, noexec unless a grant of "/tmp" with no `from` has the letters
  ---   `rwxc`, `TMPDIR` naming it (or a `set_env` TMPDIR beneath /tmp,
  ---   which the program makes), gone with the sandbox. Landlock
  ---   holds the same grants from inside, with the root's own /proc and
  ---   /tmp added to it; it cannot list the root's directories above a
  ---   grant. A `u` grant is held by Landlock ABI 9 where there is one;
  ---   below it, by the root alone, which can then hold no other socket:
  ---   the start fails beside a grant of a directory, or of a socket not
  ---   granted `u`. Under `file` /dev holds only what is granted (the
  ---   "system" profile grants /dev/null, zero, urandom and random), besides
  ---   the /dev/fd links.
  --- - `isolate` "proc" (which "file" implies) is a pid namespace and a /proc
  ---   of the sandbox's own, read-only, showing its processes alone: the
  ---   child is pid 2 beneath an init, and with "proc" alone it has the
  ---   host's filesystem otherwise, held by its grants. Where the kernel
  ---   refuses a procfs of its own (a container that masks /proc, as
  ---   Docker's does without --security-opt systempaths=unconfined) the
  ---   start fails, naming that option: there is no fallback to the host's
  ---   /proc. Every isolation needs unprivileged user namespaces; where
  ---   refused, the failure names the sysctl or AppArmor setting.
  --- - `loopback` and `u` grants give the child a network namespace of its
  ---   own with its loopback up, so it reaches no host network, nor a
  ---   service on the host's 127.0.0.1. `loopback` declares the addresses
  ---   of 127/8 it uses there, all of which are its own: it may make AF_INET
  ---   and AF_INET6 sockets, and bind and connect on them; AF_UNIX
  ---   sockets only with a `u` grant. With neither, every inet socket is
  ---   refused.
  --- - `promises` are the system calls it may make beyond its basics
  ---   (a seccomp filter). `nest` lets the program build a sandbox of its
  ---   own: it needs `isolate` "file", and it gives up Landlock, which the
  ---   kernel's refusal of a mount to a process it holds would make
  ---   useless, so the program's files are held by the root alone:
  ---   - A grant is a bind, read-only unless granted `w` or `c`, and noexec
  ---     unless granted `x`, so a program that can mount can unshare and
  ---     remount nothing wider: the mounts it copies into a user namespace
  ---     of its own are locked (read-only, noexec, nosuid and nodev stay),
  ---     and in the sandbox's own user namespace it has no capability to
  ---     mount at all.
  ---   - What Landlock told apart and a bind cannot is refused at the
  ---     start, naming the letters to add: `w` without `c` on a directory
  ---     (a writable bind lets it make and remove files, too), `c` without
  ---     `w`, and `x` without `r` (a bind that can be run can be read). A
  ---     read-only grant without `x` is mounted noexec as well, so a file
  ---     of it is neither run nor mapped executable.
  ---   - A `u` grant is held by the root alone, as below Landlock ABI 9: no
  ---     grant may be a directory, nor a socket but one granted `u`; the
  ---     sandbox's own `tmp` is none.
  ---   - Without a `u` grant, the program may make a unix socket where the
  ---     root shows no directory of the host and no socket file (`tmp`'s
  ---     own is the program's to make sockets in), in a network
  ---     namespace of its own (`loopback`): from Landlock ABI 9 whatever
  ---     it shows, since Landlock refuses a socket file no `u` grant names.
  ---     Under `nest`, which gives Landlock up, only where the root shows no
  ---     directory and no socket file, at any ABI.
  ---   - Held as ever: the pid and IPC namespaces, the network namespace
  ---     (with `loopback` or `u`), which the program may make others of but
  ---     not leave (the filter refuses setns), the socket families, signals
  ---     (to any pid, which reaches only the sandbox's own, the pid
  ---     namespace holding them) and every other rule of the filter.
  ---   - A descriptor handed in (`fds`, and 0 to 2) is refused where it is
  ---     a directory, or a regular file not open for reading and writing:
  ---     /proc/self/fd/N would open what is beneath and above the one, or
  ---     reopen the other for what it was not opened for, which Landlock
  ---     stopped. Pipes, sockets and devices are handed as ever.
  ---   - Not held: Landlock's scoping (ABI 6) of abstract unix sockets; the
  ---     size of a tmpfs the program mounts itself, which counts as its
  ---     memory does, not as `tmp`'s; and a procfs it mounts in a pid
  ---     namespace of its own, which shows what the host's /proc shows a
  ---     user (cpuinfo, meminfo, version, the sysctls it may read; writes
  ---     are refused), where the sandbox's own /proc shows its processes alone.
  --- - `env` names the variables passed through from this process's
  ---   environment and `set_env` the ones set: the child's whole
  ---   environment, so `env` beside `policy` raises. `tmp` makes a fresh
  ---   directory the child may write, `TMPDIR` naming it (over a
  ---   variable of the policy's), removed after the child is settled; under
  ---   `isolate` file, the sandbox's own /tmp instead.
  --- - `limits` are rlimits on every process of the child: 1024 open
  ---   files unless `open_files` says, and no core dump; `file_bytes` and
  ---   `cpu_seconds` as given. `processes` (RLIMIT_NPROC) holds the
  ---   whole sandbox: the kernel counts the processes and threads of the
  ---   user namespace the program runs in, so the program itself is
  ---   counted and, depending on whose user namespace each is in, so may
  ---   be the sandbox's init; one past it fails with EAGAIN. It needs
  ---   `isolate` "proc" or "file", whose user namespace is the sandbox's
  ---   own, and a kernel from Linux 5.17 (an older one counts every process
  ---   of the user the namespace was made by); a limit above this
  ---   process's own hard RLIMIT_NPROC fails too. Under `isolate`, with
  ---   none given, it is 4096, where the kernel counts so and this
  ---   process's hard limit allows.
  --- - `fds` names the only descriptors above 2 the child gets, as it
  ---   always has.
  --- - `connect` gives the child a network namespace of its own, with
  ---   its loopback up and inet sockets, whose only way out is the network
  ---   relay this start runs (cosmic/relay_serve.tl): a process of this
  ---   program's core on a database sealed for it, held by a pid namespace
  ---   and the files its resolver reads, which makes no socket of its own.
  ---   It reaches the network only through the native connectors this
  ---   process starts and hands it ([`cosmic.sandbox.relay`]): a few whose
  ---   table holds the addresses a target names literally (at most 128, with
  ---   the upstream proxy's: a policy with more fails to start, saying so),
  ---   and, where a target names a host the relay reaches directly, one that
  ---   reaches the system's name servers alone, over TCP, and a few that
  ---   connect to the public addresses a name resolves to. The program reaches it at 127.0.0.1 ports 3128
  ---   (HTTP CONNECT) and 1080 (SOCKS5), which the child's environment names:
  ---   `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` (in both cases),
  ---   `NODE_USE_ENV_PROXY=1` and a `NO_PROXY` of `localhost`, 127.0.0.1, ::1
  ---   and the policy's `loopback`, which a proxy-aware client dials in its
  ---   own network, never through the relay: a `connect` target that is one
  ---   of those hosts (a service of the host's own loopback, granted
  ---   literally) is reached only by a client that sends it to the relay
  ---   itself (an HTTP CONNECT or SOCKS5 request to 127.0.0.1:3128 or :1080).
  ---   A policy with `connect` that names
  ---   any of them in `env` or `set_env` is refused. The relay connects a
  ---   request only where a `connect` target names its host and port,
  ---   resolves a name itself only then, and refuses an address of the host
  ---   or a private, loopback or metadata one unless a target names that
  ---   address literally ([`cosmic.relay`]). It reaches the network through
  ---   this process's `https_proxy`, and its `no_proxy`, where they are set:
  ---   the proxy's host is resolved once, as the start runs, and a host that
  ---   does not resolve fails the start. It lives as long
  ---   as the child's handle does: it is ended with the child, and a relay
  ---   that dies first ends the child (SIGKILL, at its next wait). A relay that
  ---   will not start fails the start, naming why, and ends the child. The
  ---   relay's decision lines go where `relay_log` says. It needs this
  ---   program to carry [`cosmic.relay_serve`] and [`cosmic.sandbox.relay`]
  ---   and to be a cosmic core, which
  ---   the start says where it is not. Linux only: macOS refuses `connect`.
  ---
  --- A program that is this program's own file ([`Proc.executable`]),
  --- which the policy grants `rx` (the "cosmic" profile does), runs as its
  --- core by a relaunch ([`Proc.relaunch`]), granted with it: its launcher
  --- would fork and unpack a core into a cache the policy does not give
  --- it. Where this process is root, the child's user runs a copy of the
  --- core that every user may run, made once in /run/cosmic-sandbox-cores,
  --- root's alone. The relaunch's descriptors are two more `fds` the child
  --- gets; one `fds` names is refused, as is the `nest` promise (a core on a
  --- `database` below has no descriptor, and takes it).
  ---
  --- With a `database` (see [`Sandbox.Policy`]) the program is this
  --- program's core run on that file (`core --database <path>`) whatever
  --- the policy grants of this program: the command must be this program
  --- ([`Proc.executable`]) and this process a cosmic core, not a host
  --- program, or the start fails. The child is granted its core to read
  --- and run and the database to read, and no more of this program: a
  --- grant that reaches this program's own file (the "cosmic" profile's
  --- among them, left out of a merge with a `database`) fails the start,
  --- since that file holds the modules the database leaves out. The
  --- child's [`Proc.relaunch`] is that same core and database, and so are
  --- its own children's. With `nest` the core and the database are read-only
  --- binds of the child's root, which the kernel locks once the child makes
  --- a user namespace of its own, and it has no descriptor of either: it
  --- starts children of its own on that database and cannot write either
  --- file. A process started on a core with `--database` and no policy
  --- `database` takes `nest` the same way, its database bound from its own
  --- start.
  ---
  --- A child never runs as root. Where this process is not root, it runs
  --- as this process's user, mapped as itself in its user namespace.
  --- Where this process is root, it runs as a user and group of its own,
  --- one id from the top of what this process's user namespace maps
  --- ([`Sandbox.user_id`], 4294963198 to 4294967293 on a host), chosen by
  --- the pid and a count of the sandboxes this process has started, so
  --- concurrent sandboxes differ -- or the policy's `user` and `group`,
  --- the same every start, which may own the files it works on (a caller
  --- that is not root may name only itself) -- which needs CAP_SETUID, CAP_SETGID and
  --- CAP_SETFCAP (the start fails, saying so, where it lacks them). A
  --- policy that makes a namespace (`isolate`, `loopback`, a `u` grant)
  --- maps that user into a user namespace from outside; one that makes
  --- none gives root up for it directly, as `credentials` does, and so
  --- has the host's /proc and pid namespace, as an unprivileged caller's
  --- child with no `isolate` has, and starts where a container masks
  --- /proc. A pool's user is
  --- none of the owners of the host's files, and a named one is the owner
  --- of its own and in its group's (in no other group): a grant it cannot
  --- use by the file's mode -- one not open to it, as another user's
  --- directory made 0700 is not -- fails the start naming it; under `isolate`
  --- "file" the grant is mounted idmapped instead, where the kernel
  --- (Linux 5.12) and the file system (ext4, xfs, btrfs, tmpfs) allow and
  --- this process holds CAP_SYS_ADMIN, so that user is the file's owner
  --- there, with the owner's rights, and what it creates is the owner's
  --- on the host; only the files of the grant's own owner are its, so
  --- those of other users beneath stay out of its reach. Without
  --- `isolate` "file" every directory above a grant, and the one the child
  --- starts in (`cwd`, else this process's), and the TMPDIR a `tmp` makes
  --- its directory in, must also be searchable by everyone. The check reads the
  --- grant's own mode; an access control list or what is beneath a
  --- directory is not read. A policy whose `stdio` is a terminal is not
  --- refused.
  ---
  --- On macOS the child is held by Seatbelt instead ([`Seatbelt.compile`]),
  --- by a process of this program that applies the profile to itself and
  --- then executes the child's program, so a profile the system refuses
  --- fails the start, with its text, and nothing runs unconfined. It holds
  --- `grants` (a relative one from `cwd`, which must exist, and the child's
  --- program needs `rx` -- the "system" profile gives the host's own),
  --- `promises` `fork`, `jit` and `fattr`, `env`, `set_env` and `limits`
  --- but `processes`. It fails, saying so, for what Seatbelt cannot hold --
  --- `isolate`, `connect`, `loopback`, `nest`, a grant's `from`,
  --- `limits.processes`. This program, and any program on a `database`,
  --- runs as its core, as under Landlock: the core is granted `rx` and the
  --- database `r` (it is opened read-only and immutable); `tmp` is a
  --- directory made for the start and granted `rwc`. The child leads
  --- a session of its own, with no controlling terminal unless it is started
  --- by [`Child.start_on_pty`] with stdin on the pty, so `process_group`
  --- false is refused there. A start from a
  --- process Seatbelt already holds fails closed, as its profile is refused
  --- there, and nothing runs.
  ---
  --- Not with `sandbox`, whose root of its own it does not build. Where
  --- the platform has neither Landlock and seccomp nor Seatbelt the start
  --- fails. Nothing is printed about grants.
  policy: Rules.Policy
  --- The IDs and privilege limits for this launch. Excludes `policy` and
  --- sandbox unveil, offline, user and group. Child setup errors precede exec;
  --- a parent dumpability restoration error can follow exec and ends
  --- the owned child before reporting failure.
  credentials: Credentials
  --- With a `policy` whose `connect` the relay serves, where the relay's
  --- decision lines go, one for each connection it refused or made: "null"
  --- (the default), which drops them, "inherit", this process's standard
  --- error, or a descriptor of this process (the write end of a pipe a
  --- caller reads, as the verb's terminal relay does), which the caller
  --- keeps open and closes. A terminal is refused as any child's standard
  --- error is, so "inherit" with a terminal on this process's standard
  --- error fails the start. A policy with no `connect` starts no relay, and
  --- this has no effect.
  relay_log: RelayLog | integer
end

--- What [`Handle.try_wait`] answers.
local record TryWait
  --- Whether the child has exited.
  finished: boolean
  --- Its outcome, once `finished`.
  result: Result
end

-- TODO: hand the caller Stream.from_fd over a streamed output's pipe, and
-- delete `streamed`, `head`, `tail` and [`pipe_reader`], once it is
-- decided that a read of one output may stall the child on another: the
-- queue is what lets a wait on one stream service the rest, up to
-- `capture_limit` unread bytes each, so that reading stdout does not
-- stall on a full stderr, nor writing stdin on a full stdout
-- (child_lua_test's test_reading_stdout_does_not_stall_on_a_full_stderr
-- and test_writing_stdin_does_not_stall_on_a_full_stdout); a Stream.from_fd
-- over the bare pipe leaves the pipe's own buffer to hold them.
--- One captured or streamed output of one child.
local record Pipe
  fd: integer
  child_fd: integer
  chunks: {string}
  size: integer
  truncated: boolean
  --- A stream the caller reads, not one kept for the Result: `chunks`
  --- is then a queue, read from `head` and written at `tail`, and
  --- `size` is how much of it is unread.
  streamed: boolean
  --- The first terminal read or raw poll failure, after any queued bytes.
  failure: string
  head: integer
  tail: integer
  --- The Reader ended this pipe, explicitly or after an escaped writer.
  reader_closed: boolean
  consuming: boolean
end

--- Bounds and borrowed destinations for [`Handle.drain`].
local record DrainOptions
  --- Required finite wait budget, in nanoseconds; 0 makes one nonblocking round.
  timeout_ns: integer
  --- Required positive total byte budget across both outputs.
  max_bytes: integer
  --- Required exactly when stdout was started as "stream"; never closed here.
  stdout: Stream.Writer | nil
  --- Required exactly when stderr was started as "stream"; never closed here.
  stderr: Stream.Writer | nil
end

--- Why a bounded output drain stopped.
local enum DrainKind
  "eof"
  "limit"
  "timeout"
  "interrupted"
  "failed"
end

--- The outcome of [`Handle.drain`], independent of the child's exit status.
local record DrainResult
  --- The stopping condition; an interrupted guard signal remains untaken.
  kind: DrainKind
  --- Source bytes offered to sinks, including a final failed write; never replayed.
  bytes: integer
  --- Empty except for interrupted or failed, which name the original cause.
  reason: string
end

local record Handle
  metamethod __close: function(Handle)
  --- The child's process id.
  pid: integer
  --- Whether the child leads a process group of its own that this
  --- handle owns ([`Options.process_group`]).
  process_group: boolean
  --- Readers of stdout and stderr, when each was "stream". Each reads
  --- until the child's end of the pipe closes, or until the child has
  --- exited and nothing more is waiting: a descendant that escaped the
  --- group still holding it cannot hold a read up. A wait leaves them
  --- to read on; `close` ends them once what is queued is read. While
  --- the innermost open guard has caught a signal, a read or a write
  --- fails with "child: cancelled by signal N", as a wait does. A read
  --- or a write that waits past the child's own [`Options.timeout_ns`]
  --- ends the child as an expired `wait` would: a read then reads what
  --- it left, and a write fails. A read or raw poll failure follows the
  --- bytes already queued, then remains the reader's failure on later
  --- reads.
  stdout_stream: Stream.Reader | nil
  --- See `stdout_stream`.
  stderr_stream: Stream.Reader | nil
  --- A Writer to stdin, when it was "stream": [`Stream.to_fd`] over the
  --- pipe, so a write goes out whole and a failure is sticky; its `close`
  --- (or `abort`) closes the child's stdin, so the child reads end of
  --- file. A write fails once the child has closed its stdin, or has
  --- exited and nothing else holds it, and after a wait. A write the
  --- child does not read waits for it, however long: a child that stops
  --- reading until its streamed stdout is read, which sits unread at
  --- `capture_limit`, waits forever -- read the outputs as the input
  --- goes in, or bound the child with a timeout.
  stdin_stream: Stream.Writer | nil
  _feed_fd: integer | nil
  --- A descriptor readable once the child has exited (`exit_watch`),
  --- until its status is claimed; -1 where there is none, so that
  --- setting it makes no new field, which could fail to allocate with
  --- the descriptor in hand.
  _exit_fd: integer
  _result: Result
  _status: raw_process.ChildStatus
  _closed: boolean
  _explicit_close: boolean
  _drain_next: integer
  _streams: {Pipe}
  _input_fd: integer | nil
  _input: string
  _input_at: integer
  _limit: integer
  --- When the child's own `timeout_ns` passes, on the monotonic clock;
  --- nil for none ([`Options.timeout_ns`]).
  _deadline: integer | nil
  --- The temporary directory a policy's `tmp` made for the child, removed
  --- once the child is settled; nil for none.
  _tmp: string | nil
  --- The network relay that serves a policy's `connect`, a child of its
  --- own, which a settle ends (the relay's standard input closes, and it
  --- is ended should it outlive that); nil for none, and once it is ended.
  _relay: Handle
  --- Whether the relay was found dead while the child ran, which ended
  --- the child for want of its way out.
  _relay_gone: boolean
  --- Of a relay's own handle, the connectors its starter handed it, ended
  --- with it; nil for any other handle.
  _handover: RelayConfig.Handover
  --- Waits for the child to exit and answers its Result. With
  --- `timeout_ns`, or once the child's own [`Options.timeout_ns`]
  --- passes, whichever is first, a child still running is ended --
  --- SIGTERM, a grace period, then SIGKILL, its group included -- and
  --- the Result says `timed_out`; [`Child.wait_any`]'s timeout instead
  --- leaves every child running. While a [`Child.guard`] is open, a
  --- SIGINT or SIGTERM it catches ends the wait, timed or not, the same
  --- way: a child that has not exited is ended and the wait answers nil
  --- and "child: cancelled by signal N"; the guard keeps the signal, and a
  --- later wait answers the ended child's Result. In a task of
  --- [`Poll.run`] that is cancelled, it answers nil and
  --- [`Poll.CANCELLED`], and leaves the child running. A `timeout_ns`
  --- below 0 or past [`Poll.MOST_NS`] raises.
  wait: function(Handle, timeout_ns?: integer): Result | nil, string
  --- Fairly copies streamed outputs to borrowed Writers within both required
  --- bounds. EOF requires closed pipes, including escaped writers. A previous
  --- guard cancellation may be bypassed only after its signal was taken; a
  --- fresh signal interrupts without being consumed. Ordinary Reader failures
  --- remain sticky. No process is ended, reaped to completion, or timed out,
  --- past the child's own [`Options.timeout_ns`] or not.
  --- Concurrent reads/drains raise. Sink failure may have written a prefix;
  --- it ends the selected read ends, and the caller still owns child cleanup.
  --- The deadline bounds pipe waits, not arbitrary code in a Writer. A zero
  --- timeout pumps once without waiting and writes at most one chunk per pipe.
  drain: function(Handle, DrainOptions): DrainResult
  --- Whether the child has exited, without waiting: `finished` is false
  --- while it runs, and true with its `result` once it has exited and its
  --- group is cleared, as `wait` would answer. It services the child's
  --- captured and streamed outputs and input meanwhile. Once the child's
  --- own [`Options.timeout_ns`] has passed, a child still running is
  --- ended as an expired `wait` ends it, which waits for it to go, and
  --- `finished` is true, its Result `timed_out`. Nil and why when
  --- settling the child fails.
  try_wait: function(Handle): TryWait | nil, string
  --- Sends `signal` (SIGTERM by default) to the child, or to its whole
  --- group when `process_group` is true. It does not wait. False and why when the child
  --- has been reaped already or the signal cannot be sent.
  stop: function(Handle, signal?: integer): boolean, string
  --- Ends the child if it is still running, as an expired `wait` does,
  --- reaps it and closes its stdin stream, and ends its streamed outputs so
  --- their readers read what is queued and stop. Closing a settled
  --- handle only ends the streamed outputs. False and why when the
  --- child or its group cannot be ended.
  close: function(Handle): boolean, string
end

--- How often a wait looks for what no descriptor tells it of: the exit
--- of a child with no `_exit_fd` (a Linux before pidfd_open, a filter
--- refusing it), a group's last member gone.
local POLL_NS <const> = Clock.ms(10)
--- How often a wait of an adopting process wakes, at the least, to reap
--- the orphans it adopted, which no descriptor announces: often enough
--- that a long wait leaves none a zombie for long.
local REAP_NS <const> = Clock.seconds(1)
local TERM_GRACE_NS <const> = Clock.ms(250)
local KILL_REAP_NS <const> = Clock.seconds(1)
--- How long a network relay is given to end once its standard input has
--- closed, before it is ended.
local RELAY_STOP_NS <const> = Clock.seconds(1)
--- One millisecond, which [`sys.poll`] counts its waits in.
local MS <const> = Clock.ms(1)
local INT_MAX <const> = 2147483647
local CHUNK <const> = 65536
local DEFAULT_CAPTURE_LIMIT <const> = 16 * 1024 * 1024

--- SIGINT and SIGTERM held for this process while children are
--- supervised; see [`Child.guard`].
local record Guard
  metamethod __close: function(Guard)
  --- The stamp the guard last read: a signal moves it.
  _read: integer
  --- The signal delivered last, 0 until one is.
  _signal: integer
  --- The signal delivered last since the last take, 0 when none was.
  _fresh: integer
  _closed: boolean
  --- Why the dispositions could not be restored, "" when they were.
  _trouble: string
  --- The last SIGINT or SIGTERM caught, or 0 until one is. It is kept
  --- after the guard closes.
  cancelled: function(Guard): integer
  --- The last signal caught since the previous take, or 0, and clears
  --- it: the way to pass each signal on to a child.
  take: function(Guard): integer
  --- Closes the guard. The last guard open to close restores the
  --- dispositions the process had and delivers the last signal caught
  --- again; another leaves it to the guards still open. False and why
  --- when they cannot be restored, and again on every later close.
  close: function(Guard): boolean, string
  --- Closes the guard as `close` does, but keeps the last signal caught
  --- instead of delivering it, and answers that signal, or 0. Nil and
  --- why when the dispositions cannot be restored.
  release: function(Guard): integer | nil, string
  --- In a task of [`Poll.run`], waits for a signal to take, and takes
  --- it; 0 and why once `timeout_ns` passes or the task is cancelled
  --- first, or the guard is closed.
  wait: function(Guard, timeout_ns?: integer): integer, string
end

--- The open guards, the innermost last.
local open_guards: {Guard} = {}

--- The innermost open guard, if any: the one a wait reads.
local active: Guard | nil

--- The stamp of the latest signal a guard caught and then closed on
--- while another stayed open, 0 when none: the last guard to close
--- delivers it, where that guard opened after it and so never saw it.
local owed = 0

--- What a failure of this module's own, no system call's, answers: nil
--- and `why` under the module's name. A system call's message is
--- passed on as it is, or after the step it failed in.
local function refuse(why: string): nil, string
  return nil, "child: " .. why
end

--- The message a wait or a run cancelled by `signal` answers.
local function cancelled_by(signal: integer): string
  return "child: cancelled by signal " .. tostring(signal)
end

--- Every pid a handle owns until the handle has settled it. Pids, not
--- handles, so a dropped handle still reaches its finalizer.
local owned: {integer:boolean} = {}

--- Exit statuses an adopting process collected for an owned pid before
--- its handle asked; the handle takes its own out.
local reaped: {integer:raw_process.ChildStatus} = {}

--- Whether this process adopts orphaned descendants: nil until the
--- first grouped start asks.
local adopting: boolean

local function now(): integer
  return Clock.monotonic_ns()
end

--- Whether a wait on `handles` is woken by each one's exit: every one
--- not yet reaped has an `_exit_fd`.
local function exits_seen(handles: {Handle}): boolean
  for _, h in ipairs(handles) do
    if h._status == nil and h._exit_fd < 0 then return false end
    -- A relay's exit ends its child's wait too.
    local relay = h._relay
    if relay ~= nil and relay._status == nil and relay._exit_fd < 0 then return false end
  end
  return true
end

--- How long the next [`pump`] of `handles` may wait, in nanoseconds, -1
--- for no limit: until `deadline` where each one's exit wakes the wait,
--- but no longer than REAP_NS in an adopting process, and POLL_NS where
--- an exit must be looked for; less as `deadline` nears, and nil once it
--- has passed. A signal needs no bound: a wait that it ends watches the
--- guards' wake pipe while a guard is open. One that began with none
--- open is not ended by a guard another task of the run opens after:
--- a wait reads the guards open as it waits, and a guard opened
--- meanwhile guards the waits that come after it.
local function slice(deadline: integer, handles: {Handle}): integer
  local most = POLL_NS
  if exits_seen(handles) then most = adopting and REAP_NS or -1 end
  if deadline == nil then return most end
  local remaining = deadline - now()
  if remaining <= 0 then return nil end
  if most < 0 then return math.min(remaining, Poll.MOST_NS) end
  return math.min(most, remaining)
end

local function target(self: Handle): integer
  return self.process_group and -self.pid or self.pid
end

--- The earlier of `deadline` (nil for none) and the child's own, which
--- counts only while it is unsettled.
local function sooner(deadline: integer, self: Handle): integer
  local own = self._deadline
  if own == nil or self._status ~= nil or (deadline ~= nil and deadline <= own) then
    return deadline
  end
  return own
end

--- Whether the child's own deadline has passed while it is unsettled:
--- a wait that finds it so ends the child.
local function overdue(self: Handle): boolean
  return self._deadline ~= nil and self._status == nil and now() >= self._deadline
end

--- In an adopting process, reaps every child that has exited: an owned
--- pid's status is filed for its handle, and an adopted orphan is simply
--- gone. A process that does not adopt reaps only by pid, handle by
--- handle, and never touches a child it does not own.
local function collect()
  if not adopting then return end
  while true do
    local status, _ = raw.waitpid(-1, true)
    if status == nil or status.pid == 0 then return end
    if owned[status.pid] then reaped[status.pid] = status end
  end
end

--- Closes the handle's exit watch, once it has no more to say.
local function unwatch(self: Handle)
  local watch = self._exit_fd
  if watch >= 0 then
    self._exit_fd = -1
    -- Another task may be waiting on it, for this child among others.
    Poll.closing(watch)
    local _, _ = sys.close(watch)
  end
end

--- Files a status with its handle.
local function claim(self: Handle, status: raw_process.ChildStatus): raw_process.ChildStatus
  self._status = status
  reaped[self.pid] = nil
  owned[self.pid] = nil
  unwatch(self)
  return status
end

--- Ends the child of `self` where its relay has died, the child's one way
--- out: SIGKILL to it and its group, once. Defined below [`exited`], which
--- every look at a child goes through.
local relay_lost: function(Handle)

--- This handle's child's exit status, once it has one. With `block`,
--- waits for it.
local function exited(self: Handle, block?: boolean): raw_process.ChildStatus | nil, string
  if self._status then return self._status, "" end
  if self._relay ~= nil then relay_lost(self) end
  collect()
  if reaped[self.pid] then return claim(self, reaped[self.pid]), "" end
  local status, trouble = raw.waitpid(self.pid, not block)
  if not status then
    -- A pid that cannot be waited for (ECHILD: reaped past this module)
    -- has a watch readable for good, which would end every wait at once.
    unwatch(self)
    return nil, trouble
  end
  if status.pid == 0 then return nil, "" end
  return claim(self, status), ""
end

local function close_fd(fd: integer)
  if fd ~= nil then
    Poll.closing(fd)
    local _, _ = sys.close(fd)
  end
end

--- Appends one chunk to a stream, dropping its oldest bytes past the
--- limit. Chunks are joined only when the kept size doubles, so a long
--- stream costs amortized linear time.
local function keep(self: Handle, stream: Pipe, data: string)
  if stream.streamed then
    stream.tail = stream.tail + 1
    stream.chunks[stream.tail] = data
    stream.size = stream.size + #data
    return
  end
  stream.chunks[#stream.chunks + 1] = data
  stream.size = stream.size + #data
  if stream.size > 2 * self._limit then
    local whole = table.concat(stream.chunks)
    stream.chunks = { whole:sub(-self._limit) }
    stream.size = self._limit
    stream.truncated = true
  end
end

local function text_of(self: Handle, stream: Pipe): string
  local whole = table.concat(stream.chunks)
  if #whole > self._limit then
    stream.truncated = true
    return whole:sub(-self._limit)
  end
  return whole
end

local function end_stream(stream: Pipe)
  if stream.fd ~= nil then
    close_fd(stream.fd)
    stream.fd = nil
  end
end

--- Keep a source failure apart from a Reader's sticky cancellation:
--- another operation can discover it while that Reader stays cancelled.
local function fail_stream(stream: Pipe, trouble: string)
  if stream.streamed and stream.failure == nil then stream.failure = trouble end
  end_stream(stream)
end

local function end_input(self: Handle)
  close_fd(self._input_fd)
  self._input_fd = nil
end

--- Empties the wake pipe, which is readable while any byte a signal
--- wrote there is left.
local function drain_wake()
  local fd = raw.child_signal_fd()
  while true do
    local bytes, _ = sys.read(fd, 512)
    if bytes == nil or #bytes < 512 then return end
  end
end

--- Whether a wait here goes through [`Poll.run`]: in one of its tasks,
--- where the task can yield -- not in a finalizer, say, which a handle's
--- `__gc` runs in, and which waits on its own.
local function through_run(): boolean
  return Poll.in_task() and coroutine.isyieldable()
end

--- What the descriptor a [`pump`] waits on is for.
local enum Kind
  --- A captured or streamed output, to read.
  "output"
  --- The bytes of `input`, to write.
  "input"
  --- Room in the stdin stream, which its writer, waiting on it, uses.
  "feed"
  --- The child's exit, which the caller reaps.
  "exit"
  --- A signal a guard caught, to drain.
  "wake"
end

--- One descriptor a [`pump`] waits on.
local record Entry
  fd: integer
  events: integer
  --- The child it belongs to; nil for a "wake".
  owner: Handle
  kind: Kind
  --- The output an "output" reads.
  output: Pipe
end

--- What a [`pump`] does about an [`Entry`] of one kind.
local record Service
  --- Whether the entry is still its own: in a run, another task may
  --- have ended what this waited on meanwhile ([`Poll.closing`]), and
  --- its number be another file's.
  live: function(Entry): boolean
  --- Services it, once its descriptor has an event.
  ready: function(Entry)
  --- Gives up on it, once the wait found a descriptor gone bad: it
  --- cannot be serviced, so it is ended rather than spun on.
  broken: function(Entry, string)
end

local function nothing(_: Entry, _trouble?: string) end

local services: {Kind:Service} = {
  output = {
    live = function(e: Entry): boolean return e.output.fd == e.fd end,
    ready = function(e: Entry)
      local stream = e.output
      -- A streamed output takes no more than its limit leaves room for.
      local want = CHUNK
      if stream.streamed and e.owner._limit - stream.size < want then
        want = e.owner._limit - stream.size
      end
      local data, trouble, errno = sys.read(stream.fd, want)
      if data == nil then
        if errno ~= sys.EAGAIN and errno ~= sys.EINTR then fail_stream(stream, trouble) end
      elseif data == "" then
        end_stream(stream)
      else
        keep(e.owner, stream, data)
      end
    end,
    broken = function(e: Entry, trouble: string) fail_stream(e.output, trouble) end,
  },
  input = {
    live = function(e: Entry): boolean return e.owner._input_fd == e.fd end,
    ready = function(e: Entry)
      local h = e.owner
      local offset = h._input_at
      local written, _, errno = sys.write(h._input_fd, h._input:sub(offset + 1, offset + CHUNK))
      if written ~= nil then
        h._input_at = offset + written
        if h._input_at >= #h._input then end_input(h) end
      elseif errno ~= sys.EAGAIN and errno ~= sys.EINTR then
        -- EPIPE included: a child that stopped reading has said so.
        end_input(h)
      end
    end,
    broken = function(e: Entry, _trouble: string) end_input(e.owner) end,
  },
  feed = {
    live = function(e: Entry): boolean return e.owner._feed_fd == e.fd end,
    ready = nothing,
    broken = nothing,
  },
  exit = {
    live = function(e: Entry): boolean return e.owner._exit_fd == e.fd end,
    ready = nothing,
    broken = nothing,
  },
  wake = {
    live = function(e: Entry): boolean return raw.child_signal_fd() == e.fd end,
    ready = drain_wake,
    broken = nothing,
  },
}

--- What a [`pump`] of `handles` waits on: each one's open outputs, not
--- a streamed one holding `_limit` unread bytes, its pending input, and
--- its exit while it is not reaped. With `feeding`, room in that
--- handle's stdin stream too.
local function watching(handles: {Handle}, feeding?: Handle): {Entry}
  local entries: {Entry} = {}
  if feeding ~= nil then
    entries[1] = { fd = feeding._feed_fd, events = sys.POLLOUT, owner = feeding, kind = "feed" }
  end
  for _, h in ipairs(handles) do
    for _, stream in ipairs(h._streams or {}) do
      if stream.fd ~= nil and (not stream.streamed or stream.size < h._limit) then
        entries[#entries + 1] = { fd = stream.fd, events = sys.POLLIN, owner = h,
          kind = "output", output = stream }
      end
    end
    if h._input_fd ~= nil then
      entries[#entries + 1] = { fd = h._input_fd, events = sys.POLLOUT, owner = h, kind = "input" }
    end
    if h._status == nil and h._exit_fd >= 0 then
      entries[#entries + 1] = { fd = h._exit_fd, events = sys.POLLIN, owner = h, kind = "exit" }
    end
    local relay = h._relay
    if relay ~= nil and relay._status == nil and relay._exit_fd >= 0 then
      entries[#entries + 1] = { fd = relay._exit_fd, events = sys.POLLIN, owner = relay, kind = "exit" }
    end
  end
  return entries
end

--- Services `entries` once: waits up to `timeout_ns` (-1 for no limit)
--- for any of them to be ready, then reads what is there and writes what
--- fits. Returns whether anything moved. A "feed" is waited on only to
--- end the wait; its writer does the writing. With `signalled`, a
--- signal an open guard catches ends the wait too, the guards' wake
--- pipe drained for the caller to read the guard.
---
--- In a task of [`Poll.run`], the wait goes through the run, the other
--- tasks running meanwhile. Once the task is cancelled, a `cancellable`
--- pump answers false and [`Poll.CANCELLED`] at once; any other waits
--- shielded from the cancel ([`Poll.shielded`]), as the cleanup it
--- serves -- ending a child, emptying its pipes -- must finish.
local function pump(entries: {Entry}, timeout_ns: integer,
                    cancellable?: boolean, signalled?: boolean): boolean, string
  -- TODO: wait through Poll.delay and Poll.ready alone, here and in
  -- Child.end_strays's sleep, once it is decided how they answer where
  -- no task can wait. (a) They go on, holding the thread, outside a run
  -- and in the `<close>` handler of a task being killed, as Poll.wait
  -- does outside a run: this module's cleanup, which must wait there,
  -- loses its thread-held branches, and poll_test's
  -- test_waiting_outside_a_task_raises and
  -- test_kill_raises_what_a_close_handler_raises and net_serve_test's
  -- test_a_killed_protocols_close_cannot_wait, which hold those waits
  -- to raising, break with it. (b) They stay task-only, and the
  -- branches here stay.
  -- A wait that yields never, as one with no time to wait does, is
  -- no wait of the run's: it looks and goes on.
  local in_run = timeout_ns ~= 0 and through_run()
  -- Drained only by a wait of the run's, or with no task about: a wait
  -- holding the thread in a task, draining it, would take the wake from
  -- a task waiting on it (`g:wait`) before the run could tell it.
  if signalled and active ~= nil and (in_run or not Poll.in_task()) then
    entries[#entries + 1] = { fd = raw.child_signal_fd(), events = sys.POLLIN, kind = "wake" }
  end
  local fds: {integer} = {}
  local events: {integer} = {}
  for i, e in ipairs(entries) do fds[i], events[i] = e.fd, e.events end
  if #fds == 0 then
    -- Nothing here could end a wait with no limit: it waits a slice.
    if timeout_ns < 0 then timeout_ns = POLL_NS end
    if in_run then
      local paused, cancelled: boolean, string
      local function pause()
        paused, cancelled = Poll.delay(timeout_ns)
      end
      if cancellable then pause() else Poll.shielded(pause) end
      if paused then return false, "" end
      return false, cancelled
    end
    if timeout_ns > 0 then local _, _ = sys.nanosleep(timeout_ns) end
    return false, ""
  end
  local revents: {integer}
  local trouble = ""
  if in_run then
    local answers, why: {integer}, string
    local function look()
      answers, why = Poll.ready(fds, events, timeout_ns >= 0 and timeout_ns or nil)
    end
    if cancellable then look() else Poll.shielded(look) end
    -- A wait that ran out of time found nothing: no stream moved.
    if answers == nil and why == Poll.TIMEOUT then return false, "" end
    if answers == nil then return false, why end
    revents = answers
  else
    -- Rounded up: a wait with time left polls for at least a millisecond.
    local polled, why = sys.poll(fds, events, timeout_ns >= 0 and Clock.ceil(timeout_ns, MS) or -1)
    revents, trouble = polled, why
  end
  if revents == nil then
    for _, e in ipairs(entries) do
      local service = services[e.kind]
      if service.live(e) then service.broken(e, trouble) end
    end
    return true, ""
  end
  local moved = false
  for i, happened in ipairs(revents) do
    local e = entries[i]
    local service = services[e.kind]
    if happened ~= 0 and service.live(e) then
      moved = true
      service.ready(e)
    end
  end
  return moved, ""
end

--- Waits for a group to have no members left, collecting whatever this
--- process adopted from it meanwhile. False when it did not empty.
local function group_gone(self: Handle, until_ns: integer): boolean
  while true do
    local alive, _, errno = sys.kill(-self.pid, 0)
    if not alive and errno == sys.ESRCH then return true end
    if now() >= until_ns then return false end
    collect()
    local _, _ = pump(watching({ self }), POLL_NS)
  end
end

--- Removes the temporary directory a policy's `tmp` made for the child.
--- [`Fs.remove_tree`] walks by descriptor and follows no link, which
--- matters here: a process of the child's that outlived it (one with the
--- `fork` promise that left its group) may swap a subdirectory for a link
--- to a host directory while the walk runs, and a walk by path would
--- delete through it.
-- TODO: report a removal that failed -- a directory the child made
-- unreadable (its `fattr` promise lets it chmod), or one a surviving
-- descendant keeps filling -- on the Result or the Handle, once Result
-- carries a field beside the exit status for what a settle left behind
-- (see the TODO at Child.wait_any); until then the tree is left behind and
-- nothing says so.
local function remove_tmp(self: Handle)
  local dir = self._tmp
  if dir == nil then return end
  self._tmp = nil
  local _, _ = Fs.remove_tree(dir)
end

relay_lost = function(self: Handle)
  local relay = self._relay
  if relay == nil or self._relay_gone then return end
  local status, _ = exited(relay)
  if status == nil then return end
  self._relay_gone = true
  -- TODO: say why on the Result, once it carries a field beside the exit
  -- status for what a settle left behind (see the TODO at Child.wait_any):
  -- today a program whose relay died is a SIGKILL like any other.
  -- TODO: end the program the moment its relay dies, not at the next wait
  -- on it, once a handle has a task of its own to watch the relay's exit.
  local _, _ = sys.kill(target(self), sys.SIGKILL)
end

--- Ends the relay of `self` once its program is gone: its standard input
--- closes, which it takes as the end, and it is ended in a second should it
--- outlive that.
local function end_relay(self: Handle)
  local relay = self._relay
  self._relay = nil
  if relay ~= nil then
    local feed = relay.stdin_stream
    if feed ~= nil then local _, _ = feed:close() end
    local _, _ = relay:wait(RELAY_STOP_NS)
    local _, _ = relay:close()
    if relay._handover ~= nil then relay._handover.close() end
  end
end

--- Ends what is left of the child and settles it, answering its Result.
--- A child still running is sent SIGTERM -- its group's too -- and
--- SIGKILL once TERM_GRACE_NS has passed, and its Result says
--- `timed_out`; what its group has left after the leader is gone is
--- ended the same way. What its pipes still hold is then drained, and
--- every descriptor of its own is closed. Nil and why when the child
--- cannot be signalled, does not exit after SIGKILL, or leaves its group
--- members after it: the Result is kept for a later call all the same.
---
--- Its waits go through the run in a task, shielded, for a cleanup does
--- not end with its task's cancel. In a `<close>` handler of a task
--- being killed, or a finalizer, no wait can yield, and they hold the
--- thread in [`sys.poll`]: the cleanup there must finish too.
local function end_child(self: Handle): Result | nil, string
  if self._result ~= nil then return self._result, "" end
  local status, trouble = exited(self)
  if status == nil and trouble ~= "" then return nil, trouble end
  local timed_out, killed = status == nil, false
  if timed_out then
    local sent, why = sys.kill(target(self), sys.SIGTERM)
    if not sent then
      -- The child may have exited between the last look and this signal.
      local gone, _ = exited(self)
      if gone == nil then return nil, why end
    end
    local deadline = now() + TERM_GRACE_NS
    while true do
      local gone, gone_trouble = exited(self)
      if gone ~= nil then break end
      if gone_trouble ~= "" then return nil, gone_trouble end
      local left = slice(deadline, { self })
      if left ~= nil then
        local _, _ = pump(watching({ self }), left)
      elseif killed then
        return refuse("the child was not reaped after SIGKILL")
      else
        -- Only a child that ignored TERM gets here; the group's
        -- stragglers, if the leader honored it, are ended below.
        local _, _ = sys.kill(target(self), sys.SIGKILL)
        killed, deadline = true, now() + KILL_REAP_NS
      end
    end
  end
  local cleared = true
  if self.process_group then
    local alive, _, errno = sys.kill(-self.pid, 0)
    cleared = not alive and errno == sys.ESRCH
    if not cleared and not killed then
      local _, _ = sys.kill(-self.pid, sys.SIGTERM)
      cleared = group_gone(self, now() + TERM_GRACE_NS)
    end
    if not cleared then
      local _, _ = sys.kill(-self.pid, sys.SIGKILL)
      cleared = group_gone(self, now() + KILL_REAP_NS)
    end
  end
  -- The program's way out is of no use once its group is gone.
  end_relay(self)
  -- Clearing the group waits, through the run in a task, where another
  -- task may settle this handle meanwhile: its Result is the one.
  if self._result ~= nil then return self._result, "" end
  local final = self._status
  local r: Result = {
    ok = final.code == 0 and not timed_out,
    timed_out = timed_out,
    captured = {},
    truncated = false,
  }
  if final.code >= 0 then r.code = final.code end
  if final.signal >= 0 then r.signal = final.signal end
  end_input(self)
  close_fd(self._feed_fd)
  self._feed_fd = nil
  if self._streams then
    -- Anything still buffered in a pipe is there for the taking now;
    -- a writer that escaped the group can keep it open, so stop at the
    -- first round that finds nothing rather than wait for end of file.
    -- A streamed output is left open, and no fuller than its limit: its
    -- reader reads on from the pipe, and ends it (see [`pipe_reader`]).
    while true do
      local moved, _ = pump(watching({ self }), 0)
      if not moved then break end
    end
    for _, stream in ipairs(self._streams) do
      if not stream.streamed then
        end_stream(stream)
        r.captured[stream.child_fd] = text_of(self, stream)
        if stream.truncated then r.truncated = true end
      end
    end
    r.stdout = r.captured[1]
    r.stderr = r.captured[2]
  end
  self._result, self._closed = r, true
  remove_tmp(self)
  if not cleared then
    return refuse("process group " .. tostring(self.pid) .. " still has members after SIGKILL")
  end
  return r, ""
end

local closed_reader <const> = "child: the reader is closed"
local closed_writer <const> = "child: the writer is closed"
local EXITED <const> = "child: the child has exited"

--- Why a stream's wait should stop now, beyond its own data: the open
--- guard caught a signal, or the child could not be asked about.
local function interrupted(self: Handle): string
  if active ~= nil then
    local cancelled = active:cancelled()
    if cancelled ~= 0 then return cancelled_by(cancelled) end
  end
  local _, trouble = exited(self)
  return trouble
end

--- One read or drain owns its queues even while a sink or pipe wait yields.
local record Consumption
  pipes: {Pipe}
  discard: boolean
  reason: string
  metamethod __close: function(Consumption)
end

local consumption_mt: metatable<Consumption> = {
  __close = function(self: Consumption)
    for _, pipe in ipairs(self.pipes) do
      if self.discard then
        if pipe.failure == nil then pipe.failure = self.reason end
        end_stream(pipe)
        pipe.chunks, pipe.head, pipe.tail, pipe.size = {}, 1, 0, 0
      end
      pipe.consuming = false
    end
  end,
}

local function consume(pipes: {Pipe}): Consumption
  for _, pipe in ipairs(pipes) do
    if pipe.consuming then error("child: output is already being consumed", 3) end
  end
  local owner: Consumption = setmetatable({ pipes = pipes, discard = false,
    reason = "child: output sink did not complete" }, consumption_mt)
  for _, pipe in ipairs(pipes) do pipe.consuming = true end
  return owner
end

--- Takes only the queued prefix requested, shared by Reader and drain.
local function take_chunk(pipe: Pipe, want: integer): string
  local chunk = pipe.chunks[pipe.head]
  if #chunk <= want then
    pipe.chunks[pipe.head] = nil
    pipe.head = pipe.head + 1
    pipe.size = pipe.size - #chunk
    return chunk
  end
  pipe.chunks[pipe.head] = chunk:sub(want + 1)
  pipe.size = pipe.size - want
  return chunk:sub(1, want)
end

-- How an object of this module is made. A handle, a guard and the Reader
-- and Writer of a streamed pipe are each one table, whose methods live
-- once on a record's own table, reached through `__index`, with the state
-- in fields: no closure each. A Reader or a Writer is a record of its own
-- ([`PipeReader`], [`FeedWriter`]) implementing the interface it answers. A
-- handle and a guard are public records themselves, whose fields the
-- docs list, so their methods are assigned (`Handle.wait = function(self:
-- Handle, ...)`) to the fields the record declares, with the docs on
-- them: `function Handle:wait` would be listed as an undocumented
-- function beside the documented field. The note on how an object is made
-- in cosmic/stream.tl says why Teal limits how that is written.

--- The Reader of a child's streamed output: it takes what `pump` queued,
--- pumping every stream of the child while it waits.
local record PipeReader is Stream.Reader
  child: Handle
  pipe: Pipe
  closed: boolean
  --- Why a wait the child could not go on with ended, "" until one has:
  --- every later read answers it.
  failed: string
  --- Holds the pipe while a read waits; one per Reader, so a read costs no
  --- allocation.
  owner: Consumption
  read: function(PipeReader, max_bytes?: integer): string | nil, string
  close: function(PipeReader): boolean, string
end

local pipe_reader_mt: metatable<PipeReader> = { __index = PipeReader }

local function waiting_read(self: PipeReader, max_bytes?: integer): string | nil, string
  local child, pipe = self.child, self.pipe
  local _ownership <close> = self.owner
  pipe.consuming = true
  while pipe.size == 0 do
    if pipe.failure ~= nil then
      self.failed = pipe.failure
      return nil, self.failed
    end
    if pipe.fd == nil then return nil, "" end
    local why = interrupted(child)
    if why ~= "" then
      self.failed = why
      return nil, why
    end
    if child._status ~= nil then
      -- The child is gone: what it wrote is in the pipe already, and
      -- a round that finds nothing ready means only an escaped
      -- descendant holds it open, which this read does not wait for.
      local _, _ = pump(watching({ child }), 0)
      if pipe.size == 0 and pipe.fd ~= nil then
        pipe.reader_closed = true
        end_stream(pipe)
      end
    elseif overdue(child) then
      -- Ended as a wait would end it; its pipe is read on from there.
      local ended, trouble = end_child(child)
      if ended == nil and child._status == nil then
        self.failed = trouble
        return nil, trouble
      end
    else
      local left = slice(sooner(nil, child), { child })
      if left ~= nil then
        local _, cancelled = pump(watching({ child }), left, true, true)
        -- Not kept as `failed`: the task's end, not the stream's.
        if cancelled ~= "" then return nil, cancelled end
      end
    end
  end
  return take_chunk(pipe, max_bytes or CHUNK), ""
end

function PipeReader:read(max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and max_bytes < 1 then
    error("child: read's max_bytes must be positive", 2)
  end
  local pipe = self.pipe
  if pipe.consuming then error("child: output is already being consumed", 2) end
  if self.failed ~= "" then return nil, self.failed end
  if self.closed then return nil, closed_reader end
  if pipe.size ~= 0 then return take_chunk(pipe, max_bytes or CHUNK), "" end
  return waiting_read(self, max_bytes)
end

function PipeReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  local pipe = self.pipe
  pipe.reader_closed = true
  -- The child's next write to it fails, as it would into `head`.
  end_stream(pipe)
  pipe.chunks, pipe.head, pipe.tail, pipe.size = {}, 1, 0, 0
  return true, ""
end

--- The Reader of `self`'s streamed output at `index`.
local function pipe_reader(self: Handle, index: integer): Stream.Reader
  local pipe = self._streams[index]
  local owner: Consumption = setmetatable({ pipes = { pipe }, discard = false }, consumption_mt)
  local r: PipeReader = setmetatable(
    { child = self, pipe = pipe, closed = false, failed = "", owner = owner }, pipe_reader_mt)
  return r
end

--- The Writer of a child's stdin stream: [`Stream.to_fd`] over the pipe,
--- whose waits for room pump the child's outputs meanwhile, so a child
--- that waits for its output to be read does not stall the write.
local record FeedWriter is Stream.Writer
  child: Handle
  --- The pipe's descriptor as this Writer was made with, to tell it
  --- from the one the handle holds once it has been closed.
  fd: integer
  closed: boolean
  into: Stream.Writer
  write: function(FeedWriter, data: string): boolean, string
  close: function(FeedWriter): boolean, string
  abort: function(FeedWriter): boolean, string
end

local feed_writer_mt: metatable<FeedWriter> = { __index = FeedWriter }

function FeedWriter:write(data: string): boolean, string
  if self.closed then return false, closed_writer end
  -- Only a settled child's stdin is closed from under its writer.
  if self.child._feed_fd ~= self.fd then return false, EXITED end
  return self.into:write(data)
end

function FeedWriter:close(): boolean, string
  self.closed = true
  local child, fd = self.child, self.fd
  if child._feed_fd == nil then return true, "" end
  child._feed_fd = nil
  Poll.closing(fd)
  local ok, trouble = sys.close(fd)
  if not ok then return false, trouble end
  return true, ""
end

function FeedWriter:abort(): boolean, string
  return self:close()
end

local function feed_writer(self: Handle): Stream.Writer
  local fd = self._feed_fd
  local w: FeedWriter = setmetatable({ child = self, fd = fd, closed = false }, feed_writer_mt)
  -- A closure, for [`Stream.FdOptions.wait`] is called with no Writer.
  local function room(_fd: integer, _events: integer, _left: integer | nil): boolean, string
    local why = interrupted(self)
    if why == "" and overdue(self) then
      local _, trouble = end_child(self)
      why = trouble
    end
    if why == "" and self._status ~= nil then why = EXITED end
    if why ~= "" then return false, why end
    local left = slice(sooner(nil, self), { self })
    if left ~= nil then
      local _, cancelled = pump(watching({ self }, self), left, true, true)
      if cancelled ~= "" then return false, cancelled end
    end
    -- Another task may have closed it meanwhile, by this writer's
    -- close or a settle, and its number be another file's by now.
    if self._feed_fd ~= fd then return false, w.closed and closed_writer or EXITED end
    return true, ""
  end
  w.into = Stream.to_fd(fd, { nonblocking = true, wait = room })
  return w
end

--- Closes every streamed output a settle left open for its reader,
--- which then reads what is queued and ends.
local function end_streamed(self: Handle)
  if not self._streams then return end
  for _, stream in ipairs(self._streams) do
    if stream.streamed then end_stream(stream) end
  end
end

--- [`end_child`], with a net under it: whatever raises in the ending (an
--- allocation refused, a wait that fails) must still leave no process
--- behind, so a raise is answered by SIGKILL to the child, its group
--- included, and a reap that holds the thread and cannot wait through
--- anything that raised. The Result is left for a later `close` or
--- collection to settle; the failure is answered as the reason.
local function end_or_kill(self: Handle): Result | nil, string
  local ok, r, why = pcall(end_child, self)
  if ok then
    if r == nil then return nil, why end
    return r, ""
  end
  local _, _ = sys.kill(target(self), sys.SIGKILL)
  for _ = 1, 100 do
    local status, _ = exited(self)
    if status ~= nil then break end
    local _, _ = sys.nanosleep(POLL_NS)
  end
  return nil, tostring(r)
end

local function drain(self: Handle, opts: DrainOptions): DrainResult
  if type(opts) ~= "table" or math.type(opts.timeout_ns) ~= "integer" or
      math.type(opts.max_bytes) ~= "integer" or opts.max_bytes < 1 then
    error("child: drain requires integer timeout_ns and positive max_bytes", 3)
  end
  Poll.checked_ns(opts.timeout_ns, "child", "timeout_ns", 3)
  local timeout_ns, max_bytes = opts.timeout_ns, opts.max_bytes
  local pipes: {Pipe} = {}
  local sinks: {Stream.Writer} = {}
  local stdout, stderr = false, false
  for _, pipe in ipairs(self._streams or {}) do
    if pipe.streamed then
      local sink: Stream.Writer
      if pipe.child_fd == 1 then sink = opts.stdout else sink = opts.stderr end
      if sink == nil then error("child: drain requires a sink for each streamed output", 3) end
      if type(sink.write) ~= "function" then error("child: drain requires Writers", 3) end
      if pipe.child_fd == 1 then stdout = true else stderr = true end
      pipes[#pipes + 1], sinks[#sinks + 1] = pipe, sink
    end
  end
  if #pipes == 0 or (opts.stdout ~= nil and not stdout) or (opts.stderr ~= nil and not stderr) then
    error("child: drain sinks must name streamed outputs", 3)
  end
  local owner <close> = consume(pipes)
  local bytes = 0
  local guard = active
  local stamp: integer
  local deadline = now() + timeout_ns
  local function result(kind: DrainKind, reason?: string): DrainResult
    return { kind = kind, bytes = bytes, reason = reason or "" }
  end
  local function control(): DrainResult | nil
    if self._explicit_close then return result("failed", "child: the handle is closed") end
    for _, pipe in ipairs(pipes) do
      if pipe.reader_closed then return result("failed", closed_reader) end
    end
    if guard ~= nil then
      if guard._closed then return result("failed", "child: the guard is closed") end
      local signal = guard:cancelled()
      if (stamp == nil and guard._fresh ~= 0) or (stamp ~= nil and guard._read ~= stamp) then
        return result("interrupted", cancelled_by(signal))
      end
      if stamp == nil then stamp = guard._read end
    end
    return nil
  end
  local function complete(): DrainResult | nil
    local eof = true
    for _, pipe in ipairs(pipes) do
      if pipe.size == 0 and pipe.failure ~= nil then return result("failed", pipe.failure) end
      if pipe.fd ~= nil or pipe.size ~= 0 then eof = false end
    end
    if eof then return result("eof") end
    if bytes == max_bytes then return result("limit") end
    return nil
  end
  local stopped = control() or complete()
  if stopped ~= nil then return stopped end
  if timeout_ns == 0 then
    local _, _ = pump(watching({ self }), 0, true, guard ~= nil)
  end
  while true do
    stopped = control() or complete()
    if stopped ~= nil then return stopped end
    if timeout_ns ~= 0 and now() >= deadline then return result("timeout") end
    local moved = false
    local first = self._drain_next or 1
    for offset = 0, #pipes - 1 do
      local index = (first + offset - 1) % #pipes + 1
      stopped = control() or complete()
      if stopped ~= nil then return stopped end
      if timeout_ns ~= 0 and now() >= deadline then return result("timeout") end
      local pipe = pipes[index]
      if pipe.size ~= 0 then
        local chunk = take_chunk(pipe, math.min(CHUNK, max_bytes - bytes))
        bytes = bytes + #chunk
        self._drain_next = index % #pipes + 1
        owner.discard = true
        local ok, why = sinks[index]:write(chunk)
        if not ok then
          owner.reason = why
          return result("failed", why)
        end
        owner.discard = false
        moved = true
      end
    end
    stopped = control() or complete()
    if stopped ~= nil then return stopped end
    if timeout_ns == 0 then return result("timeout") end
    if not moved then
      local _, why = exited(self)
      if why ~= "" then return result("failed", why) end
      local left = slice(deadline, { self })
      if left == nil then return result("timeout") end
      local _, cancelled = pump(watching({ self }), left, true, guard ~= nil)
      stopped = control()
      if stopped ~= nil then return stopped end
      if cancelled ~= "" then return result("failed", cancelled) end
    end
  end
end

--- An explicit close ends a drain even while group cleanup is waiting.
local function closing_outputs(self: Handle)
  self._explicit_close = true
  for _, pipe in ipairs(self._streams or {}) do
    if pipe.streamed and pipe.fd ~= nil then Poll.closing(pipe.fd) end
  end
end

Handle.try_wait = function(self: Handle): TryWait | nil, string
  if self._result then return { finished = true, result = self._result }, "" end
  local _, _ = pump(watching({ self }), 0)
  local status, trouble = exited(self)
  if status == nil then
    if trouble ~= "" then return nil, trouble end
    if not overdue(self) then return { finished = false }, "" end
  end
  local r, settle_trouble = end_child(self)
  if r == nil then return nil, settle_trouble end
  return { finished = true, result = r }, ""
end

Handle.stop = function(self: Handle, signal?: integer): boolean, string
  if self._closed then return false, "child: process already reaped" end
  local ok, trouble = sys.kill(target(self), signal or sys.SIGTERM)
  if not ok then return false, trouble end
  return true, ""
end

Handle.wait = function(self: Handle, timeout_ns?: integer): Result | nil, string
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  if self._result then return self._result, "" end
  if timeout_ns == nil and self._deadline == nil and active == nil and not self._streams and
      not self._input_fd and self._relay == nil and not through_run() then
    local status, trouble = exited(self, true)
    if not status then return nil, trouble end
    return end_child(self)
  end
  local deadline: integer
  if timeout_ns ~= nil then deadline = now() + timeout_ns end
  deadline = sooner(deadline, self)
  -- Services the child's pipes until it exits, `deadline` passes ("")
  -- or the wait cannot go on: a signal the innermost open guard
  -- caught, a task cancelled, a child that cannot be asked about.
  local why = ""
  while true do
    local status, trouble = exited(self)
    if status ~= nil then return end_child(self) end
    why = trouble
    if why ~= "" then break end
    if active ~= nil and active:cancelled() ~= 0 then
      why = cancelled_by(active:cancelled())
      break
    end
    local left = slice(deadline, { self })
    if left == nil then break end
    local _, stopped = pump(watching({ self }), left, true, true)
    if stopped ~= "" then
      why = stopped
      break
    end
  end
  local cancelled = active ~= nil and active:cancelled() or 0
  if cancelled ~= 0 then
    -- A wait the guard's signal ended leaves no child running. The
    -- signal may have landed after the deadline, so say so here.
    if why == "" then why = cancelled_by(cancelled) end
    local _, ended_trouble = end_child(self)
    if ended_trouble ~= "" then
      -- `why` names the module already.
      return nil, why .. "; " .. (ended_trouble:gsub("^child: ", ""))
    end
    return nil, why
  end
  if why ~= "" then return nil, why end
  return end_child(self)
end

Handle.close = function(self: Handle): boolean, string
  closing_outputs(self)
  if not self._closed then
    local r, trouble = end_child(self)
    if not r then return false, trouble end
  end
  end_streamed(self)
  return true, ""
end

Handle.drain = drain

local handle_mt: metatable<Handle> = {
  __index = Handle,
  __close = function(self: Handle)
    closing_outputs(self)
    if not self._closed then local _, _ = end_or_kill(self) end
    end_streamed(self)
  end,
  __gc = function(self: Handle)
    closing_outputs(self)
    if not self._closed then local _, _ = end_or_kill(self) end
    end_streamed(self)
  end,
}

--- A handle for `pid`, owning it until it settles.
local function make_handle(pid: integer, process_group: boolean, limit: integer,
                           deadline: integer | nil): Handle
  local h: Handle = setmetatable({
    pid = pid, process_group = process_group, _closed = false, _exit_fd = -1, _limit = limit,
    _explicit_close = false, _drain_next = 1, _deadline = deadline, _relay_gone = false,
  }, handle_mt)
  -- Owned only once it has its metatable, so the finalizer covers the child from then; a
  -- failure between the two leaves an unowned child with a finalizer, which waitpid still reaps.
  owned[pid] = true
  return h
end

--- Takes `stamp`, a stamp the core answered, as what `g` has read: a
--- stamp that moved since the last is a signal caught, for both what
--- `cancelled` and what `take` answer.
local function noted(g: Guard, stamp: integer)
  if stamp ~= g._read then
    local signal = stamp % raw.SIGNAL_STAMP_UNIT
    g._signal, g._fresh, g._read = signal, signal, stamp
  end
end

local function read_guard(self: Guard)
  if self._closed then return end
  noted(self, raw.child_signal_read(self == active))
end

Guard.cancelled = function(self: Guard): integer
  read_guard(self)
  return self._signal
end

Guard.take = function(self: Guard): integer
  read_guard(self)
  local signal = self._fresh
  self._fresh = 0
  return signal
end

Guard.wait = function(self: Guard, timeout_ns?: integer): integer, string
  if not Poll.in_task() then error("child: g:wait waits in a task of Poll.run", 2) end
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  local deadline: integer
  if timeout_ns ~= nil then deadline = now() + timeout_ns end
  while true do
    -- Asked before each wait and after each wake, never from the
    -- pipe's bytes: another task waiting on it may have drained it.
    local signal = self:take()
    if signal ~= 0 then return signal, "" end
    if self._closed then return 0, "child: the guard is closed" end
    local left: integer
    if deadline ~= nil then left = math.max(deadline - now(), 0) end
    local woken, why = Poll.readable(raw.child_signal_fd(), left)
    if not woken then return 0, why end
    -- The last close wakes this wait having closed the pipe.
    if not self._closed then drain_wake() end
  end
end

--- Closes the guard in the core, once: the last open restores the
--- caller's dispositions. Answers "" or why they could not be
--- restored, kept for every later close or release to answer again;
--- whether this was the last; and, for the last, the signal owed it.
local function restore_guard(self: Guard): string, boolean, integer
  self._closed = true
  for i = #open_guards, 1, -1 do
    if open_guards[i] == self then
      table.remove(open_guards, i)
      break
    end
  end
  active = open_guards[#open_guards]
  local last = active == nil
  local owing = 0
  if last then owing, owed = owed % raw.SIGNAL_STAMP_UNIT, 0 end
  local fd = raw.child_signal_fd()
  local stamp, trouble = raw.unguard_child_signals(active ~= nil and active._read or 0)
  -- Every task waiting on the pipe looks again: one waiting on this
  -- guard finds it closed and returns, and one waiting on a guard
  -- still open finds its stamp unmoved and waits again.
  Poll.closing(fd)
  if stamp == nil then
    self._trouble = trouble
    return trouble, last, owing
  end
  noted(self, stamp)
  return "", last, owing
end

Guard.close = function(self: Guard): boolean, string
  if self._closed then
    if self._trouble ~= "" then return false, self._trouble end
    return true, ""
  end
  local trouble, last, owing = restore_guard(self)
  if trouble ~= "" then return false, trouble end
  if not last then
    -- The caller's dispositions are not back yet: the guards still
    -- open have seen the signal, if they opened before it, and the
    -- last to close delivers it.
    if self._signal ~= 0 and self._read > owed then owed = self._read end
    return true, ""
  end
  local signal = self._signal ~= 0 and self._signal or owing
  if signal ~= 0 then
    -- The caller's own dispositions are back: deliver it as it came.
    local _, _ = sys.kill(sys.getpid(), signal)
  end
  return true, ""
end

Guard.release = function(self: Guard): integer | nil, string
  if self._closed then
    if self._trouble ~= "" then return nil, self._trouble end
    return self._signal, ""
  end
  local trouble, last, owing = restore_guard(self)
  if trouble ~= "" then return nil, trouble end
  if last and self._signal == 0 and owing ~= 0 then
    local _, _ = sys.kill(sys.getpid(), owing)
  end
  return self._signal, ""
end

local guard_mt: metatable<Guard> = {
  __index = Guard,
  __close = function(self: Guard)
    local _, _ = self:close()
  end,
}

--- A guard not yet open: [`opened`] opens it.
local function make_guard(): Guard
  local g: Guard = setmetatable({
    _read = 0, _signal = 0, _fresh = 0, _closed = false, _trouble = "",
  }, guard_mt)
  return g
end

--- Opens a guard, the innermost of those open. The guard is made, and
--- given its place, before the core opens it, so nothing between that
--- and the answer allocates.
local function opened(): Guard | nil, string
  local g = make_guard()
  open_guards[#open_guards + 1] = g
  local stamp, trouble = raw.guard_child_signals()
  if stamp == nil then
    open_guards[#open_guards] = nil
    return nil, trouble
  end
  g._read = stamp
  active = g
  return g, ""
end

--- What [`Child.start_on_pty`] answers.
local record PtyStart
  --- The child, as [`Child.start`] answers it.
  child: Handle
  --- The pty's master, close-on-exec and blocking: the caller's to
  --- read, write and close. Closing it hangs the child's terminal up.
  master: integer
  --- The pty's slave, the caller's to close, when [`PtyOptions.keep_slave`]
  --- asked for it; -1 otherwise.
  slave: integer
end

--- What [`Child.start_on_pty`] is asked for.
local record PtyOptions
  --- Which of the child's standard streams (0 for stdin, 1, 2) are the
  --- pty's terminal, none twice, at least one. A stream named here takes
  --- no `opts` field of its own (`stdin`, `stdout` or `stderr`, and
  --- `input` beside stdin); any other stream is as `opts` says, and a
  --- terminal among those is refused under a `policy` as it is by
  --- [`Child.start`].
  streams: {integer}
  --- Whether the caller is given the slave too, open and close-on-exec, to
  --- close once it has read all the child wrote: macOS drops the output the
  --- master has not read when the last slave descriptor closes, so a child
  --- that writes and exits at once loses it unless the caller holds one.
  keep_slave: boolean
  --- The terminal's size in character cells, set before the child starts,
  --- or nil for the system's default.
  rows: integer
  --- Its width, set with `rows`.
  columns: integer
end

--- A native connector process, as [`Child.start_connector`] starts one.
local record ConnectorProcess
  --- The control stream's descriptor, nonblocking and the object's to
  --- close: a request is eight bytes written to it, a big-endian
  --- 1-based endpoint index and a port, and the reply is read from it:
  --- a big-endian errno, and, on success only, one marker byte with the
  --- connected socket passed beside it. The index 4294967295 (a public
  --- request) follows the eight bytes with a big-endian family (4 or 6)
  --- and 16 address bytes (see the core's `connector_start`). Valid until `close`.
  fd: integer
  --- The connector's process id, which `close` reaps: nil for a stream
  --- adopted with [`Child.adopt_connector`], whose process is its starter's
  --- to end.
  pid: integer | nil
  --- Whether `close` has not been called.
  open: boolean
  --- Ends the connector, which holds no state worth finishing, and reaps
  --- it (an adopted one is only disconnected): true, and true again once closed. A connector dropped unclosed is
  --- ended and reaped when it is collected.
  close: function(ConnectorProcess): boolean
  metamethod __close: function(ConnectorProcess)
end

local end_connector: function(ConnectorProcess, boolean)

local connector_mt: metatable<ConnectorProcess> = {
  __index = ConnectorProcess,
  __close = function(self: ConnectorProcess)
    local _ = self:close()
  end,
  __gc = function(self: ConnectorProcess)
    end_connector(self, true)
  end,
}

local record Child
  type ConnectorProcess = ConnectorProcess
  type ConnectorEndpoint = raw_process.ConnectorEndpoint
  type ConnectorPublic = raw_process.ConnectorPublic
  type Result = Result
  type Options = Options
  type Credentials = Credentials
  type RelayLog = RelayLog
  type Sandbox = Sandbox
  type Unveil = Unveil
  type TryWait = TryWait
  type DrainOptions = DrainOptions
  type DrainKind = DrainKind
  type DrainResult = DrainResult
  type Handle = Handle
  type Guard = Guard
  type PtyStart = PtyStart
  type PtyOptions = PtyOptions
end

--- Holds SIGINT and SIGTERM for this process while it supervises
--- children, so it can end them before it is ended itself. Until the
--- guard closes, either signal is caught rather than acted on:
--- `g:cancelled()` answers the last one delivered, 0 until one is.
--- Only `h:wait` reads the guard -- it ends its child and answers
--- "child: cancelled by signal N" once a signal is caught -- and a stream's
--- read or write, which fails with the same message and leaves the
--- child running; [`Child.wait_any`] and `h:try_wait` do not, so a loop
--- over them asks `g:cancelled()` each round. `g:take()` answers the
--- last signal delivered since the previous take, or 0, and clears it,
--- so a caller that passes signals on to its child passes each one on,
--- a repeat included; signals
--- delivered between two takes answer as the last of them. In a task
--- of [`Poll.run`], `g:wait(timeout_ns)` waits for the next signal to
--- take while the other tasks run, and takes it: the signal, or 0 and
--- why once `timeout_ns` passes, the task is cancelled, or the guard
--- closes. A signal this process ignores stays ignored.
---
--- Guards nest: one opened while another is open -- a [`Child.run`]'s
--- too -- is the innermost until it closes, and the waits (`h:wait`,
--- a stream's, [`cosmic.http`]'s) read the innermost. Each guard sees
--- the signals delivered since it opened, and none before: a guard
--- opened after a signal, to run a child during a shutdown, runs it.
--- What an inner guard sees and takes, the outer ones still see.
---
--- Closing the guard -- `g:close()`, or leaving the scope of a
--- `local g <close> = assert(Child.guard())` -- restores the
--- dispositions the process had and delivers the last signal caught
--- again, so a process that would have died of it dies of it then,
--- its children already ended. Only the last guard to close restores
--- and delivers: one closed while another is open leaves the signal to
--- the guards still open, and the last to close delivers it though it
--- opened after it. `close`
--- answers false and why when the dispositions could not be restored,
--- and again on every later close; the signal is not delivered then.
--- A guard never closed holds the signals for the rest of the
--- process's life: hold it in a `<close>` variable.
--- `g:release()` restores the dispositions as closing does but keeps
--- the last signal caught rather than delivering it, and answers it,
--- or 0: a caller that passed signals on to its child re-raises one
--- only if the child died of it, or never got it. It answers nil and
--- why when the dispositions could not be restored, and again on every
--- later release. A released guard is closed: closing it again, or
--- releasing it again, does nothing, and a release after a close
--- answers the signal the close delivered. The first guard fails, nil
--- and why, where the process has no descriptor left for the pipe
--- `g:wait` waits on. In [`Poll.run`], a wait another task began while no
--- guard was open is not ended by the signals of one opened after it.
function Child.guard(): Guard | nil, string
  return opened()
end

--- Ends `connector` and reaps it. A process this one adopted may already
--- have been reaped (`collect` takes every child), and its pid may be
--- another process's by now: it is signalled only while it is still this
--- one's unreaped child.
end_connector = function(connector: ConnectorProcess, collecting: boolean)
  if not connector.open then return end
  connector.open = false
  -- A task parked on the stream is woken, and the descriptor number is
  -- not read again once another file may hold it. A collector must not
  -- touch the run's state.
  if not collecting then Poll.closing(connector.fd) end
  local _, _ = sys.close(connector.fd)
  if connector.pid == nil then return end
  local seen, gone = raw.waitpid(connector.pid, true)
  if seen == nil or gone ~= nil and gone ~= "" or seen.pid ~= 0 then return end
  -- Nothing the connector is doing is worth waiting for: it may be in a
  -- connect that would end only at its own timeout.
  local _, _ = sys.kill(connector.pid, sys.SIGKILL)
  local _, _ = raw.waitpid(connector.pid, false)
end

--- Ends the connector and reaps it, waking a task waiting on its stream.
function ConnectorProcess:close(): boolean
  end_connector(self, false)
  return true
end

--- Plumbing behind [`Net.connector`], which is the supported face: its
--- wire protocol (the request and reply of the control stream, the
--- passed descriptor) may change with the core, and nothing else
--- should speak it.
---
--- Starts the sandbox's native TCP connector, confined to the numeric
--- `endpoints` (at most 128, each a canonical IPv4 or IPv6 `host` and a
--- `port`, 0 for any nonzero port at that address) and to nothing else:
--- no file, no exec, no other address. It connects, within `timeout_ms`
--- milliseconds (1 to 60000) each, to one endpoint a request names and
--- passes the connected socket back over its control stream; one
--- connector serves any number of requests, one at a time, until it is
--- closed. It answers nil and why where this host cannot confine one:
--- Linux on x86_64 and aarch64 only. An `endpoints` that is no table of
--- such endpoints, or a `timeout_ms` outside 1 to 60000, raises.
---
---     local connector = assert(Child.start_connector({ { host = "127.0.0.1", port = 8080 } }, 5000))
---     -- write ">I4I4" of endpoint 1 and the port to connector.fd, read the reply
---     connector:close()
---
--- With `public` (`deny`, the numeric "address/bits" prefixes it refuses,
--- and `own`, the host's own addresses), the connector also connects to
--- an address its table lacks, once it has judged the address against
--- those lists itself, and `endpoints` may be empty.
-- TODO: confine the connector on macOS with Seatbelt's numeric remote rules
-- (#2820): core/connector.c's connector_start answers ENOSYS there.
function Child.start_connector(endpoints: {raw_process.ConnectorEndpoint}, timeout_ms: integer,
                               public?: raw_process.ConnectorPublic): ConnectorProcess | nil, string
  local pair, why = raw.connector_pair()
  if pair == nil then return nil, "child: " .. why end
  local called, pid, trouble, errno = pcall(raw.connector_start, endpoints, pair[2], timeout_ms, public)
  local _, _ = sys.close(pair[2])
  if not called then
    -- A table or a timeout the core refuses: the pair is not leaked by it.
    local _, _ = sys.close(pair[1])
    error(pid, 0)
  end
  if pid == nil then
    local _, _ = sys.close(pair[1])
    if errno == sys.ENOSYS or errno == sys.EOPNOTSUPP then
      return nil, "child: the native connector is Linux only (x86_64 and aarch64): " .. trouble
    end
    return nil, "child: could not start the connector: " .. trouble
  end
  local ok, nonblocking = sys.set_nonblocking(pair[1], true)
  if not ok then
    local _, _ = sys.kill(pid, sys.SIGKILL)
    local _, _ = raw.waitpid(pid, false)
    local _, _ = sys.close(pair[1])
    return nil, "child: " .. nonblocking
  end
  local started: ConnectorProcess = setmetatable({ fd = pair[1], pid = pid, open = true }, connector_mt)
  return started
end

--- Takes the control stream `fd` of a connector this process did not
--- start (it was inherited, its starter keeping the process) as a
--- [`Child.ConnectorProcess`] with no pid: the stream is made nonblocking,
--- and `close` closes it and does not signal or wait for anything. It
--- answers nil and why where the stream cannot be made nonblocking, and
--- leaves `fd` the caller's then.
--- @param fd integer A Unix stream descriptor the connector answers on
--- @return ConnectorProcess|nil The connector's stream
--- @return string Why not, when it is nil
function Child.adopt_connector(fd: integer): ConnectorProcess | nil, string
  local ok, nonblocking = sys.set_nonblocking(fd, true)
  if not ok then return nil, "child: " .. nonblocking end
  local adopted: ConnectorProcess = setmetatable({ fd = fd, open = true }, connector_mt)
  return adopted, ""
end

--- The status a shell reports for a child that ended as `result` says:
--- its exit status, or 128 plus the number of the signal that ended it.
--- A result carrying neither, which [`Child.run`] and `h:wait` never
--- answer, is 1. Use it to exit as the child did; a child ended for
--- running past its timeout answers the signal that ended it, not the
--- 124 of `timeout(1)`.
function Child.shell_status(result: Result): integer
  if result.signal ~= nil then return 128 + result.signal end
  return result.code or 1
end

--- Raises at level 4, the caller of [`Child.start`] or [`Child.run`]: it and
--- [`without_nul`] run under `validate`, which runs under either one.
local function descriptor(value: integer | string, name: string, words: {string:boolean}):
    integer | string
  if value == nil then return "inherit" end
  if value is string and words[value] then return value end
  if value is integer and value >= 0 and value <= INT_MAX then return value end
  if name == "stdin" and value == "pipe" then
    error("child: stdin = \"pipe\" was removed: use \"stream\" and write through the handle's " ..
        "stdin_stream, closing it for end of file, or `input` for bytes known in advance", 4)
  end
  local allowed: {string} = {}
  for word in pairs(words) do allowed[#allowed + 1] = "'" .. word .. "'" end
  table.sort(allowed)
  error("child: " .. name .. " must be a file descriptor or one of " .. table.concat(allowed, ", "), 4)
end

local STDIN_WORDS <const> = { inherit = true, null = true, stream = true }
local STDOUT_WORDS <const> = { inherit = true, null = true, capture = true, stream = true }
local STDERR_WORDS <const> = {
  inherit = true, null = true, capture = true, stdout = true, stream = true,
}
local FD_WORDS <const> = { capture = true }

local function without_nul(value: string, name: string)
  if value:find("\0", 1, true) then error("child: " .. name .. " contains a NUL byte", 4) end
end

local function validate(argv: {string}, opts: Options)
  if #argv == 0 then error("child: argv is empty", 3) end
  for i, value in ipairs(argv) do
    if type(value) ~= "string" then
      error("child: argv[" .. tostring(i) .. "] must be a string", 3)
    end
    without_nul(value, "argv[" .. tostring(i) .. "]")
  end
  if opts.cwd == "" then
    error("child: cwd is empty; leave it nil to start in this process's directory", 3)
  end
  if opts.cwd ~= nil then without_nul(opts.cwd, "cwd") end
  if opts.env ~= nil then
    for name, value in pairs(opts.env) do
      if type(name) ~= "string" or name == "" or name:find("=", 1, true) then
        error("child: environment name is empty, non-string, or contains '='", 3)
      end
      if type(value) ~= "string" then error("child: environment value must be a string", 3) end
      without_nul(name, "environment name")
      without_nul(value, "environment value")
    end
  end
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  descriptor(opts.stdout, "stdout", STDOUT_WORDS)
  descriptor(opts.stderr, "stderr", STDERR_WORDS)
  if opts.input ~= nil then
    if type(opts.input) ~= "string" then error("child: input must be a string", 3) end
    if stdin ~= "inherit" then
      error("child: input and a stdin of its own exclude each other", 3)
    end
  end
  if opts.fds ~= nil then
    for number, value in pairs(opts.fds) do
      if not (number is integer) or number < 3 or number > 255 then
        error("child: fds keys are child descriptors from 3 to 255", 3)
      end
      descriptor(value, "fds[" .. tostring(number) .. "]", FD_WORDS)
    end
  end
  if opts.capture_limit ~= nil and (opts.capture_limit < 1 or opts.capture_limit > INT_MAX) then
    error("child: capture_limit is out of range", 3)
  end
  Poll.checked_ns(opts.timeout_ns, "child", "timeout_ns", 3)
  local logged = opts.relay_log
  if logged ~= nil and logged ~= "null" and logged ~= "inherit" and
      not (logged is integer and logged >= 0 and logged <= INT_MAX) then
    error("child: relay_log must be \"null\", \"inherit\" or a descriptor", 3)
  end
  if opts.policy ~= nil then
    if type(opts.policy) ~= "table" then
      error("child: policy must be a cosmic.sandbox Policy", 3)
    end
    if opts.env ~= nil then
      error("child: policy and env exclude each other: the policy's env and set_env are the " ..
          "child's whole environment", 3)
    end
    if opts.sandbox ~= nil then error("child: policy and sandbox exclude each other", 3) end
    if opts.credentials ~= nil then
      error("child: policy and credentials exclude each other: a policy's program never runs " ..
          "as root, and where this process is root the policy chooses its user", 3)
    end
  end
  if opts.credentials ~= nil then
    local user, group = opts.credentials.user, opts.credentials.group
    if not (user is integer) or not (group is integer) or
        user < 1 or user > 4294967294 or group < 1 or group > 4294967294 then
      error("child: credentials need integer user and group from 1 to 4294967294", 3)
    end
    local sandbox = opts.sandbox
    if sandbox ~= nil and (sandbox.unveil ~= nil or sandbox.offline == true or
        sandbox.user ~= nil or sandbox.group ~= nil) then
      error("child: credentials exclude sandbox unveil, offline, user and group", 3)
    end
  end
  if opts.sandbox ~= nil and opts.sandbox.noexec_scratch ~= nil then
    if type(opts.sandbox.noexec_scratch) ~= "boolean" then
      error("child: noexec_scratch must be a boolean", 3)
    end
    if opts.sandbox.noexec_scratch and opts.sandbox.unveil == nil then
      error("child: noexec_scratch requires unveil", 3)
    end
  end
  if opts.sandbox ~= nil and opts.sandbox.unveil ~= nil then
    local unveil = opts.sandbox.unveil
    for _, list in ipairs({ unveil.reads or {}, unveil.writes or {} }) do
      for _, path in ipairs(list) do
        without_nul(path, "an unveiled path")
        if path:sub(1, 1) ~= "/" then error("child: an unveiled path must be absolute", 3) end
      end
    end
  end
end

--- The pty [`Child.start_on_pty`] made for one start: its slave, and
--- which of the child's standard streams (0 to 2) are the slave.
local record Pty
  slave: integer
  --- The slave's path.
  name: string
  streams: {integer:boolean}
end

--- Descriptors this process opened for one start, closed together
--- whatever happens: the child's ends always, ours only on failure.
local record Wiring
  child_ends: {integer}
  ours: {integer}
  streams: {Pipe}
  input_fd: integer | nil
  feed_fd: integer | nil
end

local function unwire(wiring: Wiring, keep_ours: boolean)
  for _, fd in ipairs(wiring.child_ends) do local _, _ = sys.close(fd) end
  if not keep_ours then
    for _, fd in ipairs(wiring.ours) do local _, _ = sys.close(fd) end
  end
end

--- A pipe whose read end is ours and whose write end the child gets
--- as `child_fd`; the stream records it, as the caller's to read when
--- `streamed`.
local function capture(wiring: Wiring, child_fd: integer, streamed?: boolean): integer | nil, string
  local ends, trouble = raw.pipe()
  if ends == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = ends.writer
  wiring.ours[#wiring.ours + 1] = ends.reader
  local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.reader, true)
  if not nonblocking then return nil, nonblocking_trouble end
  wiring.streams[#wiring.streams + 1] = {
    fd = ends.reader, child_fd = child_fd, chunks = {}, size = 0, truncated = false,
    streamed = streamed or false, head = 1, tail = 0, reader_closed = false, consuming = false,
  }
  return ends.writer, ""
end

local function null(wiring: Wiring, flags: integer): integer | nil, string
  local fd, trouble = sys.open("/dev/null", flags)
  if fd == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = fd
  return fd, ""
end

--- The descriptor the child's output `child_fd` goes to, as `how` asks:
--- a pipe to capture or stream, /dev/null, or a descriptor given; nil
--- and "" to inherit this process's, and nil and why when it fails.
local function wire_output(wiring: Wiring, child_fd: integer,
                           how: integer | string): integer | nil, string
  if how == "capture" or how == "stream" then
    return capture(wiring, child_fd, how == "stream")
  elseif how == "null" then
    return null(wiring, sys.O_WRONLY)
  elseif how is integer then
    return how, ""
  end
  return nil, ""
end

--- Resolves the options into the descriptor each child slot copies:
--- nil to inherit, or a descriptor number.
local function wire(opts: Options, wiring: Wiring, pty?: Pty): {integer:integer} | nil, string
  local slots: {integer:integer} = {}
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  if pty ~= nil and pty.streams[0] then
    slots[0] = pty.slave
  elseif opts.input ~= nil or stdin == "stream" then
    local ends, trouble = raw.pipe()
    if ends == nil then return nil, trouble end
    wiring.child_ends[#wiring.child_ends + 1] = ends.reader
    wiring.ours[#wiring.ours + 1] = ends.writer
    slots[0] = ends.reader
    -- A write to a child that has gone fails with EPIPE rather than
    -- ending this process, whoever writes it: this module feeding
    -- `input`, or the caller writing to `h.stdin_stream`.
    local ignored, ignore_trouble = raw.ignore_sigpipe()
    if not ignored then return nil, ignore_trouble end
    local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.writer, true)
    if not nonblocking then return nil, nonblocking_trouble end
    if opts.input ~= nil then
      wiring.input_fd = ends.writer
    else
      wiring.feed_fd = ends.writer
    end
  elseif stdin == "null" then
    local fd, trouble = null(wiring, sys.O_RDONLY)
    if fd == nil then return nil, trouble end
    slots[0] = fd
  elseif stdin is integer then
    slots[0] = stdin
  end
  if pty ~= nil and pty.streams[1] then
    slots[1] = pty.slave
  else
    local out, out_trouble = wire_output(wiring, 1, descriptor(opts.stdout, "stdout", STDOUT_WORDS))
    if out_trouble ~= "" then return nil, out_trouble end
    slots[1] = out
  end
  if pty ~= nil and pty.streams[2] then
    slots[2] = pty.slave
  else
    local stderr = descriptor(opts.stderr, "stderr", STDERR_WORDS)
    if stderr == "stdout" then
      slots[2] = slots[1] or 1
    else
      local err, err_trouble = wire_output(wiring, 2, stderr)
      if err_trouble ~= "" then return nil, err_trouble end
      slots[2] = err
    end
  end
  if opts.fds ~= nil then
    local numbers: {integer} = {}
    for number in pairs(opts.fds) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    for _, number in ipairs(numbers) do
      local value = opts.fds[number]
      if value is integer then
        slots[number] = value
      else
        local fd, trouble = capture(wiring, number)
        if fd == nil then return nil, trouble end
        slots[number] = fd
      end
    end
  end
  return slots, ""
end

--- Whether `name` is a bare name -- no slash -- that is not there in
--- `cwd` (this process's own when nil), which does exist: most often a
--- program meant to be found on PATH. Not when the directory is what
--- is missing, nor when the file is there and its `#!` interpreter is
--- not: those fail with the same ENOENT.
local function unfound_name(name: string, cwd?: string): boolean
  if name == "" or name:find("/", 1, true) ~= nil then return false end
  local dir = cwd or "."
  local there, _ = sys.stat(dir)
  if there == nil then return false end
  local found, _ = sys.lstat(dir .. "/" .. name)
  return found == nil
end

--- Whether `opts.cwd` is given and missing as this process sees it --
--- not there, rather than closed to it -- so that a start that failed
--- ENOENT or ENOTDIR failed on it. Not for a sandbox that unveils, whose
--- child finds the directory in a root of its own, where `at` may bind
--- it under another name.
local function missing_cwd(opts: Options): boolean
  if opts.cwd == nil or (opts.sandbox ~= nil and opts.sandbox.unveil ~= nil) then return false end
  local there, _, errno = sys.stat(opts.cwd)
  return there == nil and (errno == sys.ENOENT or errno == sys.ENOTDIR)
end

--- Why a start that failed with EINVAL or EMFILE may have failed: the
--- descriptors it places above the highest it hands the child are
--- refused past RLIMIT_NOFILE's soft limit, which a process raises at
--- its start but no further than the hard one. "" where the limit
--- leaves them room.
local function descriptor_limit_hint(slots: {integer:integer}): string
  local top, count = 2, 0
  for number in pairs(slots) do
    count = count + 1
    if number > top then top = number end
  end
  local limits, _ = sys.getrlimit(sys.RLIMIT_NOFILE)
  -- The child's status end takes top + 1; above it, a copy of each
  -- descriptor handed and what spawn places besides.
  if limits == nil or limits.soft > top + 1 + count + raw.SPAWN_PLACED_ABOVE then return "" end
  local remedy = limits.soft < limits.hard and "sys.setrlimit raises it as far as the hard one" or
    "only a higher hard limit makes room"
  return ": the child is handed descriptor " .. tostring(top) .. ", and the start " ..
    "places descriptors above it, past RLIMIT_NOFILE's soft limit of " ..
    tostring(limits.soft) .. " (hard " .. tostring(limits.hard) .. "): " .. remedy
end

--- How much a start under a policy lets the child hold open unless the
--- policy's `open_files` says.
local DEFAULT_OPEN_FILES <const> = 1024

--- The unprivileged user and group a root caller's program runs as.
local record MappedUser
  uid: integer
  gid: integer
end

--- What a policy makes of a start.
local record Held
  --- The file to run.
  path: string
  --- The child's whole environment.
  env: {string:string}
  --- What spawn is handed to hold the child to it.
  sandbox: raw_process.Sandbox
  --- The temporary directory made for the child, "" for none: made by
  --- [`make_tmp`], the last step before the spawn.
  tmp: string
  --- Whether the policy asks for one: not under `isolate` file, whose
  --- /tmp is a tmpfs of the sandbox's own.
  wants_tmp: boolean
  --- Whether it promises `nest`, which no descriptor to a directory or to a
  --- file open for less than both may be handed to ([`nest_descriptors`]).
  nests: boolean
  --- The directory to start in, as a path the root of `isolate` file
  --- holds; nil to start in the caller's.
  cwd: string
  --- The user and group the child runs as where this process is root,
  --- which a program of a policy never is ([`mapped_user`]); nil for this
  --- process's own. The directory `tmp` makes is given to them.
  user: MappedUser
  --- `user`, where the child gives root up for it directly, in no
  --- namespace (spawn's `credentials`); nil where it is mapped into one.
  drop: MappedUser
  --- The arguments to run with, where they are not the caller's: this
  --- program's relaunch ([`relaunch_of`]).
  argv: {string}
  --- The descriptors the relaunch hands the child, by its number.
  fds: {integer:integer}
  --- Whether `sandbox` holds the child by Seatbelt, as on macOS, and not
  --- by Landlock and seccomp.
  seatbelt: boolean
  --- Under Seatbelt, the profile's parameter that names `tmp`'s directory,
  --- which [`make_tmp`] sets; nil without `tmp`.
  tmp_parameter: string
  --- The policy's `connect` targets, which the network relay serves; nil
  --- for a policy with none, which starts no relay.
  relay: {string}
end

--- The most grants spawn takes (`GRANT_MAX` in core/syscalls.c), the
--- temporary directory's included.
local MAX_GRANTS <const> = 256

--- Whether `file` is `grant` or beneath it.
local function beneath(file: string, grant: string): boolean
  if grant == "/" or file == grant then return true end
  return file:sub(1, #grant + 1) == grant .. "/"
end

--- Why a start under `grants` cannot run the `files` a program needs to
--- start ([`Rules.loaders`], the program itself first), or "": a file
--- must be beneath a grant giving `r` and one giving `x`, which may be
--- one. A grant whose path does not exist is skipped, as spawn names
--- it.
local function ungranted(files: {string}, grants: {Rules.Grant}, cwd?: string): string
  local reals: {{string}} = {}
  for _, grant in ipairs(grants) do
    local at = grant.path
    if cwd ~= nil and at:sub(1, 1) ~= "/" then at = cwd .. "/" .. at end
    local real, _ = sys.realpath(at)
    if real ~= nil then reals[#reals + 1] = { real, grant.letters } end
  end
  for i, file in ipairs(files) do
    local missing: {string} = {}
    for _, letter in ipairs({ "r", "x" }) do
      local given = false
      for _, held in ipairs(reals) do
        if beneath(file, held[1]) and held[2]:find(letter, 1, true) then given = true end
      end
      if not given then missing[#missing + 1] = letter end
    end
    if #missing > 0 then
      local what = i == 1 and "the program" or "the interpreter the program starts through"
      return string.format("%s %s is not granted %s: grant it, { path = %q, letters = \"rx\" }, " ..
          "or add the \"system\" profile for the host's own programs", what, file,
        table.concat(missing, " and "), file)
    end
  end
  return ""
end

--- The most a start under `isolate` file may grant: one of spawn's
--- unveiled paths is the sandbox's own /proc.
local MAX_ISOLATED_GRANTS <const> = MAX_GRANTS - 1

--- Whether `merged`'s `isolate` holds `kind`.
local function isolates(merged: Rules.Policy, kind: Rules.Isolate): boolean
  for _, held in ipairs(merged.isolate) do
    if held == kind then return true end
  end
  return false
end

--- Whether `merged` promises `nest`.
local function nests(merged: Rules.Policy): boolean
  for _, promise in ipairs(merged.promises) do
    if promise == "nest" then return true end
  end
  return false
end

--- A policy's fields not yet met, by what each would need.
local function unmet(merged: Rules.Policy): string
  local file = isolates(merged, "file")
  local held = #merged.grants + (merged.tmp and not file and 1 or 0)
  local most = file and MAX_ISOLATED_GRANTS or MAX_GRANTS
  if held > most then
    return "grants: the policy holds " .. held ..
      (file and ", and the sandbox's /proc is one more" or ", tmp's included") ..
      ", past the most a start takes, " .. most .. "; grant a directory above them instead"
  end
  if nests(merged) and not file then
    return "promises \"nest\" needs isolate \"file\": the root of the program's own is what " ..
      "holds its files once Landlock's hold is given up, since the kernel refuses a mount to " ..
      "a process Landlock holds"
  end
  for _, grant in ipairs(merged.grants) do
    if grant.from ~= nil and not file then
      return "grant \"" .. grant.path .. "\" has from, which needs isolate \"file\": the host's " ..
        "path is bound at that name in a root of the program's own"
    end
  end
  if merged.limits.processes ~= nil and not isolates(merged, "proc") and not file then
    return "limits.processes counts the processes of a user namespace of the sandbox's own, " ..
      "which isolate \"proc\" or \"file\" makes: add one"
  end
  for name, _ in pairs(merged.set_env_digests) do
    return "set_env_digests \"" .. name .. "\" holds a digest, not the value to set; the " ..
      "policy cannot start a program"
  end
  return ""
end

--- The size of the /tmp of a sandbox's own under `isolate` file, in bytes.
-- TODO: let a policy say how large its /tmp is (a field beside `limits`),
-- once the design names one: every `isolate` file sandbox has this size.
local TMP_BYTES <const> = 256 * 1024 * 1024

--- `path` as a root holding it names it: unchanged where absolute, else
--- beneath `base`, which is absolute.
local function named(path: string, base: string): string
  if path:sub(1, 1) == "/" then return path end
  if path == "." then return base end
  return base .. (base:sub(-1) == "/" and "" or "/") .. path
end

--- Whether `letters` holds `letter`.
local function lettered(letters: string, letter: string): boolean
  return letters:find(letter, 1, true) ~= nil
end

--- Whether a root of `grants` has the directory `base`, which it does when
--- some grant is at it, beneath it (the directories above are made) or above it.
local function holds_place(grants: {Rules.Grant}, base: string): boolean
  for _, grant in ipairs(grants) do
    local name = named(grant.path, base)
    -- Where a grant with no `from` is placed is where it resolves to.
    if grant.from == nil then
      local real, _ = sys.realpath(name)
      if real ~= nil then name = real end
    end
    if beneath(base, name) or beneath(name, base) then return true end
  end
  return false
end

--- What `isolate` file builds from a policy's grants, resolved against the
--- directory `base`: each grant's host path (its `from`, else itself) bound
--- at its name when that differs, writable where it may be written or
--- created in, and noexec where it is and may not be run; and the sandbox's
--- own /proc; `idmap` says which are mounted idmapped ([`reached_by`]).
--- With `nest`, which has no Landlock to refuse running a file, every grant
--- without `x` is noexec. Nil and why where a grant cannot be placed.
local function root_of(merged: Rules.Policy, base: string, idmap: {boolean}, nest: boolean,
                       tmp_exec: boolean): raw_process.Unveil | nil, string
  local binds: {raw_process.Bind} = {}
  local reads: {string} = {}
  local proc = true
  for index, grant in ipairs(merged.grants) do
    local name = named(grant.path, base)
    if name == "/proc" and grant.from ~= nil then
      return nil, "grant \"/proc\" has from, but /proc is the sandbox's own: grant its " ..
        "contents at another name"
    end
    if merged.tmp and (name == "/tmp" or name == "/") then
      return nil, "grant \"" .. grant.path .. "\" is the name of the sandbox's own /tmp, " ..
        "which tmp makes: grant what is beneath it, or leave tmp out, or grant \"/tmp\" " ..
        "itself with no `from`, for its letters"
    end
    if name == "/proc" or name == "/" then proc = false end
    local writable = lettered(grant.letters, "w") or lettered(grant.letters, "c")
    binds[#binds + 1] = { path = named(grant.from or grant.path, base),
      at = grant.from ~= nil and name or nil, writable = writable,
      noexec = (writable or nest) and not lettered(grant.letters, "x"), idmap = idmap[index] or nil }
  end
  if proc then reads[1] = "/proc" end
  local tmp: integer
  if merged.tmp then tmp = TMP_BYTES end
  return { reads = reads, writes = {}, binds = binds, tmp = tmp, tmp_exec = tmp_exec or nil }, ""
end

--- Why a `u` grant cannot be held under `isolate` file, or "". Below
--- Landlock ABI 9 nothing tells one unix socket of the root from another
--- (the filter allows AF_UNIX to the program whole, and a read-only bind
--- does not stop a connect), so the root alone holds: it may show no
--- directory of the host, which may hold sockets a host service put
--- there, and no socket but one granted `u`. The sandbox's own /tmp is
--- no grant and holds only what the program makes. A `u` grant beside a
--- directory grant waits on ABI 9, at which Landlock holds it, unless
--- `nest` gives Landlock up, which leaves the root alone to.
-- TODO: hold a `u` grant beside a directory grant below ABI 9, once the
-- kernels the suite runs on give Landlock ABI 9 (core/syscalls.c's
-- TODO on the same): the directory may hold a socket the grant does not
-- name, which the filter cannot tell from the granted one.
local function unix_unheld(merged: Rules.Policy, base: string, nest: boolean): string
  local abi, _ = raw.landlock_abi()
  if not nest and (abi == nil or abi >= 9) then return "" end
  for _, grant in ipairs(merged.grants) do
    local st, _ = sys.stat(named(grant.from or grant.path, base))
    local kind = st ~= nil and st.kind or ""
    if kind == "dir" or (kind == "socket" and not lettered(grant.letters, "u")) then
      local what = kind == "dir" and "a directory" or "a socket without `u`"
      if nest then
        return "a `u` grant under isolate file beside " .. what .. " (" ..
          string.format("%q", grant.path) .. ") needs Landlock, which promises \"nest\" gives " ..
          "up: the granted socket cannot be told from another socket in the root, and the " ..
          "root holds every socket a granted directory holds. Grant the socket alone (and " ..
          "files), or leave nest out"
      end
      return "a `u` grant under isolate file needs Landlock ABI 9 beside " .. what .. " (" ..
        string.format("%q", grant.path) .. "): this kernel gives ABI " .. tostring(abi) ..
        ", where the granted socket cannot be told from another socket in the root, and " ..
        "the root holds every socket a granted directory holds. Grant the socket alone " ..
        "(and files, and `tmp`), or run a kernel with ABI 9"
    end
  end
  return ""
end

--- Why a grant cannot be held by the root alone, which is all that holds
--- a program's files once `nest` gives up Landlock, or "". The root has a
--- bind that is writable or not and, where it is not given `x`, noexec:
--- it cannot tell writing a file from making or removing one in a
--- directory, nor running a file from reading it, as Landlock's `w` and
--- `c`, `x` and `r` do. So a directory granted one of `w` and `c` without
--- the other, a file granted `c` without `w`, and a grant of `x` without
--- `r` are refused, naming the letters to add.
local function nest_unheld(merged: Rules.Policy, base: string): string
  for _, grant in ipairs(merged.grants) do
    local letters = grant.letters
    local what = "grant " .. string.format("%q", grant.path) .. " (" .. letters .. ")"
    local st, _ = sys.stat(named(grant.from or grant.path, base))
    local directory = st ~= nil and st.kind == "dir"
    if lettered(letters, "x") and not lettered(letters, "r") then
      return what .. " runs files it cannot read, which a root cannot hold once \"nest\" gives " ..
        "up Landlock: add `r`"
    elseif lettered(letters, "c") and not lettered(letters, "w") then
      return what .. " creates what it cannot write, which a root cannot hold once \"nest\" gives " ..
        "up Landlock: add `w`"
    elseif directory and lettered(letters, "w") and not lettered(letters, "c") then
      return what .. " writes files but makes and removes none, which a root cannot hold once " ..
        "\"nest\" gives up Landlock: a writable directory is one a program may create in " ..
        "too; add `c`"
    end
  end
  return ""
end

--- Whether a grant of `merged` has `u`.
local function isolated_unix(merged: Rules.Policy): boolean
  for _, grant in ipairs(merged.grants) do
    if lettered(grant.letters, "u") then return true end
  end
  return false
end

--- What a process's pid is multiplied by to make a sandbox's serial
--- ([`Sandbox.user_id`]): an odd number, so processes whose pids are
--- near differ in it.
local PID_SPREAD <const> = 2481

--- The sandboxes this process has given a user: the part of the serial
--- that makes two of its own differ.
local sandboxes_started = 0

--- The user this process runs as, which a program of a policy is not to
--- be where it is root.
local function effective_user(): integer
  local status, _ = Fs.read("/proc/self/status")
  local effective = status ~= nil and status:match("\nUid:%s+%d+%s+(%d+)") or nil
  local number = effective ~= nil and math.tointeger(tonumber(effective)) or nil
  return number or sys.getuid()
end

--- The group this process runs as, which a caller that is not root may
--- name as its program's, and which a root caller's namespace maps beside
--- its program's.
local function effective_group(): integer
  local status, _ = Fs.read("/proc/self/status")
  local effective = status ~= nil and status:match("\nGid:%s+%d+%s+(%d+)") or nil
  local number = effective ~= nil and math.tointeger(tonumber(effective)) or nil
  return number or sys.getgid()
end

--- The user and group a program runs as where this process is root,
--- which a program of a policy never is: nil with no reason where this
--- process is not root (the program then runs as it does, mapped as itself
--- in a user namespace of its own), and nil and why where `merged` names
--- another `user` or `group` than its own then; where it is root and may,
--- `merged`'s `user` and `group`, or else a user of its own from
--- [`Sandbox.user_id`]'s pool; nil and why where it is root but may not
--- map one -- it needs CAP_SETUID, CAP_SETGID and CAP_SETFCAP, and a user
--- namespace that maps the user.
local function mapped_user(merged: Rules.Policy): MappedUser | nil, string
  local platform, _, _ = raw.sandbox_platform()
  local own = effective_user()
  if not platform and own == 0 then
    if merged.user ~= nil then
      return nil, "user " .. merged.user .. ": a program runs as a user of the policy's only " ..
        "where it is sandboxed, on Linux"
    end
    return nil, ""
  end
  if own ~= 0 then
    local group = effective_group()
    if merged.user ~= nil and (merged.user ~= own or (merged.group ~= nil and merged.group ~= group)) then
      return nil, "user " .. merged.user .. (merged.group ~= nil and ", group " .. merged.group or "") ..
        ": only a root caller chooses the user its program runs as, and this process is user " ..
        own .. ", group " .. group .. ", which its program runs as: name that or none"
    end
    return nil, ""
  end
  local mayed, _, _ = raw.may_map_ids()
  -- TODO: ask only CAP_SETUID and CAP_SETGID of a policy that makes no
  -- namespace, whose child gives root up directly and maps nothing, once
  -- this is told the policy: a container that leaves out CAP_SETFCAP
  -- refuses that start today for a capability it does not use.
  if not mayed then
    return nil, "this process is root, and a program of a policy never runs as root: it runs " ..
      "as a user of its own, mapped into its user namespace from outside, which needs " ..
      "CAP_SETUID, CAP_SETGID and CAP_SETFCAP in effect here (a container may leave out " ..
      "CAP_SETFCAP: add it, or start from another user)"
  end
  local uid_map, _ = Fs.read("/proc/self/uid_map")
  local gid_map, _ = Fs.read("/proc/self/gid_map")
  if uid_map == nil or gid_map == nil then
    return nil, "this process's user and group maps cannot be read, so the user a program " ..
      "of a policy runs as (never root) cannot be chosen: /proc/self/uid_map"
  end
  if merged.user ~= nil then
    local group = merged.group or merged.user
    if not Rules.maps_id(uid_map, merged.user) or not Rules.maps_id(gid_map, group) then
      return nil, "user " .. merged.user .. " and group " .. group .. ": this " ..
        "process's user namespace does not map both, so its program cannot run as them"
    end
    if Rules.in_pool(uid_map, gid_map, merged.user) or Rules.in_pool(uid_map, gid_map, group) then
      return nil, "user " .. merged.user .. " and group " .. group .. ": one is of the pool a " ..
        "root caller's sandboxes are each given a user from, which a concurrent one may be " ..
        "given: name one outside it"
    end
    return { uid = merged.user, gid = group }, ""
  end
  sandboxes_started = sandboxes_started + 1
  local id, why = Rules.user_id(uid_map, gid_map, sys.getpid() * PID_SPREAD + sandboxes_started)
  if id == nil then return nil, why end
  return { uid = id, gid = id }, ""
end

--- Whether every directory above `path`, an absolute real path, may be
--- searched by `user`, the user of a root caller's sandbox, as it must to
--- reach it in the host's own tree: "" or the directory that may not.
local function unsearchable_above(path: string, user: MappedUser): string
  local at = Fs.dirname(path)
  while true do
    local st, _ = sys.stat(at)
    local by = st ~= nil and Rules.reach("x", st, user.uid, user.gid).by or "other"
    if by ~= "other" and by ~= "user" then return at end
    if at == "/" or at == "." then return "" end
    at = Fs.dirname(at)
  end
end

--- Which of `merged`'s grants `user`, the user of a root caller's sandbox,
--- can use only as their owner can ([`Sandbox.reach`]): those are mounted idmapped, so that user is the
--- owner, where `file` gives the sandbox a root of its own to mount them
--- in. Nil, and why, where one cannot be used either way, or, without
--- `file`, only as its owner can, which only that mount gives; naming it
--- and what to do. Without `file` every directory above a grant must also
--- be searchable by that user, and so must `base`, the directory the
--- program starts in, and, for `tmp`, TMPDIR's; under it the root is built without walking to a
--- grant. A grant that does not exist is left for the start's own report.
local function reached_by(merged: Rules.Policy, base: string, file: boolean,
                          user: MappedUser): {boolean} | nil, string
  if merged.tmp and not file then
    local tmpdir = sys.getenv("TMPDIR")
    if tmpdir == nil or tmpdir == "" then tmpdir = "/tmp" end
    local real, _ = sys.realpath(tmpdir)
    local above = real ~= nil and unsearchable_above(real .. "/.", user) or ""
    if above ~= "" then
      return nil, "tmp makes its directory in TMPDIR, " .. string.format("%q", tmpdir) ..
        ", which the user a root caller's program runs as cannot reach: " .. above ..
        " is not searchable by everyone; point TMPDIR at a directory everyone may search, " ..
        "or isolate \"file\", whose /tmp is a tmpfs of the sandbox's own"
    end
  end
  local idmap: {boolean} = {}
  for index, grant in ipairs(merged.grants) do
    local named_at = named(grant.from or grant.path, base)
    local real, _ = sys.realpath(named_at)
    local st: sys.Stat
    if real ~= nil then
      local got, _ = sys.stat(real)
      st = got
    end
    if st ~= nil then
      local reach = Rules.reach(grant.letters, st, user.uid, user.gid)
      local what = "grant " .. string.format("%q", grant.path) .. " (" .. real .. ")"
      if reach.by == "" then
        return nil, what .. " cannot be used by the user a root caller's program runs as, " ..
          "user " .. user.uid .. ": " .. reach.lacks .. "; change its mode so it may"
      elseif reach.by == "owner" then
        if not file then
          return nil, what .. " is owned by user " .. st.uid .. " and not open to the user a " ..
            "root caller's program runs as, user " .. user.uid .. ", which is not its owner, so " ..
            "it cannot use it: change its mode, or isolate \"file\", which mounts it so that " ..
            "user owns it"
        end
        -- The mount shows the grant's owner as the program's user, and so
        -- cannot show that user's own files as its own too: a user
        -- namespace's map takes each outside id once. They show as the
        -- owner's instead (core/syscalls.c's swapped_map), which a
        -- policy's `user` reaches by their mode for everyone (and for the
        -- group, where it is the owner's).
        idmap[index] = true
      elseif not file then
        local above = unsearchable_above(real, user)
        if above ~= "" then
          return nil, what .. " is beneath the directory " .. above .. ", which the user a " ..
            "root caller's program runs as cannot search: change its mode, or isolate " ..
            "\"file\", which gives the program a root holding only what is granted"
        end
      end
    end
  end
  if not file then
    local above = unsearchable_above(base .. "/.", user)
    if above ~= "" then
      return nil, "the directory the program starts in, " .. string.format("%q", base) ..
        ", or one above it, " .. above .. ", cannot be searched by the user a root caller's " ..
        "program runs as: pass `cwd` of a directory everyone may search (this process's own is " ..
        "the default), or isolate \"file\""
    end
  end
  return idmap, ""
end

--- Where a root caller's programs run this program's core from: a
--- directory of root's, 0755, whose copies of the core are 0555 -- every
--- user may run one, and no one but root may write or swap one. It is in
--- /run, which every user may search and only root may write, as root's
--- own cache (in its home) is not searched and /tmp is written by all.
local SHARED_CORES <const> = "/run/cosmic-sandbox-cores"

--- Whether `st` is a directory of root's that no one else may write.
local function roots_alone(st: sys.Stat): boolean
  return st ~= nil and st.kind == "dir" and st.uid == 0 and st.mode & 0x12 == 0
end

--- `core`, this program's core, where the user of a root caller's program
--- may run it: a copy in [`SHARED_CORES`], made once per core under a lock
--- there, so concurrent starts take one copy and none replaces another's.
--- Startup hashes it against the artifact's digest every start, as no
--- stamp is left beside it. The copy's path, or nil and why.
-- TODO: remove a copy no start has used for a while, as nothing prunes
-- the launcher's own cores directory either, once that has a rule to
-- share: each core a host's root runs this program under leaves one.
local function shared_core(core: string): string | nil, string
  local name = core:match("([^/]+)$")
  if name == nil or not name:find("^core%-") then
    return nil, core .. " is not a cached core of this program"
  end
  local parent = Fs.dirname(SHARED_CORES)
  local up, _ = sys.lstat(parent)
  if not roots_alone(up) then
    return nil, parent .. " is not a directory of root's that only root may write, where " ..
      "the copy of this program's core a root caller's program runs is kept"
  end
  local made, made_trouble, made_errno = sys.mkdir(SHARED_CORES, 0x1ed)
  if made then
    local shut, shut_trouble = sys.chmod(SHARED_CORES, 0x1ed)
    if not shut then return nil, SHARED_CORES .. ": " .. shut_trouble end
  elseif made_errno ~= sys.EEXIST then
    return nil, SHARED_CORES .. ": " .. made_trouble
  end
  local st, _ = sys.lstat(SHARED_CORES)
  if st == nil or not roots_alone(st) or st.mode & 0xfff ~= 0x1ed then
    return nil, SHARED_CORES .. " is not a directory of root's, mode 0755: remove it, and the " ..
      "next start makes it again"
  end
  local lock, lock_trouble = sys.open(SHARED_CORES .. "/.lock", sys.O_RDWR | sys.O_CREAT, 0x180)
  if lock == nil then return nil, SHARED_CORES .. "/.lock: " .. lock_trouble end
  local locked, locked_trouble = sys.flock(lock, "exclusive", -1)
  if not locked then
    local _, _ = sys.close(lock)
    return nil, SHARED_CORES .. "/.lock: " .. locked_trouble
  end
  local copy = SHARED_CORES .. "/" .. name
  local failure = ""
  local there, _ = sys.lstat(copy)
  if there == nil or there.kind ~= "file" or there.uid ~= 0 or there.mode & 0xfff ~= 0x16d then
    local data, read_trouble = Fs.read(core)
    if data == nil then
      failure = core .. ": " .. read_trouble
    else
      local staged = SHARED_CORES .. "/.staged-" .. tostring(sys.getpid())
      local ok, trouble = Fs.write(staged, data, 0x16d)
      if ok then ok, trouble = sys.chmod(staged, 0x16d) end
      if ok then ok, trouble = sys.rename(staged, copy) end
      if not ok then
        local _, _ = sys.unlink(staged)
        failure = copy .. ": " .. trouble
      end
    end
  end
  local _, _ = sys.close(lock)
  if failure ~= "" then return nil, failure end
  return copy, ""
end

--- The descriptor open on each shared copy of the core, by its path: one
--- serves every start, as [`Proc.relaunch`]'s does; a spawn hands a child
--- only the descriptors it names.
local shared_fds: {string:integer} = {}

--- How a policy's program that is this program starts: by a relaunch of
--- its core ([`Proc.relaunch`]), past the launcher, which would fork and
--- unpack a core into a cache the policy does not give it. `user` is the
--- user a root caller's program runs as, which runs a copy of the core it
--- may run ([`shared_core`]); nil for this process's own. With a
--- `database`, the answer is the split shape, the core on that file
--- (`core --database <real path>`), whatever this process runs on, with
--- no descriptor to hand on; a core already run against a database
--- relaunches so too, on its own. Nil and "" where this program has no
--- core to start past its own start (a host program), or nil and why.
local function relaunch_of(user: MappedUser, database?: string): Proc.Relaunch | nil, string
  local launched, _ = Proc.relaunch()
  if launched == nil then return nil, "" end
  local portable = launched.env.COSMIC_PORTABLE_CORE_FD ~= nil
  if not portable and launched.argv[2] ~= "--database" then return nil, "" end
  if database ~= nil then
    local real, real_trouble = sys.realpath(database)
    if real == nil then return nil, "database " .. database .. ": " .. real_trouble end
    launched = { argv = { launched.argv[1], "--database", real }, env = {}, fds = {},
      cwd = launched.cwd }
    portable = false
  end
  if user == nil then return launched, "" end
  local copy, trouble = shared_core(launched.argv[1])
  if copy == nil then return nil, trouble end
  if not portable then
    local argv: {string} = { copy }
    for i = 2, #launched.argv do argv[i] = launched.argv[i] end
    return { argv = argv, env = launched.env, fds = launched.fds, cwd = launched.cwd }, ""
  end
  -- The copy may have been removed and made again since it was opened
  -- (a /run cleared, a hand): the descriptor handed on must be the file
  -- the child runs, which its startup holds it to.
  local fd = shared_fds[copy]
  if fd ~= nil then
    local held, _ = sys.fstat(fd)
    local named_now, _ = sys.lstat(copy)
    if held == nil or named_now == nil or held.ino ~= named_now.ino or held.dev ~= named_now.dev then
      local _, _ = sys.close(fd)
      shared_fds[copy] = nil
      fd = nil
    end
  end
  if fd == nil then
    local handle, open_trouble = sys.open(copy, sys.O_RDONLY)
    if handle == nil then return nil, copy .. ": " .. open_trouble end
    fd = handle
    shared_fds[copy] = fd
  end
  local core_fd = math.tointeger(tonumber(launched.env.COSMIC_PORTABLE_CORE_FD))
  local fds: {integer:integer} = {}
  for number, given in pairs(launched.fds) do fds[number] = number == core_fd and fd or given end
  local argv: {string} = { copy }
  for i = 2, #launched.argv do argv[i] = launched.argv[i] end
  return { argv = argv, env = launched.env, fds = fds, cwd = launched.cwd }, ""
end

--- This program's own file's real path ([`Proc.executable`]) where `name`,
--- a policy's program as the caller names it, from `cwd` (this process's
--- own where nil), is it; nil for any other program.
local function this_program(name: string, cwd: string): string | nil
  local executable, _ = Proc.executable()
  if executable == nil then return nil end
  local own, _ = sys.realpath(executable)
  if own == nil then return nil end
  local found: string = name
  if not name:find("/", 1, true) then
    local on_path, _ = Proc.find(name)
    if on_path == nil then return nil end
    found = on_path
  elseif cwd ~= nil and name:sub(1, 1) ~= "/" then
    found = cwd .. "/" .. name
  end
  local real, _ = sys.realpath(found)
  if real ~= own then return nil end
  return own
end

--- Whether `name`, a policy's program, is this program's own file, which
--- `grants` let it read and run.
local function runs_this_program(name: string, cwd: string, grants: {Rules.Grant}): boolean
  local own = this_program(name, cwd)
  return own ~= nil and ungranted({ own }, grants, cwd) == ""
end

--- The path of the first of `grants` that reaches `file`, a real path
--- (the grant is at it or above it, where it is a directory), as the
--- grant names it; "" for none. A relative grant is from `base`, this
--- process's own directory where nil; one with `from` reaches what `from`
--- names. A guard against a policy that grants the file by accident: a
--- hard link, a copy or a bind-mounted view of it elsewhere in a granted
--- directory still reads the program, so it does not hold against a
--- policy author who means to reach it.
local function reaching(file: string, grants: {Rules.Grant}, base: string): string
  for _, grant in ipairs(grants) do
    local at = grant.from or grant.path
    if base ~= nil and at:sub(1, 1) ~= "/" then at = base .. "/" .. at end
    local real, _ = sys.realpath(at)
    if beneath(file, real or at) then return grant.path end
  end
  return ""
end

--- The core a policy's program runs as, where it is this program or runs on
--- a `database`: [`relaunch_of`]'s start, and for a `database`, with this
--- program's own file out of the child's reach (it holds modules the
--- database leaves out). Nil and "" for any other program, or nil and why.
--- `user` is [`relaunch_of`]'s, `base` the directory grants are relative
--- to, and `reach` the grants that must not reach this program's own file:
--- the host's own (Landlock's profiles are not Seatbelt's).
local function core_of(argv: {string}, opts: Options, merged: Rules.Policy, user: MappedUser,
                       base: string, reach: {Rules.Grant}): Proc.Relaunch | nil, string
  local database: string = merged.database
  local program: string
  if database ~= nil then
    program = this_program(argv[1], opts.cwd)
    if program == nil then
      return nil, "sandbox: database " .. database .. ": a program runs on a database only " ..
        "where it is this program's core, and " .. argv[1] .. " is not this program"
    end
  elseif not runs_this_program(argv[1], opts.cwd, merged.grants) then
    return nil, ""
  end
  local found, relaunch_trouble = relaunch_of(user, database)
  if found == nil and relaunch_trouble ~= "" then return nil, "sandbox: " .. relaunch_trouble end
  if found == nil and database ~= nil then
    return nil, "sandbox: database " .. database .. ": this program is a host program, " ..
      "which has no core to start on a database"
  end
  if found ~= nil and database ~= nil then
    -- The core a database program runs is the file it is started by only
    -- where this process is that core already, so there it is granted.
    local started, _ = Proc.relaunch()
    local started_real: string
    if started ~= nil then
      local real, _ = sys.realpath(started.argv[1])
      started_real = real
    end
    local own_core = started_real == program
    local reached = own_core and "" or reaching(program, reach, base)
    if reached ~= "" then
      return nil, "sandbox: grant \"" .. reached .. "\" reaches this program's own file, " ..
        program .. ", which holds modules the database " .. database .. " leaves out: " ..
        "a program on a database is given the core and the database alone (a profile's " ..
        "grant of a directory above it, as \"system\"'s /usr is for a program installed " ..
        "there, is such a grant: leave the profile out)"
    end
  end
  return found, ""
end

--- The kernel's release, as uname(2) answers it, or "" where it fails.
local function kernel_release(): string
  local names, _ = sys.uname()
  return names ~= nil and names.release or ""
end

--- What a program started under `isolate` with no `processes` of its
--- own is held to: the count of its whole user namespace.
local DEFAULT_PROCESSES <const> = 4096

--- The `processes` limit a start sets, as RLIMIT_NPROC, or nil for none,
--- and why not: the policy's own, or [`DEFAULT_PROCESSES`] under `isolate`,
--- both held by the kernel's count of the processes and threads of the
--- sandbox's user namespace, which only a kernel from Linux 5.17 keeps
--- apart from its creator's (an older one's counts every process of the
--- user the namespace was made by, so a limit would hold the caller's
--- other processes too). The default is dropped where the kernel is
--- older, and a limit the policy names fails there; either is lowered
--- to this process's hard limit if that is lower, but only the default
--- may be: a limit the policy names above it fails.
local function process_limit(merged: Rules.Policy, isolated: boolean): integer | nil, string
  local named_limit = merged.limits.processes
  if not isolated then return nil, "" end
  local release = kernel_release()
  if release ~= "" and not Rules.counts_per_namespace(release) then
    if named_limit == nil then return nil, "" end
    return nil, "limits.processes needs a kernel that counts the processes of a user " ..
      "namespace apart from its creator's user, Linux 5.17 or a stable kernel with the fix: " ..
      "this one is " .. release
  end
  local wanted = named_limit or DEFAULT_PROCESSES
  local held, _ = sys.getrlimit(sys.RLIMIT_NPROC)
  if held ~= nil and held.hard < wanted then
    if named_limit ~= nil then
      return nil, "limits.processes " .. named_limit .. " is above this process's own hard " ..
        "limit on processes, " .. held.hard .. ", which a child cannot raise"
    end
    return held.hard, ""
  end
  return wanted, ""
end

--- Makes a policy's start: merges it, refuses what is not yet available
--- and a program its grants do not let start, then builds the
--- environment, the limits, what isolates it and, for `tmp`, the
--- directory. Nil and why when it cannot. It acquires nothing: `tmp`'s
--- directory is [`make_tmp`]'s.
local function held_to(argv: {string}, opts: Options): Held | nil, string
  local merged, why = Rules.merge(opts.policy)
  if merged == nil then return nil, why end
  local trouble = unmet(merged)
  if trouble ~= "" then return nil, "sandbox: " .. trouble end
  local relayed = #merged.connect > 0
  if relayed then
    local variables: {string} = {}
    for _, name in ipairs(merged.env) do variables[#variables + 1] = name end
    for name, _ in pairs(merged.set_env) do variables[#variables + 1] = name end
    table.sort(variables)
    local reserved = RelayConfig.reserved(variables)
    if reserved ~= "" then
      return nil, "sandbox: " .. reserved .. " is set by the relay that serves connect \"" ..
        merged.connect[1] .. "\" (the proxy variables point the program at it), so the policy " ..
        "may not name it in env or set_env"
    end
  end
  local file = isolates(merged, "file")
  local proc = isolates(merged, "proc")
  local nest = nests(merged)
  -- Under `isolate` file, `tmp` makes the sandbox's own /tmp, which a grant
  -- of "/tmp" with no `from` is the letters of: `rwc`, which is what it is,
  -- or `rwxc`, a /tmp that may run what is made there. It is no bind of the
  -- host's /tmp, so it is no grant of the root's.
  local tmp_exec = false
  if file and merged.tmp then
    local others: {Rules.Grant} = {}
    for _, grant in ipairs(merged.grants) do
      if grant.from == nil and named(grant.path, "/") == "/tmp" then
        if grant.letters ~= "rwc" and grant.letters ~= "rwxc" then
          return nil, "sandbox: grant \"" .. grant.path .. "\" (" .. grant.letters .. ") is the " ..
            "sandbox's own /tmp, which tmp makes: it is `rwc`, and `rwxc` where the program is to " ..
            "run what it makes there"
        end
        tmp_exec = lettered(grant.letters, "x")
      else
        others[#others + 1] = grant
      end
    end
    merged.grants = others
  end
  -- The directory the root of `isolate` file is built around, and the one
  -- the program starts in there: the caller's (or `cwd`'s) real path, which
  -- is what the grants' names are relative to.
  local base: string = opts.cwd
  if file then
    local here, here_trouble = sys.realpath(opts.cwd or ".")
    if here == nil then return nil, "sandbox: cwd " .. (opts.cwd or ".") .. ": " .. here_trouble end
    base = here
  end
  -- Where this process is root its program runs as a user of its own.
  -- A policy that makes no namespace -- no isolation, no network of its
  -- own -- gives root up for that user directly (spawn's `credentials`),
  -- as an unprivileged caller's child runs as it, so it needs no procfs
  -- of its own, which a container masking /proc refuses. One that makes a
  -- namespace maps the user into it from outside.
  local user, user_trouble = mapped_user(merged)
  -- This program, granted, runs by a relaunch of its core, which is granted
  -- with it: what runs is the file the grant names, through its core. On a
  -- `database` it is the core and that file alone, so this program's own
  -- file, which holds every module of the tree, is none of the child's.
  local relaunch: Proc.Relaunch
  local database: string = merged.database
  local found, relaunch_trouble = core_of(argv, opts, merged, user, base, merged.grants)
  if found == nil and relaunch_trouble ~= "" then return nil, relaunch_trouble end
  -- A core on a database is started by path with no descriptor, so
  -- `nest` may run it: the root binds the core and the database read-only
  -- (no `w`, no `c`), and once the child makes a user namespace of its own
  -- the kernel locks those binds (MNT_LOCK_READONLY, MNT_LOCKED).
  -- A portable artifact hands its artifact and core as descriptors, which
  -- [`nest_descriptors`] must refuse.
  -- TODO: run a portable artifact under `nest` too, once its
  -- relaunch runs on a database (a core and a file, no descriptor), or
  -- nest_descriptors can hand its descriptors of read-only regular
  -- files, which a child may reopen for writing through /proc/self/fd
  -- where its user may.
  if found ~= nil and nest and next(found.fds) ~= nil then
    return nil, "sandbox: this program runs from descriptors of its artifact and core, " ..
      "which the \"nest\" promise refuses a child"
  end
  if found ~= nil then
    relaunch = found
    merged.grants[#merged.grants + 1] = { path = found.argv[1], letters = "rx" }
    -- A core on a database reads it, on its own start and on every
    -- relaunch of its own; the grant is what a start that stays on it
    -- needs, whether the database is the policy's or this process's.
    if found.argv[2] == "--database" then
      merged.grants[#merged.grants + 1] = { path = found.argv[3], letters = "r" }
    end
  end
  local idmap: {boolean} = {}
  local drop: MappedUser
  if user ~= nil then
    local here, here_trouble = sys.realpath(opts.cwd or ".")
    if here == nil then return nil, "sandbox: cwd " .. (opts.cwd or ".") .. ": " .. here_trouble end
    local reached, reach_trouble = reached_by(merged, here, file, user)
    if reached == nil then return nil, "sandbox: " .. reach_trouble end
    idmap = reached
    if file or proc or #merged.loopback > 0 or relayed or isolated_unix(merged) then
      proc = true
      -- The namespace is mapped from outside with this process's own group
      -- beside the program's, which may not be one id twice.
      if user.gid == effective_group() then
        return nil, "sandbox: group " .. user.gid .. " is this process's own, which its " ..
          "program's user namespace maps beside the program's: name another group, or a " ..
          "policy that makes no namespace"
      end
    else
      drop = user
    end
  end
  local root: raw_process.Unveil
  if file and isolated_unix(merged) then
    local unheld = unix_unheld(merged, base, nest)
    if unheld ~= "" then return nil, "sandbox: " .. unheld end
  end
  if nest then
    local unheld = nest_unheld(merged, base)
    if unheld ~= "" then return nil, "sandbox: " .. unheld end
  end
  if file then
    local made, root_trouble = root_of(merged, base, idmap, nest, tmp_exec)
    if made == nil then return nil, "sandbox: " .. root_trouble end
    root = made
  end
  -- A bare name is found on this process's PATH and run by its real path,
  -- so what is granted is what runs; a name with a slash is run as written
  -- (a virtual environment's interpreter link keeps its prefix), and its
  -- grants are the real path's, which is what the kernel opens.
  -- TODO: run a link as the link under `isolate` file too, binding it at
  -- its name (a virtual environment's interpreter), once a bind can place
  -- a link: a root holds the real path alone, so the program is run by it.
  local path = argv[1]
  if relaunch ~= nil then
    path = relaunch.argv[1]
  elseif not path:find("/", 1, true) then
    local on_path, absent = Proc.find(path)
    if on_path == nil then return nil, absent end
    local real, real_trouble = sys.realpath(on_path)
    if real == nil then return nil, on_path .. ": " .. real_trouble end
    path = real
  elseif file then
    local real, real_trouble = sys.realpath(named(path, base))
    if real == nil then return nil, path .. ": " .. real_trouble end
    path = real
  end
  local files, loader_trouble = Rules.loaders(path, base)
  if files == nil then return nil, loader_trouble end
  -- Under `isolate` file the program runs from where the host has it, so
  -- only a grant at its own name gives it: one with `from` shows another.
  local checked = merged.grants
  if file then
    checked = {}
    for _, grant in ipairs(merged.grants) do
      if grant.from == nil then checked[#checked + 1] = grant end
    end
  end
  local missing = ungranted(files, checked, base)
  if missing ~= "" then return nil, "sandbox: " .. missing end
  if file and not holds_place(merged.grants, base) then
    return nil, "sandbox: under isolate file the root holds only what is granted, so the " ..
      "directory the program starts in, " .. string.format("%q", base) .. ", must be at, " ..
      "beneath or above a grant: grant it, or start in a directory that is"
  end

  local grants: {raw_process.Grant} = {}
  local unix = false
  for _, grant in ipairs(merged.grants) do
    local at = grant.from or grant.path
    if base ~= nil and at:sub(1, 1) ~= "/" then at = base .. "/" .. at end
    grants[#grants + 1] = { path = at, access = grant.letters }
    if lettered(grant.letters, "u") then unix = true end
  end
  local env: {string:string} = {}
  for _, name in ipairs(merged.env) do
    local value = sys.getenv(name)
    if value ~= nil then env[name] = value end
  end
  for name, value in pairs(merged.set_env) do env[name] = value end
  if relayed then
    for name, value in pairs(RelayConfig.proxy_env(merged.loopback)) do env[name] = value end
  end
  local run_argv: {string}
  if relaunch ~= nil then
    for name, value in pairs(relaunch.env) do env[name] = value end
    -- A file it runs is run as `--standalone`, writing no o/ in a
    -- directory its user may not own, unless the policy says otherwise.
    if env.COSMIC_STANDALONE == nil then env.COSMIC_STANDALONE = "1" end
    run_argv = {}
    for _, word in ipairs(relaunch.argv) do run_argv[#run_argv + 1] = word end
    for i = 2, #argv do run_argv[#run_argv + 1] = argv[i] end
  end
  local open_files = merged.limits.open_files
  if open_files == nil then
    open_files = DEFAULT_OPEN_FILES
    local held, _ = sys.getrlimit(sys.RLIMIT_NOFILE)
    -- A default is no reason to fail where this process's own hard limit is lower.
    if held ~= nil and held.hard < open_files then open_files = held.hard end
  end
  local rlimits: {string:integer} = { nofile = open_files, core = 0 }
  rlimits.fsize = merged.limits.file_bytes
  rlimits.cpu = merged.limits.cpu_seconds
  local counted, count_trouble = process_limit(merged, file or isolates(merged, "proc"))
  if counted == nil and count_trouble ~= "" then return nil, "sandbox: " .. count_trouble end
  -- A malformed policy is refused for its own rule even where this root
  -- cannot map a child: the static checks above need no mapped user.
  if user == nil and user_trouble ~= "" then return nil, "sandbox: " .. user_trouble end
  rlimits.nproc = counted
  local promises: {string} = {}
  for _, promise in ipairs(merged.promises) do promises[#promises + 1] = promise end
  -- A network namespace of its own with a loopback holds the network of a
  -- program that declares addresses of it, has a relay to reach, or has a
  -- unix socket to reach: the filter then lets it make inet sockets (the
  -- namespace is their hold) when it declared a loopback or `connect`, and
  -- unix ones when it was granted `u`.
  local inet = #merged.loopback > 0 or relayed
  local sockets: {string} = {}
  if unix then sockets[#sockets + 1] = "unix" end
  if inet then sockets[#sockets + 1] = "inet" end
  -- Under `nest` no ruleset holds the paths: the kernel refuses a mount to
  -- a process Landlock holds, so the root, which only the grants are bound
  -- into, does ([`nest_unheld`]).
  local sandbox: raw_process.Sandbox = { grants = not nest and grants or nil, promises = promises,
    rlimits = rlimits,
    sockets = sockets, offline = inet or unix, strict = file or proc or inet or unix,
    proc = proc and not file, user = user ~= nil and drop == nil and user.uid or nil,
    group = user ~= nil and drop == nil and user.gid or nil }
  if root ~= nil then
    sandbox.unveil = root
    if merged.tmp then
      -- A normalized path beneath /tmp (no empty, `.` or `..` component)
      -- that `set_env` names stays TMPDIR: the program makes it, in the /tmp
      -- it has. Any other value is /tmp.
      local chosen = merged.set_env.TMPDIR
      local normal = chosen ~= nil and chosen:find("^/tmp/[^/]") ~= nil
      if normal then
        for part in chosen:gmatch("[^/]*") do
          if part == "." or part == ".." then normal = false end
        end
        normal = normal and chosen:find("//", 1, true) == nil and chosen:sub(-1) ~= "/"
      end
      if not normal then env.TMPDIR = "/tmp" end
    end
  end
  if relaunch ~= nil and database ~= nil then
    -- TODO: close the gap between this check and the core's open: the core
    -- reopens the database by its path after the hash, so a file swapped
    -- in that instant runs. Hand it the checked descriptor once core/main.c
    -- opens SQLite on the descriptor it checked (the TODO in open_database).
    local holds, held_why = Rules.database_is(merged, relaunch.argv[3])
    if not holds then return nil, "sandbox: " .. held_why end
  end
  return { path = path, env = env, tmp = "", wants_tmp = merged.tmp and not file,
    sandbox = sandbox, cwd = file and base or nil, user = user, drop = drop, nests = nest,
    argv = run_argv, fds = relaunch ~= nil and relaunch.fds or nil,
    relay = relayed and merged.connect or nil }, ""
end

--- Whether this host holds a policy's child by Seatbelt, which is how
--- macOS holds one, and Linux's Landlock and seccomp are not there.
local function holds_by_seatbelt(): boolean
  local names, _ = sys.uname()
  return names ~= nil and names.sysname == "Darwin"
end

--- A policy's start on macOS: the profile [`Seatbelt.compile`] makes of
--- it, with the paths it names resolved on this host, for spawn to apply
--- before it runs the program, and the environment and limits the policy
--- gives. Nil and why for a policy Seatbelt cannot hold or not yet: its
--- own refusals, for `isolate`, `connect`, `loopback`, `nest`, `from`,
--- `limits.processes` and a digest without its value.
--- It acquires nothing.
local function held_by_seatbelt(argv: {string}, opts: Options, pty?: Pty): Held | nil, string
  local merged, why = Rules.merge(opts.policy)
  if merged == nil then return nil, why end
  -- The child leads a session of its own, so that it has no controlling
  -- terminal (the caller's would let it push input into the caller's
  -- session): a session is a group of its own too, so a start that wants
  -- the caller's group is refused rather than given another.
  if opts.process_group == false then
    return nil, "sandbox: a policy's child on macOS leads a session, and so a process group, of " ..
      "its own, so process_group = false is refused"
  end
  local own: string
  local executable, _ = Proc.executable()
  if executable ~= nil then
    local real, _ = sys.realpath(executable)
    own = real
  end
  -- The pty's slave, where stdin is on it, is the child's controlling
  -- terminal, which the profile grants and /dev/tty with it.
  local terminal = pty ~= nil and pty.streams[0] and pty.name or nil
  -- This program, granted, and a program on a `database` run as their
  -- core, as Linux's start has them ([`core_of`]): the launcher would fork
  -- and unpack a core into a cache the profile does not grant. The profile
  -- grants that core `rx` and, where it runs on a database, the database
  -- `r` alone: the core opens it read-only and immutable.
  local relaunch, core_trouble = core_of(argv, opts, merged, nil, opts.cwd, Seatbelt.grants(opts.policy))
  if relaunch == nil and core_trouble ~= "" then return nil, core_trouble end
  local core: string
  local sealed: string
  if relaunch ~= nil then
    local real, real_trouble = sys.realpath(relaunch.argv[1])
    if real == nil then return nil, "sandbox: " .. relaunch.argv[1] .. ": " .. real_trouble end
    core = real
    merged.grants[#merged.grants + 1] = { path = core, letters = "rx" }
    if relaunch.argv[2] == "--database" then
      sealed = relaunch.argv[3]
      merged.grants[#merged.grants + 1] = { path = sealed, letters = "r" }
    end
  end
  -- TODO: decide whether the profile should let a program getcwd in a
  -- directory it grants nothing of: on the macOS leg a shell (bash as
  -- /bin/sh) started in one prints "shell-init: error retrieving current
  -- directory: getcwd: cannot access parent directories" and goes on, as
  -- Linux's Landlock start never does. Until then a start whose output is
  -- compared (test/terminal) gives the program the root as its `cwd`.
  local options, resolve_trouble = Seatbelt.resolve(opts.policy, opts.cwd, own, core, sealed, terminal)
  if options == nil then return nil, "sandbox: " .. resolve_trouble end
  local profile, compile_trouble = Seatbelt.compile(opts.policy, options)
  if profile == nil then return nil, "sandbox: " .. compile_trouble end
  local path = core or argv[1]
  if core == nil and not path:find("/", 1, true) then
    local found, absent = Proc.find(path)
    if found == nil then return nil, absent end
    local real, real_trouble = sys.realpath(found)
    if real == nil then return nil, found .. ": " .. real_trouble end
    path = real
  end
  -- The program, and an interpreter its `#!` line names, are the first to
  -- fail a profile that does not grant them, as an EPERM of the exec,
  -- which this says in words.
  local files, loader_trouble = Rules.loaders(path, opts.cwd)
  if files == nil then return nil, loader_trouble end
  local missing = ungranted(files, merged.grants, opts.cwd)
  if missing ~= "" then return nil, "sandbox: " .. missing end
  local parameters = profile.tmp ~= nil and 1 or 0
  for _, _ in pairs(profile.parameters) do parameters = parameters + 1 end
  if parameters > raw.SEATBELT_PARAMETER_MAX then
    return nil, "sandbox: grants: the paths the profile holds, " .. parameters .. ", are past the " ..
      "most a start takes, " .. raw.SEATBELT_PARAMETER_MAX .. "; grant a directory above them instead"
  end
  local env: {string:string} = {}
  for _, name in ipairs(merged.env) do
    local value = sys.getenv(name)
    if value ~= nil then env[name] = value end
  end
  for name, value in pairs(merged.set_env) do env[name] = value end
  local run_argv: {string}
  if relaunch ~= nil then
    for name, value in pairs(relaunch.env) do env[name] = value end
    -- As under Landlock: run as `--standalone`, writing no o/ beside the
    -- core, unless the policy says otherwise.
    if env.COSMIC_STANDALONE == nil then env.COSMIC_STANDALONE = "1" end
    run_argv = {}
    for _, word in ipairs(relaunch.argv) do run_argv[#run_argv + 1] = word end
    for i = 2, #argv do run_argv[#run_argv + 1] = argv[i] end
  end
  if relaunch ~= nil and merged.database ~= nil then
    local holds, held_why = Rules.database_is(merged, relaunch.argv[3])
    if not holds then return nil, "sandbox: " .. held_why end
  end
  local sandbox: raw_process.Sandbox = {
    seatbelt = { profile = profile.text, parameters = profile.parameters },
    rlimits = profile.rlimits,
  }
  return { path = path, env = env, tmp = "", wants_tmp = merged.tmp, tmp_parameter = profile.tmp,
    sandbox = sandbox, nests = false, seatbelt = true, argv = run_argv,
    fds = relaunch ~= nil and relaunch.fds or nil }, ""
end

--- Makes the temporary directory a policy's `tmp` asks for, as an absolute
--- path whatever TMPDIR is (the child may start in another directory),
--- grants it `rwc` and names it in TMPDIR; it is the child's user's,
--- where that is not this process's. "" or why not.
local function make_tmp(held: Held): string
  local dir, trouble = Fs.mkdtemp("cosmic-sandbox-")
  if dir == nil then return "tmp: " .. trouble end
  local real, real_trouble = sys.realpath(dir)
  if real == nil then
    local _, _ = Fs.remove_tree(dir)
    return "tmp: " .. dir .. ": " .. real_trouble
  end
  if held.user ~= nil then
    local given, given_trouble = sys.chown(real, held.user.uid, held.user.gid)
    if not given then
      local _, _ = Fs.remove_tree(dir)
      return "tmp: " .. real .. ": " .. given_trouble
    end
  end
  held.tmp = real
  if held.seatbelt then
    -- The profile grants the directory through a parameter, left for this.
    held.sandbox.seatbelt.parameters[held.tmp_parameter] = real
  else
    local grants = held.sandbox.grants
    grants[#grants + 1] = { path = real, access = "rwc" }
  end
  held.env.TMPDIR = real
  return ""
end

--- Why a descriptor the child would get cannot be handed to a `nest`
--- child, or "". Landlock, given up there, is what stopped a descriptor
--- reaching past itself: a directory is a way to every file beneath and
--- above it (/proc/self/fd/N/..), and a regular file opened read-only or
--- write-only is reopened through /proc/self/fd/N for what it was not
--- opened for, where its owner (this process's user) may. The root holds no
--- descriptor. So a directory, or a regular file not open for both, is
--- refused, naming it; pipes, sockets and devices have no path to reach.
--- `slots` is [`wire`]'s: the descriptor each child number copies, and
--- 0 to 2 not in it are this process's own.
local function nest_descriptors(slots: {integer:integer}): string
  local numbers: {integer} = {}
  for number, _ in pairs(slots) do numbers[#numbers + 1] = number end
  for number = 0, 2 do
    if slots[number] == nil then numbers[#numbers + 1] = number end
  end
  table.sort(numbers)
  for _, number in ipairs(numbers) do
    local fd = slots[number] or number
    local what = "descriptor " .. number .. (fd ~= number and " (this process's " .. fd .. ")" or "")
    -- The descriptors the runtime retains of its own (its artifact and core,
    -- which a relaunch hands on) are refused to every binding that takes a
    -- descriptor, a stat included, by raising; any other raise is rethrown.
    local looked, st = pcall(sys.fstat, fd)
    if not looked and not tostring(st):find("retained", 1, true) then error(st, 0) end
    if not looked then
      return what .. " is one this runtime retains of its own (its artifact or core), which " ..
        "promises \"nest\" cannot hand a program: it is a file open for reading alone"
    end
    if st ~= nil and st.kind == "dir" then
      return what .. " is a directory, which promises \"nest\" cannot hand a program: " ..
        "with Landlock given up, /proc/self/fd/" .. number .. " opens every file beneath " ..
        "it and, by .., above it, and the root of its own holds no descriptor"
    elseif st ~= nil and st.kind == "file" then
      local info, _ = Fs.read("/proc/self/fdinfo/" .. fd)
      local flags = info ~= nil and info:match("flags:%s*(%d+)") or nil
      local mode = flags ~= nil and (math.tointeger(tonumber(flags, 8)) or 0) & 3 or nil
      if mode ~= 2 then
        return what .. " is a file not open for reading and writing, which promises " ..
          "\"nest\" cannot hand a program: with Landlock given up, /proc/self/fd/" ..
          number .. " reopens it for what it was not opened for wherever its owner may; " ..
          "open it O_RDWR, or pass a pipe"
      end
    end
  end
  return ""
end

--- The module the network relay's process runs: the main of a database
--- sealed for it ([`cosmic.relay_serve`]), which this module cannot require
--- (it and what it requires start children through this one).
local RELAY_MAIN <const> = "cosmic.relay_serve"

--- How long a relay has to say it serves, from its start.
local RELAY_READY_NS <const> = Clock.seconds(30)

--- What a start needs of the relay before it starts the program, so that
--- a start that cannot have one fails with nothing running.
local record RelayPrep
  --- The directory holding the database the relay runs on, which the start
  --- removes once the relay has opened it.
  dir: string
  --- The policy the relay's process is started under.
  policy: Rules.Policy
  --- The relay's config, one line of JSON.
  config: string
  --- Where its decision lines go.
  log: RelayLog | integer
  --- The connectors the relay is handed, which the start closes where the
  --- relay never starts, and the relay's handle once it has.
  handover: RelayConfig.Handover
end

--- The database a relay runs on, in a directory of its own.
local record RelayProgram
  dir: string
  path: string
  --- The SHA-256 of the file, in hex, which the start holds it to.
  digest: string
end

--- Seals [`RELAY_MAIN`] and what it requires into a directory of its own,
--- which the user a root caller's program runs as can search and read
--- (the 0700 one [`Fs.mkdtemp`] makes is shut to it, and its parents are
--- TMPDIR's, which the start says if they are too). The start removes it once
--- the relay has opened the database, before the program exists. Nil and why where this
--- program does not carry the module or the database cannot be written.
local function seal_relay(): RelayProgram | nil, string
  local found, names = pcall(Store.closure, { RELAY_MAIN })
  if not found or not names is {string} then
    return nil, "this program does not carry " .. RELAY_MAIN .. ", the relay's program (" ..
      (tostring(names):gsub("^.-:%d+: ", "")) .. "): a policy with connect needs a program that has it"
  end
  local dir, dir_trouble = Fs.mkdtemp("cosmic-relay-")
  if dir == nil then return nil, dir_trouble end
  local function fail(why: string): nil, string
    local _, _ = Fs.remove_tree(dir)
    return nil, why
  end
  local searchable, search_trouble = sys.chmod(dir, 0x1ed)
  if not searchable then return fail(dir .. ": " .. search_trouble) end
  local path = dir .. "/relay.db"
  local sealed, digest, seal_trouble = pcall(Store.seal, names, path, { main = RELAY_MAIN })
  if not sealed then return fail(RELAY_MAIN .. ": " .. (tostring(digest):gsub("^.-:%d+: ", ""))) end
  if not digest is string then return fail(path .. ": " .. tostring(seal_trouble)) end
  local shared, share_trouble = sys.chmod(path, 0x1a4)
  if not shared then return fail(path .. ": " .. share_trouble) end
  return { dir = dir, path = path, digest = digest }, ""
end

--- A connector of `endpoints` (and `public`'s lists, if given) waiting
--- `wait_ns` for each connection, for the relay: the process, or nil and
--- why. A table or list the core refuses is a why too.
local function relay_connector(endpoints: {raw_process.ConnectorEndpoint}, wait_ns: integer,
                               public?: raw_process.ConnectorPublic): ConnectorProcess | nil, string
  local called, process, why = pcall(Child.start_connector, endpoints, (wait_ns + 999999) // 1000000, public)
  if not called then return nil, (tostring(process):gsub("^.-:%d+: ", "")) end
  if process == nil then return nil, why end
  return process, ""
end

--- The connectors the relay of the `connect` targets `connect` is handed
--- ([`cosmic.sandbox.relay`]), started in this process and network:
--- [`RelayConfig.pool_size`] of the table's, of the addresses a target
--- names literally and the upstream proxy's; and, for a target that names
--- a host the relay reaches directly (no upstream, or one `no_proxy`
--- bypasses for some), the name servers' and as many public ones (refusing
--- the relay's deny list and `own`, the host's own addresses). The
--- upstream's host is resolved once, here, through the name servers'
--- connector. Nil and why, with nothing left running, where the upstream
--- cannot be used or resolved, the table would be past 128, or a
--- connector cannot start. Name servers that cannot be read are no
--- failure: the relay is told why, is handed no public connector, and
--- reaches only what a target names literally, and the upstream.
local function relay_handover(connect: {string}, own: {string}): RelayConfig.Handover | nil, string
  local env: {string: string} = {}
  for _, name in ipairs({ "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY" }) do
    env[name] = sys.getenv(name)
  end
  local planned, plan_why = SandboxRelay.plan(connect, env)
  if planned == nil then return nil, plan_why end
  local plan: Rules.Relay.Plan = planned
  local processes: {ConnectorProcess} = {}
  local closed = false
  local function close()
    if closed then return end
    closed = true
    for _, process in ipairs(processes) do local _ = process:close() end
  end
  local function fail(why: string): nil, string
    close()
    return nil, why
  end
  local config: RelayConfig.Config = { grants = connect, own_addresses = own, log = "null", tables = 0, public = 0 }
  local fds: {integer: integer} = {}
  local up = plan.upstream
  local through: Rules.Relay.Through
  local dns: ConnectorProcess
  local unresolved = ""
  -- A name is reached directly, and so resolved and connected by the relay
  -- itself, only with no upstream or one that no_proxy bypasses for some.
  local direct = plan.names and (up == nil or #up.no_proxy > 0)
  if direct or (up ~= nil and Address.parse(up.host) == nil) then
    local servers, servers_why = SandboxRelay.name_servers()
    if servers == nil then
      unresolved = servers_why
    else
      local started, dns_why = relay_connector(servers.servers, servers.wait_ns)
      if started == nil then return fail("the name servers' connector: " .. dns_why) end
      dns = started
      processes[#processes + 1] = started
      through = { fd = started.fd, name_servers = servers }
    end
  end
  local addresses: {string}
  if up ~= nil then
    local found, found_why = SandboxRelay.upstream_addresses(up, through, unresolved)
    if found == nil then return fail(found_why) end
    addresses = found
    config.upstream_addresses = found
  end
  local rows, rows_why = SandboxRelay.table(plan, addresses)
  if rows == nil then return fail(rows_why) end
  -- TODO: hand the relay one table connector and one public connector that
  -- each make several connections at once, once core/connector.c's protocol
  -- tags each request and its reply so that one process serves several
  -- connects (a change of its own): each of these makes one at a time, so
  -- RelayConfig.pool_size connects that hang, to the upstream proxy or to a
  -- granted name, hold every other connection of their kind.
  if #rows > 0 then
    config.table = rows
    for i = 1, RelayConfig.pool_size do
      local process, why = relay_connector(rows, RelayConfig.connect_ns)
      if process == nil then return fail("table connector " .. i .. ": " .. why) end
      processes[#processes + 1] = process
      config.tables, fds[RelayConfig.table_fd + i - 1] = i, process.fd
    end
  end
  if direct and through == nil then
    -- No name resolves: the public connectors would reach nothing.
    config.unresolved = unresolved
  elseif direct then
    for i = 1, RelayConfig.pool_size do
      local process, why = relay_connector({}, RelayConfig.connect_ns, SandboxRelay.public(own))
      if process == nil then return fail("public connector " .. i .. ": " .. why) end
      processes[#processes + 1] = process
      config.public, fds[RelayConfig.public_fd + i - 1] = i, process.fd
    end
    config.name_servers, config.name_server_wait_ns = through.name_servers.servers, through.name_servers.wait_ns
    fds[RelayConfig.name_server_fd] = through.fd
  elseif dns ~= nil then
    -- Only the upstream's lookup needed it: the relay resolves no name, as
    -- every name goes through the upstream.
    local _ = dns:close()
  end
  return { config = config, fds = fds, close = close }, ""
end

--- What the relay of a policy with `connect` needs before a program is
--- started: the host's own addresses, the sealed database, the connectors
--- it is handed, started, and the config. Nil and why, with nothing left
--- running, where it cannot have them.
local function prepare_relay(connect: {string}, opts: Options): RelayPrep | nil, string
  -- A descriptor given as the relay's log is the relay's standard error, on
  -- which a terminal is refused as for any sandboxed process; say so naming
  -- the option, not the relay's own start. The descriptors this program
  -- retains for itself raise when asked (every binding refuses them).
  local logged = opts.relay_log
  if logged is integer then
    local looked, terminal = pcall(isatty, logged)
    if not looked then
      return nil, "relay_log " .. logged .. " is a descriptor this program keeps for itself"
    elseif terminal then
      return nil, "relay_log " .. logged .. " is a terminal, which a sandboxed relay may not hold as its " ..
        "standard error: give a pipe, or \"inherit\" where this process's standard error is not one"
    end
  end
  -- The host's own addresses are read once, here: an address the host gains
  -- while the program runs is not refused by this relay.
  local addresses, address_trouble = RelayConfig.host_addresses()
  if addresses == nil then return nil, address_trouble end
  local program, seal_trouble = seal_relay()
  if program == nil then return nil, seal_trouble end
  local handover, handover_trouble = relay_handover(connect, addresses)
  if handover == nil then
    local _, _ = Fs.remove_tree(program.dir)
    return nil, handover_trouble
  end
  local log = opts.relay_log or "null"
  local config = handover.config
  config.https_proxy = sys.getenv("https_proxy") or sys.getenv("HTTPS_PROXY")
  config.no_proxy = sys.getenv("no_proxy") or sys.getenv("NO_PROXY")
  config.log = log == "null" and "null" or "stderr"
  return { dir = program.dir, policy = SandboxRelay.policy(program.path, program.digest),
    config = RelayConfig.encode(config), log = log, handover = handover }, ""
end

--- Removes the database `prep` sealed, which the relay has opened or never
--- will.
local function abandon_relay(prep: RelayPrep | nil)
  if prep ~= nil then
    local _, _ = Fs.remove_tree(prep.dir)
  end
end

--- A relay process started, and the lines it says on its standard output,
--- which the start reads through two stages.
local record RelayLaunch
  handle: Handle
  lines: Stream.Lines
end

--- Ends `relay` at once, and the connectors it was handed, for a start
--- that goes no further.
local function kill_relay(relay: Handle)
  local _, _ = sys.kill(target(relay), sys.SIGKILL)
  local _, _ = end_or_kill(relay)
  if relay._handover ~= nil then relay._handover.close() end
end

--- What a relay that ended without the line a start waits for tells, as
--- `how` ended it and `read_trouble` is why its output failed.
local function relay_ended(relay: Handle, read_trouble: string, log: RelayLog | integer): string
  local ended, _ = end_or_kill(relay)
  local how = ended ~= nil and ended.signal ~= nil and "signal " .. ended.signal or
    "status " .. tostring(ended ~= nil and ended.code or "unknown")
  return "the relay ended (" .. how .. ") before it served" ..
    (read_trouble ~= "" and ": " .. read_trouble or "") ..
    (log ~= "null" and "" or "; start with relay_log = \"inherit\" to see why")
end

--- Reads the relay's next line, which must be `wanted`: true; or false and
--- why, the relay ended. A relay that said `error: why` fails with why.
local function relay_says(launch: RelayLaunch, wanted: string, log: RelayLog | integer): boolean, string
  local line, read_trouble = launch.lines:read()
  if line == wanted then return true, "" end
  if line ~= nil then
    kill_relay(launch.handle)
    return false, (line:gsub("^error: ", ""))
  end
  return false, relay_ended(launch.handle, read_trouble, log)
end

--- Waits for the relay to say it serves, which it does once the program's
--- listeners have reached it. Nil of the relay's deadline then: it lives as
--- long as the program does.
local function await_relay(launch: RelayLaunch, log: RelayLog | integer): boolean, string
  local said, why = relay_says(launch, "ready", log)
  if not said then return false, why end
  launch.handle._deadline = nil
  return true, ""
end

--- [`Child.start`] on options already validated. With `pty`, one that
--- [`Child.start_on_pty`] has just made, the standard streams it names are
--- its slave, which is not refused as a terminal is; stream 0 among them
--- also makes it the child's controlling terminal.
local begin_relay: function(RelayPrep, integer): RelayLaunch | nil, string

local function start(argv: {string}, opts: Options, pty?: Pty): Handle | nil, string
  -- Refuse an explicit terminal before inspecting any platform policy:
  -- it needs a relay even on a host that cannot apply that policy.
  if opts.policy ~= nil then
    local streams: {integer: integer | string} = { [0] = opts.stdin, [1] = opts.stdout, [2] = opts.stderr }
    for number, stream in pairs(streams) do
      if stream is integer and isatty(stream) then
        return refuse("start: sandbox: terminal stdio[" .. number .. "] needs the verb's pty relay")
      end
    end
  end
  local held: Held
  if opts.policy ~= nil then
    local made: Held | nil
    local why: string
    if holds_by_seatbelt() then
      made, why = held_by_seatbelt(argv, opts, pty)
    else
      made, why = held_to(argv, opts)
    end
    if made == nil then return refuse("start: " .. why) end
    held = made
  end
  local grouped = opts.process_group
  if grouped == nil then grouped = true end
  if grouped and adopting == nil then
    local subreaper, _ = raw.subreaper()
    adopting = subreaper
  end
  local wiring: Wiring = { child_ends = {}, ours = {}, streams = {} }
  local slots, wire_trouble = wire(opts, wiring, pty)
  if slots == nil then
    unwire(wiring, false)
    return refuse("start: " .. wire_trouble)
  end
  if held ~= nil then
    -- A terminal on any descriptor the child holds, not only stdio, lets it
    -- inject input (TIOCSTI) into the caller's session. The descriptors the
    -- runtime retains of its own (its artifact and core) are files, and
    -- every binding refuses them by raising; any other raise is rethrown.
    for number = 0, 2 do
      local fd = slots[number] or number
      if not (pty ~= nil and pty.streams[number]) and isatty(fd) then
        unwire(wiring, false)
        return refuse("start: sandbox: terminal stdio[" .. number .. "] needs the verb's pty relay")
      end
    end
    for number, fd in pairs(slots) do
      local looked, terminal = true, false
      if number > 2 then looked, terminal = pcall(isatty, fd) end
      if not looked and not tostring(terminal):find("retained", 1, true) then error(terminal, 0) end
      if looked and terminal then
        unwire(wiring, false)
        return refuse("start: sandbox: terminal fds[" .. number .. "] needs the verb's pty relay")
      end
    end
  end
  if held ~= nil and held.nests then
    local why = nest_descriptors(slots)
    if why ~= "" then
      unwire(wiring, false)
      return refuse("start: sandbox: " .. why)
    end
  end
  local extra: {integer:integer}
  for number, fd in pairs(slots) do
    if number > 2 then
      extra = extra or {}
      extra[number] = fd
    end
  end
  if held ~= nil and held.fds ~= nil then
    for number, fd in pairs(held.fds) do
      if slots[number] ~= nil then
        unwire(wiring, false)
        return refuse("start: sandbox: fds[" .. number .. "] is a descriptor this program's " ..
            "relaunch hands it (its artifact or core) on: name another")
      end
      extra = extra or {}
      extra[number] = fd
    end
  end
  -- TODO: offer the rest of spawn's `sandbox` -- a ruleset from
  -- raw.landlock_ruleset, a pledge -- once a caller wants a child held
  -- to one: build/sandbox_probe.tl, which reaches the raw table for them.
  local sandbox: raw_process.Sandbox = nil
  if opts.sandbox ~= nil then
    local given = opts.sandbox.unveil
    sandbox = { offline = opts.sandbox.offline == true,
      noexec_scratch = opts.sandbox.noexec_scratch == true, user = opts.sandbox.user,
      group = opts.sandbox.group }
    if given ~= nil then
      sandbox.unveil = { reads = given.reads or {}, writes = given.writes or {}, at = given.at }
    end
  end
  local credentials: raw_process.Credentials
  if opts.credentials ~= nil then
    credentials = { user = opts.credentials.user, group = opts.credentials.group }
  end
  local path, env, cwd = argv[1], opts.env, opts.cwd
  local prep: RelayPrep
  local channel: {integer}
  local early: RelayLaunch
  if held ~= nil then
    path, env, sandbox = held.path, held.env, held.sandbox
    if held.drop ~= nil then credentials = { user = held.drop.uid, group = held.drop.gid } end
    if held.cwd ~= nil then cwd = held.cwd end
    if held.relay ~= nil then
      -- The relay starts first and opens its database before the program
      -- exists: the database is then removed, so no program can swap it
      -- while the relay opens it. The relay waits for the program's
      -- listeners on its end of this channel.
      local made, relay_trouble = prepare_relay(held.relay, opts)
      if made == nil then
        unwire(wiring, false)
        return refuse("start: sandbox: relay: " .. relay_trouble)
      end
      prep = made
      local pair, pair_trouble = raw.connector_pair()
      if pair == nil then
        unwire(wiring, false)
        abandon_relay(prep)
        prep.handover.close()
        return refuse("start: sandbox: relay: " .. pair_trouble)
      end
      channel = pair
      local launched: RelayLaunch
      local launch_trouble = ""
      local ok, raised = pcall(function()
        local began, why = begin_relay(prep, pair[2])
        launched, launch_trouble = began, why
      end)
      if not ok then launched, launch_trouble = nil, tostring(raised) end
      local _, _ = sys.close(pair[2])
      abandon_relay(prep)
      if launched == nil then
        unwire(wiring, false)
        local _, _ = sys.close(pair[1])
        prep.handover.close()
        return refuse("start: sandbox: relay: " .. launch_trouble)
      end
      early = launched
      sandbox.relay = { fd = pair[1], ports = { RelayConfig.http_port, RelayConfig.socks_port } }
    end
    if held.wants_tmp then
      local why = make_tmp(held)
      if why ~= "" then
        unwire(wiring, false)
        if channel ~= nil then
          local _, _ = sys.close(channel[1])
          kill_relay(early.handle)
        end
        return refuse("start: sandbox: " .. why)
      end
    end
  end
  -- Nothing but the spawn lies between the directory's making and its
  -- owner, the handle: a spawn that raises (an argument it refuses) must
  -- not leave it, nor the descriptors wired, behind.
  local run_argv = held ~= nil and held.argv or argv
  -- The pty's path is the terminal where stdin is on it.
  local terminal: boolean | string = false
  if pty ~= nil and pty.streams[0] then terminal = pty.name or true end
  local called, pid, trouble, errno = pcall(raw.spawn, path, run_argv, env, cwd,
    slots[0], slots[1], slots[2], grouped, extra, sandbox, credentials, terminal)
  if not called then
    unwire(wiring, false)
    if channel ~= nil then
      local _, _ = sys.close(channel[1])
      kill_relay(early.handle)
    end
    if held ~= nil and held.tmp ~= "" then
      local _, _ = Fs.remove_tree(held.tmp)
    end
    error(pid, 0)
  end
  unwire(wiring, pid ~= nil)
  if channel ~= nil then
    -- The program's end of the channel is its own now.
    local _, _ = sys.close(channel[1])
  end
  if not pid then
    if channel ~= nil then kill_relay(early.handle) end
    if held ~= nil and held.tmp ~= "" then
      local _, _ = Fs.remove_tree(held.tmp)
    end
    if held ~= nil and held.seatbelt and errno == sys.ENOSYS then
      trouble = trouble .. ": this system has no sandbox_init_with_parameters, which holds a " ..
        "policy's child by Seatbelt"
    elseif held ~= nil and held.seatbelt and errno == sys.EPERM and
        trouble:find("execve", 1, true) then
      -- The profile held the start itself: what it runs is the one thing it
      -- must grant.
      trouble = trouble .. ": a child held by Seatbelt needs an `rx` grant for its program, " ..
        "and the \"system\" profile for the host's own files it loads"
    elseif held ~= nil and errno == sys.ENOSYS then
      trouble = trouble .. ": a policy is held by Landlock and seccomp, which only Linux gives"
    elseif (errno == sys.ENOENT or errno == sys.ENOTDIR) and missing_cwd(opts) then
      trouble = trouble .. ": cwd " .. string.format("%q", opts.cwd) .. " does not exist"
    elseif errno == sys.ENOENT and unfound_name(argv[1], opts.cwd) then
      trouble = trouble .. ": " .. string.format("%q", argv[1]) ..
        " is run as a path, with no PATH search; Proc.find(" ..
        string.format("%q", argv[1]) .. ") answers where a shell would find it"
    elseif errno == sys.EINVAL or errno == sys.EMFILE then
      trouble = trouble .. descriptor_limit_hint(slots)
    end
    return refuse("start: " .. trouble)
  end
  local deadline: integer
  if opts.timeout_ns ~= nil then deadline = now() + opts.timeout_ns end
  local h = make_handle(pid, grouped, opts.capture_limit or DEFAULT_CAPTURE_LIMIT, deadline)
  if held ~= nil and held.tmp ~= "" then h._tmp = held.tmp end
  if #wiring.streams > 0 then h._streams = wiring.streams end
  if wiring.input_fd ~= nil then
    h._input_fd, h._input, h._input_at = wiring.input_fd, opts.input, 0
    if #opts.input == 0 then end_input(h) end
  end
  if wiring.feed_fd ~= nil then
    h._feed_fd = wiring.feed_fd
    h.stdin_stream = feed_writer(h)
  end
  for index, stream in ipairs(wiring.streams) do
    if stream.streamed then
      local reader = pipe_reader(h, index)
      if stream.child_fd == 1 then h.stdout_stream = reader else h.stderr_stream = reader end
    end
  end
  -- Opened last, once the handle is whole, so nothing that allocates
  -- comes between it and the handle taking it; and before anything
  -- reaps the child, as nothing since the spawn has called `collect`. A child with none -- where the
  -- platform or a filter gives none -- has its exit looked for every
  -- POLL_NS instead.
  local watch, _ = raw.exit_watch(pid)
  if watch ~= nil then h._exit_fd = watch end
  if channel ~= nil then
    h._relay = early.handle
    local served = false
    local serve_trouble = ""
    local ok, raised = pcall(function()
      served, serve_trouble = await_relay(early, prep.log)
    end)
    if not ok then served, serve_trouble = false, tostring(raised) end
    if not served then
      -- A program with no way out is no program the policy described.
      kill_relay(early.handle)
      local _, _ = sys.kill(target(h), sys.SIGKILL)
      local _, _ = end_or_kill(h)
      return refuse("start: sandbox: relay: " .. serve_trouble)
    end
  end
  return h, ""
end

--- Starts the relay's process of `prep` as a child of its own: this
--- program's core on the sealed database, whose descriptor 3 is `channel`,
--- the end of the program's relay channel that will carry the listeners,
--- whose descriptors from 4 are the control streams of the connectors it
--- is handed, and whose standard input carries the config and, held open,
--- keeps it alive. The relay's handle owns the connectors from then on.
--- It answers once the relay says it has opened its database, which it
--- does before it waits for the listeners: the database is then no longer
--- needed. Nil and why where it cannot start or ends first.
begin_relay = function(prep: RelayPrep, channel: integer): RelayLaunch | nil, string
  local program, program_trouble = Proc.executable()
  if program == nil then return nil, "this program's own file is unknown: " .. program_trouble end
  local logged = prep.log
  local log: integer | Stderr
  if logged is integer then
    log = logged
  else
    log = logged == "inherit" and "inherit" or "null"
  end
  local fds: {integer: integer} = { [3] = channel }
  for number, fd in pairs(prep.handover.fds) do fds[number] = fd end
  local started, trouble = start({ program }, { policy = prep.policy, cwd = "/", stdin = "stream",
    stdout = "stream", stderr = log, fds = fds, capture_limit = 4096, timeout_ns = RELAY_READY_NS })
  if started == nil then return nil, (trouble:gsub("^child: start: ", "")) end
  local relay: Handle = started
  relay._handover = prep.handover
  local feed, reader = relay.stdin_stream, relay.stdout_stream
  if feed == nil or reader == nil then
    kill_relay(relay)
    return nil, "the relay has no standard streams"
  end
  local written, write_trouble = feed:write(prep.config .. "\n")
  if not written then
    kill_relay(relay)
    return nil, "the relay would not take its config: " .. write_trouble
  end
  local launch: RelayLaunch = { handle = relay, lines = Stream.lines(reader) }
  local began, why = relay_says(launch, "opened", prep.log)
  if not began then return nil, why end
  return launch, ""
end

--- Starts one executable and returns an owning handle. argv[1] is an exact
--- path, without PATH lookup: [`Proc.find`] finds a program by
--- name. Dropping or closing a handle whose child is unfinished ends the
--- child and its group; `wait(timeout)` does the same on expiry, and so
--- does a wait once the child's `timeout_ns`, counted from here, has
--- passed. Nothing ends it for `timeout_ns` while nothing waits on it
--- ([`Options.timeout_ns`]).
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  validate(argv, opts)
  return start(argv, opts)
end

--- The two ends of a pty [`Child.start_on_pty`] has opened, closed when
--- it returns or raises: the child holds its own slave once it is
--- started, and ours would keep the master from ever reading the end of
--- the child's output.
local record PtyHolder
  metamethod __close: function(PtyHolder)
  master: integer
  slave: integer
  --- Whether the master is the caller's.
  keep: boolean
  --- Whether the slave is the caller's too.
  keep_slave: boolean
end

local pty_holder_mt: metatable<PtyHolder> = {
  __close = function(self: PtyHolder)
    if not self.keep_slave then
      local _, _ = sys.close(self.slave)
    end
    if not self.keep then
      local _, _ = sys.close(self.master)
    end
  end,
}

--- Starts a program as [`Child.start`] does, with a pty of its own as the
--- standard streams `pty.streams` names, and answers the child with the
--- pty's master. This is the one start that gives a child under a
--- `policy` a terminal, and the only terminal it gives is the one it opens
--- here, whose master the caller holds: a descriptor the caller names
--- never becomes the child's terminal, since a program holding the
--- caller's own terminal could push input into its session and write
--- control sequences to it. A caller that owns the master reads what the
--- child writes and filters it (the `cosmic sandbox` relay does). When
--- stdin is among the streams the child also starts a session of its own
--- with the pty as its controlling terminal, made before the policy's
--- confinement, so `process_group` has no say; without stdin it has none.
--- Under a `policy` on macOS the profile grants the child that terminal
--- and `/dev/tty`, which it is not otherwise given.
--- Nil and why where the pty cannot be opened or the start fails.
--- @param argv the program and its arguments, as [`Child.start`] takes them
--- @param opts the start's options, naming none of the pty's streams
--- @param pty the pty's streams and size
--- @return the child and the master, or nil
--- @return why, when there is none
function Child.start_on_pty(argv: {string}, opts: Options, pty: PtyOptions): PtyStart | nil, string
  validate(argv, opts)
  local streams: {integer:boolean} = {}
  for _, number in ipairs(pty.streams) do
    if not (number is integer) or number < 0 or number > 2 or streams[number] then
      error("child: pty streams are each of 0, 1 and 2 once", 2)
    end
    streams[number] = true
  end
  if next(streams) == nil then error("child: a pty needs at least one stream", 2) end
  if (streams[0] and (opts.stdin ~= nil or opts.input ~= nil)) or
      (streams[1] and opts.stdout ~= nil) or (streams[2] and opts.stderr ~= nil) then
    error("child: a stream on the pty takes no stdin, input, stdout or stderr of its own", 2)
  end
  local made, why = sys.openpty()
  if made == nil then return refuse("pty: " .. why) end
  if pty.rows ~= nil and pty.columns ~= nil then
    local _, _ = sys.setwinsize(made.master, pty.rows, pty.columns)
  end
  -- Closes both ends where the start raises, or fails; the slave on any
  -- return, the master unless the caller is to have it.
  local holding <close>: PtyHolder = setmetatable({ master = made.master, slave = made.slave,
    keep = false, keep_slave = false }, pty_holder_mt)
  -- Darwin's start opens the slave by name to make it the controlling
  -- terminal, and its profile grants that path; Linux has no use for it.
  local slave_path: string
  if streams[0] and holds_by_seatbelt() then
    local found, name_why = sys.ttyname(made.slave)
    if found == nil then return refuse("pty: " .. name_why) end
    slave_path = found
  end
  local started, trouble = start(argv, opts, { slave = made.slave, streams = streams, name = slave_path })
  if started == nil then return nil, trouble end
  holding.keep = true
  holding.keep_slave = pty.keep_slave == true
  return { child = started, master = made.master, slave = holding.keep_slave and made.slave or -1 }, ""
end

--- Waits for the first of several handles to finish, servicing every
--- one's streams meanwhile, and returns it settled: its [`wait()`] answers
--- at once. Nil and [`Poll.TIMEOUT`] when `timeout_ns` passes first --
--- no handle finished, and nothing failed -- and the handles are left
--- running: a timeout is `done == nil and trouble == Poll.TIMEOUT`, and
--- any other trouble beside a nil `done` is a failure. A handle whose
--- own [`Options.timeout_ns`] passes first is ended, as an expired
--- [`Handle.wait`] ends it -- which waits for it to go, so the call
--- can outlast its own `timeout_ns` by the grace period -- and is
--- answered settled, its Result `timed_out`. In a task of
--- [`Poll.run`] that is cancelled, it answers nil and
--- [`Poll.CANCELLED`], the handles left running too. A `timeout_ns`
--- below 0 or past [`Poll.MOST_NS`] raises.
function Child.wait_any(handles: {Handle}, timeout_ns?: integer): Handle | nil, string
  -- TODO: carry a settled group's lingering members on Child.Result, a
  -- field beside the exit status, and answer the handle with "" here:
  -- build/test.tl reads the trouble beside the handle's result today, and
  -- build.contracts exempts this pair from the error-slot rules until then.
  if #handles == 0 then error("child: no handles to wait for", 2) end
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  local deadline = timeout_ns ~= nil and now() + timeout_ns or nil
  while true do
    for _, h in ipairs(handles) do
      if h._result then return h, "" end
      local status, trouble = exited(h)
      if status ~= nil then
        local _, settle_trouble = end_child(h)
        return h, settle_trouble
      end
      if trouble ~= "" then return nil, trouble end
      if overdue(h) then
        local _, settle_trouble = end_child(h)
        return h, settle_trouble
      end
    end
    local soonest = deadline
    for _, h in ipairs(handles) do soonest = sooner(soonest, h) end
    local left = slice(soonest, handles)
    if left ~= nil then
      local _, cancelled = pump(watching(handles), left, true)
      if cancelled ~= "" then return nil, cancelled end
    elseif deadline ~= nil and now() >= deadline then
      return nil, Poll.TIMEOUT
    end
  end
end

--- The children of this process that no handle owns, as the process
--- table lists this thread's (`children`), but for the sandboxes' inits
--- it started (`sandbox_inits`), each of which ends with the child it
--- was started for; nil where there is no such list.
local function strays(): {integer} | nil
  local children, _ = raw.children()
  if children == nil then return nil end
  local inits: {integer:boolean} = {}
  for _, pid in ipairs(raw.sandbox_inits()) do inits[pid] = true end
  local found: {integer} = {}
  for _, pid in ipairs(children) do
    if not owned[pid] and not inits[pid] then found[#found + 1] = pid end
  end
  return found
end

--- Ends and reaps every child of this process that no handle owns:
--- what a supervised child left behind when it died without ending
--- its own descendants -- a process group it started, say, which its
--- own group's SIGKILL never reached -- and that this process adopted
--- as their subreaper. Each is sent SIGKILL, with its group when it
--- leads one, until none is left or a second has passed; a stray in
--- one of the process groups `spared` names is left running. Returns
--- how many were ended. Only a Linux process that adopts orphans can
--- find them; elsewhere this returns 0 and they are init's.
function Child.end_strays(spared?: {integer}): integer
  if not adopting then return 0 end
  local groups: {integer:boolean} = {}
  for _, group in ipairs(spared or {}) do groups[group] = true end
  local ended = 0
  local seen: {integer:boolean} = {}
  local deadline = now() + KILL_REAP_NS
  while true do
    collect()
    local found = strays()
    if found ~= nil and next(groups) ~= nil then
      local ending: {integer} = {}
      for _, pid in ipairs(found) do
        -- Not answered: ended as before.
        local group, _ = sys.getpgid(pid)
        if group == nil or not groups[group] then ending[#ending + 1] = pid end
      end
      found = ending
    end
    if found == nil or #found == 0 or now() >= deadline then return ended end
    for _, pid in ipairs(found) do
      local _, _ = sys.kill(-pid, sys.SIGKILL)
      local _, _ = sys.kill(pid, sys.SIGKILL)
      if not seen[pid] then
        seen[pid] = true
        ended = ended + 1
      end
    end
    if through_run() then
      -- Shielded: ending the strays is a cleanup, which a cancel does
      -- not cut short.
      Poll.shielded(function()
        local _, _ = Poll.delay(POLL_NS // 10)
      end)
    else
      local _, _ = sys.nanosleep(POLL_NS // 10)
    end
  end
end

--- Runs a program -- one executable path -- to completion and answers its
--- [`Result`]. A child that exits nonzero, or is ended by a signal or its
--- timeout, is still a [`Result`], with `ok` false. `argv[1]` is used exactly as given:
--- there is no PATH search, and [`Proc.find`] finds a program by name. A nil
--- environment inherits this process's environment; a table replaces it
--- exactly. Standard streams inherit by default, or accept caller-owned
--- descriptors (which remain open here), "null", or "capture"; "stream"
--- is refused, as nothing could read or write it before the run returns.
--- The child owns a new process group by default, so timeout cleanup
--- includes descendants.
---
--- While the child runs, SIGINT and SIGTERM are held in a [`Child.guard`]:
--- either one ends the child and its group, then the caller's
--- dispositions are restored and the signal delivered again. The run
--- then answers nil and "child: cancelled by signal N". A run made while the
--- caller holds a [`Child.guard`] holds one inside it: a signal the
--- caller's guard caught before the run began does not end it, and one
--- that ends it is left to the caller's guard rather than delivered.
--- It also answers nil and why when the child cannot be started, and
--- nil and "child: signal guard: ..." when its guard cannot be opened.
--- In a task of [`Poll.run`] that is cancelled, it ends the child, as a
--- timeout would, and answers nil and [`Poll.CANCELLED`].
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  if opts.stdin == "stream" or opts.stdout == "stream" or opts.stderr == "stream" then
    error("child: a \"stream\" is read or written while the child runs: use Child.start", 2)
  end
  local held, guard_trouble = opened()
  if held == nil then return refuse("signal guard: " .. guard_trouble) end
  -- Closed after the child is ended, as the run is left: the child is
  -- ended before the guard gives back the signals.
  local guard <close>: Guard = held
  local started, wait_trouble = start(argv, opts)
  local r: Result | nil
  local cleanup_trouble: string
  if started ~= nil then
    -- Ends the child where the run is left by a raise, or a task's kill.
    local _ending <close> = started
    -- Bounded by the deadline `start` gave it from `opts.timeout_ns`.
    r, wait_trouble = started:wait()
    if not started._closed and (guard:cancelled() ~= 0 or r == nil) then
      local _, failure = end_or_kill(started)
      if failure ~= "" then cleanup_trouble = failure end
    end
  end
  -- Closing re-delivers a caught signal, after the cleanup above.
  local restored, restore_trouble = guard:close()
  if not restored then return refuse("signal restore: " .. restore_trouble) end
  local cancellation = guard:cancelled()
  if cancellation ~= 0 then
    return nil, cleanup_trouble or wait_trouble or cancelled_by(cancellation)
  end
  if cleanup_trouble then return nil, cleanup_trouble end
  if r then return r, "" end
  return nil, wait_trouble
end

return Child
