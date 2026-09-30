/*
 * The socket table: the calls [`cosmic.net`] listens, accepts, connects
 * and sends with, registered as the raw [`cosmic.internal.socket`]
 * module, which only that wrapper is handed. Every socket it makes is
 * closed on exec and nonblocking, so a wait is always `wait`'s, which
 * a deadline and a [`Child.guard`] end; reading is [`cosmic.sys`]'s `read`.
 * Each is answered as a `Socket` that owns its descriptor from the
 * moment it is made, so a raise before the caller has wrapped it --
 * memory running out -- leaks nothing: the collector closes it.
 *
 * An address is a table whose `kind` says how the rest of it is read,
 * so a kind of socket is one more branch where an address becomes a
 * `sockaddr`, not a call of its own.
 *
 * The grammar and the two shapes are core/syscalls.h's: each entry is a
 * LuaCATS annotation block followed by COSMIC_SYSCALL naming it, which
 * [`build/gen_syscalls.tl`] turns into the declaration of
 * [`cosmic.internal.socket`].
 */

#ifndef COSMIC_SOCKET_H
#define COSMIC_SOCKET_H

#include "lua.h"
#include "syscalls.h"

/* Opens the table as the raw [`cosmic.internal.socket`] module. */
int cosmic_open_socket (lua_State *L);

#endif

/* Entries, as core/syscalls.h's are: X-macros core/socket.c expands
 * again into the table the module is opened with. */
#ifndef COSMIC_SYSCALL
#define COSMIC_SYSCALL(name, arity) int cosmic_sys_##name(lua_State *L)
#endif
#ifndef COSMIC_CONSTANT
#define COSMIC_CONSTANT(name)
#endif

/*
 * --- Where a socket is, read by its `kind`.
 * ---@class Address
 * ---@field kind string "unix", a socket file named by `path`, or "tcp", a TCP `port` of a `host`
 * ---@field path string the socket file's path, for "unix", never empty: of any length a path may have, but the file's own name, past its last "/", at most `SOCKET_NAME_MAX` bytes, which a longer one fails with ENAMETOOLONG rather than being cut short. A path past that bound whole is reached from its directory
 * ---@field host string the host's numeric IPv4 or IPv6 address, for "tcp": a name is not looked up, nor an IPv6 scope read, and either fails with EINVAL, as a NUL in it does
 * ---@field port integer the port, for "tcp", from 0 to 65535: 0 to listen at a port the kernel chooses, which `bound` then names
 */

/*
 * --- A socket this table made, which owns its descriptor, and a unix listener's socket file: `close`, `<close>` or the collector closes the descriptor and then removes the file while its name is still the file the listener made, so one that has taken the name since is left alone. A unix listener holds a second descriptor for its life, of the file's directory, which it removes the file from wherever the process has moved to and whatever the length of its path; the directory cannot be unmounted while it is held.
 * ---@class Socket: userdata
 * ---@field fd fun(self:Socket):integer the descriptor, for the calls that take one; raises once the socket is closed
 * ---@field close fun(self:Socket):boolean,string,integer closes it: true, or false, what went wrong and the error number, the descriptor closed even so; true again once closed
 * ---@field __close fun(self:Socket) closes it as `close` does, its failure ignored
 */

/*
 * --- Makes a stream socket listening at an address. A unix one is a new socket file, the socket's to remove: a path already there, a stale socket file included, fails with EADDRINUSE and is left alone, and one whose name another file has taken before it could be read back fails with EEXIST and is left to that file. A TCP one fails with EADDRINUSE on a port a listener holds; on Linux it takes one left in TIME_WAIT (SO_REUSEADDR), where macOS refuses it until TIME_WAIT ends.
 * ---@param address Address where to listen
 * ---@param backlog integer how many connections may wait to be accepted, from 1
 * ---@return Socket|nil socket the listening socket, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(listen, 2);

/*
 * --- Takes the next connection waiting on a listening descriptor, as a socket of its own, closed on exec and nonblocking.
 * ---@param fd integer the listening descriptor
 * ---@return Socket|nil connection the connection's socket, or nil on failure: EAGAIN when none is waiting. A pending connection that failed before it was taken is passed over for the next.
 * ---@return string error what went wrong, when connection is nil
 * ---@return integer errno the error number, when connection is nil
 */
COSMIC_SYSCALL(accept, 1);

/*
 * --- Connects a new stream socket to an address. A unix one fails ECONNREFUSED where nothing listens at a socket file and ENOENT where there is no file; where its listener's backlog is full, Linux's waits for room, while macOS's fails ECONNREFUSED at once, as though nothing listened. A TCP one waits for the connection to be made, and fails with what refused it: ECONNREFUSED where nothing listens at the port. A wait fails ETIMEDOUT once the time runs out, and EINTR once an open `Child.guard` catches a signal.
 * ---@param address Address where to connect
 * ---@param timeout_ms integer how long to wait at most, -1 for no limit
 * ---@return Socket|nil socket the connected socket, closed on exec and nonblocking, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(connect, 2);

/*
 * --- Starts connecting a new stream socket to an address, waiting for nothing: a caller that waits on its own terms (a task of [`Poll.run`]) waits until the socket is writable and then asks `connected`. It answers the socket once connected or while a TCP connection is being made. It fails as `connect` does where that fails at once, and EAGAIN, the socket closed, where a unix listener's backlog is full on Linux: ask again with a new socket, since waiting for writable does not wait for room there.
 * ---@param address Address where to connect
 * ---@return Socket|nil socket the socket, connected or connecting, closed on exec and nonblocking, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(start, 1);

/*
 * --- Whether the connection `start` began on a socket, which has since polled writable, was made: true, or false and what refused it (SO_ERROR), ECONNREFUSED where nothing listens at the port. Asked before the socket is writable, it answers true for a connection still being made.
 * ---@param fd integer the connecting descriptor
 * ---@return boolean ok false once the connection failed
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(connected, 1);

/*
 * --- Two unix stream sockets connected to each other, each a `Socket` of its own.
 * ---@class Pair
 * ---@field first Socket one end
 * ---@field second Socket the other end
 */

/*
 * --- Makes two unix stream sockets connected to each other (socketpair), each closed on exec and nonblocking, and each sending as `send` does, EPIPE rather than SIGPIPE once the other has gone.
 * ---@return Pair|nil pair the two ends, or nil on failure
 * ---@return string error what went wrong, when pair is nil
 * ---@return integer errno the error number, when pair is nil
 */
COSMIC_SYSCALL(pair, 0);

/*
 * --- Sends what of `data` the socket takes now. A peer that has gone fails with EPIPE rather than raising SIGPIPE.
 * ---@param fd integer the connected descriptor
 * ---@param data string the bytes to send
 * ---@return integer|nil sent how many bytes were sent, from the first, or nil on failure: EAGAIN when the socket takes none now
 * ---@return string error what went wrong, when sent is nil
 * ---@return integer errno the error number, when sent is nil
 */
COSMIC_SYSCALL(send, 2);

/*
 * --- Where a TCP socket is bound: its host and port, the port the kernel chose for one listening at port 0.
 * ---@param fd integer the descriptor
 * ---@return Address|nil address its address, or nil on failure: EAFNOSUPPORT for a unix one
 * ---@return string error what went wrong, when address is nil
 * ---@return integer errno the error number, when address is nil
 */
COSMIC_SYSCALL(bound, 1);

/*
 * --- Where a connected socket's peer is: a TCP one's host and port, or a unix one's path as its socket was bound, "" for one bound nowhere (as every socket `connect`, `start` and `pair` make is) or in Linux's abstract namespace.
 * ---@param fd integer the connected descriptor
 * ---@return Address|nil address the peer's address, or nil on failure: ENOTCONN once the socket is not connected, as a TCP one reset by its peer may be
 * ---@return string error what went wrong, when address is nil
 * ---@return integer errno the error number, when address is nil
 */
COSMIC_SYSCALL(peer, 1);

/*
 * --- Ends one direction of a connection, or both: after "write" the peer reads the end of what was sent.
 * ---@param fd integer the connected descriptor
 * ---@param how string "read", "write" or "both"
 * ---@return boolean ok false on failure
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(shutdown, 2);

/*
 * --- Waits until a descriptor can be read (a listener: accepted), or written, or the time runs out. A signal an open `Child.guard` catches ends the wait, EINTR, within a tenth of a second; any other signal does not.
 * ---@param fd integer the descriptor
 * ---@param writable boolean true to wait until a write would not block, false until a read would not
 * ---@param timeout_ms integer how long to wait at most, -1 for no limit
 * ---@return boolean ok false on failure: ETIMEDOUT when the time ran out, EINTR when a guard caught a signal
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(wait, 3);

/*
 * --- The error numbers the calls above answer that a caller acts on, and the bound on a socket file's name, from this libc.
 * ---@class Constants
 * ---@field EAGAIN integer nothing to take or send now, or no room at a unix listener to `start` a connection: wait, then ask again
 * ---@field EINTR integer a guard caught a signal while `wait` waited
 * ---@field ETIMEDOUT integer `wait`'s time ran out
 * ---@field EADDRINUSE integer an address taken: a socket file or port another has
 * ---@field ECONNREFUSED integer nothing listens at an address
 * ---@field EINVAL integer a "tcp" host is no numeric address
 * ---@field ENAMETOOLONG integer a unix path's file name is past `SOCKET_NAME_MAX`, or its directory past the platform's bound on a path
 * ---@field SOCKET_NAME_MAX integer the most bytes a socket file's own name may take: 107 on Linux, 103 on macOS
 */
COSMIC_CONSTANT(EAGAIN)
COSMIC_CONSTANT(EINTR)
COSMIC_CONSTANT(ETIMEDOUT)
COSMIC_CONSTANT(EADDRINUSE)
COSMIC_CONSTANT(ECONNREFUSED)
COSMIC_CONSTANT(EINVAL)
COSMIC_CONSTANT(ENAMETOOLONG)
COSMIC_CONSTANT(SOCKET_NAME_MAX)
