# Sandbox: a default-deny policy, its command line and its primitives

Status: draft for discussion, revision 3; not to merge. Revisions 1 and
2, their reviews and the decisions that followed are summarized at the
end.

## Goal

A simple, powerful command line and standard library that run a program
held, with everything it starts, to nothing at all, and let the caller
build up from there to what the program needs: the paths it reads,
writes, runs and creates, the hosts it reaches, the system calls it
makes, the terminal it uses, the environment it sees, the resources it
spends, and how far it is isolated from the rest of the host.

One rule over all of it: a policy is met, or the program does not
start. There is no strict mode and no best-effort mode; what the host
cannot enforce refuses the start and names what is missing.

Prior art: OpenBSD's pledge(2) and unveil(2); Cosmopolitan libc's port
of both to Linux and its `pledge` command; bubblewrap; landrun and
landlock-rs; Deno's permission flags; systemd's sandboxing; macOS
Seatbelt; Anthropic's sandbox-runtime.

## Layers

- **Public: one policy, `cosmic.sandbox`**, plain typed records and pure
  functions over them; no builder. `Child.start(argv, { sandbox =
  policy })` runs a child under it; `cosmic sandbox` is its command line.
- **Internal: the primitives** -- namespaces, Landlock, the seccomp
  filter -- through the raw `spawn` sandbox in core/process.h, which the
  policy compiles to through new bindings beside the old ones.
- **The test harness stays on the primitives.** It needs what no policy
  needs yet (a tree bound at /tree, a worker mapped to uid 65532, a
  noexec scratch, a store handed by descriptor). Harness and policy share
  one conformance matrix. [`Child.Sandbox`]'s public fields move off the
  public surface.

## The policy

```teal
local policy: Sandbox.Policy = {
  paths = { ["/usr"] = "rx", ["."] = "rwc", ["/run/user/1000/bus"] = "u" },
  isolate = { "file", "proc", "net" },
  promises = { "proc", "tty" },
  net = { connect = { "github.com:443", "pypi.org:443" }, dns = true },
  env = { PATH = true, LANG = "C.UTF-8" },  -- true passes, a string sets
  fds = { [3] = log_fd },
  tmp = true,
  limits = { cpu_s = 60, memory_bytes = 2 << 30 },
}
```

Nothing is granted that the policy does not name. Functions:
`Sandbox.decode`/`encode` (one canonical JSON, unknown keys refused),
`Sandbox.merge` (a profile, a file, the flags), `Sandbox.check` (what
this host can meet, from a probe). `meet`, `within` and `digest` wait on
a caller: nested sandboxes, `restrict`, a key.

### paths

Letters, each a set of rights:

- `r`: read files, list directories.
- `w`: write and truncate files.
- `x`: execve. Only that: a granted, readable file can still be run by a
  granted loader.
- `c`: create and remove; rename and link between granted paths.
- `u`: connect to the unix socket at this path. A socket grant delegates
  to the program whatever that service does for its callers -- a
  session bus, an agent, a container daemon -- which is the point of
  granting it.

Each grant resolves once, links included, at the start, by descriptor;
that one resolution makes the Landlock rule, the bind under `isolate
file` and the report. A grant whose target differs from its name is
said at the start (`grant rwc: out -> /home/you`) and in the printed
policy. A grant must exist.

What is not granted cannot be opened, run, written, created or listed,
on every host. Its metadata -- whether it exists, its size, times and
owner, through `stat`, `access`, `readlink`, `chdir` -- is undefined
unless `file` is isolated: Landlock cannot hold those calls, a root of
the program's own can.

### isolate

Isolation by effect, each a request a host meets or the start fails:

- `file`: a root of the program's own, holding only what `paths` grant;
  anything else does not exist (ENOENT). Linux: a mount namespace.
  macOS: refused.
- `proc`: a process space of its own: it sees and signals only what it
  started, and gets a /proc of its own. Linux: a pid namespace.
- `net`: a network of its own, a loopback and nothing else; the outside
  only through the relay. Linux: a network namespace. Implied by any
  `net` grant.

Without `proc`, the program still never sees the host's processes: the
host's /proc is never granted, and signals and abstract sockets are
scoped to the sandbox (Landlock ABI 6). A host that can give neither
that scoping nor `proc` and `net` isolation refuses every start.

### promises

The system-call filter is an allow list: what the always-allowed basics
and the granted promises do not cover is refused, and a call it does not
know answers ENOSYS, so libc falls back.

- Always allowed (OpenBSD's `stdio`): memory, time, signals to itself,
  threads, the descriptors it was handed, read-only terminal queries,
  file-backed executable mappings (a dynamic loader's).
- `proc`: fork, and clone without namespace flags.
- `tty`: drive its terminal (termios, job control, window size).
- `jit`: anonymous executable memory.
- `fattr`: change a file's mode, times, owner, extended attributes.
- `id`: setuid and its kin.

Never allowed: ptrace, process_vm_*, mounts, pivot_root, bpf,
perf_event_open, kexec, modules, keyctl, io_uring, userfaultfd, setns,
open_by_handle_at, pidfd_getfd, process_madvise, unshare and clone with
namespace flags; sockets but unix and, inside `isolate net`, TCP to the
relay; TIOCSTI and TIOCLINUX. `landlock_*` and `seccomp` stay allowed,
so a program that sandboxes itself still can.

Ported by hand from Cosmopolitan's pledge-linux.c (ISC) for x86_64 and
aarch64, reviewed against each new kernel.

### net

Only through the relay. Any network grant implies `isolate net`; the
program's only way out is the supervisor's relay on its loopback: an
HTTP CONNECT and SOCKS proxy, named in `HTTPS_PROXY`, `HTTP_PROXY` and
`ALL_PROXY`, and a DNS stub named in the program's resolv.conf.

- `connect`: `host:port` the relay will open, by name or address; `*`
  for any host.
- `dns`: names resolved through the stub, answering A and AAAA only.
  Every lookup leaves the sandbox: it is a channel out, said so.

A program that ignores proxy variables reaches nothing; that is said,
not worked around. The relay works alike on macOS.

### the terminal

Only `cosmic sandbox` gives a program a terminal: a pty it relays. The
relay passes text and an allow list of control sequences (colour,
cursor movement, a few modes), drops OSC, DCS, APC, PM and SOS but a
window title, answers terminal queries itself, forwards window size and
signals, and on the program's exit restores the caller's terminal and
flushes its pending input. The program always starts a session of its
own. [`Child.start`] with a policy and a terminal on stdin, stdout or
stderr refuses, naming the fix.

### descriptors, env, tmp, limits

- **fds**: the program gets 0, 1, 2 and what `fds` names; everything
  else is closed.
- **env**: nothing by default; `true` passes a variable, a string sets
  it.
- **tmp**: a fresh `/tmp` of its own -- a tmpfs under `isolate file`, or
  a scratch directory granted `rwc` with `TMPDIR` naming it.
- **limits**: rlimits, per process, said so (`RLIMIT_NPROC` counts the
  user's processes, `RLIMIT_AS` breaks programs that reserve address
  space); a wall-clock limit; the exit says which fired, with peak
  memory and CPU time.

### the program

Found on the caller's PATH, resolved to its real path once, granted
`rx`, run by that path. Before the start its ELF interpreter, or its
`#!` line, is read in a confined helper, and a missing grant is named in
the refusal; libraries are a hint, not a check.

## Policy files

JSON, unknown keys refused, paths relative to the file. A file can only
narrow what the command line grants, never add to it: a cloned project's
policy cannot reach outside what its user typed.

## Errors

Each denial answers what its mechanism answers, documented per kind:
EACCES for a path Landlock refuses, EXDEV for a refused rename across
grants, ENOENT for a name `isolate file` hides, EACCES for a call the
filter refuses, ENOSYS for a call it does not know. A refused start
exits 125 and is reported on a descriptor of the supervisor's, so the
program's own 125 is never taken for one.

## The command line

```
cosmic sandbox [options] [--] program [args...]
  --read PATH  --run PATH  --write PATH (rwc)  --grant LETTERS:PATH
  --isolate file|proc|net
  --promise NAME            proc, tty, jit, fattr, id
  --connect HOST:PORT       --dns
  --env NAME[=VALUE]        --fd N     --tmp     --limit k=v,...
  --system                  the system's programs, libraries, configuration
  --policy FILE             narrows; repeatable
  --print-policy  --check
```

```
cosmic sandbox --system --read . -- ls -l
cosmic sandbox --system --tls --write y --dns --connect github.com:443 \
  -- git clone https://github.com/x/y y
cosmic sandbox --system --write . --tmp --promise proc --isolate file -- make
```

Profiles (`--system`, `--tls`, more as callers need them) are policies
shipped in the binary, listing exactly what they grant in `cosmic help
sandbox`.

## macOS

The same policy compiles to a Seatbelt profile applied by a trampoline
(cosmic relaunched, `sandbox_init`, `execve`), paths escaped or passed
as parameters. `isolate file` is refused; `proc` maps to Seatbelt's
process rules; the relay works as on Linux.

## Phases

1. Policy, functions, command line; the allow-list filter; paths with
   one resolution; `isolate`; the relay (proxy and DNS stub); the pty
   relay; descriptors, env, tmp, limits; the program's preflight.
   Split, in order: the filter; grants and `isolate`; the policy and the
   verb; the relay; the pty relay.
2. Seatbelt.
3. `Sandbox.restrict`, nested sandboxes (`meet`, `within`), `--learn`.

## History

- **Revision 1** proposed the policy and the layering. Its review found
  grants that followed links, unix sockets reaching docker.sock, a thin
  seccomp floor, a wrong claim about abstract sockets, terminal leaks
  and an ABI-based `check`.
- **Revision 2** fixed those and added `show`. Its review found
  promises unenforced in phase 1, DNS and outbound connections unable to
  coexist, policy files as attacker input, relay escape-sequence gaps,
  about fourteen concepts where eight would do, and a phase 1 too large.
- **Decisions since**: `show` split into access, listing, metadata and
  processes, with metadata undefined unless `file` is isolated;
  isolation by effect; no strict mode; network through the relay only;
  an allow-list filter from the start; grants resolved and reported;
  policy files narrow only; the pty relay in the command line alone;
  unix sockets a path letter, with no list of "escape" sockets.

## Open questions

- Profiles beyond `--system` and `--tls`, and exactly what each grants.
- Limits beyond rlimits (cgroups where delegated).
- Whether `--learn` belongs at all.

[`Child.Sandbox`]: ../../cosmic/child.tl
[`Child.start`]: ../../cosmic/child.tl
