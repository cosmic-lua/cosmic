# Sandbox: a default-deny policy, its command line and its primitives

Status: draft for discussion; not to merge.

## Goal

A simple, powerful command line and standard library that run a program
held, with everything it starts, to nothing at all, and let the caller
build up from there to what the program needs: the paths it reads,
writes, runs and creates, the network it reaches, the processes it
starts, the terminal it uses, the environment it sees, the resources it
spends. What the host cannot enforce is said, never silently dropped.

Prior art this draws on: OpenBSD's pledge(2) and unveil(2); Justine
Tunney's port of both to Linux in Cosmopolitan libc (seccomp-bpf for
pledge, Landlock for unveil) and its `pledge` command; bubblewrap's
build-a-root-from-nothing model and its `--new-session` lesson
(TIOCSTI); landrun and landlock-rs (strict by default, an explicit
best-effort mode, a report of what was enforced); Deno's permission
flags (`--allow-env`); systemd's sandboxing properties; macOS Seatbelt;
Anthropic's sandbox-runtime (bwrap plus seccomp on Linux, sandbox-exec
on macOS, an egress proxy for per-host rules).

## Layers

- **Public: one policy, `cosmic.sandbox`.** The only sandbox vocabulary
  of the standard library and the command line. `Child.start(argv, {
  sandbox = policy })` runs a child under it; later,
  `Sandbox.restrict(policy)` holds the running process itself.
- **Internal: the primitives.** `landlock`, `seccomp` and `namespaces`,
  each a small module under `cosmic.internal`, Linux by name, tested on
  its own. The facade compiles a policy down to them. The test harness
  keeps using them directly, for what it alone needs: a tree bound at
  /tree, a worker run as uid 65532, a noexec scratch.

The primitives are not public, for now:

- **Portability.** macOS has neither Landlock nor seccomp; a public
  `cosmic.landlock` is a Linux-only API in a portable library.
- **Churn.** Landlock is at ABI 10 or 11, and each ABI adds rights. A
  ruleset that does not name a right leaves it allowed, so a caller
  pinned to an old list of rights is silently weaker on a newer kernel.
  The facade tracks that in one place.
- **Seccomp is hard to get right.** Syscall tables per architecture,
  checks on arguments (`openat` flags, `clone` flags, ioctl numbers,
  `PROT_EXEC`). Raw BPF in Lua invites filters that look strict and are
  not.
- **No feature before its caller.** If one ever needs what the policy
  cannot say, a `linux = { ... }` section may only deny more than the
  policy, or the one primitive it needs is promoted.

## The policy

Plain data, not a builder: it can live in a file, be printed, be diffed,
be merged with a profile and be checked against what a host enforces.
Nothing is granted that it does not name.

```teal
local policy: Sandbox.Policy = {
  paths = { ["/usr"] = "rx", ["/etc/ssl"] = "r", ["."] = "rwc" },
  promises = { "proc", "exec" },
  net = { connect = { 443 } },
  env = { "PATH", "HOME", LANG = "C.UTF-8" },
  tmp = true,
  limits = { cpu_s = 60, memory = "2G", procs = 64 },
}
```

### paths

OpenBSD unveil's four letters, each a set of Landlock rights:

- `r`: read files, list directories.
- `w`: write and truncate files.
- `x`: execute.
- `c`: create and remove files, directories and special files; rename
  and link between granted paths.

This is the only grant of file access. A path is taken as named, its
links unresolved; a relative one is read from the working directory.

### promises

A Linux-meaningful subset of OpenBSD's:

- `proc`: fork and clone, without namespace flags.
- `exec`: execve.
- `tty`: terminal ioctls but TIOCSTI and TIOCLINUX, and the caller's
  session; without it, the program starts a session of its own.
- `inet`: IPv4 and IPv6 sockets, to any address and port.
- `unix`: unix sockets.
- `dns`: what a resolver needs (inet datagrams, the resolver's files).
- `jit`: OpenBSD's `prot_exec`, mapping memory executable.
- `fattr`, `chown`: change a file's mode, times, owner. Landlock does
  not gate these at all.
- `id`: setuid and its kin.

Always granted, as OpenBSD's `stdio`: memory, time, signals to itself,
the descriptors it was given. Never grantable: ptrace, mount, bpf,
kernel modules, keyctl, io_uring, userfaultfd and the like (the core's
`pledge_refused`, kept as a floor).

OpenBSD's `rpath`, `wpath` and `cpath` are left out: on OpenBSD they
gate calls and unveil gates paths, but with Landlock unveil gates both,
and two grants of one access confuse.

### net

Nothing by default. `connect` and `bind` take ports (Landlock: TCP from
ABI 4, UDP from ABI 10), with seccomp holding the socket families.
`inet` grants every address. Per-host rules need a proxy -- the kernel
knows ports, not hosts -- and wait on a caller.

### env

Nothing by default. Each entry is a name passed on or a name set.

### tmp

A fresh `/tmp` of the program's own: a tmpfs in a root of its own, or,
under Landlock alone, a scratch directory on the host, granted `rwc`,
with `TMPDIR` naming it.

### limits

rlimits: CPU seconds, memory, processes, descriptors, file size.

### always

The program itself is granted `rx`. Signals and abstract unix sockets
reach nothing outside the sandbox (Landlock ABI 6 scoping, or a pid
namespace).

## Enforcement

The contract is Landlock's: anything not granted fails with EACCES (or
EPERM, for a call a promise did not grant). Where the host allows user
namespaces, the sandbox adds to it -- a root of its own, so a path not
granted does not exist (ENOENT, as on OpenBSD); a pid and an IPC
namespace; a network namespace when no network is granted -- but never
changes it. The caller never picks a mechanism.

- **Strict by default.** A denial the host cannot enforce refuses the
  start, naming it ("Landlock ABI 3 cannot hold TCP connect; ABI 4
  can"). `--best-effort` accepts less and says what it dropped.
- **`Sandbox.check(policy)`** answers, starting nothing, each section --
  paths, net, promises, hiding -- `full`, `degraded` or `none`, and why.
- **Denials explained.** The supervisor takes each refused call through
  seccomp's user notification, prints `denied connect(): grant
  net.connect 443 or promise inet`, and answers EPERM. A path's denial
  is harder: Landlock's audit log (ABI 7) is root's to read, so it is a
  guess from the last failing call, said as one.

## The command line

Each flag is one field of the policy.

```
cosmic sandbox [options] [--] program [args...]
  -v PATH[:rwxc]      grant a path (default r); repeat
  -p 'proc exec tty'  promises
  --connect PORT, --bind PORT, --inet
  -e NAME[=VALUE]     pass or set an environment variable
  --tmp               a /tmp of its own
  -P NAME             a profile: system, tls, ...
  -f FILE             a policy file; flags add to it
  --check             say what this host would enforce, run nothing
  --best-effort       accept less, said
  --kill              end the program on a refused call, not EPERM
  -q                  explain no denial

cosmic sandbox -P system -v .:r -- ls -l
cosmic sandbox -P system -P tls -v .:rwc --connect 443 -e HOME -- curl -O https://...
cosmic sandbox -f build.json --tmp -- make
```

Profiles are policy fragments shipped in the binary -- `system` the
system's files read-only and runnable, /dev/null and the like, PATH,
LANG and TERM; `tls` the CA bundles -- named, never implied: the
default is nothing.

## Seccomp

The core's filter grows from a deny list into an allow list driven by
the promises, ported from Cosmopolitan's tables (ISC; x86_64 and
aarch64; checks on open flags, clone flags, ioctls and PROT_EXEC), with
the deny list kept as a floor.

## macOS

The same policy compiles to a Seatbelt profile through `sandbox_init`
-- deprecated, but used by Chromium and sandbox-runtime. Until then
`check` answers `none` there and a strict start refuses.

## Where this departs from doc/design.md

That section makes the sandbox an opt-in fence for builds and tests,
with network none, loopback or all, and no promises. This draft makes
default-deny the contract, adds promises and the environment, is strict
by default, explains denials, and makes namespaces hardening the
contract does not depend on. Its conformance matrix -- one policy on
every CI leg, one expected result -- still holds, the hiding cells
allowed to differ by the strength `check` declares.

## Phases

1. The policy, `check`, the command line, and Linux enforcement:
   Landlock paths and ports, namespaces, today's deny list and socket
   families as the seccomp part. Strict by default.
2. Promises as a seccomp allow list; denials explained through user
   notification.
3. Seatbelt on macOS.
4. `Sandbox.restrict` for the running process; an egress proxy if a
   caller needs per-host rules.

## Open questions

- A builder (`Sandbox.new():path("/usr", "rx"):promise("exec")`) beside,
  or instead of, the plain record.
- What `--best-effort` may drop: everything, or never the network.
- Whether `tty` should allocate a pty and relay it, rather than share
  the caller's terminal.
