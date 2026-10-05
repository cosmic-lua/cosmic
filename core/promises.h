/*
 * The promises filter: the seccomp program a sandboxed program is held
 * to beside its Landlock ruleset, as an allow list of system calls. What
 * the basics and the promises asked for do not name is refused with
 * EPERM; a call numbered above the reviewed table, `clone3` and
 * `openat2` answer ENOSYS, so a libc falls back; a refused ioctl answers
 * ENOTTY; a call of another architecture ends the process.
 *
 * The program is a pure function of the promises, the architecture and
 * the process's own pid and what else holds it (COSMIC_HELD_), so
 * core/syscalls.c has the child build and install it
 * ([`cosmic_promises_apply`]), and `promise_filter` builds it for either
 * architecture, whatever the host, for core/promises_test.tl's
 * interpreter. The tables are core/promises.c's.
 */

#ifndef COSMIC_PROMISES_H
#define COSMIC_PROMISES_H

#include <stdbool.h>

/* One past the highest call number the tables are reviewed to: a call
 * above it is answered ENOSYS. */
#define PROMISE_CALLS_REVIEWED 472

/* One past the highest call number the headers this core was built with
 * name, or 0 where they name no count (Linux's generic table, aarch64's,
 * does; x86_64's does not): a header past the reviewed number names
 * calls no one has judged. A value, not a function, so core/syscalls.c's
 * table of constants hands it to Lua. */
extern const int cosmic_promise_headers_end;
#define PROMISE_CALLS_HEADERS cosmic_promise_headers_end

/* The promises, as a set of bits: `fork` is fork and clone without a
 * namespace flag, `jit` anonymous executable memory, `fattr` changing a
 * file's mode, times, owner and extended attributes, `nest` building a
 * sandbox of its own. */
#define COSMIC_PROMISE_FORK 0x1u
#define COSMIC_PROMISE_JIT 0x2u
#define COSMIC_PROMISE_FATTR 0x4u
#define COSMIC_PROMISE_NEST 0x8u

/* The promise `name` names, as one bit of the set [`cosmic_promises_apply`]
 * takes, or 0 for a name that is none: "fork", "jit", "fattr" or "nest". */
unsigned cosmic_promise_named (const char *name);

/* The socket families a filter lets a process make with socket(): the
 * bits of the `sockets` of [`cosmic_promises_apply`]. A socketpair of unix
 * sockets is always allowed, and netlink and packet sockets never. */
#define COSMIC_SOCKETS_UNIX 0x1u
#define COSMIC_SOCKETS_INET 0x2u

/* What a process is held to by more than the filter, so that the filter
 * lets through a call whose arguments the filter cannot read but the
 * hold makes harmless: the bits of the `held` of [`cosmic_promises_apply`].
 * Each is the caller's to know from what it made, never to guess: a bit
 * set without its hold lets the process reach what the filter would have
 * kept it from.
 *
 * - `COSMIC_HELD_SIGNALS`: the process is in a Landlock domain that
 *   handles LANDLOCK_SCOPE_SIGNAL (ABI 6). The signal calls then take any
 *   pid, since the kernel refuses a target outside the domain, and
 *   pidfd_send_signal is allowed.
 * - `COSMIC_HELD_UNIX`: socket(AF_UNIX) is allowed. The process is in a
 *   root of its own that shows only what it was granted, in a network
 *   namespace of its own (its abstract sockets are its own and no host
 *   client reaches a name it binds), and held by one of two: a Landlock
 *   domain that handles LANDLOCK_ACCESS_FS_RESOLVE_UNIX (ABI 9), which
 *   refuses a connect to a socket file no `u` grant names; or a root that
 *   shows no directory of the host's and no socket file, so no socket
 *   exists there but the ones the process makes, which is all that holds a
 *   process below it, and one that promises `nest`, which has no Landlock
 *   domain, at any ABI. A root that shows a directory is held by neither
 *   where there is no domain or it is below ABI 9, and the hold is not
 *   given.
 * - `COSMIC_HELD_LIMITS`: setrlimit and prlimit64 that set the process's
 *   own limits are allowed. The process cannot raise a hard limit: it is
 *   in a user namespace the start made, or its capabilities lack
 *   CAP_SYS_RESOURCE of the initial one, which the kernel asks for it
 *   ([`cosmic_promises_apply`] sets this itself for the latter).
 * - `COSMIC_HELD_PIDS`: getpgid, getsid, setpgid and capget take any pid. The
 *   process is in a pid namespace of its own, so a pid it names is a
 *   process of the sandbox or none. */
#define COSMIC_HELD_SIGNALS 0x1u
#define COSMIC_HELD_UNIX 0x2u
#define COSMIC_HELD_LIMITS 0x4u
#define COSMIC_HELD_PIDS 0x8u

/* Holds the calling process, for good, to `promises` and to making
 * sockets of the families `sockets` names: no_new_privs, and
 * the program for this architecture and the process's own pid, installed.
 * 0, or an errno; ENOSYS off Linux, and on any architecture but x86_64
 * and aarch64. The pid is the one the scheduling rules, and the signal
 * calls unless `held` has COSMIC_HELD_SIGNALS, hold a call to, which stays
 * the process's across exec: a child calls this once it is the child, as
 * the last step before it execs. `held` is what the process is held to
 * besides (the COSMIC_HELD_ bits), which only the caller knows from what
 * it applied. */
int cosmic_promises_apply (unsigned promises, unsigned sockets, unsigned held);

#endif
