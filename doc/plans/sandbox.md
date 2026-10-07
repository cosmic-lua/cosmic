# Sandbox: a default-deny policy, its command line and its primitives

Status: draft for discussion, revision 7; not to merge.

## Goal and the one rule

A command line and a standard library that run a program held, with
everything it starts, to nothing at all, and let the caller build up to
what the program needs: the paths it reads, writes, runs and creates,
the hosts it reaches, the system calls it makes, the environment it
sees, the resources it spends, how far it is isolated from the host.

A policy is met, or the program does not start. There is no strict
mode, no best-effort mode and no separate check: a start that cannot be
met fails, naming what is missing and how to provide it -- the sysctl
or AppArmor profile Ubuntu 24.04 needs, the container option a procfs
needs, the kernel a Landlock right needs.

The public surface is one policy, [`cosmic.sandbox`]: plain typed
records and pure functions. `Child.start(argv, { policy = p })` runs a
child under it, `Sandbox.restrict(p)` holds the running process,
`cosmic sandbox` is its command line, and a test declares one with
[`Test.policy`]. Namespaces, Landlock and the seccomp filter are its
internals. The test harness runs on it.

Prior art: OpenBSD's pledge(2) and unveil(2); Cosmopolitan libc's port
of both to Linux; bubblewrap; landrun and landlock-rs; Deno's
permissions; systemd's sandboxing; macOS Seatbelt; Anthropic's
sandbox-runtime.

## The policy

```teal
local record Sandbox
  enum Isolate "file" "proc" end
  enum Promise "fork" "jit" "fattr" "nest" end

  record Grant
    path: string       -- as the program sees it; relative to the cwd
    letters: string    -- of "rwxcu", in that order
    from: string       -- the host's path, when it differs; isolate file
  end

  record Limits        -- rlimits on every process, but `processes`
    open_files: integer
    file_bytes: integer
    cpu_seconds: integer
    processes: integer -- the whole sandbox: a user namespace's count
  end

  record Policy
    profiles: {string}         -- "system", "cosmic"; resolved by merge
    grants: {Grant}
    isolate: {Isolate}
    promises: {Promise}
    connect: {string}          -- "host:port"; host or port may be "*"
    loopback: {string}         -- 127/8 addresses used inside
    env: {string}              -- variables passed through
    set_env: {string:string}   -- variables set
    tmp: boolean
    limits: Limits
  end

  decode: function(json: string): Policy, string
  encode: function(Policy): string
  merge: function(...: Policy): Policy, string
  restrict: function(Policy): boolean, string
end
```

- **merge** resolves `profiles`, joins letters per path, unions lists,
  and fails on two values for one `set_env` name or one limit.
- **encode** is the canonical JSON of a merged policy: lists sorted,
  `profiles` resolved away, `set_env` values as digests. Printed and
  reported policies show `env` and `set_env` by name only.
- **[`Child.Options`]** gains `policy`. With one, the environment is the
  policy's alone, and `Options.env` beside it fails; `fds` names the
  only descriptors past 0-2 the program gets; `timeout_ns` is the
  wall-clock limit. [`Child.start`] prints nothing about grants.

## Grants

- `r`: read files, list directories.
- `w`: write and truncate files.
- `x`: execve. Not a code boundary: a readable file can still be mapped
  executable by a granted loader.
- `c`: create and remove, sockets included; rename and link between
  granted paths.
- `u`: connect to the unix socket at this path. A socket grant
  delegates to the program whatever that service does for its callers.
  Held by Landlock ABI 9. Below it, `isolate file` holds a `u` grant
  only when no other grant is a directory or a socket: the filter's
  AF_UNIX allowance cannot tell one socket from another, and a
  read-only bind does not stop a connect, so any socket in a granted
  directory would be reachable too. Otherwise the start fails. Any `u`
  grant isolates the network, so the program cannot bind an abstract
  name a host client expects.

Each grant resolves once, links included, by descriptor; that one
resolution makes the Landlock rule, the bind under `isolate file` and
the report. A grant whose target differs from its name is reported. A
grant must exist. `from` binds a host path at another name, under
`isolate file`; its mount point is made in the sandbox's own tmpfs,
never in a host directory. Under `isolate file`, writable grants are
mounted noexec unless also granted `x`.

What is not granted cannot be opened, run, written, created or listed,
on every host. Its metadata -- existence, size, times, owner, through
`stat`, `access`, `readlink`, `chdir` -- is undefined unless `file` is
isolated.

## Isolation and the network

- `file`: a root of the program's own, holding only what is granted;
  anything else does not exist (ENOENT). Implies `proc`.
- `proc`: a process space and a /proc of its own. Where the kernel
  refuses the procfs (a container without `systempaths=unconfined`),
  the start fails, naming that option.
- The network: with no `connect`, `loopback` or `u`, the filter refuses
  inet, netlink and packet sockets, on every host, in or out of a
  namespace. With `loopback` or `u`, a network namespace with a
  loopback; `loopback` names the addresses the program uses there, a
  declaration rather than a hold, since all of 127/8 is its own. With
  `connect`, that namespace and the relay.

Every isolation needs unprivileged user namespaces; where they are
refused, the failure names the sysctl or AppArmor profile.

Without `proc`, the program still never reaches the host's processes:
the host's /proc is never granted; signals are held by Landlock ABI 6
scoping, or to the program's own pid; calls taking another pid
(`prlimit64`, `setpriority`, `sched_*`, `getpgid`, `getsid`) are
allowed only on its own.

A program never runs as root. A root caller's program runs as a mapped
unprivileged user, its own uid from a reserved range per sandbox. A
writable grant that user cannot write gets an idmapped mount under
`isolate file` where the kernel and filesystem allow it, else the start
fails naming it; a host that cannot map a user fails.

## Promises

The filter is an allow list. What the basics and the granted promises
do not cover answers EPERM; a call above the reviewed table, and
`clone3` and `openat2`, answer ENOSYS, so libc falls back; a refused
ioctl answers ENOTTY. Every refusal the harness meets names the call
and the promise that grants it.

- Always allowed: memory, time, signals to itself, threads, the
  descriptors it was handed, file operations held by grants,
  file-backed executable mappings, execve, unix socketpairs, read-only
  terminal queries, `landlock_*` and seccomp filter installation.
- `fork`: fork, and clone without any namespace flag.
- `jit`: anonymous executable memory. Without it, `PR_SET_MDWE` (or,
  before Linux 6.3, the filter) refuses memory both writable and
  executable; `memfd_create` needs `MFD_NOEXEC_SEAL` either way.
- `fattr`: change a file's mode, times, owner, extended attributes;
  setuid, setgid and sticky bits never.
- `nest`: build a sandbox of its own. Needs `isolate file`; the filter
  allows `unshare`, `mount` and `pivot_root`, which reach only the
  program's own namespaces, and Landlock's hold is given up, since
  Landlock refuses mounts. Everything else holds.

Never allowed: ptrace, process_vm_*, mounts and namespaces (but under
`nest`), bpf, perf_event_open, kexec, modules, keyctl, io_uring,
userfaultfd, setns, open_by_handle_at, pidfd_getfd, process_madvise;
ioctls and prctl options outside their allow lists; fcntl's F_NOTIFY
and F_SETLEASE; vmsplice.

The tables are [`core/promises.c`], ported by hand from Cosmopolitan's
pledge-linux.c with its ISC notice and a `cosmic bom` record, for
x86_64 and aarch64; a cBPF interpreter in Teal tests every promise on
both from any host.

## Tmp and limits

- `tmp`: a fresh `/tmp` -- a sized tmpfs under `isolate file`, or a
  mkdtemp directory granted `rwc` with `TMPDIR` naming it, removed after
  exit without following links.
- `limits`: rlimits on every process, with defaults (no core dumps,
  1024 open files), always met; `processes` holds the whole sandbox by
  a user namespace's count (Linux 5.17, or a fixed stable kernel), set
  inside it, and `isolate proc` brings 4096 by default. Exhausting a
  resource is not escaping: the sandbox promises only what `limits`
  asks. Memory and CPU for the whole sandbox wait on cgroups.

## The program

Found on the caller's PATH, resolved to its real path once, run by
that path with the name it was typed as as argv[0]; a virtual
environment's interpreter link is run as the link. A relaunched helper
held by the same policy reads its ELF interpreter or `#!` line and
names a missing grant; it is skipped when the program is cosmic's own
core.

## Restricting the running process

`Sandbox.restrict(policy)` holds the calling process and what it
starts to `grants`, `promises` and `limits` for good, by Landlock and
the filter. It fails for anything it cannot meet in-process --
`isolate`, `connect`, `loopback`, `u`, `env`, `set_env`, `tmp`,
`processes` -- and while the process has another thread, a live child,
or a descriptor `fds` does not name. Called again, it narrows.

## Errors

EACCES for a path Landlock refuses, EXDEV for a refused rename across
grants, ENOENT for a name `isolate file` hides, EPERM for a call the
filter refuses, ENOSYS and ENOTTY as above. A failed start exits 125
with the reason on stderr.

## Tests

`Test.policy { ... }` replaces [`Test.needs`]: a test declares a policy,
in the policy's own fields, and the harness changes so that nothing
test-only is left:

- Paths are relative to the worker's working directory, /tree.
- `profiles = { "system" }`, and `"cosmic"` for this program's real
  core, read and run, started past its launcher, its core cache under
  the sandbox's `tmp`.
- The store a test reads is a grant: its closure store at
  `o/cosmic.db`, or the whole projection where it reads beyond its
  closure; the in-process hold goes. What the processes a test starts
  may load is the store they are granted.
- Host caches are per user, so no worker runs as root.
- Every variable is named; `"*"` and `$NAME` paths go.
- `noexec` is a writable grant without `x`.
- Each test declares its promises: `fork` in the ~111 that start
  processes, `fattr` in the ~29 that change modes or times, `nest` in
  the 15 that build sandboxes.

The harness merges that with the worker's own grants (the tree at
/tree, the padded scratch with `rwxcu`, the store by `from`), starts
the worker with `Child.start({ policy })`, and the worker holds itself
with [`Sandbox.restrict`] before any of the test's code runs. A test's
key holds the encoded policy, less host paths, in the harness's own
canonical form. A verdict reached unsandboxed is never shared. Where
the platform or container cannot meet a policy, the harness runs
workers without one and reports it.

Migration: (a) [`Test.policy`] beside [`Test.needs`], keys identical; (b) a
second path behind a flag, a non-gating CI job until green; (c) the
policy path the default, Landlock only -- an epoch bump; (d) the
filter on every worker -- a second bump; (e) [`Test.needs`] and the old
path deleted.

## The command line

Written by hand, with a test that every policy field has a flag.

```
cosmic sandbox [options] [--] program [args...]
  --read PATH (r)  --run PATH (rx)  --write PATH (rwc)  --path LETTERS:PATH
  --system  --cosmic
  --isolate file|proc     --promise fork|jit|fattr|nest
  --connect HOST:PORT     --loopback ADDR
  --env NAME  --set-env NAME=VALUE  --tmp
  --open-files N  --file-bytes N  --cpu-seconds N  --processes N
  --fd N  --timeout SECONDS
cosmic sandbox connect HOST PORT
```

```
cosmic sandbox --system --read . -- ls -l
mkdir y && cosmic sandbox --system --promise fork --write y \
  --connect github.com:443 -- git clone https://github.com/x/y y
cosmic sandbox --system --path rwxc:. --tmp --promise fork --isolate file -- make
```

## The relay and the terminal (later phases)

**The relay**, the program's only way out: a confined process of its
own, holding listeners the sandbox bound in its network; it serves
[`Child.start`] and the command line alike, and the sandbox ends with
it. HTTP CONNECT and SOCKS5 with names; hosts parsed strictly,
resolved once, every answer checked against loopback, link-local,
private, CGNAT, metadata and mapped forms (opened only by a literal
grant), the checked address connected; SNI matched to the host; capped
connections, headers and queries; a DNS stub answering granted names
only. The proxy variables are set in both cases, with `NO_PROXY` for
loopback and `NODE_USE_ENV_PROXY=1`. Programs that ignore them reach
nothing; `cosmic sandbox connect` serves ssh's ProxyCommand.

It is three parts, so that no part both parses what the sandbox sends
and holds a host socket that is not yet connected:

- **The resolver** is c-ares, the library the core already carries for
  curl, given a binding of its own: it reads the host's resolv.conf and
  hosts (and, on macOS, the dnsinfo service), resolves a granted name
  once, and returns every address, so that one forbidden answer refuses
  the name rather than being skipped.
- **The connector** (#2815) is a native process with no file access,
  exec or fork: it takes only numeric endpoints the relay has already
  checked, connects, and passes the connected socket back over
  descriptors (#2813). The relay never holds an unconnected host
  socket.
- **The relay** parses the sandbox's side: CONNECT, SOCKS5, SNI and the
  DNS stub, the stub served over [`Net.datagram`] (#2811). It answers a
  granted name from the resolver's checked addresses and refuses every
  other name.

**The terminal**: only `cosmic sandbox` relays one, as a pty (#2814
gives the core `openpty`, terminal modes, window size, a controlling
terminal for the child, and the refusal of a policy with a terminal on
stdio). The relay loop applies an allow list of control sequences,
answers queries itself, forwards the window size and signals, and
restores and flushes the caller's terminal at exit.
[`Child.start`] with a policy and a terminal on stdio fails.

## macOS

[`Seatbelt.compile`] (#2812) compiles a policy to a default-deny
profile with paths passed as parameters, refusing what Seatbelt cannot
hold (`isolate`, `nest`, `loopback`, `connect`, `processes`, `tmp`, the
database). What remains:

- one C function applying it through `sandbox_init_with_parameters`
  before exec in the Darwin trampoline, `sandbox-exec` the fallback
  where that is absent, a refusal never retried without it; the
  trampoline also gives the child a controlling terminal;
- [`Child.start`] and [`Sandbox.restrict`] applying it, and then `tmp`
  and the database granted, as Linux grants them;
- the connector confined by numeric remote rules, and the relay on the
  host's loopback behind a per-sandbox token, with c-ares's dnsinfo
  service the only Mach service the relay reaches.

Until then, a policy fails there and the harness runs workers without
one.

## Phases

Each names its caller.

1. The filter, [`core/promises.c`] and its interpreter test; Landlock
   rulesets built in the child from descriptors; [`Sandbox.restrict`]
   replacing the worker's `forbid_running`. Caller: the harness.
2. Isolation reshaped: `proc` alone, `file` implying it, grants by
   descriptor and at other names, noexec, the mapped user and idmapped
   mounts, `processes`, `nest`. Caller: the harness.
3. [`cosmic.sandbox`] and `Child.start({ policy })`, the profiles, the
   preflight. Caller: the harness.
4. The harness on the policy, migration steps (a) to (e).
5. The `cosmic sandbox` verb.
6. The relay. The core has UDP (#2811) and descriptor passing
   (#2813); the connector is in #2815. Left: the c-ares binding, the
   relay's listeners and DNS stub, the proxy variables, `connect` in
   [`Child.start`], and `cosmic sandbox connect`. Caller: the verb, and
   tests that fetch.
7. The pty relay. The core's terminal calls are in #2814. Left: the
   relay loop and the verb's use of it. Caller: the verb.
8. Seatbelt. The compiler is done (#2812). Left: applying it, as
   [macOS](#macos) lists. Caller: the harness's macOS leg.

## Roadmap

Cgroup limits for memory and CPU; policy files (narrow-only, judged
after resolution); plain-HTTP forwarding; a transparent network mode;
nested sandboxes through a broker.

## History

1. Policy and layering; review: links followed, docker.sock reachable,
   a thin filter, terminal leaks.
2. `show`; review: promises unenforced, DNS against connect, policy
   files as attacker input, too many concepts.
3. Isolation by effect, a relay-only network, an allow-list filter,
   files narrow-only; review: `u` before ABI 9, the relay a confused
   deputy, processes reachable by pid, Ubuntu 24.04.
4. Those fixed, failures naming remedies.
5. Grilled: limits by scope, the harness on the policy, `restrict`,
   tests declaring policies, `env` in the policy. Review: the network
   open without a namespace, the `cosmic` profile and the core cache,
   `processes` miscounted, unions in the record, phases contradicting
   the text, `nests` regressed.
6. Those fixed; grilled: `nest` as a promise, the harness changed so
   test-only fields go, never root without exceptions, a refused procfs
   failing, each test declaring its promises, [`Test.policy`].
7. Implementation (#2677) found `isolate file` does not hold a `u`
   grant below ABI 9 beside a granted directory or socket.
8. Phases 1-5 done; the relay split into a c-ares resolver, a confined
   connector and the parsing relay; the core's UDP, descriptor passing
   and Seatbelt compiler landed, the pty and connector in review.

[`Child.Options`]: ../../cosmic/child.tl
[`Child.start`]: ../../cosmic/child.tl
[`core/promises.c`]: ../../core/promises.c
[`cosmic.sandbox`]: ../../cosmic/sandbox.tl
[`Net.datagram`]: ../../cosmic/net.tl
[`Sandbox.restrict`]: ../../cosmic/sandbox.tl
[`Seatbelt.compile`]: ../../cosmic/seatbelt.tl
[`Test.needs`]: ../../cosmic/test.tl
[`Test.policy`]: ../../cosmic/test.tl
