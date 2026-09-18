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

#define COSMIC_SYSCALL(name) int cosmic_sys_##name(lua_State *L)

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
 * ---@param flags integer the O_* flags, from `syscalls.O`
 * ---@param mode integer the mode for a newly created file, default 0o644
 * ---@return integer|nil fd the descriptor, or nil on failure
 * ---@return string error what went wrong, when fd is nil
 * ---@return integer errno the error number, when fd is nil
 */
COSMIC_SYSCALL(open);

/*
 * --- Closes a descriptor.
 * ---@param fd integer the descriptor to close
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(close);

/*
 * --- Reads up to `count` bytes. An empty string means end of file.
 * ---@param fd integer the descriptor to read
 * ---@param count integer how many bytes to ask for
 * ---@return string|nil data the bytes read, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer errno the error number, when data is nil
 */
COSMIC_SYSCALL(read);

/*
 * --- Reads up to `count` bytes from an explicit offset.
 * ---@param fd integer the descriptor to read
 * ---@param count integer how many bytes to ask for
 * ---@param offset integer the offset to read from
 * ---@return string|nil data the bytes read, or nil on failure
 * ---@return string error what went wrong, when data is nil
 * ---@return integer errno the error number, when data is nil
 */
COSMIC_SYSCALL(pread);

/*
 * --- Writes bytes and returns how many went out.
 * ---@param fd integer the descriptor to write
 * ---@param data string the bytes to write
 * ---@return integer|nil written how many bytes went out, or nil on failure
 * ---@return string error what went wrong, when written is nil
 * ---@return integer errno the error number, when written is nil
 */
COSMIC_SYSCALL(write);

/*
 * --- Moves a descriptor's offset and returns the new one.
 * ---@param fd integer the descriptor to move
 * ---@param offset integer how far to move
 * ---@param whence integer one of `syscalls.SEEK_SET`, `_CUR`, `_END`
 * ---@return integer|nil offset the new offset, or nil on failure
 * ---@return string error what went wrong, when offset is nil
 * ---@return integer errno the error number, when offset is nil
 */
COSMIC_SYSCALL(lseek);

/*
 * --- Describes an open descriptor.
 * ---@param fd integer the descriptor to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(fstat);

/*
 * --- Describes a path, following a symbolic link at the end of it.
 * ---@param path string the path to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(stat);

/*
 * --- Describes a path, describing a symbolic link rather than its target.
 * ---@param path string the path to describe
 * ---@return Stat|nil stat the description, or nil on failure
 * ---@return string error what went wrong, when stat is nil
 * ---@return integer errno the error number, when stat is nil
 */
COSMIC_SYSCALL(lstat);

/*
 * --- Creates a directory.
 * ---@param path string the directory to create
 * ---@param mode integer the mode to create it with, default 0o755
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(mkdir);

/*
 * --- Removes an empty directory.
 * ---@param path string the directory to remove
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(rmdir);

/*
 * --- Removes a name from the filesystem.
 * ---@param path string the name to remove
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(unlink);

/*
 * --- Moves a name, replacing the destination if it exists.
 * ---@param from string the name to move
 * ---@param to string where to move it
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(rename);

/*
 * --- Sets a path's permission bits.
 * ---@param path string the path to change
 * ---@param mode integer the permission bits to set
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chmod);

/*
 * --- Lists a directory's entries, without `.` and `..`, in no order.
 * ---@param path string the directory to list
 * ---@return {string}|nil names the entry names, or nil on failure
 * ---@return string error what went wrong, when names is nil
 * ---@return integer errno the error number, when names is nil
 */
COSMIC_SYSCALL(readdir);

/*
 * --- Returns the process's current directory.
 * ---@return string|nil path the directory, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(getcwd);

/*
 * --- Changes the process's current directory.
 * ---@param path string the directory to move to
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(chdir);

/*
 * --- Resolves a path to an absolute one with no link and no `..` left.
 * ---@param path string the path to resolve
 * ---@return string|nil path the resolved path, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(realpath);

/*
 * --- Returns the path of the running executable.
 * ---@return string|nil path the executable's path, or nil on failure
 * ---@return string error what went wrong, when path is nil
 * ---@return integer errno the error number, when path is nil
 */
COSMIC_SYSCALL(executable);

/*
 * --- Reads one environment variable.
 * ---@param name string the variable to read
 * ---@return string|nil value the value, or nil when it is not set
 */
COSMIC_SYSCALL(getenv);

/*
 * --- Reads the whole environment as a name-to-value map.
 * ---@return {string:string} environment every variable the process has
 */
COSMIC_SYSCALL(environ);

/*
 * --- Ends the process. It does not return.
 * ---@param status integer the exit status
 */
COSMIC_SYSCALL(exit);

/*
 * --- Returns the process's own identifier.
 * ---@return integer pid the process identifier
 */
COSMIC_SYSCALL(getpid);

/*
 * --- Reads a clock, in seconds and nanoseconds.
 * ---@param clock integer one of `syscalls.CLOCK_REALTIME`, `_MONOTONIC`
 * ---@return integer|nil seconds whole seconds, or nil on failure
 * ---@return string error what went wrong, when seconds is nil
 * ---@return integer errno the error number, when seconds is nil
 */
COSMIC_SYSCALL(clock_gettime);

/*
 * --- Sleeps for a number of nanoseconds, resuming after a signal.
 * ---@param nanoseconds integer how long to sleep
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(nanosleep);

/*
 * --- Says whether a descriptor is a terminal.
 * ---@param fd integer the descriptor to ask about
 * ---@return boolean tty true when the descriptor is a terminal
 */
COSMIC_SYSCALL(isatty);

/*
 * --- Hashes bytes with SHA-256 and returns the 32 raw bytes.
 * ---@param data string the bytes to hash
 * ---@return string digest the 32-byte digest
 */
COSMIC_SYSCALL(sha256);

/*
 * --- Compresses bytes with deflate.
 * ---@param data string the bytes to compress
 * ---@return string|nil packed the compressed bytes, or nil on failure
 * ---@return string error what went wrong, when packed is nil
 */
COSMIC_SYSCALL(deflate);

/*
 * --- Expands bytes that deflate compressed.
 * ---@param data string the compressed bytes
 * ---@param size integer the expanded size, which the caller recorded
 * ---@return string|nil data the expanded bytes, or nil on failure
 * ---@return string error what went wrong, when data is nil
 */
COSMIC_SYSCALL(inflate);

/* Opens the table as the `cosmic.syscalls` module. */
int cosmic_open_syscalls(lua_State *L);

#endif
