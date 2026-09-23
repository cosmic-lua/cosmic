/*
 * curl insists on a build-time configuration header (autotools'
 * `configure` or CMake normally generate `curl_config.h`); this is the
 * hand-written equivalent for the three targets this tree cross-
 * compiles for. HTTP and HTTPS only: every other protocol curl can
 * speak is left disabled here (most of their source files are already
 * gone from vendor/curl's PIN). DNS goes through c-ares (USE_ARES) on
 * every target -- one resolver, one behavior, rather than the system
 * resolver on some and c-ares on others -- and TLS through mbedtls
 * (USE_MBEDTLS), the library core/crypto.c already uses. No
 * zlib (no Content-Encoding decompression), no HTTP/2, no cookies.
 *
 * curl tests every CURL_DISABLE_* and USE_* macro with `#ifdef`, so
 * nothing here is ever defined to 0: a macro defined false would read
 * as true. Only macros curl's remaining sources read are defined.
 */
#ifndef COSMIC_CURL_CONFIG_H
#define COSMIC_CURL_CONFIG_H

/* Headers and functions every target here (musl and Darwin's libc,
 * both POSIX.1-2008) has. */
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_SYS_RESOURCE_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NET_IF_H 1
#define HAVE_NETDB_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_PWD_H 1
#define HAVE_UTIME_H 1
#define HAVE_FCNTL_H 1
#define HAVE_POLL_H 1
#define HAVE_SYS_POLL_H 1
#define HAVE_DIRENT_H 1
#define HAVE_IFADDRS_H 1
#define HAVE_STDATOMIC_H 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_TIMEVAL 1
#define HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID 1
#define HAVE_SA_FAMILY_T 1
#define HAVE_SUSECONDS_T 1

#define HAVE_SOCKET 1
#define HAVE_RECV 1
#define HAVE_SEND 1
#define HAVE_SOCKETPAIR 1
#define HAVE_PIPE 1
#define HAVE_POLL 1
#define HAVE_FCNTL 1
#define HAVE_FCNTL_O_NONBLOCK 1
#define HAVE_IOCTL_FIONBIO 1
#define HAVE_GETSOCKNAME 1
#define HAVE_GETPEERNAME 1
#define HAVE_GETIFADDRS 1
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_FREEADDRINFO 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETADDRINFO_THREADSAFE 1
#define HAVE_GETHOSTNAME 1
#define HAVE_GETTIMEOFDAY 1
/* Transfer timing (timeouts, low-speed checks, happy eyeballs) runs on
 * CLOCK_MONOTONIC, immune to wall-clock steps; macOS has had it since
 * 10.12, older than any release zig targets. */
#define HAVE_CLOCK_GETTIME_MONOTONIC 1
#define HAVE_GETEUID 1
#define HAVE_GETPPID 1
#define HAVE_SIGACTION 1
#define HAVE_SIGSETJMP 1
#define HAVE_BASENAME 1
#define HAVE_ALARM 1
#define HAVE_SETLOCALE 1
#define HAVE_GMTIME_R 1
#define HAVE_LOCALTIME_R 1
#define HAVE_STRERROR_R 1
#define HAVE_POSIX_STRERROR_R 1
#define HAVE_FSEEKO 1
#define HAVE_DECL_FSEEKO 1
#define HAVE_UTIME 1
#define HAVE_REALPATH 1

#define GETHOSTNAME_TYPE_ARG2 size_t

/* Sizes: LP64 on all three targets this tree ships (x86_64 and
 * aarch64 Linux, aarch64 macOS all use 8-byte long/size_t/off_t). */
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SIZE_T 8
#define SIZEOF_OFF_T 8
#define SIZEOF_CURL_OFF_T 8
#define SIZEOF_CURL_SOCKET_T 4
#define SIZEOF_TIME_T 8

#define CURL_OS "cosmic"

/* DNS through c-ares, TLS through mbedtls -- everything else disabled.
 * USE_ARES only says c-ares is linked; USE_RESOLV_ARES is what makes it
 * curl's resolver. Without it curl falls back to a blocking
 * getaddrinfo() on the calling thread, stalling every transfer in the
 * multi handle for as long as a lookup takes. No CA bundle path: the
 * trust store reaches curl only as CURLOPT_CAINFO_BLOB (core/http.c). */
#define USE_ARES 1
#define USE_RESOLV_ARES 1
#define USE_MBEDTLS 1
#define USE_IPV6 1

/* Every protocol but HTTP/HTTPS is already stripped out of
 * vendor/curl's PIN; these flags mainly turn off pieces of the files
 * that remain (auth mechanisms, cookies, altsvc, ...). */
#define CURL_DISABLE_FTP 1
#define CURL_DISABLE_DICT 1
#define CURL_DISABLE_GOPHER 1
#define CURL_DISABLE_IMAP 1
#define CURL_DISABLE_LDAP 1
#define CURL_DISABLE_LDAPS 1
#define CURL_DISABLE_MQTT 1
#define CURL_DISABLE_POP3 1
#define CURL_DISABLE_RTSP 1
#define CURL_DISABLE_SMTP 1
#define CURL_DISABLE_TELNET 1
#define CURL_DISABLE_TFTP 1
#define CURL_DISABLE_FILE 1

/* Decided: no cookies, no HTTP/2 (USE_NGHTTP2 simply never defined),
 * no compressed transfer-encoding (no zlib/brotli/zstd HAVE_* either).
 * Nor anything else core/http.c never asks for: HSTS and Alt-Svc
 * caches, DNS-over-HTTPS, WebSockets, MIME and form posts, .netrc,
 * binding to a local address or interface, the option-introspection
 * API (curl_easy_option_*), the progress meter, and SHA-512/256
 * (only Digest auth's RFC 7616 variant uses it; MD5 and SHA-256
 * Digest stay). CURLOPT_VERBOSE's strings stay on, as
 * does proxy support: HTTPS_PROXY is how most sandboxes reach out,
 * and the header API: core/http.c reads the final response's headers
 * with curl_easy_nextheader. */
#define CURL_DISABLE_COOKIES 1
#define CURL_DISABLE_ALTSVC 1
#define CURL_DISABLE_HSTS 1
#define CURL_DISABLE_WEBSOCKETS 1
#define CURL_DISABLE_DOH 1
#define CURL_DISABLE_NETRC 1
#define CURL_DISABLE_MIME 1
#define CURL_DISABLE_FORM_API 1
#define CURL_DISABLE_SHUFFLE_DNS 1
#define CURL_DISABLE_BINDLOCAL 1
#define CURL_DISABLE_GETOPTIONS 1
#define CURL_DISABLE_PROGRESS_METER 1
#define CURL_DISABLE_SHA512_256 1

/* No SASL/NTLM/Kerberos/GSSAPI vendored (their source files are
 * dropped from the PIN, and HAVE_GSSAPI is never defined, so
 * curl_gssapi.c and http_negotiate.c compile to nothing). Basic and
 * Digest auth stay on -- both are plain string/hash work, useful for
 * an HTTPS_PROXY that wants proxy-authorization, and vauth/digest.c is
 * still vendored. */
#define CURL_DISABLE_BEARER_AUTH 1
#define CURL_DISABLE_KERBEROS_AUTH 1
#define CURL_DISABLE_NEGOTIATE_AUTH 1
#define CURL_DISABLE_AWS 1
#define CURL_DISABLE_HTTPSIG 1

#endif /* COSMIC_CURL_CONFIG_H */
