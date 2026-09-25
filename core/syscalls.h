/*
 * The syscall table: one C function per call, the same signature on
 * Linux and on macOS, so a Teal module written once behaves the same on
 * both and the sandbox has one door.
 *
 * Every entry is a LuaCATS annotation block followed by COSMIC_SYSCALL
 * naming it. The block is the source of truth: `build/gen_syscalls.tl`
 * turns it into the Teal declaration and the documentation row, and
 * refuses a function whose annotation is missing a slot. A binding
 * cannot exist without its type, and the C surface cannot grow without
 * a diff in this file -- or in core/process.h, which declares, in the
 * same grammar, the calls only `cosmic.child` and `cosmic.proc` are
 * handed, as the raw `cosmic.internal.process`.
 *
 * Two shapes, and no third. An argument-shape error -- a degenerate
 * input no correct program passes -- raises. A failure a correct caller
 * meets at runtime returns `nil, error, errno` from a call that answers
 * a value and `false, error, errno` from an effect (`core/fail.h`): the
 * error in slot two, the errno in slot three, nothing else sharing a
 * slot. This table is the one place a third slot is allowed; a Teal
 * function over it answers in two.
 */

#ifndef COSMIC_SYSCALLS_H
#define COSMIC_SYSCALLS_H

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
 * does. `spawn` (core/process.h), whose path and cwd refused a NUL by
 * raising before this rule, still does: `cosmic.child` depends on it,
 * and neither way truncates. */
const char *cosmic_path (lua_State *L, int index);

/* Opens the table as the `cosmic.sys` module. */
int cosmic_open_syscalls (lua_State *L);

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
 * --- What `stat`, `lstat` and `fstat` report about a path.
 * ---@class Stat
 * ---@field size integer the size in bytes
 * ---@field mode integer the type and permission bits
 * ---@field kind string one of "file", "dir", "link", "other"
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
 * --- Opens a path and returns a descriptor.
 * ---@param path string the path to open
 * ---@param flags integer the O_* flags, from `syscalls.O`
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
 * ---@param whence integer one of `syscalls.SEEK_SET`, `_CUR`, `_END`
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
 * --- Moves a name, replacing the destination if it exists.
 * ---@param from string the name to move
 * ---@param to string where to move it
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(rename, 2);

/*
 * --- Sets a path's permission bits.
 * ---@param path string the path to change
 * ---@param mode integer the permission bits to set
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chmod, 2);

/*
 * --- Lists a directory's entries, without `.` and `..`, each with what it is, as `lstat` names it: "dir", "file", "link" for a symbolic link (never followed), or "other".
 * ---@param path string the directory to list
 * ---@return {string:string}|nil entries each entry's kind by its name, or nil on failure
 * ---@return string error what went wrong, when entries is nil
 * ---@return integer errno the error number, when entries is nil
 */
COSMIC_SYSCALL(readdir, 1);

/*
 * --- What a tree holds, digested: `tree_digest`'s answer.
 * ---@class TreeDigest
 * ---@field digest string the hex sha256 of every entry at and beneath the path, links unfollowed, in name order: each one's contents where asked for, and otherwise what `lstat` says of it -- type and permissions, size, modification and change times, and inode
 * ---@field special boolean whether it holds a socket, a FIFO or a device other than /dev/null, /dev/zero or /dev/urandom, each of which answers from past the tree, or anything the walk could not see: an entry it could not read or list, or one more than 128 directories down
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
 * --- Returns the real user identifier the process runs as.
 * ---@return integer uid the user identifier
 */
COSMIC_SYSCALL(getuid, 0);

/*
 * --- Sets the file mode creation mask, the permission bits a new file or
 * --- directory is made without, for this process and every child it
 * --- starts afterwards.
 * ---@param mask integer the permission bits to withhold, 0 to 0777
 * ---@return integer previous the mask before this call
 */
COSMIC_SYSCALL(umask, 1);

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
 * --- How many processors are online, at least one.
 * ---@return integer count the number of online processors
 */
COSMIC_SYSCALL(cpu_count, 0);

/*
 * --- The host as `uname(2)` names it: raw values, unnormalized, for a
 * --- caller to map onto its own host names.
 * ---@class Uname
 * ---@field sysname string the kernel name: "Linux", "Darwin"
 * ---@field machine string the machine: "x86_64", "aarch64", "arm64"
 */

/*
 * --- The host's kernel name and machine, as `uname(2)` reports them.
 * ---@return Uname|nil uname the two names, or nil on failure
 * ---@return string error what went wrong, when uname is nil
 * ---@return integer errno the error number, when uname is nil
 */
COSMIC_SYSCALL(uname, 0);

/*
 * --- Reads a clock, in nanoseconds.
 * ---@param clock integer one of `syscalls.CLOCK_REALTIME`, `_MONOTONIC`
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
 * --- The symbolic name of an errno, the name <errno.h> gives it: the
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
 * --- does. The link itself is changed, not its target.
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
 * ---@field SEEK_SET integer seek from the start
 * ---@field SEEK_CUR integer seek from where the descriptor is
 * ---@field SEEK_END integer seek from the end
 * ---@field CLOCK_REALTIME integer the wall clock, which can step
 * ---@field CLOCK_MONOTONIC integer a clock that only moves forward
 * ---@field ENOENT integer there is no such file
 * ---@field EEXIST integer the name is already taken
 * ---@field EACCES integer permission was refused
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
 * ---@field SIGHUP integer the terminal hung up
 * ---@field SIGINT integer interrupt, as from a terminal
 * ---@field SIGQUIT integer quit, as from a terminal
 * ---@field SIGKILL integer force termination
 * ---@field SIGPIPE integer a write to a pipe nobody reads
 * ---@field SIGTERM integer request termination
 * ---@field SIGUSR1 integer the first user-defined signal
 */
COSMIC_CONSTANT(O_RDONLY)
COSMIC_CONSTANT(O_WRONLY)
COSMIC_CONSTANT(O_RDWR)
COSMIC_CONSTANT(O_CREAT)
COSMIC_CONSTANT(O_EXCL)
COSMIC_CONSTANT(O_TRUNC)
COSMIC_CONSTANT(O_APPEND)
COSMIC_CONSTANT(SEEK_SET)
COSMIC_CONSTANT(SEEK_CUR)
COSMIC_CONSTANT(SEEK_END)
COSMIC_CONSTANT(CLOCK_REALTIME)
COSMIC_CONSTANT(CLOCK_MONOTONIC)
COSMIC_CONSTANT(ENOENT)
COSMIC_CONSTANT(EEXIST)
COSMIC_CONSTANT(EACCES)
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
COSMIC_CONSTANT(SIGHUP)
COSMIC_CONSTANT(SIGINT)
COSMIC_CONSTANT(SIGQUIT)
COSMIC_CONSTANT(SIGKILL)
COSMIC_CONSTANT(SIGPIPE)
COSMIC_CONSTANT(SIGTERM)
COSMIC_CONSTANT(SIGUSR1)
