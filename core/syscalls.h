/*
 * The syscall table: one C function per call, the same signature on
 * Linux and on macOS, so a Teal module written once behaves the same on
 * both and the sandbox has one door.
 *
 * Every entry is a LuaCATS annotation block followed by COSMIC_SYSCALL
 * naming it. The block is the source of truth: `build/gen_syscalls.tl`
 * turns it into the Teal declaration, and
 * refuses a function whose annotation is missing a slot. A binding
 * cannot exist without its type, and the C surface cannot grow without
 * a diff in this file.
 *
 * Two shapes, and no third. An argument-shape error -- a degenerate
 * input no correct program passes -- raises. A failure a correct caller
 * meets at runtime returns `nil, error, errno`: the error in slot two,
 * the errno in slot three, nothing else sharing a slot.
 */

#ifndef COSMIC_SYSCALLS_H
#define COSMIC_SYSCALLS_H

#include "lua.h"

/* `arity` is the number of parameters the annotation block just above
 * declares -- the generator cross-checks the two against each other, so
 * a `@param` line and this count can never drift apart unnoticed. It is
 * not part of the C signature, which is always `(lua_State *L)`: the
 * arguments come off the Lua stack, not a C parameter list. */
#define COSMIC_SYSCALL(name, arity) int cosmic_sys_##name(lua_State *L)

/*
 * --- What `stat`, `lstat` and `fstat` report about a path.
 * ---@class Stat
 * ---@field size integer the size in bytes
 * ---@field mode integer the type and permission bits
 * ---@field kind string one of "file", "dir", "link", "other"
 * ---@field mtime integer the modification time, whole seconds
 * ---@field mtime_ns integer the nanoseconds part of the modification time
 * ---@field ino integer the inode number
 * ---@field dev integer the device the inode is on
 * ---@field nlink integer how many names point at it
 * ---@field uid integer the owning user
 * ---@field gid integer the owning group
 */

/*
 * --- Opens a path and returns a descriptor.
 * ---@param path string the path to open
 * ---@param flags integer the O_* flags, ORed together
 * ---@param mode? integer the mode for a newly created file, default 0o644
 * ---@return integer|nil fd the descriptor, or nil on failure
 * ---@return string error what went wrong, when fd is nil
 * ---@return integer errno the error number, when fd is nil
 */
COSMIC_SYSCALL(open, 3);

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
 * ---@param fd integer the descriptor to read
 * ---@param count integer how many bytes to ask for
 * ---@return string|nil data the bytes read, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer errno the error number, when data is nil
 */
COSMIC_SYSCALL(read, 2);

/*
 * --- Reads up to `count` bytes from an explicit offset.
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
 * --- Lists a directory's entries, without `.` and `..`, in no order.
 * ---@param path string the directory to list
 * ---@return {string}|nil names the entry names, or nil on failure
 * ---@return string error what went wrong, when names is nil
 * ---@return integer errno the error number, when names is nil
 */
COSMIC_SYSCALL(readdir, 1);

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
 * --- Returns the path of the running executable.
 * ---@return string|nil path the executable's path, or nil on failure
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
 * --- Says whether a descriptor is a terminal.
 * ---@param fd integer the descriptor to ask about
 * ---@return boolean tty true when the descriptor is a terminal
 */
COSMIC_SYSCALL(isatty, 1);

/*
 * --- Hashes bytes with SHA-256 and returns the 32 raw bytes.
 * ---@param data string the bytes to hash
 * ---@return string digest the 32-byte digest
 */
COSMIC_SYSCALL(sha256, 1);

/*
 * --- Compresses bytes with deflate.
 * ---@param data string the bytes to compress
 * ---@return string|nil packed the compressed bytes, or nil on failure
 * ---@return string error what went wrong, when packed is nil
 * ---@return integer code miniz's own result code, when packed is nil
 */
COSMIC_SYSCALL(deflate, 1);

/*
 * --- Expands bytes that deflate compressed.
 * ---@param data string the compressed bytes
 * ---@param size integer the expanded size, which the caller recorded
 * ---@return string|nil data the expanded bytes, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer code miniz's own result code, when data is nil
 */
COSMIC_SYSCALL(inflate, 2);

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
 */

/* Opens the table as the `cosmic.sys` module. */
int cosmic_open_syscalls(lua_State *L);

#endif
