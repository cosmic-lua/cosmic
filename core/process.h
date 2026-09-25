/*
 * The process table: the calls `cosmic.child` starts, feeds and reaps a
 * child with, and the one `cosmic.proc` relaunches this program with.
 * Registered as the raw `cosmic.internal.process` module, which only
 * those wrappers (and `build.filesystem_observations`, which watches a
 * test's children through it) are handed: none of it is public. A
 * public `waitpid(-1)` would reap a child a `Child` handle owns in an
 * adopting process, and a public spawn would start one no handle owns.
 *
 * The grammar and the two shapes are core/syscalls.h's: each entry is a
 * LuaCATS annotation block followed by COSMIC_SYSCALL naming it, which
 * `build/gen_syscalls.tl` turns into the declaration of
 * `cosmic.internal.process`. The functions themselves live in
 * core/syscalls.c, with the signal state and descriptor handling they
 * share with `execve`.
 */

#ifndef COSMIC_PROCESS_H
#define COSMIC_PROCESS_H

#include "lua.h"
#include "syscalls.h"

/*
 * --- What `spawn` holds a child to from its exec on, with every process it starts.
 * ---@class Sandbox
 * ---@field ruleset integer a ruleset from `landlock_ruleset`, or nil for none
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
 * ---@param fds? {integer:integer} more descriptors the child gets, each child descriptor from 3 to 255 by the descriptor it copies; every other one above 2 is closed
 * ---@param sandbox? Sandbox what the child, and every process it starts, is held to from its exec on
 * ---@return integer|nil pid the child process id, or nil when setup or exec failed
 * ---@return string error what went wrong, when pid is nil
 * ---@return integer errno the error number, when pid is nil
 */
COSMIC_SYSCALL(spawn, 10);

/*
 * --- A Landlock ruleset a child can be held to (`spawn`'s `sandbox`): opening and running what is beneath each path of `reads`, and changing what is beneath each of `writes` too, and no other file or directory -- nor, where the kernel can hold it to these, a TCP connection or a bound port, an abstract unix socket or a signal to a process outside it. It does not hold what Landlock cannot: stat and the like of any path, a unix socket named by a path, UDP, or a descriptor the child is handed already open. Closed on exec. ENOSYS, EOPNOTSUPP or EPERM where there is no Landlock to be had: not built in, turned off, or refused by a filter.
 * ---@param reads {string} the files and directories the child may read and run
 * ---@param writes {string} the files and directories it may change too
 * ---@return integer|nil ruleset the ruleset's descriptor, or nil on failure
 * ---@return string error what went wrong, when ruleset is nil
 * ---@return integer errno the error number, when ruleset is nil
 */
COSMIC_SYSCALL(landlock_ruleset, 2);

/*
 * ---@class ChildStatus
 * ---@field pid integer zero when a nonblocking wait found no finished child
 * ---@field code integer exit status, or -1 when the child was signaled or unfinished
 * ---@field signal integer terminating signal, or -1 when it exited or is unfinished
 */

/*
 * --- Reaps a child, optionally returning immediately while it is running.
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
 * --- Turns a descriptor's nonblocking mode on or off.
 * ---@param fd integer the descriptor
 * ---@param on boolean true for nonblocking reads and writes
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(set_nonblocking, 2);

/*
 * --- Waits until a descriptor is ready or the timeout passes. A signal ends the wait early, as though nothing were ready.
 * ---@param fds {integer} the descriptors to watch, at most 1024
 * ---@param events {integer} the POLL* mask wanted for each descriptor
 * ---@param timeout_ms integer how long to wait, -1 for no limit
 * ---@return {integer}|nil revents the POLL* mask that happened for each descriptor, or nil on failure
 * ---@return string error what went wrong, when revents is nil
 * ---@return integer errno the error number, when revents is nil
 */
COSMIC_SYSCALL(poll, 3);

/*
 * --- Makes this process adopt the orphaned descendants of its children, so it can reap them; Linux only.
 * ---@return boolean ok false on failure, with ENOSYS where there is no such thing
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(subreaper, 0);

/*
 * --- Ignores SIGPIPE, so a write to a closed pipe fails with EPIPE instead of ending the process. A child started afterward gets the default back.
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(ignore_sigpipe, 0);

/* Opens the table as the raw `cosmic.internal.process` module. */
int cosmic_open_process (lua_State *L);

#endif
