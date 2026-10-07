/*
 * The process table: the calls [`cosmic.child`] starts, feeds and reaps a
 * child with, and [`cosmic.proc`] looks up accounts and relaunches with.
 * Registered as the raw [`cosmic.internal.process`] module, which only
 * those wrappers (and [`build.confine`], which starts a test's sandboxed
 * children through it) are handed: none of it is public. A
 * public `waitpid(-1)` would reap a child a `Child` handle owns in an
 * adopting process, and a public spawn would start one no handle owns.
 *
 * The grammar and the two shapes are core/syscalls.h's: each entry is a
 * LuaCATS annotation block followed by COSMIC_SYSCALL naming it, which
 * [`build/gen_syscalls.tl`] turns into the declaration of
 * [`cosmic.internal.process`]. The functions themselves live in
 * core/syscalls.c, with the signal state and descriptor handling they
 * share with `execve`.
 */

#ifndef COSMIC_PROCESS_H
#define COSMIC_PROCESS_H

#include <stdbool.h>
#include <stdint.h>

#include "lua.h"
#include "promises.h"
#include "syscalls.h"

/* The most paths a sandbox unveils (`Unveil`): a test worker's
 * (build/test_sandbox.tl) is given each file of its module's import
 * closure by name. */
#define UNVEIL_MAX 256

/* The most parameters a Seatbelt profile takes (`Seatbelt`'s
 * `parameters`): a grant's path is one each, and a start's argv carries
 * them ([`cosmic_trampoline`]). */
#define SEATBELT_PARAMETER_MAX 512

/* How many descriptors `spawn` places above the highest it hands a
 * child (`top` + 2 and up), besides a copy of each it hands: the status
 * pipe's two ends; the ruleset; and, for an unveiled child, /proc/self
 * and the mapping pipe's two ends for one that gives root up, this
 * program, and the started and ready pipes' four ends
 * (core/syscalls.c's `start_unveiled`); and the relay's channel
 * (`Sandbox`'s `relay`). F_DUPFD refuses them past
 * RLIMIT_NOFILE's soft limit; cosmic.child's `start` says so where the
 * limit leaves too few. A descriptor placed there besides counts here. */
#define SPAWN_PLACED_ABOVE 12

/* What a signal stamp counts each caught signal as: the stamp is their
 * count times this, plus the last one's number, which is below it. */
#define SIGNAL_STAMP_UNIT 64

/* The native connector's protocol (core/connector.c), which
 * core/socket.c's lookups through a connector and cosmic.net speak too.
 * The connector says CONNECTOR_HELLO first, "CNC" and the protocol's
 * version as one big-endian word, so a client of another version is
 * told so before it asks anything. A request is CONNECTOR_REQUEST_BYTES;
 * a reply carries its tag back, and replies come in the order the
 * connects end. At most CONNECTOR_FLIGHT connects are made at once: a
 * request for another is answered CONNECTOR_BUSY. CONNECTOR_DENIED is a
 * public connector's refusal by its lists. Both are past any errno, so a
 * kernel's failure to connect is never taken for either. */
#define CONNECTOR_HELLO 0x434e4302
#define CONNECTOR_REQUEST_BYTES 36
#define CONNECTOR_FLIGHT 64
#define CONNECTOR_DENIED 0x10000
#define CONNECTOR_BUSY 0x10001

/* Raises RLIMIT_NOFILE's soft limit toward the hard one, as far as
 * 10240 (macOS's OPEN_MAX) or kern.maxfilesperproc where that is lower,
 * as a Go program's runtime does at its start:
 * a spawn places descriptors above the highest it hands a child, 257
 * and up for a relaunch, past a soft limit as low as macOS's default.
 * A program this process execs is given the soft limit it started with
 * back, unless it set RLIMIT_NOFILE itself (`setrlimit`). A refusal leaves the
 * limit as it was. `main` calls it before anything starts a child. */
void cosmic_raise_descriptor_limit (void);

/* Opens the table as the raw [`cosmic.internal.process`] module. */
int cosmic_open_process (lua_State *L);

/* Records the working directory the runtime was entered in, for
 * `relaunch`'s `cwd`. */
void cosmic_process_entered (void);

/* Whether the innermost open [`Child.guard`] has yet to read a SIGINT
 * or SIGTERM caught since it opened or last read (`child_signal_read`):
 * a wait of core/http.c's asks it each round, so a signal ends a read
 * or an open that no data would. It reads the signal without taking
 * it, so the guard's holder still sees it. */
bool cosmic_signal_caught (void);

/* The longest a wait sleeps before it asks again whether a guard caught
 * a signal. A signal that lands between that question and the sleep
 * only sets the guard's flag, so a sleep with no bound could outlast
 * it forever; each slice bounds how late it is seen, as core/http.c's
 * one-second polls and cosmic.child's do. */
#define COSMIC_WAIT_SLICE_MS 100

/* Milliseconds on the monotonic clock. */
int64_t cosmic_now_ms (void);

/* How long a wait for `deadline` (on [`cosmic_now_ms`]'s clock, -1 for
 * no limit) may sleep now: a slice at most, 0 once it has passed. */
int cosmic_wait_slice (int64_t deadline);

/* Sleeps `*pause` milliseconds, doubling it up to a slice for the next
 * time, before a call that answered EAGAIN is asked again: 0 to ask
 * again, ETIMEDOUT once `deadline` has passed, EINTR once a guard has
 * caught a signal. */
int cosmic_paused (int64_t deadline, int64_t *pause);

#if defined(__linux__)
#include <stdbool.h>

/* The name an unveiled child's init runs this program under, as its
 * argv[0] and nothing else (core/syscalls.c's `start_init`). */
#define COSMIC_SANDBOX_INIT "cosmic sandbox init"

/* The name it goes by (/proc/<pid>/comm), for a reader of `ps`. */
#define COSMIC_SANDBOX_INIT_COMM "cosmic-init"

/* Whether this start is an unveiled child's init: argv is
 * COSMIC_SANDBOX_INIT alone, this is pid 1 of its pid namespace, its
 * environment is empty, and 0, 1 and 2 are the pipes `start_init`
 * hands it -- so a pid 1 started under that name by anything else, as
 * `exec -a` can, is not taken for one. `main` asks before anything of a
 * start. */
bool cosmic_sandbox_init_asked (int argc, char **argv);

/* Pid 1 of an unveiled child's pid namespace (core/syscalls.c). */
_Noreturn void cosmic_sandbox_init (void);
#endif

#if defined(__APPLE__)
#include <stdbool.h>

/* The name Darwin's child start runs this program under, as its argv[0],
 * to give a child what posix_spawn has no step for before its own exec
 * (core/syscalls.c's `spawn_program`). */
#define COSMIC_TRAMPOLINE "cosmic trampoline"

/* Whether this start is a child's trampoline: argv[0] is
 * COSMIC_TRAMPOLINE, the arguments are as `spawn_program` makes them, and
 * the status descriptor they name is a pipe. `main` asks before anything of
 * a start. */
bool cosmic_trampoline_asked (int argc, char **argv);

/* Gives the child its own session and terminal, its limits and its
 * Seatbelt profile, then executes the program the arguments name, with
 * this process's environment: it is that program's, which no step of the
 * start touched. A failure, and a profile's refusal above all, is
 * reported over the status descriptor and ends this process, never
 * the program (core/syscalls.c). */
_Noreturn void cosmic_trampoline (int argc, char **argv);
#endif

#endif

/* Entries, as core/syscalls.h's are: X-macros core/syscalls.c expands
 * again into the table the module is opened with. */
#ifndef COSMIC_SYSCALL
#define COSMIC_SYSCALL(name, arity) int cosmic_sys_##name(lua_State *L)
#endif
#ifndef COSMIC_CONSTANT
#define COSMIC_CONSTANT(name)
#endif

/*
 * --- The numeric identity of a named account.
 * ---@class User
 * ---@field uid integer the user identifier
 * ---@field gid integer the primary group identifier
 */

/*
 * --- Looks up a nonempty name without NUL bytes through getpwnam_r in this process. Only uid and gid are copied. The caller buffer grows up to 1 MiB; this bounds neither libc's own allocation nor directory-service latency. Missing is nil with an empty reason and errno 0; malformed names raise.
 * ---@param name string the account name
 * ---@return User|nil user the numeric identity, or nil when missing or lookup failed
 * ---@return string error what went wrong, empty when missing
 * ---@return integer errno the error number, 0 when missing
 */
COSMIC_SYSCALL(user, 1);

/*
 * --- One numeric TCP endpoint already resolved and approved by the sandbox's trusted launcher. Port 0 grants ports 1 through 65535 at this address; it does not grant another address.
 * ---@class ConnectorEndpoint
 * ---@field host string a canonical numeric IPv4 or IPv6 address, without a scope
 * ---@field port integer the granted port, or 0 for any nonzero port
 */

/*
 * --- Makes the private stream socketpair a native connector uses. Both descriptors are close-on-exec and the caller must close both. No child is started.
 * ---@return {integer}|nil pair two owned Unix stream descriptors, or nil on failure
 * ---@return string error what went wrong, when pair is nil
 * ---@return integer errno the error number, when pair is nil
 */
COSMIC_SYSCALL(connector_pair, 0);

/*
 * --- What a public native connector refuses, as data its caller owns: the connector holds no list of its own. Each `deny` entry is a numeric "address/bits" prefix, IPv4 or IPv6; each `own` entry a numeric address of the host, which an IPv4-mapped IPv6 spelling reduces to the IPv4 address it carries. At most 128 deny entries and 256 own addresses. An address is refused when a deny prefix or an own address holds it, and an IPv6 address also unless it is in 2000::/3, so IPv4-mapped and NAT64 forms are refused undecoded.
 * ---@class ConnectorPublic
 * ---@field deny {string} the refused prefixes, such as "10.0.0.0/8" and "fc00::/7"
 * ---@field own {string}|nil the host's own numeric addresses, refused as their own
 */

/*
 * --- Starts the sandbox's native TCP connector, held to at most 128 approved numeric endpoints in immutable memory and no file access, exec, fork or descriptor replacement. Wildcard port tables together hold at most 262144 addresses. The caller supplies one end of connector_pair, retains ownership of it, and closes its copy after starting. The connector first writes `CONNECTOR_HELLO` (socket's constants), a big-endian word, and then serves requests, each `CONNECTOR_REQUEST_BYTES` (36): big-endian words of a tag, a 1-based endpoint index, a port, a wait in milliseconds (the connect's, at most `timeout_ms`; 0 for `timeout_ms`) and a family, then 16 address bytes; a table request's family and address are zero (EINVAL otherwise). Up to `CONNECTOR_FLIGHT` connects are made at once, a request for another answered `CONNECTOR_BUSY`. A reply is the request's tag and an errno, big-endian words, then, on success only, the NUL marker and one SCM_RIGHTS descriptor recvfds expects; replies come as connects end, in any order, each whole. Closing the other end ends the connector; the caller owns and reaps its pid. Linux x86_64 and aarch64; ENOSYS elsewhere.
 * --- With `public`, the connector also connects to an address no table holds. Its request's index is 4294967295 (0xffffffff), its family 4 or 6 and its 16 address bytes the address (an IPv4 address in the first four, the rest zero). Index 0 is refused (EPERM) by every connector. The connector classifies the address against `public`'s data in its own confined process and, if allowed, connects through a writable scratch slot its filter accepts beside the table's immutable ones. The reply is the table's, with `CONNECTOR_DENIED` for an address its lists refuse, EINVAL for a malformed request and EPERM where the connector is not public. Port 0 asks only for the decision: errno 0 for an allowed address, and no socket or descriptor. The table may then be empty.
 * ---@param endpoints {ConnectorEndpoint} the launcher's checked, frozen numeric endpoints; empty only with `public`
 * ---@param control integer the private Unix stream descriptor, checked like every descriptor
 * ---@param timeout_ms integer connect deadline, from 1 to 60000 milliseconds
 * ---@param public ConnectorPublic|nil what a public connector refuses; nil for a table-only connector
 * ---@return integer|nil pid the confined child, or nil on failure
 * ---@return string error what went wrong, when pid is nil
 * ---@return integer errno the error number, when pid is nil
 */
COSMIC_SYSCALL(connector_start, 4);

/*
 * --- A synthetic immutable address-table range used to inspect the connector's seccomp program, without installing one.
 * ---@class ConnectorRange
 * ---@field base integer address of the first 128-byte table slot, aligned to 128
 * ---@field slots integer number of slots, from 1 to 65535
 * ---@field length integer sockaddr size: 16 for Linux IPv4, 28 for Linux IPv6
 */

/*
 * --- Builds the native connector's actual seccomp program for either supported Linux architecture; its layout is promise_filter's eight-byte instructions. No filter is applied.
 * ---@param architecture string "x86_64" or "aarch64"
 * ---@param ranges {ConnectorRange} the immutable table ranges, at most 128
 * ---@param control integer the protected private Unix stream descriptor
 * ---@param status integer the startup pipe descriptor
 * ---@return string program the generated classic BPF program
 */
COSMIC_SYSCALL(connector_filter, 4);

/*
 * --- Runs a fixed native security probe in a child under the connector's actual filter, with one approved endpoint (a "scratch_" one with an empty-deny public connector). No arbitrary code is run. An operation refused by seccomp returns its errno; a killed probe returns minus its signal number.
 * ---@param endpoint ConnectorEndpoint the approved endpoint
 * ---@param operation string "pointer", "length", "mutation", "mprotect", "remap", "dup", "recvmsg", "sendto", "sendmsg", "close_control", "udp", "open", "exec" or "fork"; or, on a public connector's scratch page, "scratch_mprotect", "scratch_remap", "scratch_pointer", "scratch_length", "scratch_offset", "scratch_past" or "scratch_swapped"; or "unscratched", on a table-only connector with a writable page its filter does not list
 * ---@return integer|nil result the refusal errno or negative terminating signal, or nil on setup failure
 * ---@return string error what went wrong, when result is nil
 * ---@return integer errno the setup error number, when result is nil
 */
COSMIC_SYSCALL(connector_probe, 2);

/*
 * --- The paths a sandbox unveils, each absolute; at most `UNVEIL_MAX` in all.
 * ---@class Unveil
 * ---@field reads {string} the files and directories the child has, read-only
 * ---@field writes {string} the ones it has to change too
 * ---@field at {string:string} for a path of `reads` or `writes`, by that path as given, the absolute name it is bound at in the child's root instead of its own -- not /, and no link to it is made there -- so a tree given at /tree is there alone, wherever the host has it; nil for none
 * ---@field binds {Bind} paths with more said of each than `reads` and `writes` say, bound as those are, each one entry of the `UNVEIL_MAX`; nil for none
 * ---@field tmp integer the size in bytes of a /tmp of the root's own: a tmpfs, noexec unless `tmp_exec`, which `grants` are given read, write and create beneath; needs `strict`, or it raises. Nil for the default /tmp, of no set size and not noexec, and with `strict` for no /tmp at all
 * ---@field tmp_exec boolean with `tmp`, whether what is made in that /tmp may execute: the tmpfs is not mounted noexec and `grants` are given execute beneath it too, as a grant `rwxc` is; nil or false for a /tmp that cannot run what it holds. Needs `tmp`, or it raises
 */

/*
 * --- Where a sandbox's relay listeners are made and where they go (`Sandbox`'s `relay`).
 * ---@class Relay
 * ---@field fd integer this process's end of a stream socketpair, which `recvfds` reads two listening descriptors from once `spawn` has answered (the start waits for the child to exec or fail, so they are there): the first at `ports[1]`, the second at `ports[2]`. The child's copy is closed once it has sent them; this process closes its own, which must be 3 or more. After a start that failed it closes the channel and trusts no pair read from it: a failed start may have sent both before failing later, and what it holds is not a relay
 * ---@field ports {integer} the two ports, 1 to 65535 and differing (a port twice raises), or nil for 3128 (HTTP CONNECT) and 1080 (SOCKS5)
 */

/*
 * --- One path an unveiled root holds, as the `binds` of `Unveil` list them.
 * ---@class Bind
 * ---@field path string the host's file or directory, absolute, resolved when the child starts
 * ---@field at string the absolute name it is bound at in the child's root instead of its own, as `Unveil`'s `at` says (and not a name another bind is at); nil for its own, with a link there for a name it was given through
 * ---@field writable boolean whether the child may change it; read-only otherwise
 * ---@field noexec boolean whether the mount is noexec, so nothing there executes, nor maps executable, through any alias of it
 * ---@field idmap boolean with `Sandbox`'s `user`, whether the mount is idmapped: the user and group that own the path -- and no other -- are the user and group the child runs as, so it reads and writes what only the owner may, and what it creates the owner owns on the host. Made by this process before the child's namespaces, so it needs CAP_SYS_ADMIN where the file system is mounted, Linux 5.12 and a file system that supports idmapped mounts (ext4, xfs, btrfs, tmpfs); a start that fails to make one answers a message naming the path (`strict`)
 */

/*
 * --- One path a child is granted, and what it may do there (`Sandbox`'s `grants`).
 * ---@class Grant
 * ---@field path string the file or directory, as this process sees it: a relative one from its working directory, resolved once, through links, when the child starts; it must exist, or the start fails naming it
 * ---@field access string letters of "rwxcu", in any order: `r` reads files and lists directories; `w` writes and truncates files (truncating needs Landlock ABI 3); `x` runs files; `c` creates and removes files, directories, links, fifos and sockets (never a device node), and renames and links between granted paths (Landlock ABI 2 and up; EXDEV where no grant allows the move); `u` connects to the unix socket at the path (Landlock ABI 9: below it the start fails, EOPNOTSUPP, naming the ABI the kernel gives, unless the child is `strict` with an `unveil`: Landlock then cannot tell one socket from another, so the caller must bind no socket but this one into the root -- `cosmic.child`'s policy start refuses a `u` grant below ABI 9 beside any directory or other socket grant). A grant on a directory reaches what is beneath it; on a file, what a file takes -- `c` on one grants nothing
 */

/*
 * --- What `spawn` holds a child to from its exec on, with every process it starts.
 * ---@class Sandbox
 * ---@field ruleset integer a ruleset from `landlock_ruleset`, or nil for none. It is built in this process, from paths as this process sees them, before the child has a root of its own, and holds the files those paths are, and nothing of the network, which `offline` holds: with `unveil`, a rule on a path the child is given reaches it, but none reaches what the child's root is built of -- its own /tmp, the directories above an unveiled path, / itself, and its own /proc -- which no path here names, so a child held to one cannot write its own /tmp, list /, or read its own /proc -- though, where the kernel gives it the host's (see `unveil`), a ruleset naming /proc reaches that. With `unveil` and `offline` it holds nothing more that matters of the filesystem, the network or signals -- a narrower ruleset is a narrower unveiling, the network namespace reaches nothing past the child's own loopback, nor shares an abstract unix socket with any process outside it, and the pid namespace holds no process outside it to signal. And a child it holds cannot confine one of its own, since Landlock refuses a mount or pivot_root to a process it holds
 * ---@field grants {Grant} the paths the child may reach and how, or nil for no such hold: a Landlock ruleset built in this process, from each path opened once with O_PATH, that handles every filesystem right the kernel's ABI knows, up to ABI 9's (a newer kernel's rights are left allowed), so anything no grant gives is refused with EACCES (or EXDEV, for a rename or link REFER does not allow) -- the child's own program too, which needs `rx` -- and device files' ioctls are never given. Where the kernel has them it holds the child further: ABI 6 scopes it, so it reaches no abstract unix socket and signals no process outside its own domain, and ABI 4 refuses it TCP, bind and connect alike, there being no way to grant either. A kernel below an ABI loses that part and the start goes on, except for a `u` grant. `grants = {}` grants nothing, which is a start that fails unless the program itself is granted: a child needs `rx` on its program and on the loader or interpreter it names (EACCES, the message says so). Not with `ruleset`, which it is built to replace; it holds as a ruleset does, last before the promises filter, and the same limits (stat and the like are not held, a descriptor handed in is as open as it was). Linux; ENOSYS elsewhere, and, where there is no Landlock (not built in, turned off, or refused by a filter) the start fails with the reason and what to enable
 * ---@field rlimits {string:integer} limits the child is held to, soft and hard together so it cannot raise one: by resource, `nofile` (RLIMIT_NOFILE, descriptors it may hold open), `fsize` (RLIMIT_FSIZE, the most bytes of a file it may write), `cpu` (RLIMIT_CPU, CPU seconds before SIGKILL: soft and hard are the same, so no SIGXCPU comes first), `core` (RLIMIT_CORE, 0 for no core dump) or `nproc` (RLIMIT_NPROC: with a user namespace of the child's own, whose user is its alone -- `unveil`, `proc` -- the kernel counts every process and thread of the whole sandbox, Linux 5.17 on, against it; without one, every process of this process's user); math.maxinteger for none, and a negative one raises. Set in the child after its descriptors are placed, so a `nofile` below the descriptors it is handed leaves those open and refuses more; a limit above the parent's hard one fails the start with EPERM. Linux and macOS, where a process of this program sets them just before the profile and the exec; ENOSYS elsewhere
 * ---@field unveil Unveil what alone the child has of the filesystem, or nil for all of it: a root of its own, in namespaces of its own -- a pid namespace among them, of which it is pid 2, beneath an init of its own at pid 1 that ends when it does, ending whatever it left running there, and ends when this process does, so it sees and signals only the processes it starts, while its pid, status and signals here are any child's; and a session of its own, and so a process group of its own whatever `process_group` says, with no controlling terminal -- and System V IPC of its own, holding those paths at the names they resolve to, or each at the name `at` gives it, and, for each given through a link, that link there too -- and, with /proc among them and no /dev given whole, /dev/fd and /dev/stdin, /dev/stdout and /dev/stderr as links into it, and, unless /tmp or / is among them, a /tmp of its own that its own children share, empty but for the paths given beneath the host's -- and nothing else, so a path outside them is not there to stat any more than to open. A ruleset with it reaches the unveiled paths alone (see `ruleset`): a rule on a directory above one does not reach into it, since each is a mount of its own, so name the unveiled paths themselves. /proc given is a procfs of its pid namespace, holding that namespace's processes and nothing of the host's (no /proc/sys and the like; a path beneath /proc given besides it is not there), and writable, so the child can map its own child's ids and confine one of its own in turn: what it can write there is its own processes' and its own session's. Where the kernel refuses one -- a container's runtime masking parts of its /proc, as Docker's does without --security-opt systempaths=unconfined, where a user namespace may not mount a procfs -- it is the host's, read-only like any path given to read, so the child cannot confine one of its own (EROFS); it shows the host's processes and state, and its pids are the host's, not the ones the child is in: /proc/self and /proc/thread-self are the child's own, /proc/<its getpid()> another process's. A child confined from inside another sandbox -- one whose root user has given up the CAP_SETFCAP that mapping root into a user namespace takes -- runs as root unmapped: the kernel's overflow id (65534) inside, owning what root owns but with no capability to override a file's permissions, on a root and a /tmp built in a directory of its TMPDIR, which is left there; unmapped, it cannot confine one of its own again. Linux, where unprivileged user namespaces are allowed; ENOSYS elsewhere, and EPERM or the like where they are not
 * ---@field noexec_scratch boolean with `unveil`, a fresh writable tmpfs at /noexec whose files cannot execute. No unveiled path or alias may occupy /, /noexec or beneath /noexec. This option does not change ordinary /tmp policy. Reading, interpreting or copying its bytes elsewhere is allowed. Linux only; creation failure is reported without a host-directory fallback
 * ---@field strict boolean a policy's sandbox, in which a start met whole or failing: with `unveil`, no /tmp but `unveil`'s `tmp`; a root's own tmpfs (so the user must be mapped: EPERM for a root inside another sandbox, which has none); a procfs of its own or no start, with no fallback to the host's /proc; and `grants` given Landlock's rules for its own /proc and /tmp. A start that fails in making its namespaces, its procfs or its root answers a message naming the remedy -- unprivileged user namespaces (user.max_user_namespaces, kernel.unprivileged_userns_clone, kernel.apparmor_restrict_unprivileged_userns), or the container option a procfs needs (--security-opt systempaths=unconfined) -- and its errno
 * ---@field proc boolean a pid namespace and a procfs of its own over the host's /proc, in a mount namespace of its own, the host's filesystem otherwise and not a root of its own: the child is pid 2 beneath an init, as with `unveil`, whose other namespaces and session it shares; no fallback to the host's /proc, a refusal fails the start. Not with `unveil`
 * ---@field sockets {string} with `promises`, the socket families the child may make with socket(): "unix" (AF_UNIX) and "inet" (AF_INET and AF_INET6); netlink and packet sockets never. With `grants`, "inet" leaves TCP unhandled (below Landlock ABI 4 it always was), the network namespace being what holds it: give it with `offline`, which `sockets` requires
 * ---@field offline boolean a network namespace of its own, with nothing but a loopback, which is up: a connection to 127.0.0.1 reaches a listener of the child's own processes, or is refused
 * ---@field host_network boolean with `promises` and `sockets` naming "inet" alone (a "unix" socket in the host's network would reach the host's abstract names), and no `offline`: the child keeps the host's network, and may make inet sockets there. Raw only, and set by nothing but its own tests: the relay process it was for runs offline on the connectors its starter hands it. No policy field gives it. The filter cannot restrict the addresses connect() reaches, and Landlock leaves TCP unhandled for "inet", so a process holding this reaches the host network, loopback and everything beyond it, and whatever it is given to connect it may reach: give it only to a process whose own code checks every address before it connects. Without it, `sockets` requires `offline`, whose network namespace is their hold
 * ---@field relay Relay with `offline`: the child binds TCP listeners on 127.0.0.1 in its network namespace, as the one thing it does there before any Landlock ruleset or filter holds it, and sends both descriptors, listening, in one message over `relay`'s channel, so this process accepts what a program in the sandbox connects to those ports. A failure of the sockets, a bind, a listen or the send fails the start before exec and answers a message naming the relay's listeners, strict or not; the child inherits this process's seccomp filter, so a parent pledged without \"inet\" cannot make them (EPERM, reported as a relay failure). Raises without `offline`
 * ---@field user integer with `unveil` or `proc` and `group`, the user the child runs as in place of this process's root, which must hold CAP_SETUID, CAP_SETGID and CAP_SETFCAP where that user and group are mapped (root, most often), or nil to run as this process's own: its namespace maps root and that user beside it, written from outside by a process of this one's, and its root is built by root there, with what it makes owned by that user, as an unprivileged caller's child's is; then it gives root up for that user and group, with no supplementary group, and, where its /proc is its own, makes a user namespace mapping that user and group alone, as such a caller's child has -- so, as that one can, it confines one of its own at any depth. Neither 0 nor -1. EPERM where this process may not map them
 * ---@field group integer the group the child runs as with `user`, which needs one
 * ---@field promises {string} the promises the child is held to, or nil for no filter: a seccomp allow list (core/promises.c), which answers EPERM to every call the basics and these do not name. The basics are what every program has: memory, time, signals to itself, threads, descriptors, the file calls Landlock holds the paths of, executable mappings of files, execve, a unix socketpair and read-only terminal queries. `"fork"` adds fork, vfork and clone without a namespace flag; `"jit"` adds executable memory that is not a file's; `"fattr"` adds changing a file's mode, times, owner and extended attributes (never with a setuid, setgid or sticky bit); `"nest"` adds what a program needs to build a sandbox of its own -- unshare of the user, mount, pid, IPC and network namespaces, mount, umount2, pivot_root, open_tree, move_mount, mount_setattr, setrlimit, prctl's PR_CAPBSET_DROP and PR_CAP_AMBIENT, and, beside `"fork"`, clone into those namespaces and with CLONE_PARENT -- and is for a program no Landlock ruleset holds, since the kernel refuses a mount to one. `clone3` and `openat2` answer ENOSYS, a refused ioctl ENOTTY, and socket() is refused unless `sockets` names its family or the child is in a root of its own (`unveil`, strict), a network namespace of its own (`offline`) and either a Landlock ruleset that handles unix sockets by path (ABI 9) or, below it, a root that shows no directory of the host's and no socket file (the start checks the paths and descriptors, and fails if a bound path changes kind), which lets it make a unix socket. A child in a user namespace of its own (`unveil` or `offline`), or whose capabilities lack CAP_SYS_RESOURCE, may set its own limits with setrlimit and prlimit64, which the kernel allows lowering and refuses raising a hard limit; a child in a pid namespace of its own (`unveil`) may name any pid to getpgid, getsid and setpgid. It is built in the child, after Landlock and just before exec, and holds every process the child starts. The signal calls (kill, tkill, tgkill, pidfd_send_signal and the queueing ones) take any pid where the child is held to `grants`, whose ruleset scopes signals (ABI 6): the kernel then refuses a signal to a process outside the child's domain, with EPERM, so a process it forks can signal its own and the child's. Otherwise -- a kernel below ABI 6, a `ruleset`, no `grants` -- they take only the pid the child had when it was built, so a process it forks, which has another, cannot signal itself, and its abort() ends by SIGSEGV rather than SIGABRT. `jit` is no boundary against a program that can write a file it can also map (one file mapped shared writable and executable) or against a write through /proc/self/mem. On aarch64 an mprotect adding PROT_EXEC is allowed only with PROT_BTI and without PROT_WRITE, as glibc's loader makes it Beside `pledge`, whose filter it adds to. Linux on x86_64 and aarch64; ENOSYS elsewhere
 * ---@field seatbelt Seatbelt the Seatbelt profile the child is held to, or nil for none: applied by a process of this program that executes the child's program as its last step, so it holds the program and everything it starts, and a refusal of the profile fails the start with its text, never running the program unconfined. macOS only; raises elsewhere, and ENOSYS where the system has no `sandbox_init_with_parameters`
 * ---@field pledge {string} the promises the child may keep, or nil for no filter: with one, a socket may be only of a family promised -- "unix" for AF_UNIX, "inet" for AF_INET and AF_INET6 -- and the calls that reach past the process (ptrace, pidfd_getfd, mounting, bpf, loading modules, io_uring and the like) fail with EPERM; keeping a child from another process's /proc/<pid>/mem takes a ruleset too. Linux on x86_64 and aarch64; ENOSYS elsewhere
 */

/*
 * --- A compiled Seatbelt profile (cosmic.sandbox.seatbelt's `Profile`), as `Sandbox`'s `seatbelt` holds it.
 * ---@class Seatbelt
 * ---@field profile string the profile's SBPL text, with no NUL
 * ---@field parameters {string:string} the profile's parameters, by name: values the text names with `(param "NAME")`, so none is part of the text. At most `SEATBELT_PARAMETER_MAX`
 */

/*
 * --- An ordinary-filesystem credential transition, supported on Linux.
 * ---@class Credentials
 * ---@field user integer the real, effective and saved user ID, 1 to 4294967294
 * ---@field group integer the real, effective and saved group ID, 1 to 4294967294
 */

/*
 * --- Starts one child with explicit arguments, environment, directory and
 * --- standard descriptors. The child is reported only after exec succeeds.
 * ---@param path string the executable path
 * ---@param argv {string} the arguments, the program's own name first
 * ---@param environment? {string:string} the exact environment, or nil to inherit
 * ---@param cwd? string the child's working directory, or nil to inherit
 * ---@param stdin? integer the child's fd 0 source, or nil to inherit fd 0
 * ---@param stdout? integer the child's fd 1 source, or nil to inherit fd 1
 * ---@param stderr? integer the child's fd 2 source, or nil to inherit fd 2
 * ---@param process_group boolean put the child in a new process group
 * ---@param fds? {integer:integer} more descriptors the child gets, each child descriptor from 3 to 255 by the descriptor it copies; every other one above 2 is closed. The artifact descriptor a portable start retains raises here, as in every descriptor argument, but as `relaunch` hands it on: at the child descriptor the child's environment names its artifact's, from a process that may still run its own core
 * ---@param sandbox? Sandbox what the child, and every process it starts, is held to from its exec on
 * ---@param credentials? Credentials clear supplementary groups and effective, permitted, inheritable and ambient capabilities, set all IDs, and set no_new_privs before cwd and exec. Excludes sandbox unveil, offline, user and group. Inherited cwd and descriptors remain grants. The capability bounding set is unchanged. ENOSYS off Linux. Child setup failure prevents exec; parent dumpability restoration failure can follow exec and ends the owned child before returning failure
 * ---@param terminal? boolean|string make fd 0 the controlling terminal of a new session before confinement and exec. It must be a terminal slave; failure prevents exec. Internal relay starts only; cosmic.child continues to refuse terminal stdio with a policy except for the pty it opens itself. On macOS the slave's path is given instead of `true`, which the child's trampoline opens as the session's leader to acquire the terminal, before any `seatbelt` profile applies, and a start with a terminal goes through the trampoline whatever the profile
 * ---@return integer|nil pid the child process id, or nil when setup or exec failed
 * ---@return string error what went wrong, when pid is nil
 * ---@return integer errno the error number, when pid is nil
 */
COSMIC_SYSCALL(spawn, 12);

/*
 * --- A Landlock ruleset a child can be held to (`spawn`'s `sandbox`): opening and running what is beneath each path of `reads`, and changing what is beneath each of `writes` too, and no other file or directory -- nor, where the kernel can hold it to these, an abstract unix socket or a signal to a process outside it. It does not hold stat and the like of any path, a unix socket named by a path, or a descriptor the child is handed already open, which Landlock cannot, nor the network, TCP or UDP, which `spawn`'s `offline` holds alike on every kernel. Closed on exec. ENOSYS, EOPNOTSUPP or EPERM where there is no Landlock to be had: not built in, turned off, or refused by a filter.
 * ---@param reads {string} the files and directories the child may read and run
 * ---@param writes {string} the files and directories it may change too
 * ---@return integer|nil ruleset the ruleset's descriptor, or nil on failure
 * ---@return string error what went wrong, when ruleset is nil
 * ---@return integer errno the error number, when ruleset is nil
 */
COSMIC_SYSCALL(landlock_ruleset, 2);

/*
 * --- The Landlock ABI version this kernel gives, 1 and up, which says which rights a ruleset can hold (`spawn`'s `grants` needs 9 for `u`).
 * ---@return integer|nil abi the version, or nil where there is no Landlock to be had: not built in, turned off, or refused by a filter
 * ---@return string error what went wrong, when abi is nil
 * ---@return integer errno the error number, when abi is nil: ENOSYS where there is none at all
 */
COSMIC_SYSCALL(landlock_abi, 0);

/*
 * --- Holds this process, and every process it starts from here on, to running only the files beneath each of `paths`: an exec of any other file -- or of a program whose interpreter is another -- is refused with EACCES; and to moving or linking a file into another directory only beneath them, EXDEV elsewhere. Nothing else is held: it reads, writes and connects as before. EOPNOTSUPP where the kernel's Landlock is older than its second ABI, whose rulesets refuse every such move. For good: no_new_privs is set, so a setuid program runs with no more privilege than its caller, and, as Landlock holds any process it holds, it may not mount or pivot_root, so it cannot confine a process of its own in a root of its own (`spawn`'s `unveil`). ENOSYS, EOPNOTSUPP or EPERM where there is no Landlock to be had: not built in, turned off, or refused by a filter.
 * ---@param paths {string} the files and directories beneath which a file may be run
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(landlock_restrict_execute, 1);

/*
 * ---@class ChildStatus
 * ---@field pid integer zero when a nonblocking wait found no finished child
 * ---@field code integer exit status, or -1 when the child was signaled or unfinished
 * ---@field signal integer terminating signal, or -1 when it exited or is unfinished
 */

/*
 * --- Reaps a child, optionally returning immediately while it is running. A sandbox's program (`spawn`'s `unveil`) reaped, its init is ended and reaped too, waiting at most a second, so nothing of the sandbox runs once this returns.
 * ---@param pid integer the child process id, -1 for any child, or a negated process group for any child in it
 * ---@param nohang boolean true to poll instead of block
 * ---@return ChildStatus|nil status the child's status, or nil on failure
 * ---@return string error what went wrong, when status is nil
 * ---@return integer errno the error number, when status is nil
 */
COSMIC_SYSCALL(waitpid, 2);

/*
 * --- A descriptor that polls readable once the child `pid` has exited, and stays readable while it is open -- on Darwin, at least until the child is reaped: a pidfd on Linux, a kqueue watching the exit on Darwin. It is closed on exec, and the caller's to close. It reaps nothing, which `waitpid` still does; and it is opened before anything can reap the child, whose pid, once reaped, may name another process. ENOSYS where there is neither, as on a Linux before 5.3; EPERM or the like where a filter refuses it; and ESRCH where the process is gone: reaped, or, on Darwin, exited.
 * ---@param pid integer the child's process id
 * ---@return integer|nil fd the descriptor, or nil on failure
 * ---@return string error what went wrong, when fd is nil
 * ---@return integer errno the error number, when fd is nil
 */
COSMIC_SYSCALL(exit_watch, 1);

/*
 * --- How to start this same program again without its launcher: the physical core, given the private startup contract the launcher would give it.
 * ---@class Relaunch
 * ---@field path string the running core's own path, to execute
 * ---@field host boolean|nil true for a host program, which needs nothing but its path; the fields below are then absent
 * ---@field database string|nil the absolute path of the database a core started with `--database` runs against, which with `path` is all that is needed; the fields below are then absent
 * ---@field artifact string|nil the artifact's logical path, the core's `--artifact` argument
 * ---@field artifact_fd integer|nil this process's retained artifact descriptor, for the child's artifact descriptor
 * ---@field core_fd integer|nil a new descriptor on the running core, closed on exec, for the child's core descriptor
 * ---@field environment {string:string}|nil the private startup contract, naming the two child descriptors
 * ---@field cwd string|nil the working directory this process started in, to start the child in; nil where it could not be read then
 */

/*
 * --- Describes starting this program again exactly: the same core, artifact and database, bypassing the launcher.
 * ---@param artifact_fd integer the descriptor the child sees the artifact as, 3 to 255
 * ---@param core_fd integer the descriptor the child sees its core as, 3 to 255
 * ---@return Relaunch|nil relaunch how to start it, or nil when this process has no portable artifact
 * ---@return string error what went wrong, when relaunch is nil
 * ---@return integer errno the error number, ENOSYS for a start without an artifact
 */
COSMIC_SYSCALL(relaunch, 2);

/*
 * --- The two ends of a new pipe, each closed on exec.
 * ---@class Pipe
 * ---@field reader integer the end to read from
 * ---@field writer integer the end to write to
 */

/*
 * --- Makes a pipe whose ends are both closed on exec.
 * ---@return Pipe|nil pipe the two ends, or nil on failure
 * ---@return string error what went wrong, when pipe is nil
 * ---@return integer errno the error number, when pipe is nil
 */
COSMIC_SYSCALL(pipe, 0);

/*
 * --- Makes this process adopt the orphaned descendants of its children, so it can reap them; Linux only.
 * ---@return boolean ok false on failure, with ENOSYS where there is no such thing
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(subreaper, 0);

/*
 * --- The inits of the sandboxes this process started (`spawn`'s `unveil`) that are still its children: each pid 1 of an unveiled child's pid namespace, which `spawn` starts as this process's child beside the program, and which `waitpid` ends and reaps once it reaps the program. No stray to end: ending one ends the program it was started for. Empty where there are none, and on a system with no sandbox.
 * ---@return {integer} pids their process ids
 */
COSMIC_SYSCALL(sandbox_inits, 0);

/*
 * --- The children of the calling thread, which starts every child, that are not yet reaped, orphans it adopted as a subreaper among them. They are read from Linux's /proc/thread-self/children, named so rather than by `getpid()`, which in a sandbox whose /proc is the host's names another process. ENOSYS where there is no such list, and the error that refused it where it cannot be read (ENOENT from a kernel built without it).
 * ---@return {integer}|nil pids their process ids, in the kernel's order, or nil on failure
 * ---@return string error what went wrong, when pids is nil
 * ---@return integer errno the error number, when pids is nil
 */
COSMIC_SYSCALL(children, 0);

/*
 * --- What a process holds itself to (`restrict_self`), in the fields `spawn`'s `sandbox` holds a child to.
 * ---@class Restriction
 * ---@field grants {Grant} the paths it may reach and how, as `spawn`'s `grants`: a Landlock ruleset of its own, which may be empty. A `u` grant needs ABI 9
 * ---@field promises {string} the promises, as `spawn`'s `promises`: always a filter, which may be empty
 * ---@field rlimits {string:integer} the limits, as `spawn`'s `rlimits`, soft and hard together but never raised: a limit already as low is left as it is, and one that must be lowered asks for setrlimit, which an earlier restriction's filter refuses where the process holds CAP_SYS_RESOURCE (it allows it to a process that does not: the kernel then refuses a raised hard limit)
 * ---@field seatbelt Seatbelt on macOS, the profile the process is held to, which holds its paths and what its promises allow, so `grants` and `promises` are empty there; required on macOS, and raises elsewhere
 */

/*
 * --- Holds this process, and everything it starts, for good to what `restriction` names: its limits, then Landlock's ruleset, then the promises filter (core/promises.c), the last, so a later call narrows both and lowers no limit the filter refuses. Called again it adds: Landlock stacks rulesets and the kernel takes the intersection of the filters. Refused while this process has another thread (a restriction holds the thread that makes it), a child not yet reaped, or a descriptor above 2 is open that neither `keep` names nor the runtime keeps itself (this program's artifact and the databases of its store), or where `keep` names one that is not open: those checks change nothing, and the kernel's own calls after them, which can fail, can leave the limits lowered or the ruleset made. The process's /proc is read through descriptors it opens at its first restriction and keeps (close-on-exec, and not counted as the program's), since Landlock then refuses the path: a process forked from a restricted one cannot be inspected, and refuses. The filter's kill and scheduling rules take this process's pid, so a process it starts afterwards, which has another, cannot signal itself, and its abort() ends by SIGSEGV, until Landlock's signal scope (ABI 6, which the ruleset sets where the kernel has it) holds signals instead. Linux on x86_64 and aarch64. On macOS it holds the process to `restriction`'s `seatbelt` profile instead (sandbox_init_with_parameters), after its limits: the profile holds every thread, so another thread does not refuse it, but a child not yet reaped or a descriptor not accounted for does, as on Linux, the descriptors found by asking each number. It is refused, EPERM, once a profile holds the process, since macOS applies no second one, and so is a `spawn` with `seatbelt` then; ENOSYS where the system has no `sandbox_init_with_parameters`. ENOSYS elsewhere
 * ---@param restriction Restriction what to hold this process to
 * ---@param keep? {integer} the descriptors above 2 this process keeps open, which no restriction closes
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, naming the descriptor, the path or the call, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(restrict_self, 2);

/*
 * --- Whether this process's user namespace maps `id` inside, as a user and as a group, as its /proc/self/uid_map and gid_map list them: false with EINVAL, setuid's answer for an id it does not map, where either does not, and ENOSYS off Linux.
 * ---@param id integer the id, from 0 below 2^32 - 1
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(maps_id, 1);

/*
 * --- Whether this process may map ids of another user than its own into a user namespace from outside, as `spawn`'s `user` does: its effective user is root, holding CAP_SETUID, CAP_SETGID and CAP_SETFCAP in effect. False with EPERM where it may not, and ENOSYS off Linux.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(may_map_ids, 0);

/*
 * --- Whether a sandbox gets a procfs of its own pid namespace here (`spawn`'s `unveil`), as the kernel answers a child started to mount one as a sandbox does, in user, mount and pid namespaces of its own: false with the errno that refused it where it would get the host's /proc instead -- EPERM where a user namespace may not mount a procfs, as where a container's runtime masks parts of /proc, or where no user namespace is to be had; EINVAL from a kernel before 5.8; ECHILD where that child was ended by a signal -- and ENOSYS off Linux.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(own_proc, 0);

/*
 * --- Whether this platform can sandbox a child at all -- `spawn`'s `unveil`, `ruleset` and `pledge`, `landlock_ruleset`, `subreaper` -- whatever this host's kernel or its settings then refuse: true on Linux, false with ENOSYS elsewhere.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(sandbox_platform, 0);

/*
 * --- Ignores SIGPIPE, so a write to a closed pipe fails with EPIPE instead of ending the process. A child started afterward gets the default back unless SIGPIPE was already ignored at this process's start.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(ignore_sigpipe, 0);

/*
 * --- Creates a Unix stream socket, closed on exec, for a host capability probe. This says nothing about permission to bind a path or connect to a peer. The caller closes its descriptor.
 * ---@return integer|nil fd the socket descriptor, or nil on failure
 * ---@return string error what went wrong, when fd is nil
 * ---@return integer errno the error number, when fd is nil
 */
COSMIC_SYSCALL(unix_socket, 0);

/*
 * --- Opens a guard over SIGINT and SIGTERM for bounded child supervision, the innermost of those open. The first open catches each signal this process does not ignore, and opens the wake pipe (`child_signal_fd`); an ignored signal stays ignored. Each caught signal moves the stamp, `SIGNAL_STAMP_UNIT` times the count of signals caught plus the last one's number, which is never reset. Every open must be closed by `unguard_child_signals`.
 * ---@return integer|nil stamp the stamp as this guard opens, which it has read, or nil on failure
 * ---@return string error what went wrong, when stamp is nil
 * ---@return integer errno the error number, when stamp is nil
 */
COSMIC_SYSCALL(guard_child_signals, 0);

/*
 * --- Closes one open guard. The last close restores the dispositions the first open found and closes the wake pipe; any other hands the waits of core/http.c to the guard now innermost, which has read up to `read_to`. With no guard open it closes nothing.
 * ---@param read_to integer the stamp the guard innermost after this close last read; unread by the last close
 * ---@return integer|nil stamp the stamp as the guard closed, or nil when the dispositions could not be restored
 * ---@return string error what went wrong, when stamp is nil
 * ---@return integer errno the error number, when stamp is nil
 */
COSMIC_SYSCALL(unguard_child_signals, 1);

/*
 * --- The stamp now. When `innermost`, the innermost guard has read it, and the waits of core/http.c are no longer ended by the signals it counts.
 * ---@param innermost boolean whether the innermost open guard reads it
 * ---@return integer stamp the stamp
 */
COSMIC_SYSCALL(child_signal_read, 1);

/*
 * --- The read end of the wake pipe, which becomes readable when a guard catches a signal, or -1 while no guard is open. Non-blocking and close-on-exec. The pipe is shared by every guard, and its bytes say only that the stamp may have moved: a reader drains it after it wakes, then compares the stamp with its own.
 * ---@return integer fd the descriptor, or -1
 */
COSMIC_SYSCALL(child_signal_fd, 0);

/*
 * --- How `promise_filter` builds the program.
 * ---@class PromiseOptions
 * ---@field pid integer the process id the program is for, which the calls that ask about a process, and the signal calls unless `scoped`, hold it to (default 1)
 * ---@field scoped boolean whether the process is in a Landlock domain that scopes signals, so a signal call takes any pid and pidfd_send_signal is allowed (default false)
 * ---@field unix_held boolean whether the process is in a root of its own, a network namespace of its own, and either a Landlock domain that handles unix sockets by path (ABI 9) or a root showing no directory or socket of the host's, so socket() may make a unix socket without `unix` (default false)
 * ---@field limits_held boolean whether the process cannot raise a hard limit, so setrlimit and prlimit64 may set its own limits (default false)
 * ---@field pids_held boolean whether the process is in a pid namespace of its own, so getpgid, getsid, setpgid and capget take any pid (default false)
 * ---@field unix boolean whether a unix socket may be made with socket(), which a socketpair always may (default false)
 * ---@field inet boolean whether an AF_INET or AF_INET6 socket may be made with socket() (default false)
 */

/*
 * --- The seccomp program `spawn`'s `promises` hold a child to, as the instructions of classic BPF a kernel would be handed, eight bytes each, little-endian (`struct sock_filter`: a 16-bit code, two 8-bit jumps, a 32-bit operand), for either architecture whatever this host is. A test runs it against a call it makes up, as the kernel would (core/promises_test.tl).
 * ---@param promises {string} the promises, as `spawn`'s `promises` takes them
 * ---@param arch string "x86_64" or "aarch64"
 * ---@param options? PromiseOptions what the program is for
 * ---@return string program the instructions
 */
COSMIC_SYSCALL(promise_filter, 3);

/*
 * --- The numbers this table's calls take, from this build.
 * ---@class Constants
 * ---@field UNVEIL_MAX integer the most paths a sandbox unveils, its reads and writes together
 * ---@field SIGNAL_STAMP_UNIT integer what a stamp counts each caught signal as, above the last one's number
 * ---@field SPAWN_PLACED_ABOVE integer how many descriptors `spawn` places above the highest it hands a child, besides a copy of each it hands
 * ---@field SEATBELT_PARAMETER_MAX integer the most parameters a `seatbelt` profile takes
 * ---@field PROMISE_CALLS_REVIEWED integer one past the highest system call number the promises' tables have been reviewed to: a call above it answers ENOSYS
 * ---@field PROMISE_CALLS_HEADERS integer one past the highest number the headers this core was built with name, or 0 where they name no count: past PROMISE_CALLS_REVIEWED, they name calls no one has judged
 */
COSMIC_CONSTANT(UNVEIL_MAX)
COSMIC_CONSTANT(SIGNAL_STAMP_UNIT)
COSMIC_CONSTANT(SPAWN_PLACED_ABOVE)
COSMIC_CONSTANT(SEATBELT_PARAMETER_MAX)
COSMIC_CONSTANT(PROMISE_CALLS_REVIEWED)
COSMIC_CONSTANT(PROMISE_CALLS_HEADERS)
