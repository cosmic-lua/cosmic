/*
 * c-ares insists on a build-time configuration header (autotools'
 * `configure` or CMake normally generate one from ares_config.h.cmake);
 * this is the hand-written equivalent for the three targets this tree
 * cross-compiles for -- x86_64/aarch64 Linux (musl) and aarch64 macOS
 * -- all POSIX.1-2008-ish and all without c-ares's own threading
 * (CARES_THREADS is off: the core drives one poll loop itself, as
 * `cosmic.child` already does).
 *
 * Only what the pruned src/lib tree in vendor/cares actually reads
 * is defined; Windows, thirdparty, and thread-specific code paths are
 * left out entirely rather than defined false, since c-ares mostly
 * gates on `#ifdef` rather than `#if`.
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
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
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
#define HAVE_SOCKET 1
#define HAVE_CONNECT 1
#define HAVE_RECV 1
#define HAVE_RECVFROM 1
#define HAVE_SEND 1
#define HAVE_SENDTO 1
#define HAVE_SETSOCKOPT 1
#define HAVE_WRITEV 1
#define HAVE_IOCTL 1
#define HAVE_FCNTL 1
#define HAVE_FCNTL_O_NONBLOCK 1
#define HAVE_POLL 1
#define HAVE_PIPE 1
#define HAVE_GETENV 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_GETHOSTNAME 1
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_IF_INDEXTONAME 1
#define HAVE_INET_NET_PTON 1
#define HAVE_INET_NTOP 1
#define HAVE_INET_PTON 1
#define HAVE_STRDUP 1
#define HAVE_STRCASECMP 1
#define HAVE_STRNCASECMP 1
#define HAVE_STRNLEN 1
#define HAVE_STAT 1
#define HAVE_GETIFADDRS 1
#define HAVE_MEMMEM 1
#define HAVE_LONGLONG 1

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
#define RECVFROM_TYPE_ARG6_IS_VOID 0
#define RECVFROM_QUAL_ARG5
#define RECVFROM_TYPE_RETV ssize_t
#define GETHOSTNAME_TYPE_ARG2 size_t
#define GETNAMEINFO_QUAL_ARG1
#define GETNAMEINFO_TYPE_ARG1 struct sockaddr *
#define GETNAMEINFO_TYPE_ARG2 socklen_t
#define GETNAMEINFO_TYPE_ARG46 size_t
#define GETNAMEINFO_TYPE_ARG7 int

/* Randomness: same OS calls `crypto.c`'s external PSA RNG uses --
 * getrandom(2) on Linux, getentropy(2) on Darwin -- so c-ares's own
 * connection-ID and query-ID randomization never falls back to
 * rand(). */
#if defined(__APPLE__)
#define HAVE_AVAILABILITYMACROS_H 1
#else
#define HAVE_GETRANDOM 1
#endif

/* Event backend: epoll on Linux, kqueue on Darwin -- both faster than
 * the portable poll() fallback c-ares also carries, and neither pulls
 * in threads. */
#if defined(__APPLE__)
#define HAVE_KQUEUE 1
#define HAVE_SYS_EVENT_H 1
#else
#define HAVE_EPOLL 1
#define HAVE_SYS_EPOLL_H 1
#endif

/* c-ares's own thread-safety is off everywhere: the core drives one
 * poll loop itself, matching AGENTS.md's rule against dynamic loading
 * and matching how `cosmic.child` already multiplexes work without a
 * second thread. Leaving every HAVE_PTHREAD_* / CARES_THREADS macro
 * undefined takes the library's single-threaded code paths. */

#endif /* COSMIC_ARES_CONFIG_H */
