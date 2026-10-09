/*
 * The socket table: the calls [`cosmic.net`] listens, accepts, connects,
 * sends and resolves names with, registered as the raw [`cosmic.internal.socket`]
 * module, which only that wrapper is handed. Every socket it makes is
 * closed on exec and nonblocking, so a wait is always `wait`'s, which
 * a deadline and a [`Signal.guard`] end; reading is [`cosmic.sys`]'s `read`.
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
 * ---@field kind string "unix", a socket file named by `path`, or "tcp", a TCP `port` of a `host`, or "udp", a datagram `port` of a `host`
 * ---@field path string the socket file's path, for "unix", never empty: of any length a path may have, but the file's own name, past its last "/", at most `SOCKET_NAME_MAX` bytes (107 on Linux, 103 on macOS), which a longer one fails with ENAMETOOLONG rather than being cut short. A path past that bound whole is reached from its directory
 * ---@field host string the host's numeric IPv4 or IPv6 address, for "tcp" and "udp": IPv4 is four decimal octets without leading zeroes, including an IPv6 dotted tail; a name is not looked up, nor an IPv6 scope read, and either fails with EINVAL, as a NUL in it does
 * ---@field port integer the port, for "tcp" and "udp", from 0 to 65535: 0 to listen at a port the kernel chooses, which the listener's `address` then names
 */

/*
 * --- A socket this table made, which owns its descriptor, and a unix listener's socket file: `close`, `<close>` or the collector closes the descriptor and then removes the file while its name is still the file the listener made, so one that has taken the name since is left alone. A unix listener holds a second descriptor for its life, of the file's directory, which it removes the file from wherever the process has moved to and whatever the length of its path; the directory cannot be unmounted while it is held.
 * ---@class Socket: userdata
 * ---@field fd fun(self:Socket):integer the descriptor, for the calls that take one; raises once the socket is closed
 * ---@field close fun(self:Socket):boolean,string,integer closes it: true, or false, what went wrong and the error number, the descriptor closed even so; true again once closed
 * ---@field __close fun(self:Socket) closes it as `close` does, its failure ignored
 */

/*
 * --- A complete datagram and the numeric address it came from.
 * ---@class Packet
 * ---@field data string the complete datagram, possibly empty
 * ---@field address Address the sender's "udp" host and port
 */

/*
 * --- Binds a UDP socket, nonblocking and closed on exec, to a numeric address. Port 0 takes one the kernel chooses. The returned Socket owns the descriptor before any further allocation.
 * ---@param address Address a "udp" address, with numeric IPv4 or IPv6 host
 * ---@return Socket|nil socket the bound socket, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(datagram, 1);

/*
 * --- Sends one complete UDP datagram, possibly empty, to a numeric address. No partial datagram is sent. Nothing is looked up.
 * ---@param fd integer the datagram descriptor
 * ---@param data string the datagram, at most 65535 bytes
 * ---@param address Address the destination's "udp" address
 * ---@return boolean ok false on failure: EAGAIN when nothing may be sent now
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(sendto, 3);

/*
 * --- Takes one complete UDP datagram, with its sender's numeric address. A datagram larger than max_bytes is consumed and refused with EMSGSIZE, never returned cut short. An allocation failure after receipt consumes it too.
 * ---@param fd integer the datagram descriptor
 * ---@param max_bytes integer the largest datagram to take, from 1 to 65535
 * ---@return Packet|nil packet the complete datagram, or nil on failure: EAGAIN when none is waiting
 * ---@return string error what went wrong, when packet is nil
 * ---@return integer errno the error number, when packet is nil
 */
COSMIC_SYSCALL(recvfrom, 2);

/*
 * --- Makes a stream socket listening at an address. A unix one is a new socket file, the socket's to remove: a path already there, a stale socket file included, fails with EADDRINUSE and is left alone, and one whose name another file has taken before it could be read back fails with EEXIST and is left to that file. A TCP one fails with EADDRINUSE on a port a listener holds; on Linux it takes one left in TIME_WAIT (SO_REUSEADDR), where macOS refuses it until TIME_WAIT ends. A unix path too long to bind whole is bound from its directory, and raises where the process cannot return to its working directory after.
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
 * --- Takes a copy of a listening TCP descriptor this process holds, as a socket of its own, closed on exec and nonblocking: one inherited, or received by `recvfds`. The original stays its holder's to close. Both share one open file description, so making the copy nonblocking makes the original so. It fails ENOTSOCK for a file, a pipe or any descriptor that is no socket, EBADF for one not open, EPROTOTYPE for a socket that is no stream, EINVAL for a stream socket that is not listening, and EAFNOSUPPORT for one listening on a unix socket file; the retained artifact descriptor itself raises (a copy of it, which is no retained descriptor, does not).
 * ---@param fd integer the listening descriptor
 * ---@return Socket|nil socket the copy, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(adopt, 1);

/*
 * --- Connects a new stream socket to an address. A unix one fails ECONNREFUSED where nothing listens at a socket file and ENOENT where there is no file; where its listener's backlog is full, it fails at once: EAGAIN on Linux, and ECONNREFUSED on macOS, which cannot tell a busy listener from none. A caller that would wait for room asks again. A TCP one waits for the connection to be made, and fails with what refused it: ECONNREFUSED where nothing listens at the port. A failure the connect itself answers, rather than the wait, is answered at once, EAGAIN included (Linux's where it has no local port or other resource for the connection). A wait fails ETIMEDOUT once the time runs out, and EINTR once an open `Signal.guard` catches a signal. A unix path too long to connect to whole is connected to from its directory, and raises where the process cannot return to its working directory after.
 * ---@param address Address where to connect
 * ---@param timeout_ms integer how long to wait at most, -1 for no limit
 * ---@return Socket|nil socket the connected socket, closed on exec and nonblocking, or nil on failure
 * ---@return string error what went wrong, when socket is nil
 * ---@return integer errno the error number, when socket is nil
 */
COSMIC_SYSCALL(connect, 2);

/*
 * --- Starts connecting a new stream socket to an address, waiting for nothing: a caller that waits on its own terms (a task of [`Poll.run`]) waits until the socket is writable and then asks `connected`. It answers the socket once connected or while a TCP connection is being made. It fails, or raises, as `connect` does where that fails at once, a unix listener whose backlog is full included.
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
 * --- Sends what of `data` the socket takes now, from byte `from` on, so a caller sending the rest after a partial send copies none of it. A peer that has gone fails with EPIPE rather than raising SIGPIPE.
 * ---@param fd integer the connected descriptor
 * ---@param data string the bytes to send
 * ---@param from? integer the first byte to send, from 1 (the default) to one past the last; any other raises
 * ---@return integer|nil sent how many bytes were sent, from `from`, or nil on failure: EAGAIN when the socket takes none now
 * ---@return string error what went wrong, when sent is nil
 * ---@return integer errno the error number, when sent is nil
 */
COSMIC_SYSCALL(send, 3);

/*
 * --- Sends a batch of descriptor copies over a Unix stream socket. The caller retains ownership of its descriptors. The channel carries only batches sent with this call: one NUL marker byte and SCM_RIGHTS ancillary data per batch. A retained artifact descriptor or an alias of it raises. A closed descriptor fails EBADF; a non-Unix channel fails EAFNOSUPPORT, and another socket kind fails EPROTOTYPE. A peer gone fails EPIPE without SIGPIPE.
 * ---@param fd integer the connected Unix stream descriptor
 * ---@param fds {integer} the descriptors to duplicate for the receiver, from 1 to 16
 * ---@return boolean ok false on failure: EAGAIN when the socket takes none now
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(sendfds, 2);

/*
 * --- Receives exactly one descriptor batch from a Unix stream socket. Every received descriptor is closed on exec, with its shared file status flags preserved, and held by a Socket owner even when it is a file rather than a socket. The caller must use only fd/close on such a holder; socket operations still require a socket descriptor. Missing, extra, truncated or malformed ancillary data fails EPROTO and closes every descriptor received. A retained artifact alias raises and is closed too. Nothing received is left open if an allocation fails. The sender retains its originals.
 * ---@param fd integer the connected Unix stream descriptor, reserved for descriptor batches
 * ---@param count integer exactly how many descriptors the batch must hold, from 1 to 16
 * ---@return {Socket}|nil descriptors the owned descriptors, or nil on failure: EAGAIN when nothing is waiting
 * ---@return string error what went wrong, when descriptors is nil
 * ---@return integer errno the error number, when descriptors is nil
 */
COSMIC_SYSCALL(recvfds, 2);

/*
 * --- The "tcp" host and port a connected stream socket is connected to. It fails ENOTCONN for a socket that is not connected (EINVAL on macOS for one its far side reset), EPROTOTYPE for one that is no stream, EAFNOSUPPORT for one that is not IPv4 or IPv6, and ENOTSOCK for what is no socket.
 * ---@param fd integer the connected descriptor
 * ---@return Address|nil address the peer's address, or nil on failure
 * ---@return string error what went wrong, when address is nil
 * ---@return integer errno the error number, when address is nil
 */
COSMIC_SYSCALL(peer, 1);

/*
 * --- Where a socket is bound: a TCP one's host and port, the port the kernel chose for one listening at port 0, or a unix one's path as it was bound -- its file's own name alone, for a path too long to bind whole -- "" for one bound nowhere.
 * ---@param fd integer the descriptor
 * ---@return Address|nil address its address, or nil on failure
 * ---@return string error what went wrong, when address is nil
 * ---@return integer errno the error number, when address is nil
 */
COSMIC_SYSCALL(bound, 1);

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
 * --- Waits until a descriptor can be read (a listener: accepted), or written, or the time runs out. A signal an open `Signal.guard` catches ends the wait, EINTR, within a tenth of a second; any other signal does not.
 * ---@param fd integer the descriptor
 * ---@param writable boolean true to wait until a write would not block, false until a read would not
 * ---@param timeout_ms integer how long to wait at most, -1 for no limit
 * ---@return boolean ok false on failure: ETIMEDOUT when the time ran out, EINTR when a guard caught a signal
 * ---@return string error what went wrong, when ok is false
 * ---@return integer errno the error number, when ok is false
 */
COSMIC_SYSCALL(wait, 3);

/*
 * --- One address a name resolves to.
 * ---@class Resolved
 * ---@field address string the address in numeric form: an IPv4 address in four decimal octets, an IPv6 one as `inet_ntop` writes it
 * ---@field family string "ipv4" or "ipv6"
 */

/*
 * --- One name server a lookup through a connector asks.
 * ---@class ThroughServer
 * ---@field host string its numeric IPv4 or IPv6 address
 * ---@field port integer its TCP port, 1 through 65535
 * ---@field index integer the 1-based index of the connector's table entry that reaches it at that port
 */

/*
 * --- A host name lookup in progress, which owns its c-ares channel and every socket c-ares holds for it: `close`, `<close>` or the collector ends the lookup and closes them, a query still pending among them. It never blocks by itself: the caller runs it with `step`, which reports the descriptors c-ares watches and when it next needs a call, and waits for them as it likes (a task of a poll loop, or `wait`).
 * ---@class Lookup: userdata
 * ---@field step fun(self:Lookup,fds:{integer}|nil,events:{integer}|nil):boolean,{integer},{integer},integer,{Want} hands c-ares what the caller found (`fds` and `events` pair, each event word poll's bits, a hang-up or an error reading as readable), runs its timers, and answers whether the lookup is done, the descriptors c-ares watches, the events it wants of each (poll's `POLLIN` and `POLLOUT` bits), how many milliseconds it may wait before it needs a call again (-1 for no timer, and once done), and the connects it has asked for since the last step, each told once. A descriptor of a connect waiting for its socket is not listed. Raises for fds and events that do not pair.
 * ---@field wait fun(self:Lookup,timeout_ms:integer):boolean,string,integer waits at most `timeout_ms` (-1 for no limit beyond a tenth of a second) for a descriptor c-ares watches or its timer, then hands it what happened: true, or false, what went wrong and the error number: EINTR where a `Signal.guard` caught a signal. It returns after one slice, done or not, and listing nothing; `step` reports where the lookup is
 * ---@field supply fun(self:Lookup,id:integer,fd:integer|nil,errno:integer|nil):boolean,string,integer answers the connect `id` that a step reported with the connected stream socket `fd`, which is copied in place of c-ares's stand-in (the caller closes its own), or with none, which leaves that server failing; `errno` ETIMEDOUT with none says the server went unanswered for want of time. True, or false, what went wrong and the error number: ENOENT for a connect c-ares has since given up on
 * ---@field result fun(self:Lookup):{Resolved}|nil,string,integer what the lookup answered once a step said it is done, as `lookup` lists the errors; a lookup not done is ETIMEDOUT
 * ---@field close fun(self:Lookup) ends the lookup; nothing once closed
 * ---@field __close fun(self:Lookup) ends it as `close` does
 */

/*
 * --- One connect a lookup through a connector has asked for.
 * ---@class Want
 * ---@field id integer names the connect to `supply`
 * ---@field index integer the 1-based index of the connector's table entry that reaches the server
 * ---@field port integer the server's TCP port
 */

/*
 * --- Starts a lookup of a host name with c-ares and answers it as a `Lookup`, to be run to the end by `step`. It answers every address the system's resolver returns, IPv4 and IPv6, in the order c-ares gives them, with none dropped and none filtered. The system's configuration is read as c-ares reads it: resolv.conf and hosts (and, on macOS, the system's DNS configuration), HOSTALIASES ignored. A numeric IPv4 or IPv6 address, written as a "tcp" address's host is, answers itself and asks no one; a name, and a literal that is not numeric in that grammar, is looked up. Hosts file entries answer as a server's records do. The answer is every address RECEIVED: one family's lookup failing while the other's succeeds answers the addresses of the one that succeeded, as c-ares does, and nothing says that one failed. A caller that checks addresses must connect only to the ones returned and never look the name up again. A name with fewer dots than the system's ndots may be tried under its search domains first (resolv.conf's `search`), so a single-label name may resolve under one; `servers`, `hosts` and `through` are for tests and trusted callers, never for values a sandboxed program chose. Nothing is cached between calls. With `through`, the lookup goes over TCP alone and reaches the network only through the connections its caller supplies: c-ares is refused every datagram socket, each connect to one of `through`'s servers is reported by `step` to be asked of a native connector (core/connector.c) by the entry's table index, and answered with `supply`. The servers are `through`'s, never the system's, each tried once with the whole time; the rest of the system's configuration is read as above. Linux only: elsewhere ENOSYS once the arguments are checked, as no connector runs there. The lookup's `timeout_ms` bounds c-ares's own clocks, and the caller ends the lookup at its deadline. A degenerate argument raises, a malformed server included; a name that is empty, over 254 bytes (253 and a trailing dot), holds a NUL or a "%" fails EINVAL, as a name may come from bytes the caller did not write.
 * ---@param name string the host name or numeric address
 * ---@param timeout_ms integer how long c-ares waits at most, from 0, -1 for no limit beyond its own retries and timeouts
 * ---@param servers? string name servers to ask in place of the system's, as c-ares writes them: `host[:port]`, an IPv6 host in brackets before its port, comma-separated; a malformed list fails EINVAL
 * ---@param hosts? string a hosts file to read in place of the system's
 * ---@param through? {ThroughServer} the name servers to ask through a connector, 1 through 128, in place of `servers`, which must then be nil
 * ---@return Lookup|nil lookup the lookup, or nil on failure
 * ---@return string error what went wrong, when lookup is nil
 * ---@return integer errno the error number, when lookup is nil: `RESOLVE_` codes and errnos as `Lookup.result` lists them, ENOMEM, or EINVAL for a name or server list c-ares refuses
 */
COSMIC_SYSCALL(lookup, 5);

/*
 * --- The name servers the system's configuration names, as c-ares reads it for `resolve` (resolv.conf; on macOS, the system's DNS configuration first), in its order: c-ares's own list, `host:port` comma-separated, an IPv6 host in brackets, a link-local one followed by `%` and its interface, and a server whose TCP port differs from its UDP one written as a `dns://` URI with a `tcpport` query. With none configured, c-ares's default, 127.0.0.1:53.
 * ---@param resolv_conf? string a resolv.conf to read in place of the system's, for tests
 * ---@return string|nil servers the list, or nil on failure
 * ---@return string error what went wrong, when servers is nil
 * ---@return integer errno the error number, when servers is nil: EACCES where the configuration could not be read, ENOMEM, or EINVAL for a path that holds a NUL
 */
COSMIC_SYSCALL(nameservers, 1);

/*
 * --- The error numbers the calls above answer that a caller acts on, and the bound on a socket file's name, from this libc.
 * ---@class Constants
 * ---@field EAGAIN integer nothing to take or send now, or, on Linux, a unix listener's backlog full to `connect` or `start`: wait, then ask again
 * ---@field EINTR integer a guard caught a signal while `wait` waited
 * ---@field ETIMEDOUT integer `wait`'s time ran out
 * ---@field EADDRINUSE integer an address taken: a socket file or port another has
 * ---@field ECONNREFUSED integer nothing listens at an address
 * ---@field EPROTO integer a descriptor batch was malformed, truncated, or held a different count
 * ---@field EPROTOTYPE integer a descriptor channel was not a stream socket
 * ---@field ENOTCONN integer `peer`: the socket is connected to nothing, as one its far side reset is on Linux (macOS answers EINVAL for that)
 * ---@field EINVAL integer a "tcp" host is no numeric address
 * ---@field ENAMETOOLONG integer a unix path's file name is past `SOCKET_NAME_MAX`, or its directory past the platform's bound on a path
 * ---@field SOCKET_NAME_MAX integer the most bytes a socket file's own name may take: 107 on Linux, 103 on macOS
 * ---@field CONNECTOR_HELLO integer what a native connector (core/connector.c) says first on its control stream, a big-endian word: "CNC" and its protocol's version
 * ---@field CONNECTOR_REQUEST_BYTES integer the length of a request to a native connector
 * ---@field CONNECTOR_FLIGHT integer the most connects a native connector makes at once
 * ---@field CONNECTOR_DENIED integer a public connector's reply for an address its lists refuse, past any errno
 * ---@field CONNECTOR_BUSY integer a connector's reply for a connect past `CONNECTOR_FLIGHT`, past any errno
 * ---@field RESOLVE_NOTFOUND integer `Lookup.result`: the name does not exist (NXDOMAIN), -2 on every OS
 * ---@field RESOLVE_NODATA integer `Lookup.result`: the name exists and has no IPv4 or IPv6 address, -5 on every OS
 * ---@field RESOLVE_FAILED integer `Lookup.result`: the servers answered with a failure or a malformed answer, -4 on every OS
 */
COSMIC_CONSTANT(EAGAIN)
COSMIC_CONSTANT(EINTR)
COSMIC_CONSTANT(ETIMEDOUT)
COSMIC_CONSTANT(EADDRINUSE)
COSMIC_CONSTANT(ECONNREFUSED)
COSMIC_CONSTANT(EPROTO)
COSMIC_CONSTANT(EPROTOTYPE)
COSMIC_CONSTANT(ENOTCONN)
COSMIC_CONSTANT(EINVAL)
COSMIC_CONSTANT(ENAMETOOLONG)
COSMIC_CONSTANT(SOCKET_NAME_MAX)
COSMIC_CONSTANT(CONNECTOR_HELLO)
COSMIC_CONSTANT(CONNECTOR_REQUEST_BYTES)
COSMIC_CONSTANT(CONNECTOR_FLIGHT)
COSMIC_CONSTANT(CONNECTOR_DENIED)
COSMIC_CONSTANT(CONNECTOR_BUSY)
COSMIC_CONSTANT(RESOLVE_NOTFOUND)
COSMIC_CONSTANT(RESOLVE_NODATA)
COSMIC_CONSTANT(RESOLVE_FAILED)
