# Sandbox: a default-deny policy, its command line and its primitives

Status: draft for discussion, revision 5; not to merge. Earlier
revisions, their reviews and the decisions that followed are summarized
at the end.

## Goal

A simple, powerful command line and standard library that run a program
held, with everything it starts, to nothing at all, and let the caller
build up from there to what the program needs: the paths it reads,
writes, runs and creates, the hosts it reaches, the system calls it
makes, the environment it sees, the resources it spends, and how far it
is isolated from the rest of the host.

One rule over all of it: a policy is met, or the program does not
start. There is no strict mode, no best-effort mode and no separate
check: a start that cannot be met fails, naming what is missing and how
to provide it.

Prior art: OpenBSD's pledge(2) and unveil(2); Cosmopolitan libc's port
of both to Linux and its `pledge` command; bubblewrap; landrun and
landlock-rs; Deno's permission flags; systemd's sandboxing; macOS
Seatbelt; Anthropic's sandbox-runtime.

## Layers

- **Public: one policy, `cosmic.sandbox`**, plain typed records and pure
  functions over them; no builder. `Child.start(argv, { policy = p })`
  runs a child under it, `Sandbox.restrict(p)` holds the running process,
  `cosmic sandbox` is its command line, and a test declares one in
  [`Test.needs`].
- **Internal: the primitives** -- namespaces, Landlock, the seccomp
  filter -- through the raw `spawn` sandbox in core/process.h, which the
  policy compiles to through new options beside the old ones.
- **The test harness runs on the policy**, from phase 1: it is the
  policy's hardest caller, and the policy is shaped to carry it (see
  Tests). The raw primitives end up internal to `cosmic.sandbox`.

## The policy

```teal
local record Sandbox
  enum Isolate "file" "proc" end
  enum Promise "proc" "jit" "fattr" end

  record Grant             -- a path bound at another name
    from: string            -- the host's path
    letters: string
  end

  record Limits
    record Each             -- every process; rlimits; always met
      open_files: integer
      file_bytes: integer
      cpu_seconds: integer
    end
    record Whole            -- the sandbox's whole tree; met or refused
      processes: integer    -- a user namespace's count
      memory_bytes: integer -- cgroup v2
      cpu_percent: integer  -- cgroup v2
    end
    each: Each
    whole: Whole
  end

  record Policy
    uses: {string}               -- profiles merged in: "system", "cosmic"
    paths: {string:string|Grant} -- path -> letters of "rwxcu"
    isolate: {Isolate}
    promises: {Promise}
    connect: {string}            -- "host:port"; host or port may be "*"
    loopback: {string}           -- 127/8 addresses served inside
    env: {string:boolean|string} -- true passes, a string sets
    user: integer                -- whom a root caller's program runs as
    tmp: boolean
    limits: Limits
  end

  decode: function(json: string): Policy, string
  encode: function(Policy): string
  merge: function(...: Policy): Policy
  profile: function(name: string): Policy
  restrict: function(Policy): boolean, string
end
```

[`Child.Options`] gains `policy`. With one, the program's environment is
the policy's `env` alone (plus `TMPDIR` and the proxy variables the
policy itself sets), and `Options.env` beside it fails, naming the
field; `fds` names the only descriptors beyond 0-2 the program gets
(live descriptors cannot be encoded, so they stay options), and
`timeout_ns` is the wall-clock limit. Relative paths resolve against
`Options.cwd`, else the working directory.

A program never runs as root: a root caller's program runs as a mapped
unprivileged user, `user` or 65532 by default.

### paths

- `r`: read files, list directories.
- `w`: write and truncate files.
- `x`: execve. Only that: a granted, readable file can still be mapped
  executable or run by a granted loader.
- `c`: create and remove; rename and link between granted paths.
- `u`: connect to the unix socket at this path. A socket grant delegates
  to the program whatever that service does for its callers, which is
  the point of granting it. Held by Landlock ABI 9, or by `isolate
  file`; on neither, the start fails. Any `u` grant also isolates the
  network, so the program cannot bind an abstract name a host client
  expects. Without a `u` grant, `socket(AF_UNIX)` is refused;
  `socketpair` is not.

A grant may bind a host path at another name (`["/tree"] = { from =
tree, letters = "r" }`) under `isolate file`; without it, that fails.
Each grant resolves once, links included, at the start, by descriptor;
that one resolution makes the Landlock rule, the bind under `isolate
file` and the report. A grant whose target differs from its name is
said at the start (`grant rwc: out -> /home/you`). A grant must exist.
Under `isolate file`, writable grants are mounted noexec unless also
granted `x`.

What is not granted cannot be opened, run, written, created or listed,
on every host. Its metadata -- existence, size, times, owner, through
`stat`, `access`, `readlink`, `chdir` -- is undefined unless `file` is
isolated.

### isolate

Isolation by effect, each met or the start fails:

- `file`: a root of the program's own, holding only what `paths` grant;
  anything else does not exist (ENOENT). Implies `proc`, since a program
  without a /proc of its own loses /dev/fd and /proc/self. Linux: user,
  mount, pid and IPC namespaces. macOS: refused.
- `proc`: a process space of its own and a /proc of its own (pid 1 is
  the sandbox's init). Linux: user, pid and mount namespaces, a fresh
  procfs; where the kernel refuses the procfs, the start fails.

The network is isolated whenever the policy grants any network, any
`loopback` or any `u`: a network namespace with a loopback, the
`loopback` addresses the program may bind and reach inside it, and the
relay's listeners.

Every isolation needs unprivileged user namespaces. Where they are
refused -- Ubuntu 24.04's `kernel.apparmor_restrict_unprivileged_userns`,
a container's seccomp profile -- the failure says so and names the fix:
the sysctl, as this repository's CI sets it, or an AppArmor profile for
cosmic alone.

Without `proc`, the program still never reaches the host's processes:
the host's /proc is never granted; signals are held to the sandbox by
Landlock ABI 6 scoping, or, without it, only the program's own pid may
be signalled (no `proc` promise); calls taking another pid
(`prlimit64`, `setpriority`, `sched_*`, `getpgid`, `getsid`) are allowed
only on its own. Abstract sockets are held by ABI 6 scoping, a network
namespace, or no unix sockets at all.

### promises

The system-call filter is an allow list. What the always-allowed basics
and the granted promises do not cover answers EPERM; a call above the
reviewed table, and `clone3` and `openat2` (whose arguments the filter
cannot read), answer ENOSYS so libc falls back; a refused ioctl answers
ENOTTY.

- Always allowed (OpenBSD's `stdio`, and what Landlock already holds by
  path): memory, time, signals to itself, threads, the descriptors it
  was handed, file reads, writes, creation and removal (held by
  `paths`), file-backed executable mappings (a dynamic loader's),
  execve, unix socketpairs, read-only terminal queries, `landlock_*` and
  `seccomp` filter installation (only ever narrowing).
- `proc`: fork, and clone without any namespace flag.
- `jit`: anonymous executable memory. Without it, `PR_SET_MDWE` refuses
  memory both writable and executable, through fork and exec.
- `fattr`: change a file's mode, times, owner, extended attributes; the
  setuid, setgid and sticky bits never.

Never allowed: ptrace, process_vm_*, mounts, pivot_root, bpf,
perf_event_open, kexec, modules, keyctl, io_uring, userfaultfd, setns,
open_by_handle_at, pidfd_getfd, process_madvise, unshare; ioctls and
prctl options outside their allow lists (no TIOCSTI, TIOCLINUX,
TIOCSETD, TIOCCONS); fcntl's F_NOTIFY and F_SETLEASE; vmsplice; inet
sockets but to the relay, which only the network namespace enforces.

The tables live in `core/promises.c`, one list of `__NR_` names per
promise and small argument rules, ported by hand from Cosmopolitan's
pledge-linux.c with its ISC notice and a `cosmic bom` record, for
x86_64 and aarch64. A cBPF interpreter in Teal checks every promise's
allowed and refused calls on both architectures from any host; a guard
test fails when the headers' highest system call passes the reviewed
mark.

### the network

Only through the relay. The program's network is its own; its only way
out is the relay, which listens on the program's loopback and connects
from the host's.

- `connect`: `host:port` the relay will open; `*` for any host or any
  port. Hosts are parsed strictly (lowercase labels, one trailing dot
  dropped, non-ASCII refused; addresses by `inet_pton`, bracketed for
  IPv6, no zone).
- The relay resolves a name once, refuses any answer in loopback,
  link-local, private, CGNAT, metadata (169.254.169.254, fd00:ec2::254,
  100.100.100.200, 168.63.129.16) or mapped and translated forms unless
  a grant names that address literally, and connects to the address it
  checked. A TLS ClientHello's SNI must match the requested host.
- It speaks HTTP CONNECT and SOCKS5 with names (`socks5h`); no
  plain-HTTP forwarding, no SOCKS4. Its DNS stub answers A and AAAA for
  granted names only; every lookup is a channel out, said so.
- The policy sets `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` in both
  cases, `NO_PROXY` for loopback, and `NODE_USE_ENV_PROXY=1`, and binds
  a `resolv.conf` naming the stub (a mount namespace).
- The relay is its own process: relaunched by the supervisor, holding
  only the listeners the sandbox's first process bound in its network
  and passed out, held by its own Landlock ruleset and filter, capped in
  connections, header bytes and queries. If it dies, the sandbox ends.
  It serves [`Child.start`] and the command line alike.

A program that ignores proxy variables -- ssh, rsync, database clients,
raw sockets, Java by default -- reaches nothing. `cosmic sandbox connect
HOST PORT` is a ProxyCommand for ssh; profiles may set a tool's own
proxy settings. A transparent mode, a userspace TCP stack in the
namespace turning every connect into a relay request, is on the roadmap.

### the terminal

Only `cosmic sandbox` gives a program a terminal, when the caller's
stdin or stdout is one: a pty it relays. Terminal ioctls are allowed
when a relay is attached. The relay passes text and an allow list of
control sequences, drops OSC, DCS, APC, PM and SOS but a window title,
answers terminal queries itself, forwards window size and signals, and
on exit restores the caller's terminal and flushes its pending input.
The program always starts a session of its own. [`Child.start`] with a
policy and a terminal on stdio fails, naming the fix.

### tmp, limits

- **tmp**: a fresh `/tmp` -- a tmpfs with a size under `isolate file`,
  or a mkdtemp directory granted `rwc` with `TMPDIR` naming it, removed
  after exit without following links.
- **limits**, by scope. `each` are rlimits on every process, always met,
  with defaults (no core dumps, 1024 open files; file size and CPU
  unlimited). `whole` hold the sandbox's tree and are met or the start
  fails: `processes` by a user namespace's count (Linux 5.14+), memory
  and CPU by a delegated cgroup v2. `isolate proc` brings a default
  `processes` ceiling of 4096; a sandbox without a user namespace gets no
  `whole` default, so a default never fails a start. Exhausting a
  resource is not containment: what `limits` does not ask, the sandbox
  does not promise. Disk is not limited but by `tmp`'s size.

### the program

Found on the caller's PATH (relative entries refused), resolved to its
real path once, run by that path with the name it was typed as as
argv[0] (rustup and busybox dispatch on it); a link to an interpreter
in a virtual environment is run as the link. Before the start a
relaunched helper, held by the same policy, reads its ELF interpreter
or `#!` line and names a missing grant in the failure; a foreign
architecture fails by name.

## Restricting the running process

`Sandbox.restrict(policy)` holds the calling process, and everything it
starts, to `paths`, `promises` and `limits` for good: Landlock and the
filter, applied to itself. A running process cannot move into a root of
its own, so a policy asking for `isolate`, `connect`, `loopback` or `u`
fails here. The test worker holds itself so, in place of today's
`forbid_running`.

## Nesting

A sandboxed program cannot build a sandbox of its own: the filter
refuses namespaces and mounts, and Landlock refuses mounts. A test that
needs to (the sandbox's own tests, a test running `cosmic test`) runs
unconfined, and says so.

## Tests

[`Test.needs`] declares a policy, in the policy's own fields, plus what is
only about tests (the Lua it loads, timeouts, fuzz corpora):

- `uses = { "system" }` for the system's files, `"cosmic"` for this very
  program and its core (today's `tool`);
- `paths` for files of the host (today's `host`), and `r` on the whole
  module store where a test reads beyond its closure (today's `store`);
- `loopback` for its 127/8 addresses (today's `network`), `env`,
  `promises`, `isolate` as anywhere;
- `unconfined = "why"` for a test that runs outside any sandbox (today's
  `nests`), reported as such.

The harness merges that with the worker's own grants (the tree at
/tree, its scratch as `tmp`, its store by descriptor) and starts the
worker with `Child.start({ policy })`; the worker holds itself with
`Sandbox.restrict`. A test's verdict key holds `Sandbox.encode` of its
merged policy. Where a platform has no sandbox at all, the harness runs
workers without a policy and reports it; the policy never weakens.

## One schema

`Sandbox.Policy` is the one source: the command line's flags are
generated from its fields, as `cosmic help` generates a verb's options;
its JSON keys and [`Test.needs`] keys are its field names. Profiles
(`system`, `cosmic`, more as callers need them) are policies shipped in
the binary, merged in by `uses`, `--system` or `--cosmic`.

## Errors

Each denial answers what its mechanism answers: EACCES for a path
Landlock refuses, EXDEV for a refused rename across grants, ENOENT for a
name `isolate file` hides, EPERM for a call the filter refuses, ENOSYS
and ENOTTY as above. A failed start exits 125, with the reason on stderr
and, with `--report-fd N`, as JSON on that descriptor, written before
the program runs, so the program's own 125 is never taken for one.

## The command line

```
cosmic sandbox [options] [--] program [args...]
  --read PATH (r)  --run PATH (rx)  --write PATH (rwc)  --path LETTERS:PATH
  --system         the system's programs, libraries, configuration, CA roots
  --isolate file|proc
  --promise proc|jit|fattr
  --connect HOST:PORT
  --cosmic         this program and its core
  --loopback ADDR  --user UID
  --tmp  --env NAME[=VALUE]  --fd N  --limit k=v,...  --timeout SECONDS
  --print-policy   --report-fd N
cosmic sandbox connect HOST PORT
```

```
cosmic sandbox --system --read . -- ls -l
mkdir y && cosmic sandbox --system --promise proc --isolate proc --write y \
  --connect github.com:443 -- git clone https://github.com/x/y y
cosmic sandbox --system --write . --tmp --promise proc --isolate file -- make
```

`--system` grants, read-only and runnable, exactly what `cosmic help
sandbox` lists, links resolved: /usr, /lib*, /bin, the loader's and the
locale's configuration, the CA roots; it passes PATH, LANG and TERM.

## macOS

The same policy compiles to a Seatbelt profile applied by a trampoline
(cosmic relaunched, `sandbox_init`, `execve`), paths passed as
parameters. `isolate` is refused. The relay listens on the host's
loopback with a per-sandbox token in the proxy URL, and the profile
allows the program that port alone.

## Phases

1. The filter (`core/promises.c`, its interpreter test, the bom
   record).
2. Landlock rulesets built in the child from descriptors: letters,
   scoping, the failure's remedies; `Sandbox.restrict`.
3. Isolation reshaped: `proc` alone, `file` implying `proc`, binds from
   descriptors and at other names, noexec writable binds, the mapped
   user, `loopback`, `whole` limits.
4. `cosmic.sandbox`, `Child.start({ policy })`, the profiles, the
   preflight.
5. The harness on the policy: [`Test.needs`] migrated, the worker held by
   `Sandbox.restrict`, keys from `Sandbox.encode` -- an epoch bump and a
   full run.
6. The `cosmic sandbox` verb, flags generated from the record,
   `--print-policy`, `--report-fd`.
7. Network prerequisites in the core: UDP, a resolver, descriptor
   passing, adopting a listener -- useful to [`cosmic.net`] alone.
8. The relay, `connect`, the DNS stub, `cosmic sandbox connect`.
9. The pty relay.
10. Seatbelt. Then policy files, the transparent network mode.

## History

- **Revision 1** proposed the policy and its layering. Review: grants
  following links, unix sockets reaching docker.sock, a thin seccomp
  floor, terminal leaks, an ABI-based check.
- **Revision 2** fixed those and added `show`. Review: promises
  unenforced in phase 1, DNS and outbound connections unable to
  coexist, policy files as attacker input, relay escape-sequence gaps,
  too many concepts, a phase 1 too large.
- **Revision 3** made isolation an effect, the network relay-only, the
  filter an allow list, grants resolved, files narrow-only, the pty
  relay the command line's alone, unix sockets a letter. Review: `u`
  unenforceable below Landlock ABI 9, narrowing judged by name, the
  relay a confused deputy (loopback, metadata, rebinding, fronting),
  processes reachable by pid, the DNS stub unreachable, examples
  breaking their own rules, overlapping concepts, and stock Ubuntu
  24.04 able to meet little.
- **Revision 4** fixed those; on Ubuntu 24.04, a failure names the
  sysctl or AppArmor profile that meets the policy, as CI already sets.
- **Revision 5**: limits by scope, exhaustion not containment unless
  asked; the harness on the policy from phase 1, its requirements turned
  into policy features (grants at other names, never root, `loopback`);
  no nesting, a nesting test unconfined and said; `Sandbox.restrict` in
  phase 1; [`Test.needs`] in the policy's own fields, with profiles for
  `system` and `cosmic`; `env` in the policy; one schema generating the
  flags; policy files out of phase 1.

## Open questions

- Profiles beyond `system` and `cosmic`, and setting tools' own proxy
  settings.
- Policy files: narrow-only, judged after resolution, needing `meet`.
- Plain-HTTP forwarding for package mirrors.
- Limits beyond rlimits (cgroups where delegated).

[`Child.Options`]: ../../cosmic/child.tl
[`Child.start`]: ../../cosmic/child.tl
[`cosmic.net`]: ../../cosmic/net.tl
[`Test.needs`]: ../../cosmic/test.tl
