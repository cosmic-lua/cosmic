/*
 * c-ares insists on a build-time configuration header (autotools'
 * `configure` or CMake normally generate one from ares_config.h.cmake);
 * this is the hand-written equivalent for the three targets this tree
 * cross-compiles for -- x86_64/aarch64 Linux (musl) and aarch64 macOS
 * -- all POSIX.1-2008-ish and all without c-ares's own threading
 * (CARES_THREADS is off: the core drives one poll loop itself, as
 * `cosmic.child` already does).
 *
 * Only what the pruned src/lib tree in vendor/cares actually reads is
 * defined, and nothing is ever defined to 0: c-ares tests these with
 * `#ifdef`, so a macro defined false would read as true. Windows,
 * thirdparty and thread-specific code paths are left undefined.
 */
#ifndef COSMIC_ARES_CONFIG_H
#define COSMIC_ARES_CONFIG_H

#define CARES_STATICLIB 1

/* Headers every target here has. */
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_RANDOM_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NET_IF_H 1
#define HAVE_NETDB_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_ARPA_NAMESER_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRINGS_H 1
#define HAVE_TIME_H 1
#define HAVE_LIMITS_H 1
#define HAVE_ERRNO_H 1
#define HAVE_ASSERT_H 1
#define HAVE_SIGNAL_H 1
#define HAVE_FCNTL_H 1
#define HAVE_POLL_H 1
#define HAVE_IFADDRS_H 1
#define HAVE_STRUCT_ADDRINFO 1
#define HAVE_STRUCT_IN6_ADDR 1
#define HAVE_STRUCT_SOCKADDR_IN6 1
#define HAVE_STRUCT_SOCKADDR_IN6_SIN6_SCOPE_ID 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_TIMEVAL 1
#define HAVE_AF_INET6 1
#define HAVE_PF_INET6 1

/* Functions every target here has: musl and Darwin's libc are both
 * POSIX.1-2008 for all of these. */
#define HAVE_RECV 1
#define HAVE_RECVFROM 1
#define HAVE_SEND 1
#define HAVE_SENDTO 1
#define HAVE_WRITEV 1
#define HAVE_FCNTL_O_NONBLOCK 1
#define HAVE_POLL 1
#define HAVE_PIPE 1
#define HAVE_GETENV 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_GETHOSTNAME 1
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_IF_INDEXTONAME 1
#define HAVE_STRDUP 1
#define HAVE_STRCASECMP 1
#define HAVE_STRNCASECMP 1
#define HAVE_STRNLEN 1
#define HAVE_STAT 1
#define HAVE_GETIFADDRS 1
#define HAVE_MEMMEM 1

/* Query timeouts and server metrics run on CLOCK_MONOTONIC, so a wall
 * clock stepped by NTP or by hand neither fires nor stalls them
 * (gettimeofday() is only the fallback if the call fails). macOS has
 * had clock_gettime() since 10.12, older than any release zig targets. */
#define HAVE_CLOCK_GETTIME 1
#define HAVE_CLOCK_GETTIME_MONOTONIC 1

/* recv/send/recvfrom signatures: plain POSIX on every target here, no
 * winsock `int`-as-`socklen_t` oddities to paper over. */
#define RECV_TYPE_ARG1 int
#define RECV_TYPE_ARG2 void *
#define RECV_TYPE_ARG3 size_t
#define RECV_TYPE_ARG4 int
#define RECV_TYPE_RETV ssize_t
#define SEND_TYPE_ARG1 int
#define SEND_TYPE_ARG2 const void *
#define SEND_TYPE_ARG3 size_t
#define SEND_TYPE_ARG4 int
#define SEND_TYPE_RETV ssize_t
#define RECVFROM_TYPE_ARG1 int
#define RECVFROM_TYPE_ARG2 void *
#define RECVFROM_TYPE_ARG2_IS_VOID 1
#define RECVFROM_TYPE_ARG3 size_t
#define RECVFROM_TYPE_ARG4 int
#define RECVFROM_TYPE_ARG5 struct sockaddr *
#define RECVFROM_TYPE_ARG6 ares_socklen_t *
#define RECVFROM_TYPE_RETV ssize_t
#define GETHOSTNAME_TYPE_ARG2 size_t

/* Randomness for query IDs, DNS cookies and server shuffling comes from
 * the OS -- arc4random_buf(3) on Darwin, getrandom(2) on Linux -- so
 * c-ares never falls back to its own rand()-seeded RC4 generator.
 *
 * SIGPIPE: on Linux each send() passes MSG_NOSIGNAL; on Darwin, which
 * has no such flag, c-ares sets SO_NOSIGPIPE on the socket instead
 * (keyed on the header's own SO_NOSIGPIPE, nothing to define here). */
#if defined(__APPLE__)
#define HAVE_AVAILABILITYMACROS_H 1
#define HAVE_ARC4RANDOM_BUF 1
#else
#define HAVE_GETRANDOM 1
#define HAVE_MSG_NOSIGNAL 1
#endif

/* No event backend (epoll, kqueue, poll, select): c-ares only uses one
 * inside its own event thread, which CARES_THREADS being off leaves
 * out, so the event/ sources are not built. Leaving every
 * HAVE_PTHREAD_* / CARES_THREADS macro undefined takes the library's
 * single-threaded code paths. */

#endif /* COSMIC_ARES_CONFIG_H */
