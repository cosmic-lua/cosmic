/*
 * The process table: the calls [`cosmic.child`] starts, feeds and reaps a
 * child with, and the one [`cosmic.proc`] relaunches this program with.
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
#include "syscalls.h"

/* The most paths a sandbox unveils (`Unveil`): a test worker's
 * (build/test_sandbox.tl) is given each file of its module's import
 * closure by name. */
#define UNVEIL_MAX 256

/* What a signal stamp counts each caught signal as: the stamp is their
 * count times this, plus the last one's number, which is below it. */
#define SIGNAL_STAMP_UNIT 64

/* Opens the table as the raw [`cosmic.internal.process`] module. */
int cosmic_open_process (lua_State *L);

/* Records the command line the runtime was entered with, its first
 * word the program's own name, for `arguments` to answer, and the
 * working directory, for `relaunch`'s `cwd`: `argv` is held, not
 * copied, so it must outlive every Lua state. */
void cosmic_process_entered (int argc, char **argv);

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
 * --- The paths a sandbox unveils, each absolute; at most `UNVEIL_MAX` in all.
 * ---@class Unveil
 * ---@field reads {string} the files and directories the child has, read-only
 * ---@field writes {string} the ones it has to change too
 * ---@field at {string:string} for a path of `reads` or `writes`, by that path as given, the absolute name it is bound at in the child's root instead of its own -- not /, and no link to it is made there -- so a tree given at /tree is there alone, wherever the host has it; nil for none
 */

/*
 * --- What `spawn` holds a child to from its exec on, with every process it starts.
 * ---@class Sandbox
 * ---@field ruleset integer a ruleset from `landlock_ruleset`, or nil for none. It is built in this process, from paths as this process sees them, before the child has a root of its own, and holds the files those paths are, and nothing of the network, which `offline` holds: with `unveil`, a rule on a path the child is given reaches it, but none reaches what the child's root is built of -- its own /tmp, the directories above an unveiled path, / itself, and its own /proc -- which no path here names, so a child held to one cannot write its own /tmp, list /, or read its own /proc -- though, where the kernel gives it the host's (see `unveil`), a ruleset naming /proc reaches that. With `unveil` and `offline` it holds nothing more that matters of the filesystem, the network or signals -- a narrower ruleset is a narrower unveiling, the network namespace reaches nothing past the child's own loopback, nor shares an abstract unix socket with any process outside it, and the pid namespace holds no process outside it to signal. And a child it holds cannot confine one of its own, since Landlock refuses a mount or pivot_root to a process it holds
 * ---@field unveil Unveil what alone the child has of the filesystem, or nil for all of it: a root of its own, in namespaces of its own -- a pid namespace among them, of which it is pid 2, beneath an init of its own at pid 1 that ends when it does, ending whatever it left running there, and ends when this process does, so it sees and signals only the processes it starts, while its pid, status and signals here are any child's; and a session of its own, and so a process group of its own whatever `process_group` says, with no controlling terminal -- and System V IPC of its own, holding those paths at the names they resolve to, or each at the name `at` gives it, and, for each given through a link, that link there too -- and, with /proc among them and no /dev given whole, /dev/fd and /dev/stdin, /dev/stdout and /dev/stderr as links into it, and, unless /tmp or / is among them, a /tmp of its own that its own children share, empty but for the paths given beneath the host's -- and nothing else, so a path outside them is not there to stat any more than to open. A ruleset with it reaches the unveiled paths alone (see `ruleset`): a rule on a directory above one does not reach into it, since each is a mount of its own, so name the unveiled paths themselves. /proc given is a procfs of its pid namespace, holding that namespace's processes and nothing of the host's (no /proc/sys and the like; a path beneath /proc given besides it is not there), and writable, so the child can map its own child's ids and confine one of its own in turn: what it can write there is its own processes' and its own session's. Where the kernel refuses one -- a container's runtime masking parts of its /proc, as Docker's does without --security-opt systempaths=unconfined, where a user namespace may not mount a procfs -- it is the host's, read-only like any path given to read, so the child cannot confine one of its own (EROFS); it shows the host's processes and state, and its pids are the host's, not the ones the child is in: /proc/self and /proc/thread-self are the child's own, /proc/<its getpid()> another process's. A child confined from inside another sandbox -- one whose root user has given up the CAP_SETFCAP that mapping root into a user namespace takes -- runs as root unmapped: the kernel's overflow id (65534) inside, owning what root owns but with no capability to override a file's permissions, on a root and a /tmp built in a directory of its TMPDIR, which is left there; unmapped, it cannot confine one of its own again. Linux, where unprivileged user namespaces are allowed; ENOSYS elsewhere, and EPERM or the like where they are not
 * ---@field offline boolean a network namespace of its own, with nothing but a loopback, which is up: a connection to 127.0.0.1 reaches a listener of the child's own processes, or is refused
 * ---@field user integer with `unveil` and `group`, the user the child runs as in place of this process's root, which must hold CAP_SETUID, CAP_SETGID and CAP_SETFCAP where that user and group are mapped (root, most often), or nil to run as this process's own: its namespace maps root and that user beside it, written from outside by a process of this one's, and its root is built by root there, with what it makes owned by that user, as an unprivileged caller's child's is; then it gives root up for that user and group, with no supplementary group, and, where its /proc is its own, makes a user namespace mapping that user and group alone, as such a caller's child has -- so, as that one can, it confines one of its own at any depth. Neither 0 nor -1. EPERM where this process may not map them
 * ---@field group integer the group the child runs as with `user`, which needs one
 * ---@field pledge {string} the promises the child may keep, or nil for no filter: with one, a socket may be only of a family promised -- "unix" for AF_UNIX, "inet" for AF_INET and AF_INET6 -- and the calls that reach past the process (ptrace, pidfd_getfd, mounting, bpf, loading modules, io_uring and the like) fail with EPERM; keeping a child from another process's /proc/<pid>/mem takes a ruleset too. Linux on x86_64 and aarch64; ENOSYS elsewhere
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
 * ---@return integer|nil pid the child process id, or nil when setup or exec failed
 * ---@return string error what went wrong, when pid is nil
 * ---@return integer errno the error number, when pid is nil
 */
COSMIC_SYSCALL(spawn, 10);

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
 * --- How to start this same program again without its launcher: the physical core, given the private startup contract the launcher would give it.
 * ---@class Relaunch
 * ---@field path string the running core's own path, to execute
 * ---@field host boolean|nil true for a host program, which needs nothing but its path; the fields below are then absent
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
 * --- The arguments this program was started with, after its own name: the words its main module is handed from 1 on, with no `--artifact` pair a launcher or `relaunch` put before them, so that `relaunch`'s argv and these, in `relaunch`'s `cwd`, start this program again on the same command line.
 * ---@return {string} arguments the arguments, in order; empty for none
 */
COSMIC_SYSCALL(arguments, 0);

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
 * --- Ignores SIGPIPE, so a write to a closed pipe fails with EPIPE instead of ending the process. A child started afterward gets the default back.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(ignore_sigpipe, 0);

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
 * --- The numbers this table's calls take, from this build.
 * ---@class Constants
 * ---@field UNVEIL_MAX integer the most paths a sandbox unveils, its reads and writes together
 * ---@field SIGNAL_STAMP_UNIT integer what a stamp counts each caught signal as, above the last one's number
 */
COSMIC_CONSTANT(UNVEIL_MAX)
COSMIC_CONSTANT(SIGNAL_STAMP_UNIT)
