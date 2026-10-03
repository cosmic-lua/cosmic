# Sandbox: a default-deny policy, its command line and its primitives

Status: draft for discussion, revision 2; not to merge. Revision 1 and
its review are summarized at the end.

## Goal

A simple, powerful command line and standard library that run a program
held, with everything it starts, to nothing at all, and let the caller
build up from there to what the program needs: the paths it reads,
writes, runs and creates, the names it can see, the network it reaches,
the processes it starts, the terminal it uses, the environment it sees,
the resources it spends. What the host cannot enforce refuses the start,
or, asked, is reported -- never silently dropped.

Prior art: OpenBSD's pledge(2) and unveil(2); Cosmopolitan libc's port
of both to Linux (seccomp-bpf, Landlock) and its `pledge` command;
bubblewrap; landrun and landlock-rs (strict by default, a report of what
was enforced); Deno's permission flags; systemd's sandboxing; macOS
Seatbelt; Anthropic's sandbox-runtime.

## Layers

- **Public: one policy, `cosmic.sandbox`**, plain typed records and pure
  functions over them. `Child.start(argv, { sandbox = policy })` runs a
  child under it; `cosmic sandbox` is its command line. Later,
  `Sandbox.restrict(policy)` holds the running process.
- **Internal: the primitives.** The raw `spawn` sandbox in core/process.h
  (namespaces, Landlock, the seccomp filter), unchanged in shape. The
  policy compiles to it through new bindings beside the old ones. The
  test harness stays on the primitives: it needs binds under another name
  (/tree), a worker mapped to uid 65532, a noexec scratch, a closure store
  handed by descriptor, and an exec-only hold of itself, which no policy
  needs yet. Harness and policy share one conformance matrix.
- `Child.Sandbox`'s public fields today (`unveil`, `offline`, `user`,
  `group`, `noexec_scratch`) move off the public surface; the harness
  reaches them through the raw table, as it already does for most.

## The policy

```teal
local policy: Sandbox.Policy = {
  paths = { ["/usr"] = "rx", ["/etc/ssl"] = "r", ["."] = "rwc" },
  show = { "/" },                      -- the default: every name visible
  promises = { "proc", "tty" },
  net = { connect = { 443 }, loopback = { "127.0.0.1" } },
  unix = { "/run/user/1000/bus" },
  env = { pass = { "PATH", "HOME" }, set = { LANG = "C.UTF-8" } },
  fds = { [3] = log_fd },
  tmp = true,
  limits = { cpu_s = 60, memory_bytes = 2 << 30, procs = 64 },
}
```

Nothing is granted that the policy does not name. The pure functions:

- `Sandbox.validate(p)`: a reason for a policy that cannot be, or nil.
- `Sandbox.merge(a, b)`: the union, for one sandbox built from a profile,
  a file and flags. Two different values for one `env.set` name refuse.
- `Sandbox.meet(a, b)` and `Sandbox.within(outer, inner)`: a sandbox
  started inside another is held to both, and `within` says, before the
  start, what of the inner one the outer already denies.
- `Sandbox.check(p)`: what this host enforces of each section (below).
- `Sandbox.encode(p)` and `Sandbox.digest(p)`: one canonical JSON, and
  its hash, for a key.

No builder: a policy is a value to print, diff, merge, hash and check,
and the command line is already the way to build one up.

### paths

OpenBSD unveil's letters, each a set of Landlock rights:

- `r`: read files, list directories.
- `w`: write and truncate files.
- `x`: execve. Only that: a granted, readable file can still be run by
  a granted loader (`ld.so ./file`).
- `c`: create and remove files, directories and special files; rename
  and link between granted paths.

Each grant is opened once, with `O_NOFOLLOW`, at the start; that one
descriptor makes the Landlock rule and, in a root of its own, the bind.
A symlink is refused unless the grant says `follow`. A relative path is
read from the working directory; in a policy file, from the file's own
directory. A grant must exist: to let a program create `./out`, grant
`.` the letter `c`, or create `out` first.

### show

The names the program can see. The default, `{ "/" }`, shows every name:
a path not granted is there to `stat` and list, and refused to open
(EACCES). Anything narrower builds the program a root of its own
holding only what `show` and `paths` name, so the rest does not exist
(ENOENT, as on OpenBSD) -- which needs user namespaces; where the host
refuses them, a strict start refuses. `show = {}` shows the grants and
nothing else.

### promises

- `proc`: fork, and clone without namespace flags. Threads are not
  `proc`: every program may make them.
- `tty`: the program's terminal (below) is a pty it may drive: termios,
  job control, window size. TIOCSTI and TIOCLINUX are never allowed.
- `inet`: IPv4 and IPv6 TCP to any address. `net` narrows it.
- `dns`: names resolved through a stub the supervisor serves inside the
  sandbox's own network; no other datagrams.
- `jit`: anonymous executable memory. File-backed executable mappings
  -- what a dynamic loader makes -- are always allowed.
- `fattr`, `chown`: change a file's mode, times, owner, which Landlock
  does not gate.
- `id`: setuid and its kin.

There is no `exec` promise: the filter is installed before the program's
own exec, and exec is held by `x` on paths. OpenBSD's `rpath`, `wpath`
and `cpath` are left out: `paths` gates both the call and the path.

Always allowed (OpenBSD's `stdio`): memory, time, signals to itself,
threads, the descriptors it was handed, and read-only terminal queries
(TCGETS, TIOCGWINSZ). Never allowed, whatever is promised:

- ptrace, process_vm_*, mount and the new mount calls, pivot_root, bpf,
  perf_event_open, kexec, kernel modules, keyctl, io_uring, userfaultfd,
  setns, open_by_handle_at, pidfd_getfd, process_madvise (today's floor);
- `unshare`, and `clone` with any CLONE_NEW* flag; `clone3` answers
  ENOSYS, so libc falls back to `clone`, which the filter can read;
- sockets but `AF_UNIX` (with `unix`) and TCP over `AF_INET`/`AF_INET6`
  (with `inet` or `net`): no MPTCP, SCTP, ping, raw or packet sockets, no
  TCP fast open;
- `personality` outside the safe set, `memfd_create` with `MFD_EXEC`.

### net

Nothing by default; no network but a loopback of the sandbox's own when
anything below is asked. `loopback` names 127/8 addresses served inside
it. `connect` and `bind` take TCP ports (Landlock ABI 4), to any host:
the flag says so (`--connect-any-host`), since port 443 is every host's
443, cloud metadata's included. UDP waits on Landlock's UDP rules (not
merged as of June 2026). Per-host rules need a proxy -- the kernel knows
ports, not hosts -- and wait on a caller.

### unix

Each unix socket path the program may connect to. Landlock holds that
from ABI 9; below it a strict start refuses `unix` unless `show` hides
the rest. Abstract sockets and signals never reach outside the sandbox:
Landlock ABI 6 scoping, or a network and a pid namespace; neither, and a
strict start refuses.

### the terminal

The program never holds the caller's terminal. Where stdin, stdout or
stderr is one, the supervisor opens a pty for the program and relays
it: bytes both ways, window size, and the signals the terminal would
send. Without `tty` the program may only read and write it. The
caller's terminal reads what the relay writes, so escape sequences that
reach outside the session (OSC 52 clipboard writes, queries whose
replies land in the caller's input) are dropped by the relay. When the
program exits, everything it started is ended (pid namespace, or a
subreaper and kill-all), so nothing stays to read later keystrokes.

### descriptors

The program gets 0, 1 and 2 (relayed, for a terminal) and the
descriptors `fds` names; every other is closed before it runs.

### env

Nothing by default. `pass` names variables passed on, `set` sets them.
A name that runs code in what the program starts (`LD_PRELOAD`,
`LD_AUDIT`, `BASH_ENV`, `PYTHONPATH`, `GIT_SSH_COMMAND` and the like) is
refused unless marked deliberate.

### tmp, limits

`tmp`: a fresh `/tmp` of the program's own -- a tmpfs in a root of its
own, or a scratch directory on the host, granted `rwc`, with `TMPDIR`
naming it, `check` saying `/tmp` itself stays refused. `limits`: CPU
seconds, memory, processes, descriptors, file size, as rlimits (per
process, said so); the exit reports which one fired, and peak memory
and CPU time.

### the program

Found on the caller's PATH, resolved once, its file granted `rx` and run
by descriptor. Before the start the sandbox reads its ELF interpreter
and libraries, or its `#!` line, and refuses naming whatever of them the
policy does not grant. A working directory not granted refuses the
start rather than running at `/`.

## Enforcement

- **One errno.** Every denial the sandbox makes answers EACCES -- what
  Landlock answers, and what the filter answers too -- but ENOENT for a
  name `show` hides, and ENOSYS for a call libc is meant to fall back
  from. (Open: a socket family refused may answer EAFNOSUPPORT, which
  programs read as "try another family".)
- **Strict by default.** A denial the host cannot enforce refuses the
  start, naming it. `--best-effort` accepts less, but never drops
  `no_new_privs`, the floor, the scoping of signals and abstract
  sockets, or a denied network; what it drops is in `Child.start`'s
  result, not only on stderr, and a policy file cannot ask for it.
- **`Sandbox.check`** reports each section -- paths, show, net, unix,
  promises, terminal -- `full`, `degraded` or `none`, with why, from a
  throwaway start that applies every layer and tries one denied
  operation in each: never from an ABI number, which hosts misreport
  (Ubuntu 24.04 grants a user namespace and then refuses its mounts). A
  Landlock newer than this code knows makes paths `degraded`, naming the
  rights it cannot hold.
- **Denials explained.** Phase 2: `cosmic sandbox` takes refused calls
  through seccomp's user notification, deny-only, and prints them in its
  own flags' words, once each, with a summary at exit (`rerun with:
  --tls --dns --connect-any-host 443`). A refused path or port is
  Landlock's and invisible there; `--explain` says so rather than guess.
  Where a listener is already held (a sandbox in a sandbox), it falls
  back to nothing, said.

## The command line

```
cosmic sandbox [options] [--] program [args...]
  --read PATH         grant r          --run PATH       grant rx
  --write PATH        grant rwc        --grant LETTERS:PATH
  --show PATH         show a name (repeat; --show none for grants only)
  --promise NAME      proc, tty, inet, dns, jit, fattr, chown, id
  --connect-any-host PORT   --bind PORT   --loopback ADDR
  --unix PATH         --fd N          --env NAME[=VALUE]
  --tmp               --limit cpu=60,memory=2G,procs=64
  --system            the system's programs, libraries and configuration
  --policy FILE       --print-policy   --check   --best-effort
```

```
cosmic sandbox --system --read . -- ls -l
cosmic sandbox --system --tls --promise dns --write out --connect-any-host 443 \
  -- curl -o out/page https://example.com
cosmic sandbox --policy build.json --tmp --show none -- make
```

`--system` grants, read-only and runnable, exactly the paths it lists in
`cosmic help sandbox` (/usr, /lib*, /bin, the loader's configuration, the
locale), and passes PATH, LANG and TERM. Policy files are JSON, unknown
keys refused. `--print-policy` writes the merged policy, so a command
line becomes a file. Exit: the program's status (128+n for a signal);
125 when the sandbox refused, 126 when the program could not start in
it, 127 when it was not found.

## Seccomp

Phase 1 extends today's deny-list filter: the floor above, socket types,
ioctl numbers (compared on their low 32 bits), errno. Phase 2 makes it an
allow list driven by the promises, hand-ported from Cosmopolitan's
pledge-linux.c (ISC, about 2,400 lines; not vendorable as is), new calls
answering ENOSYS so libc falls back.

## macOS

The same policy compiles to a Seatbelt profile, applied by a trampoline
-- cosmic relaunched, calling `sandbox_init`, then `execve` -- since
`posix_spawn` has no hook. `show` narrower than `/` and per-port rules
are refused there.

## Where this departs from doc/design.md

Default-deny is the contract; the policy has promises, the environment
and descriptors; strict by default. Kept from it: grading from checks
that ran, one errno, the conformance matrix.

## Phases

1. The policy, its functions, `check`, the command line, and Linux
   enforcement: per-path Landlock rights opened once with `O_NOFOLLOW`,
   `show` through namespaces, TCP ports, loopback, unix paths (ABI 9 or
   hidden), the extended floor, one errno, the pty relay, descriptors,
   env, tmp, limits, the program's preflight. Strict by default.
2. Promises as a seccomp allow list; denials explained.
3. Seatbelt.
4. `Sandbox.restrict`; an egress proxy for per-host rules; `--learn`, a
   plainly unconfined run that writes the policy it would have needed.

## Revision 1's review, in brief

Four reviews (security, usability, alternatives, feasibility) of
revision 1 changed: grants opened once without following links (they
were followed); `unix` scoped to paths (it reached docker.sock below
ABI 9); the floor refusing namespaces, `clone3` and every socket but
TCP and unix; abstract-socket scoping (a pid namespace does not scope
it); `check` from a probe, not an ABI; `--best-effort` never dropping
the floor; no `exec` promise; `jit` anonymous only; UDP unconfirmed;
descriptors closed; hiding made a request (`show`); composition
(`meet`, `within`); loopback; long flags; JSON policy files; the
program's preflight; no builder; the harness kept on the primitives.

## Open questions

- Errno for a refused socket family: EACCES, or EAFNOSUPPORT.
- Escape filtering in the relay: a deny list of sequences, or a
  stricter allow list.
- Whether `x` should also refuse running a granted file through a
  granted loader (noexec mounts in a root of its own; nothing under
  Landlock alone).
