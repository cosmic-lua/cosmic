/*
 * The syscall table: one C function per call, the same signature on
 * Linux and on macOS, so a Teal module written once behaves the same on
 * both and the sandbox has one door.
 *
 * Every entry is a LuaCATS annotation block followed by COSMIC_SYSCALL
 * naming it. The block is the source of truth: [`build/gen_syscalls.tl`]
 * turns it into the Teal declaration and the documentation row, and
 * refuses a function whose annotation is missing a slot. A binding
 * cannot exist without its type, and the C surface cannot grow without
 * a diff in this file -- or in core/process.h, which declares, in the
 * same grammar, the calls only [`cosmic.child`], [`cosmic.proc`] and
 * [`build.confine`] are handed, as the raw [`cosmic.internal.process`].
 *
 * Two shapes, and no third. An argument-shape error -- a degenerate
 * input no correct program passes -- raises. A failure a correct caller
 * meets at runtime returns `nil, error, errno` from a call that answers
 * a value and `false, error, errno` from an effect ([`core/fail.h`]): the
 * error in slot two, the errno in slot three, nothing else sharing a
 * slot. This table is the one place a third slot is allowed; a Teal
 * function over it answers in two.
 *
 * One descriptor is no argument's: the one a portable start retains on
 * its artifact, through which the database the program carries is read.
 * Every call here and in core/process.h that takes a descriptor raises
 * on it (core/check.h's `cosmic_checkfd`), `close` included, so a loop
 * closing every descriptor from 3 up raises at it (none in the tree
 * does; `spawn` closes a child's for it); and `open`, `chmod` and
 * `utimensat` refuse it named through /proc/<pid>/fd or /dev/fd, EACCES.
 */

#ifndef COSMIC_SYSCALLS_H
#define COSMIC_SYSCALLS_H

#include <stdbool.h>
#include <stddef.h>

#include "lua.h"

/* The process's logical, directly executable relaunch path.
 * cosmic_surface_open installs it per Lua state, from the path main passes,
 * after portable startup has adopted the artifact descriptor. */
#define COSMIC_LOGICAL_EXECUTABLE "cosmic.logical_executable"


/* A path argument's bytes, or NULL when they hold a NUL byte. C reads a
 * path only up to its first NUL, so a call handed "a\0/../b" would act
 * on "a" -- a different file from the one the caller named, and one a
 * check made on the whole string never saw. A path can come from bytes
 * the caller did not write (an archive entry, say), so every call that
 * takes one refuses such a path as a runtime failure, EINVAL, rather
 * than raising. A non-string still raises, as any argument-shape error
 * does. `spawn` (core/process.h) raises on a NUL in its path or cwd
 * instead, which [`cosmic.child`] depends on; neither way truncates.
 * `execve` and `landlock_ruleset` raise on one too. */
const char *cosmic_path (lua_State *L, int index);

/* Opens the table as the [`cosmic.sys`] module. */
int cosmic_open_syscalls (lua_State *L);

/* Whether `text`, `used` bytes of a /proc/<pid>/mountinfo, lists the
 * filesystem on `device` ("major:minor", as its third field writes it)
 * as mounted with local_lock "flock" or "all" among the filesystem's
 * own options, which keep an NFS client's flock apart from its fcntl
 * locks (`flock_kind`). A line that does not parse is passed over. */
bool cosmic_mountinfo_local_flock (const char *text, size_t used, const char *device);

#endif

/*
 * Everything below is entries, each an X-macro this header declares by
 * default and core/syscalls.c expands again, defined its own way, into
 * the statements that fill the table the module is opened with -- so an
 * entry here is a function the table holds, and no second list can
 * drift from this one. A definition opens with the same macro,
 * `COSMIC_SYSCALL(open, 3) { ... }`.
 *
 * `arity` is the number of parameters the annotation block just above an
 * entry declares -- the generator cross-checks the two against each
 * other, so a `@param` line and this count can never drift apart
 * unnoticed. It is not part of the C signature, which is always
 * `(lua_State *L)`: the arguments come off the Lua stack, not a C
 * parameter list. A COSMIC_CONSTANT names one of the `Constants` the
 * table carries, each a field of that class's annotation, in its order
 * (the generator holds the two to each other).
 */
#ifndef COSMIC_SYSCALL
#define COSMIC_SYSCALL(name, arity) int cosmic_sys_##name(lua_State *L)
#endif
#ifndef COSMIC_CONSTANT
#define COSMIC_CONSTANT(name)
#endif

/*
 * --- What a path is, as `stat`, `lstat` and `fstat` name it in a `Stat`'s
 * --- `kind` and `readdir` names each entry. A name outside these is a
 * --- compile error, not a comparison that is never true.
 * ---@alias Kind
 * ---| "file" # a regular file
 * ---| "dir" # a directory
 * ---| "link" # a symbolic link
 * ---| "socket" # a socket
 * ---| "fifo" # a named pipe
 * ---| "char" # a character device
 * ---| "block" # a block device
 * ---| "other" # any other type a system has
 */

/*
 * --- What `stat`, `lstat` and `fstat` report about a path.
 * ---@class Stat
 * ---@field size integer the size in bytes
 * ---@field mode integer the type and permission bits
 * ---@field kind Kind what the path is
 * ---@field mtime integer the modification time, whole seconds
 * ---@field mtime_ns integer the nanoseconds part of the modification time
 * ---@field atime integer the access time, whole seconds
 * ---@field atime_ns integer the nanoseconds part of the access time
 * ---@field ctime integer the status change time, whole seconds
 * ---@field ctime_ns integer the nanoseconds part of the status change time
 * ---@field ino integer the inode number
 * ---@field dev integer the device the inode is on
 * ---@field nlink integer how many names point at it
 * ---@field uid integer the owning user
 * ---@field gid integer the owning group
 */

/*
 * --- Opens a path and returns a descriptor, always close-on-exec whatever
 * --- `flags` says: a program it execs inherits only a copy `dup2` makes. The
 * --- program's own file named through a descriptor of it (/proc/self/fd/<n>,
 * --- /dev/fd/<n>, a link to one) is refused, EACCES, before anything is opened.
 * ---@param path string the path to open
 * ---@param flags integer the O_* flags, such as `O_RDONLY` or `O_WRONLY | O_CREAT`
 * ---@param mode? integer the mode for a newly created file, default 0o644
 * ---@return integer|nil fd the descriptor, or nil on failure
 * ---@return string error what went wrong, when fd is nil
 * ---@return integer errno the error number, when fd is nil
 */
COSMIC_SYSCALL(open, 3);

/*
 * ---@class TemporaryFile
 * ---@field fd integer the open descriptor
 * ---@field path string the created path
 */

/*
 * --- Creates a fresh file beside `path`, exclusively, and returns its open
 * --- descriptor and name. The requested mode has ordinary umask semantics.
 * ---@param path string the destination the temporary file will neighbor
 * ---@param mode? integer the creation mode, default 0o644
 * ---@return TemporaryFile|nil file the created file, or nil on failure
 * ---@return string error what went wrong, when file is nil
 * ---@return integer errno the error number, when file is nil
 */
COSMIC_SYSCALL(open_temporary, 2);

/*
 * --- Closes a descriptor.
 * ---@param fd integer the descriptor to close
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(close, 1);

/*
 * --- Reads up to `count` bytes. An empty string means end of file.
 * --- A read may answer short, and one asks for no more than it can
 * --- answer: past 64 KiB, at most what is left of a regular file (never
 * --- under 64 KiB), or 1 MiB of anything else. A count far past that
 * --- costs nothing; loop until the empty string for all of it.
 * ---@param fd integer the descriptor to read
 * ---@param count integer how many bytes to ask for
 * ---@return string|nil data the bytes read, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer errno the error number, when data is nil
 */
COSMIC_SYSCALL(read, 2);

/*
 * --- Reads up to `count` bytes from an explicit offset, asking for no
 * --- more than it can answer, as read does.
 * ---@param fd integer the descriptor to read
 * ---@param count integer how many bytes to ask for
 * ---@param offset integer the offset to read from
 * ---@return string|nil data the bytes read, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer errno the error number, when data is nil
 */
COSMIC_SYSCALL(pread, 3);

/*
 * --- Writes bytes and returns how many went out.
 * ---@param fd integer the descriptor to write
 * ---@param data string the bytes to write
 * ---@return integer|nil written how many bytes went out, or nil on failure
 * ---@return string error what went wrong, when written is nil
 * ---@return integer errno the error number, when written is nil
 */
COSMIC_SYSCALL(write, 2);

/*
 * --- Moves a descriptor's offset and returns the new one.
 * ---@param fd integer the descriptor to move
 * ---@param offset integer how far to move
 * ---@param whence integer one of `SEEK_SET`, `SEEK_CUR`, `SEEK_END`
 * ---@return integer|nil offset the new offset, or nil on failure
 * ---@return string error what went wrong, when offset is nil
 * ---@return integer errno the error number, when offset is nil
 */
COSMIC_SYSCALL(lseek, 3);

/*
 * --- Describes an open descriptor.
 * ---@param fd integer the descriptor to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(fstat, 1);

/*
 * --- Describes a path, following a symbolic link at the end of it.
 * ---@param path string the path to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(stat, 1);

/*
 * --- Describes a path, describing a symbolic link rather than its target.
 * ---@param path string the path to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(lstat, 1);

/*
 * --- Creates a directory.
 * ---@param path string the directory to create
 * ---@param mode? integer the mode to create it with, default 0o755
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(mkdir, 2);

/*
 * --- Removes an empty directory.
 * ---@param path string the directory to remove
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(rmdir, 1);

/*
 * --- Removes a name from the filesystem.
 * ---@param path string the name to remove
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(unlink, 1);

/*
 * --- Removes a path and, for a directory, everything beneath it: `rm -rf`. The walk is relative to descriptors and never follows a link -- a link is removed as itself, and an entry swapped for a link by a process still running while this walks is removed too, not followed -- so nothing outside the path is touched. A path already gone, or one beneath something that is no directory, is not a failure; a path ending in "/" names what it names without them, so a link is removed, not followed; "/" is refused, EINVAL. A directory it cannot open or that will not empty (something keeps making entries in it) fails, ENOTEMPTY or the open's errno; what was removed stays removed. The path's own directories above it are resolved as any path's are.
 * ---@param path string the path to remove
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(remove_tree, 1);

/*
 * --- Moves a name, replacing the destination if it exists.
 * ---@param from string the name to move
 * ---@param to string where to move it
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(rename, 2);

/*
 * --- Sets a path's permission bits. The program's own file named through a
 * --- descriptor of it (/proc/self/fd/<n>, /dev/fd/<n>) is refused, EACCES.
 * ---@param path string the path to change
 * ---@param mode integer the permission bits to set
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chmod, 2);

/*
 * --- Sets a path's owner and group, following a link at its last part. The program's own file named through a descriptor of it (/proc/self/fd/<n>, /dev/fd/<n>) is refused, EACCES.
 * ---@param path string the path to change
 * ---@param uid integer the user to own it, or -1 to leave its owner
 * ---@param gid integer the group to own it, or -1 to leave its group
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chown, 3);

/*
 * --- Lists a directory's entries, without `.` and `..`, each with what it is, as `lstat` names it (its `kind`): "link" for a symbolic link, which is never followed.
 * ---@param path string the directory to list
 * ---@return {string:Kind}|nil entries each entry's kind by its name, or nil on failure
 * ---@return string error what went wrong, when entries is nil
 * ---@return integer errno the error number, when entries is nil
 */
COSMIC_SYSCALL(readdir, 1);

/* `tree_digest` has no caller in the tree but its tests
 * (core/syscalls_test.tl): it is kept for the TODO above
 * build/declared_key.tl's `walk_system` ("walk in C, as [`sys.tree_digest`]
 * walks by stamps"), which is to digest the system's paths through it
 * rather than an `lstat` of each entry crossing into Lua. */

/*
 * --- What a tree holds, digested: `tree_digest`'s answer.
 * ---@class TreeDigest
 * ---@field digest string the hex sha256 of every entry at and beneath the path, links unfollowed, in name order: each one's contents where asked for, and otherwise what `lstat` says of it -- type and permissions, size, modification and change times, and inode
 * ---@field special boolean whether it holds a socket, a FIFO or a device other than /dev/null, /dev/zero, /dev/full or /dev/urandom, each of which answers from past the tree, or anything the walk could not see: an entry it could not read or list, or one more than 128 directories down -- but for one it was refused (EACCES, EPERM), digested by its permissions and owner, which is all a process with no more privilege than the walk's could learn of it
 */

/*
 * --- Digests a file or directory and everything beneath it, in one walk: a change to any entry, its name, what it is or what it holds changes the digest. An entry that cannot be read is digested as the error it gave.
 * ---@param path string the file or directory, not followed where it is a link
 * ---@param contents boolean digest each file's contents rather than what `lstat` says of it
 * ---@return TreeDigest|nil digest what it holds, or nil when the path itself cannot be read
 * ---@return string error what went wrong, when digest is nil
 * ---@return integer errno the error number, when digest is nil
 */
COSMIC_SYSCALL(tree_digest, 2);

/*
 * --- Returns the process's current directory.
 * ---@return string|nil path the directory, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(getcwd, 0);

/*
 * --- Changes the process's current directory.
 * ---@param path string the directory to move to
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chdir, 1);

/*
 * --- Resolves a path to an absolute one with no link and no `..` left.
 * ---@param path string the path to resolve
 * ---@return string|nil path the resolved path, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(realpath, 1);

/*
 * --- Creates a fresh, empty directory from a template ending in six
 * --- literal `X` characters, which are replaced with characters that
 * --- make the name unique.
 * ---@param template string the path to create, ending in "XXXXXX"
 * ---@return string|nil path the created directory, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(mkdtemp, 1);

/*
 * --- Returns the logical path that directly relaunches this program. For a
 * --- portable program this is the artifact path, not its cached native core.
 * ---@return string|nil path the relaunchable program path, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(executable, 0);

/*
 * --- Reads one environment variable.
 * ---@param name string the variable to read
 * ---@return string|nil value the value, or nil when it is not set
 */
COSMIC_SYSCALL(getenv, 1);

/*
 * --- Reads the whole environment as a name-to-value map.
 * ---@return {string:string} environment every variable the process has
 */
COSMIC_SYSCALL(environ, 0);

/*
 * --- Ends the process. It does not return.
 * ---@param status? integer the exit status, default 0
 */
COSMIC_SYSCALL(exit, 1);

/*
 * --- Returns the process's own identifier.
 * ---@return integer pid the process identifier
 */
COSMIC_SYSCALL(getpid, 0);

/*
 * --- Returns the process group a process is in.
 * ---@param pid integer the process id, or 0 for this process; a negative one raises
 * ---@return integer|nil pgid the process group's identifier, or nil on failure
 * ---@return string error what went wrong, when pgid is nil
 * ---@return integer errno the error number, when pgid is nil
 */
COSMIC_SYSCALL(getpgid, 1);

/*
 * --- Returns the real user identifier the process runs as.
 * ---@return integer uid the user identifier
 */
COSMIC_SYSCALL(getuid, 0);

/*
 * --- Returns the real group identifier the process runs as.
 * ---@return integer gid the group identifier
 */
COSMIC_SYSCALL(getgid, 0);

/*
 * --- The supplementary groups the process runs with, in the order the
 * --- system keeps them, which may or may not hold the effective group
 * --- (macOS's does, first; Linux's does where it was given one). On
 * --- macOS they are the user's groups as directory services lists them,
 * --- which may be more than NGROUPS_MAX and do not follow a change
 * --- setgroups made. EINVAL where the list grew between the call's two
 * --- looks at it.
 * ---@return {integer}|nil groups each group's identifier, or nil on failure
 * ---@return string error what went wrong, when groups is nil
 * ---@return integer errno the error number, when groups is nil
 */
COSMIC_SYSCALL(getgroups, 0);

/*
 * --- Whether this process may be dumped, and its /proc files are its own user's to read and write (prctl's PR_GET_DUMPABLE): 1 where so, 0 where they are root's, 2 where a core dump would be root's alone. With `set`, 0 or 1, it is made so first. ENOSYS off Linux.
 * ---@param set? integer 0 or 1 to make it so, or nil to only ask
 * ---@return integer|nil dumpable 0, 1 or 2, or nil on failure
 * ---@return string error what went wrong, when dumpable is nil
 * ---@return integer errno the error number, when dumpable is nil
 */
COSMIC_SYSCALL(dumpable, 1);

/*
 * --- Sets the file mode creation mask, the permission bits a new file or
 * --- directory is made without, for this process and every child it
 * --- starts afterwards.
 * ---@param mask integer the permission bits to withhold, 0 to 0777
 * ---@return integer previous the mask before this call
 */
COSMIC_SYSCALL(umask, 1);

/*
 * --- A resource's limits, as `getrlimit` answers them and `setrlimit`
 * --- takes them. `math.maxinteger` stands for no limit (RLIM_INFINITY) on
 * --- every system, and a limit at or past it is answered as none.
 * ---@class Limits
 * ---@field soft integer the limit the system holds the process to
 * ---@field hard integer the most the soft limit may be raised to
 */

/*
 * --- The limits the process is held to on `resource`.
 * ---@param resource integer the resource, such as `RLIMIT_NOFILE`
 * ---@return Limits|nil limits the soft and hard limits, or nil on failure
 * ---@return string error what went wrong, when limits is nil
 * ---@return integer errno the error number, when limits is nil
 */
COSMIC_SYSCALL(getrlimit, 1);

/*
 * --- Holds the process, and every child it starts afterwards, to
 * --- `soft` on `resource`, with `hard` the most it may be raised to
 * --- again; `math.maxinteger` stands for no limit. The process starts
 * --- with RLIMIT_NOFILE's soft limit raised toward the hard one, as far
 * --- as 10240 (macOS's kern.maxfilesperproc, where that is lower), so
 * --- `getrlimit` answers the raised limit, not the one it was started
 * --- with; a program it starts is given that one back, until this sets
 * --- RLIMIT_NOFILE. A negative limit raises. A soft limit above the hard one is refused with EINVAL,
 * --- and a hard one raised without the privilege to with EPERM. The
 * --- system bounds RLIMIT_NOFILE besides: Linux refuses a limit past
 * --- fs.nr_open with EPERM; macOS bounds a soft limit, or a hard one
 * --- changed, by kern.maxfilesperproc (kern.maxfiles for root), and
 * --- may refuse one past it with EINVAL or hold the process to the
 * --- bound instead, a soft one of no limit included -- give its hard
 * --- limit back as `getrlimit` answers it, and a soft one below that
 * --- bound.
 * ---@param resource integer the resource, such as `RLIMIT_NOFILE`
 * ---@param soft integer the limit to hold the process to
 * ---@param hard integer the most the soft limit may be raised to
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(setrlimit, 3);

/*
 * --- Draws bytes from the operating system's entropy source, fit for a
 * --- key, token or nonce.
 * ---@param count integer how many bytes, 0 to 1 MiB
 * ---@return string|nil bytes the bytes, or nil on failure
 * ---@return string error what went wrong, when bytes is nil
 * ---@return integer errno the error number, when bytes is nil
 */
COSMIC_SYSCALL(entropy, 1);

/*
 * --- Replaces the process with another program. It returns only on failure.
 * ---@param path string the executable to run
 * ---@param argv {string} the arguments, the program's own name first
 * ---@param environment {string:string} the environment the program starts with
 * ---@return boolean ok false, since the call returns only on failure
 * ---@return string error what went wrong
 * ---@return integer errno the error number
 */
COSMIC_SYSCALL(execve, 3);

/*
 * --- Sends a signal to a process, or to a group when pid is negative.
 * ---@param pid integer the process id, negated for a process group
 * ---@param signal integer the signal number
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(kill, 2);

/*
 * --- A new descriptor for what `fd` names: the lowest one free, closed on exec.
 * ---@param fd integer the descriptor to copy
 * ---@return integer|nil copy the new descriptor, or nil on failure
 * ---@return string error what went wrong, when copy is nil
 * ---@return integer errno the error number, when copy is nil
 */
COSMIC_SYSCALL(dup, 1);

/*
 * --- Makes `to` name what `fd` names, closing what `to` named first. When `fd` is `to`, nothing changes, its close-on-exec flag included; otherwise `to` is left open across exec, as a process's standard descriptors are.
 * ---@param fd integer the descriptor to copy
 * ---@param to integer the descriptor to make a copy of it
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(dup2, 2);

/*
 * --- A descriptor's own flags, `fcntl(fd, F_GETFD)`: FD_CLOEXEC is set
 * --- when it is closed on exec.
 * ---@param fd integer the descriptor to ask about
 * ---@return integer|nil flags the descriptor's flags, or nil on failure
 * ---@return string error what went wrong, when flags is nil
 * ---@return integer errno the error number, when flags is nil
 */
COSMIC_SYSCALL(fd_flags, 1);

/*
 * --- How many processors are online, at least one.
 * ---@return integer count the number of online processors
 */
COSMIC_SYSCALL(cpu_count, 0);

/*
 * --- The processor's features the core's vendored code may choose code by, each by the name Linux's /proc/cpuinfo lists it under, in byte order: on x86_64 "aes", "pclmulqdq", "sse4_1" and "ssse3", from cpuid; on aarch64 "aes", "asimd", "crc32" and "pmull", from the auxiliary vector's hardware capabilities on Linux and sysctlbyname's hw.optional names on Darwin. Those this processor lacks are left out, and every one on any other machine.
 * ---@return {string} features the features this processor has
 */
COSMIC_SYSCALL(cpu_features, 0);

/*
 * --- The host as `uname(2)` names it: raw values, unnormalized, for a
 * --- caller to map onto its own host names.
 * ---@class Uname
 * ---@field sysname string the kernel name: "Linux", "Darwin"
 * ---@field machine string the machine: "x86_64", "aarch64", "arm64"
 * ---@field release string the kernel's release, as /proc/sys/kernel/osrelease reads: "6.18.44-fc-v64"
 */

/*
 * --- The host's kernel name, release and machine, as `uname(2)` reports them.
 * ---@return Uname|nil uname the three names, or nil on failure
 * ---@return string error what went wrong, when uname is nil
 * ---@return integer errno the error number, when uname is nil
 */
COSMIC_SYSCALL(uname, 0);

/*
 * --- One IPv4 or IPv6 address of one of the host's interfaces.
 * ---@class InterfaceAddress
 * ---@field name string the interface's name: "lo0", "en0"
 * ---@field family string "ipv4" or "ipv6"
 * ---@field address string the address in numeric form, as `inet_ntop` writes it, with no zone: a link-local IPv6 address comes without the interface index Darwin's kernel writes into its second group
 * ---@field prefix integer how many leading one bits the address's netmask has, 0 where the interface reports no netmask
 * ---@field up boolean whether the interface is up (IFF_UP)
 * ---@field loopback boolean whether the interface is a loopback one (IFF_LOOPBACK)
 */

/*
 * --- The IPv4 and IPv6 addresses of the host's interfaces, as `getifaddrs(3)` lists them, in its order; an entry of another family (a link-layer address) is left out. Darwin only: elsewhere ENOSYS. Linux's `getifaddrs` asks the kernel over a netlink socket, which a sandboxed process's filter refuses, so a caller there reads /proc/self/net instead ([`cosmic.relay.config`]'s `host_addresses`).
 * ---@return {InterfaceAddress}|nil addresses every address, or nil on failure
 * ---@return string error what went wrong, when addresses is nil
 * ---@return integer errno the error number, when addresses is nil: ENOSYS off Darwin
 */
COSMIC_SYSCALL(getifaddrs, 0);

/*
 * --- Reads a clock, in nanoseconds.
 * ---@param clock integer one of `CLOCK_REALTIME`, `CLOCK_MONOTONIC`
 * ---@return integer|nil nanoseconds the reading, or nil on failure
 * ---@return string error what went wrong, when nanoseconds is nil
 * ---@return integer errno the error number, when nanoseconds is nil
 */
COSMIC_SYSCALL(clock_gettime, 1);

/*
 * --- Sleeps for a number of nanoseconds, resuming after a signal.
 * ---@param nanoseconds integer how long to sleep
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(nanosleep, 1);

/*
 * --- The symbolic name of an errno, the name C's errno header gives it: the
 * --- third slot of a failure is this OS's number (`EAGAIN` is 11 on
 * --- Linux and 35 on macOS), and its name is the same on both. On
 * --- Linux, where `EOPNOTSUPP` and `ENOTSUP` share a number, it is
 * --- named `EOPNOTSUPP`.
 * ---@param number integer the errno
 * ---@return string|nil name its name, or nil for a number cosmic's errno table holds no entry for
 */
COSMIC_SYSCALL(errno_name, 1);

/*
 * --- What an errno says: the text a failure's second slot carries for
 * --- it, the same words on every OS (musl's), where libc's `strerror`
 * --- would answer each OS's own.
 * ---@param number integer the errno
 * ---@return string message its message, "No error information" for a number with none
 */
COSMIC_SYSCALL(errno_message, 1);

/*
 * --- Says whether a descriptor is a terminal.
 * ---@param fd integer the descriptor to ask about
 * ---@return boolean tty true when the descriptor is a terminal
 */
COSMIC_SYSCALL(isatty, 1);

/*
 * --- The path of the terminal a descriptor is open on, such as a pty slave's /dev/ttys003 or /dev/pts/3.
 * ---@param fd integer the descriptor to ask about
 * ---@return string|nil name the terminal's path, or nil on failure (ENOTTY for a descriptor that is no terminal)
 * ---@return string error what went wrong, when name is nil
 * ---@return integer errno the error number, when name is nil
 */
COSMIC_SYSCALL(ttyname, 1);

/*
 * --- A newly opened pseudo-terminal; both descriptors are close-on-exec,
 * --- blocking, and owned by the caller. Close both when finished.
 * ---@class Pty
 * ---@field master integer the relay's descriptor
 * ---@field slave integer the program's terminal descriptor
 */

/*
 * --- Opens and unlocks a fresh pseudo-terminal without acquiring it as a
 * --- controlling terminal. It requires access to the host's pty devices.
 * ---@return Pty|nil pty the pair, or nil on failure
 * ---@return string error what went wrong, when pty is nil
 * ---@return integer errno the error number, when pty is nil
 */
COSMIC_SYSCALL(openpty, 0);

/*
 * --- Saves this terminal's state as opaque bytes for tcsetattr. The state
 * --- is local to this host and core; do not persist it or edit its bytes.
 * ---@param fd integer the terminal descriptor
 * ---@return string|nil state the saved state, or nil on failure
 * ---@return string error what went wrong, when state is nil
 * ---@return integer errno the error number, when state is nil
 */
COSMIC_SYSCALL(tcgetattr, 1);

/*
 * --- Restores a state from tcgetattr immediately, without flushing queues.
 * ---@param fd integer the terminal descriptor
 * ---@param state string the opaque state from tcgetattr on this host
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(tcsetattr, 2);

/*
 * --- Sets raw mode immediately: bytes pass without echo, canonical line
 * --- processing, signal characters or output translation. Save first with
 * --- tcgetattr and restore with tcsetattr when finished.
 * ---@param fd integer the terminal descriptor
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(tcraw, 1);

/*
 * --- Discards pending terminal input and output.
 * ---@param fd integer the terminal descriptor
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(tcflush, 1);

/*
 * --- A terminal's dimensions, measured in character cells.
 * ---@class WindowSize
 * ---@field rows integer the number of rows
 * ---@field columns integer the number of columns
 */

/*
 * --- Reads the terminal's window size.
 * ---@param fd integer the terminal descriptor
 * ---@return WindowSize|nil size the dimensions, or nil on failure
 * ---@return string error what went wrong, when size is nil
 * ---@return integer errno the error number, when size is nil
 */
COSMIC_SYSCALL(winsize, 1);

/*
 * --- Sets the terminal's size, notifying its foreground process group
 * --- with SIGWINCH. Dimensions outside 0..65535 raise.
 * ---@param fd integer the terminal descriptor
 * ---@param rows integer the number of rows
 * ---@param columns integer the number of columns
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(setwinsize, 3);

/*
 * --- Starts a session and makes fd its controlling terminal. A refused
 * --- ioctl can leave the new session in place; call only in a pre-exec
 * --- trampoline, whose failure ends that child. A session leader fails.
 * ---@param fd integer the terminal descriptor
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(controlling_terminal, 1);


/*
 * --- Creates a symbolic link at `path` pointing at `target`. `target`
 * --- is stored verbatim and is never resolved.
 * ---@param target string the link's contents
 * ---@param path string the link to create
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(symlink, 2);

/*
 * --- Reads a symbolic link's target.
 * ---@param path string the link to read
 * ---@return string|nil target the link's contents, or nil on failure
 * ---@return string error what went wrong, when target is nil
 * ---@return integer errno the error number, when target is nil
 */
COSMIC_SYSCALL(readlink, 1);

/*
 * --- Sets a path's access time, modification time, or both, each as
 * --- whole seconds since the epoch and the nanoseconds after them, the
 * --- shape a Stat reports (`mtime`, `mtime_ns`). Nil seconds leave that
 * --- time as it is; nil nanoseconds are 0, and nanoseconds outside
 * --- [0, 1e9), or given without seconds, raise, as naming neither time
 * --- does. The link itself is changed, not its target. The program's own
 * --- file named through a descriptor of it is refused, EACCES.
 * ---@param path string the path to change
 * ---@param atime_s? integer the access time's seconds, or nil to keep it
 * ---@param atime_ns? integer the nanoseconds after atime_s, default 0
 * ---@param mtime_s? integer the modification time's seconds, or nil to keep it
 * ---@param mtime_ns? integer the nanoseconds after mtime_s, default 0
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(utimensat, 5);

/*
 * --- Flushes a descriptor's data and metadata to storage.
 * ---@param fd integer the descriptor to flush
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(fsync, 1);

/*
 * --- Requests Darwin's F_FULLFSYNC: flush the file and ask the device
 * --- to flush its write cache. The device may not honor that request;
 * --- success is not proof of physical durability. A filesystem that
 * --- cannot perform it returns its error. ENOSYS off Darwin, with no
 * --- fallback to fsync; [`cosmic.sys.fsync`] retains its ordinary contract.
 * ---@param fd integer the descriptor to flush
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(full_fsync, 1);

/*
 * --- Sets a descriptor's file to exactly `length` bytes, cutting it
 * --- short or extending it with zero bytes.
 * ---@param fd integer the descriptor, open for writing
 * ---@param length integer the size to set, not negative
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(ftruncate, 2);

/*
 * --- Locks the file a descriptor is open on, as `flock(2)` does: the
 * --- lock belongs to the open file, so another open of the same file,
 * --- in this process or another, is refused a lock that conflicts with
 * --- it, and it is released when every descriptor of that open is
 * --- closed -- when the process ends, too. "exclusive" conflicts with
 * --- every other lock, "shared" only with an exclusive one, and
 * --- "unlock" releases what this open holds. A conflicting lock is
 * --- waited for until `timeout_ms` has passed, "Operation timed out",
 * --- or the innermost open `Child.guard` catches SIGINT or SIGTERM, "Interrupted system
 * --- call", each seen within a tenth of a second. Over NFS or SMB, an
 * --- exclusive lock needs a descriptor open for writing.
 * ---@param fd integer the descriptor, open on the file to lock
 * ---@param how string "exclusive", "shared" or "unlock"
 * ---@param timeout_ms? integer how long to wait, in milliseconds, from 0 (the default: ask once); -1 for no limit
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(flock, 3);

/*
 * --- How a `flock` of the file `fd` is open on stands to fcntl locks, SQLite's among them: "apart" where the two are kept apart, so neither excludes the other, as Linux keeps them on a local filesystem; "shared" where they are in one list, and a whole-file flock conflicts with an fcntl lock of another owner, even another open of this same process -- as Darwin and the BSDs keep them, and as Linux's clients of SMB, and of NFS but where it is mounted with local_lock "flock" or "all", make a flock a whole-file fcntl lock.
 * ---@param fd integer the descriptor, open on the file to ask about
 * ---@return string|nil kind "apart" or "shared", or nil on failure
 * ---@return string error what went wrong, when kind is nil
 * ---@return integer errno the error number, when kind is nil
 */
COSMIC_SYSCALL(flock_kind, 1);

/*
 * --- Whether this process may reach `path` as `mode` asks: 0 for only
 * --- that it exists, else R_OK, W_OK and X_OK or'd together. It is
 * --- asked with the effective ids, as `execvp` and `open` ask, and
 * --- follows a link. A refusal is a failure, EACCES its errno.
 * ---@param path string the path to ask about
 * ---@param mode integer 0, or R_OK, W_OK and X_OK or'd together
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(access, 2);

/*
 * --- Makes a named pipe at `path`, with the permission bits `mode` less
 * --- the umask.
 * ---@param path string the pipe to make
 * ---@param mode? integer its permission bits, default 0o644
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(mkfifo, 2);

/*
 * --- Turns a descriptor's nonblocking mode on or off: on, a read or write
 * --- that would wait fails with EAGAIN instead. The mode belongs to the
 * --- open file, so every descriptor duplicated from it shares it.
 * ---@param fd integer the descriptor
 * ---@param on boolean true for nonblocking reads and writes
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(set_nonblocking, 2);

/*
 * --- Waits until one of the descriptors is ready or the timeout passes,
 * --- and answers what happened to each, 0 for one not ready. A
 * --- descriptor of -1 is not watched and answers 0, one below -1 raises,
 * --- and one not open answers POLLNVAL. A descriptor given more than once
 * --- is watched once, for every event its entries want, and each entry
 * --- answers only its own events (and POLLERR, POLLHUP, POLLNVAL), on
 * --- every system alike. A signal ends the wait early, as
 * --- though nothing were ready. There is no count the call itself
 * --- refuses: the kernel refuses more distinct descriptors than
 * --- RLIMIT_NOFILE's soft limit (at most OPEN_MAX on macOS) with EINVAL;
 * --- `setrlimit` raises it.
 * ---@param fds {integer} the descriptors to watch
 * ---@param events {integer} the POLL* mask wanted for each descriptor
 * ---@param timeout_ms integer how long to wait, -1 for no limit
 * ---@return {integer}|nil revents the POLL* mask that happened for each descriptor, or nil on failure
 * ---@return string error what went wrong, when revents is nil
 * ---@return integer errno the error number, when revents is nil
 */
COSMIC_SYSCALL(poll, 3);

/*
 * --- The numbers the calls above take and give back. They come from
 * --- this libc, so nothing above the table carries a platform's own.
 * ---@class Constants
 * ---@field O_RDONLY integer open for reading
 * ---@field O_WRONLY integer open for writing
 * ---@field O_RDWR integer open for both
 * ---@field O_CREAT integer create the file when it is missing
 * ---@field O_EXCL integer with O_CREAT, refuse an existing file
 * ---@field O_TRUNC integer empty the file on open
 * ---@field O_APPEND integer every write goes to the end
 * ---@field O_NOFOLLOW integer refuse a path whose last part is a link
 * ---@field O_NONBLOCK integer never wait: open a named pipe with no writer, read what is there
 * ---@field O_NOCTTY integer never make a terminal opened the controlling one
 * ---@field R_OK integer for `access`: may read it
 * ---@field W_OK integer for `access`: may write it
 * ---@field X_OK integer for `access`: may run it, or search it as a directory
 * ---@field FD_CLOEXEC integer in `fd_flags`: closed on exec
 * ---@field SEEK_SET integer seek from the start
 * ---@field SEEK_CUR integer seek from where the descriptor is
 * ---@field SEEK_END integer seek from the end
 * ---@field CLOCK_REALTIME integer the wall clock, which can step
 * ---@field CLOCK_MONOTONIC integer a clock that only moves forward
 * ---@field ENOENT integer there is no such file
 * ---@field EEXIST integer the name is already taken
 * ---@field EACCES integer permission was refused
 * ---@field EAFNOSUPPORT integer the socket address family is not supported
 * ---@field EPROTONOSUPPORT integer the socket protocol is not supported
 * ---@field EINTR integer a signal arrived first
 * ---@field EISDIR integer it is a directory
 * ---@field ENOTDIR integer it is not a directory
 * ---@field ENOTEMPTY integer the directory still holds entries
 * ---@field EAGAIN integer nothing is ready yet
 * ---@field EPIPE integer the other end is gone
 * ---@field EXDEV integer the two paths are on different filesystems
 * ---@field ECHILD integer there is no child to wait for
 * ---@field ESRCH integer there is no such process or group
 * ---@field EBADF integer the descriptor is not open
 * ---@field ENOSYS integer this platform has no such call
 * ---@field EOPNOTSUPP integer the kernel has the call but it is turned off
 * ---@field EPERM integer the call is not permitted, as a seccomp filter refuses one
 * ---@field ENOSPC integer no room is left, as when no more user namespaces may be made
 * ---@field EINVAL integer an argument is invalid, such as a path holding a NUL byte
 * ---@field EMFILE integer no descriptor is free below RLIMIT_NOFILE's soft limit
 * ---@field SIGHUP integer the terminal hung up
 * ---@field SIGINT integer interrupt, as from a terminal
 * ---@field SIGQUIT integer quit, as from a terminal
 * ---@field SIGKILL integer force termination
 * ---@field SIGPIPE integer a write to a pipe nobody reads
 * ---@field SIGTERM integer request termination
 * ---@field SIGUSR1 integer the first user-defined signal
 * ---@field POLLIN integer for `poll`: there is data to read, or a connection to accept
 * ---@field POLLOUT integer for `poll`: a write would not wait
 * ---@field POLLERR integer for `poll`: the descriptor is in error
 * ---@field POLLHUP integer for `poll`: the other end hung up
 * ---@field POLLNVAL integer for `poll`: the descriptor is not open
 * ---@field RLIMIT_NOFILE integer for `getrlimit` and `setrlimit`: one more than the highest descriptor the process may open
 * ---@field RLIMIT_FSIZE integer for `getrlimit` and `setrlimit`: the most bytes of a file the process may write
 * ---@field RLIMIT_CPU integer for `getrlimit` and `setrlimit`: the CPU seconds the process may spend before SIGXCPU
 * ---@field RLIMIT_CORE integer for `getrlimit` and `setrlimit`: the most bytes of a core dump the process may write, 0 for none
 * ---@field RLIMIT_NPROC integer for `getrlimit` and `setrlimit`: the most processes and threads the process's user may have, counted per user namespace from Linux 5.17
 */
COSMIC_CONSTANT(O_RDONLY)
COSMIC_CONSTANT(O_WRONLY)
COSMIC_CONSTANT(O_RDWR)
COSMIC_CONSTANT(O_CREAT)
COSMIC_CONSTANT(O_EXCL)
COSMIC_CONSTANT(O_TRUNC)
COSMIC_CONSTANT(O_APPEND)
COSMIC_CONSTANT(O_NOFOLLOW)
COSMIC_CONSTANT(O_NONBLOCK)
COSMIC_CONSTANT(O_NOCTTY)
COSMIC_CONSTANT(R_OK)
COSMIC_CONSTANT(W_OK)
COSMIC_CONSTANT(X_OK)
COSMIC_CONSTANT(FD_CLOEXEC)
COSMIC_CONSTANT(SEEK_SET)
COSMIC_CONSTANT(SEEK_CUR)
COSMIC_CONSTANT(SEEK_END)
COSMIC_CONSTANT(CLOCK_REALTIME)
COSMIC_CONSTANT(CLOCK_MONOTONIC)
COSMIC_CONSTANT(ENOENT)
COSMIC_CONSTANT(EEXIST)
COSMIC_CONSTANT(EACCES)
COSMIC_CONSTANT(EAFNOSUPPORT)
COSMIC_CONSTANT(EPROTONOSUPPORT)
COSMIC_CONSTANT(EINTR)
COSMIC_CONSTANT(EISDIR)
COSMIC_CONSTANT(ENOTDIR)
COSMIC_CONSTANT(ENOTEMPTY)
COSMIC_CONSTANT(EAGAIN)
COSMIC_CONSTANT(EPIPE)
COSMIC_CONSTANT(EXDEV)
COSMIC_CONSTANT(ECHILD)
COSMIC_CONSTANT(ESRCH)
COSMIC_CONSTANT(EBADF)
COSMIC_CONSTANT(ENOSYS)
COSMIC_CONSTANT(EOPNOTSUPP)
COSMIC_CONSTANT(EPERM)
COSMIC_CONSTANT(ENOSPC)
COSMIC_CONSTANT(EINVAL)
COSMIC_CONSTANT(EMFILE)
COSMIC_CONSTANT(SIGHUP)
COSMIC_CONSTANT(SIGINT)
COSMIC_CONSTANT(SIGQUIT)
COSMIC_CONSTANT(SIGKILL)
COSMIC_CONSTANT(SIGPIPE)
COSMIC_CONSTANT(SIGTERM)
COSMIC_CONSTANT(SIGUSR1)
COSMIC_CONSTANT(POLLIN)
COSMIC_CONSTANT(POLLOUT)
COSMIC_CONSTANT(POLLERR)
COSMIC_CONSTANT(POLLHUP)
COSMIC_CONSTANT(POLLNVAL)
COSMIC_CONSTANT(RLIMIT_NOFILE)
COSMIC_CONSTANT(RLIMIT_FSIZE)
COSMIC_CONSTANT(RLIMIT_CPU)
COSMIC_CONSTANT(RLIMIT_CORE)
COSMIC_CONSTANT(RLIMIT_NPROC)
