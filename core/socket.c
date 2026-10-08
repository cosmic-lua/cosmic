/*
 * The socket table core/socket.h declares.
 */

/* accept4, and SOCK_CLOEXEC with it, are extensions on Linux; macOS
 * has neither, and gets their effect through fcntl (`made`). */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#endif

#include <ares.h>

#include "check.h"
#include "errnos.h"
#include "fail.h"
#include "guard.h"
#include "memory.h"
#include "portable.h"
#include "store.h"
#include "lauxlib.h"
#include "process.h"
#include "socket.h"

/* The longest name a socket file's own name (past its path's last "/")
 * may be: sun_path's size, less the NUL the kernel is handed after it. */
#define SOCKET_NAME_MAX ((lua_Integer)(sizeof ((struct sockaddr_un *)0)->sun_path - 1))

/* Where a socket is. A unix path too long for sun_path is reached from
 * its directory: `directory` names it, and `address` holds the file's
 * own name; `directory` is "" where `address` holds the path whole. */
struct target {
  struct sockaddr_storage address;
  socklen_t length;
  char directory[PATH_MAX];
};

/* libc's numeric parsers differ on leading zeroes and scoped IPv6.
 * Require four decimal octets without leading zeroes, including the IPv4
 * tail of a mapped IPv6 address; IPv6 otherwise uses only hex and colons. */
bool cosmic_numeric_host (const char *host, size_t size) {
  bool ipv6 = false;
  const char *v4 = host;
  const char *end = host + size;
  for (const char *at = host; at < end; at++) {
    char c = *at;
    if (c == ':') {
      ipv6 = true;
      v4 = at + 1;
    } else if (c != '.' && !(c >= '0' && c <= '9') &&
               !(c >= 'a' && c <= 'f') && !(c >= 'A' && c <= 'F')) {
      return false;
    }
  }
  if (ipv6 && memchr(v4, '.', (size_t)(end - v4)) == NULL) {
    return memchr(host, '.', size) == NULL;
  }
  unsigned octets = 0;
  const char *at = v4;
  while (at < end) {
    const char *start = at;
    unsigned value = 0;
    while (at < end && *at >= '0' && *at <= '9') {
      if (at - start >= 3) return false;
      value = value * 10 + (unsigned)(*at++ - '0');
    }
    if (at == start || value > 255 || (at - start > 1 && *start == '0')) return false;
    octets++;
    if (at == end) return octets == 4;
    if (*at++ != '.' || at == end) return false;
  }
  return false;
}

/* The "tcp" address of the table at `index` in `*out`: 0, or EINVAL for
 * a host that is no numeric IPv4 or IPv6 address -- a name, a NUL in
 * it, an IPv6 scope -- which a caller may meet at runtime. A host that
 * is no string, or a port that is no integer from 0 to 65535, raises. */
static int tcp_address_of (lua_State *L, int index, struct target *out) {
  lua_getfield(L, index, "port");
  lua_Integer port = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
  if (port < 0 || port > 65535) {
    return luaL_argerror(L, index, "port must be a whole number from 0 to 65535");
  }
  lua_pop(L, 1);
  lua_getfield(L, index, "host");
  if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, index, "host must be a string");
  size_t size = 0;
  const char *host = lua_tolstring(L, -1, &size);
  struct sockaddr_in *v4 = (struct sockaddr_in *)&out->address;
  struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&out->address;
  int failure = 0;
  if (!cosmic_numeric_host(host, size)) {
    failure = EINVAL;
  } else if (strchr(host, ':') == NULL && inet_pton(AF_INET, host, &v4->sin_addr) == 1) {
    v4->sin_family = AF_INET;
    v4->sin_port = htons((uint16_t)port);
    out->length = (socklen_t)sizeof *v4;
  } else if (inet_pton(AF_INET6, host, &v6->sin6_addr) == 1) {
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons((uint16_t)port);
    out->length = (socklen_t)sizeof *v6;
  } else {
    failure = EINVAL;
  }
  lua_pop(L, 1);
  return failure;
}

/* Where the table at `index` says a socket is, in `*out`: 0, or the
 * errno a caller meets at runtime (a path holding a NUL, a directory
 * past PATH_MAX, a file's own name past SOCKET_NAME_MAX, a host that is
 * no numeric address). An address no correct program passes -- a kind
 * the table does not read, a path that is no string or is empty, a port
 * out of range -- raises. Nothing is left on the stack, and nothing of
 * it is kept but the copies in `*out`. */
static int address_of (lua_State *L, int index, struct target *out) {
  /* The argument errors here, and in tcp_address_of, are the raw binding's
   * last line of defence: cosmic.net checks an address first and raises
   * "net: address must be ...", so only a caller of the binding itself
   * meets them, in luaL_argerror's own form. That is decided, not a gap. */
  memset(&out->address, 0, sizeof out->address);
  out->length = 0;
  out->directory[0] = '\0';
  luaL_checktype(L, index, LUA_TTABLE);
  lua_getfield(L, index, "kind");
  const char *kind = lua_tostring(L, -1);
  bool tcp = kind != NULL && strcmp(kind, "tcp") == 0;
  if (!tcp && (kind == NULL || strcmp(kind, "unix") != 0)) {
    return luaL_argerror(L, index, "kind must be \"unix\" or \"tcp\"");
  }
  lua_pop(L, 1);
  if (tcp) return tcp_address_of(L, index, out);
  lua_getfield(L, index, "path");
  if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, index, "path must be a string");
  const char *path = cosmic_path(L, lua_gettop(L));
  size_t size = lua_rawlen(L, -1);
  if (size == 0) return luaL_argerror(L, index, "path is empty");
  struct sockaddr_un *unix_address = (struct sockaddr_un *)&out->address;
  const char *name = path;
  size_t name_size = size;
  int failure = 0;
  if (path == NULL) {
    failure = EINVAL;
  } else if (size > (size_t)SOCKET_NAME_MAX) {
    /* The kernel would take a path that fills sun_path with no NUL after
     * it, which no other program could name back; one past it is
     * reached from its directory instead. */
    size_t slash = size;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    name = path + slash;
    name_size = size - slash;
    size_t directory_size = slash > 1 ? slash - 1 : slash;
    if (slash == 0 || name_size > (size_t)SOCKET_NAME_MAX ||
        directory_size >= sizeof out->directory) {
      failure = ENAMETOOLONG;
    } else if (name_size == 0) {
      failure = EISDIR;
    } else {
      memcpy(out->directory, path, directory_size);
      out->directory[directory_size] = '\0';
    }
  }
  if (failure == 0) {
    unix_address->sun_family = AF_UNIX;
    memcpy(unix_address->sun_path, name, name_size);
    out->length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + name_size + 1);
  }
  lua_pop(L, 1);
  return failure;
}

/* A numeric UDP address, sharing TCP's numeric-only parser but never
 * accepting a stream or a Unix path. */
static int datagram_address_of (lua_State *L, int index, struct target *out) {
  memset(out, 0, sizeof *out);
  luaL_checktype(L, index, LUA_TTABLE);
  lua_getfield(L, index, "kind");
  size_t size = 0;
  const char *kind = lua_tolstring(L, -1, &size);
  luaL_argcheck(L, kind != NULL && size == 3 && memcmp(kind, "udp", 3) == 0,
    index, "kind must be \"udp\"");
  lua_pop(L, 1);
  return tcp_address_of(L, index, out);
}

/* A directory opened only to be searched: as a bind or an unlink in it
 * needs, with no permission to read it. */
#if defined(O_PATH)
#define DIRECTORY_FLAGS (O_PATH | O_DIRECTORY | O_CLOEXEC)
#elif defined(O_SEARCH)
#define DIRECTORY_FLAGS (O_SEARCH | O_DIRECTORY | O_CLOEXEC)
#else
/* TODO: a directory that can be searched but not read fails EACCES
 * here, where a bind by its whole path would not; open it to search
 * alone once the platform has O_PATH or O_SEARCH. */
#define DIRECTORY_FLAGS (O_RDONLY | O_DIRECTORY | O_CLOEXEC)
#endif

/* Binds `fd` to `target`, or connects it there, with the process in
 * `there`, the directory a long path is reached from, and back where it
 * was before this returns: 0, or why not. No Lua runs between, and the
 * Lua state is this process's one thread, so nothing else meets the
 * directory changed. Neither macOS nor Linux has bindat and connectat
 * (FreeBSD's) to name the directory by its descriptor instead. Where
 * the process cannot return -- its directory no longer searchable --
 * `*stranded` is why, and it is left in `there`; else 0. */
static int reach_from (int fd, int there, const struct target *target, bool binding, int *stranded) {
  const struct sockaddr *address = (const struct sockaddr *)&target->address;
  *stranded = 0;
  int here = open(".", DIRECTORY_FLAGS);
  if (here < 0) return errno;
  int failure = 0;
  if (fchdir(there) != 0) {
    failure = errno;
  } else {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    if (done != 0) failure = errno;
    if (fchdir(here) != 0) *stranded = errno;
  }
  close(here);
  return failure;
}

/* Binds `fd` to `target`, or connects it there: 0, or why not. A
 * target reached from its directory is reached as [`reach_from`] says,
 * `*stranded` with it. */
static int reach (int fd, const struct target *target, bool binding, int *stranded) {
  const struct sockaddr *address = (const struct sockaddr *)&target->address;
  *stranded = 0;
  if (target->directory[0] == '\0') {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    return done == 0 ? 0 : errno;
  }
  int there = open(target->directory, DIRECTORY_FLAGS);
  if (there < 0) return errno;
  int failure = reach_from(fd, there, target, binding, stranded);
  close(there);
  return failure;
}

/* Raises for a process [`reach_from`] left in another directory, which
 * no failure returned would tell its caller: every relative path it
 * names from then on would name another file. `why` is the errno of
 * the return. A macro, since no test can reach it: where "." is opened
 * to be searched (O_PATH, O_SEARCH), only a directory made unsearchable
 * between that open and the return strands the process. */
#define STRANDED_ERROR(L, why) \
  luaL_error((L), "the process could not return to its working directory: %s", \
    cosmic_errno_describe((why), NULL))

/* Makes `fd` what every socket of the table is: closed on exec,
 * nonblocking, and, where a send cannot say so itself, answering EPIPE
 * rather than raising SIGPIPE. 0, or why not. */
static int made (int fd) {
#if !defined(SOCK_CLOEXEC)
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) return errno;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return errno;
#endif
#if defined(SO_NOSIGPIPE)
  int on = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) != 0) return errno;
#endif
  (void)fd;
  return 0;
}

/* A new socket of `family` and `type`, made as `made` says, or -1 with
 * errno set. */
static int new_socket (int family, int type) {
#if defined(SOCK_CLOEXEC)
  int fd = socket(family, type | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
  int fd = socket(family, type, 0);
#endif
  if (fd < 0) return -1;
  int failure = made(fd);
  if (failure != 0) {
    close(fd);
    errno = failure;
    return -1;
  }
  return fd;
}

#define SOCKET_TYPE "cosmic.socket"

/* What a `Socket` owns: its descriptor, -1 once closed, and for a unix
 * listener a descriptor of its socket file's directory, -1 for none,
 * and the file's own `name` there. The file is the listener's to
 * remove once `made`, while the name is the file `device` and `inode`
 * identify. Named from its directory's descriptor, the file is removed
 * wherever the process has moved to since, and whatever the length of
 * its whole path. */
struct owned {
  int fd;
  int directory;
  bool made;
  dev_t device;
  ino_t inode;
  char name[];
};

/* Removes the file `owned` made while its name is still that file,
 * then closes the descriptor it holds, each once: 0, or the first
 * failure. A file gone already is no failure. The file is read back
 * before the descriptor closes, since the bound socket keeps its inode
 * allocated until then: once it is closed, a file made at the name
 * could be given the removed file's inode number. */
static int released (struct owned *owned) {
  int failure = 0;
  if (owned->directory >= 0) {
    struct stat now;
    if (!owned->made) {
      /* Nothing of the listener's to remove. */
    } else if (fstatat(owned->directory, owned->name, &now, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno != ENOENT) failure = errno;
    } else if (now.st_dev == owned->device && now.st_ino == owned->inode &&
               unlinkat(owned->directory, owned->name, 0) != 0) {
      failure = errno;
    }
    owned->made = false;
    close(owned->directory);
    owned->directory = -1;
  }
  if (owned->fd >= 0) {
    if (close(owned->fd) != 0 && failure == 0) failure = errno;
    owned->fd = -1;
  }
  return failure;
}

static int socket_fd (lua_State *L) {
  struct owned *owned = luaL_checkudata(L, 1, SOCKET_TYPE);
  luaL_argcheck(L, owned->fd >= 0, 1, "the socket is closed");
  lua_pushinteger(L, owned->fd);
  return 1;
}

static int socket_close (lua_State *L) {
  int failure = released(luaL_checkudata(L, 1, SOCKET_TYPE));
  if (failure != 0) return cosmic_fail_effect(L, failure);
  return cosmic_ok(L);
}

/* __close and __gc: what `close` does, with nowhere to say it failed. */
static int socket_release (lua_State *L) {
  released(luaL_checkudata(L, 1, SOCKET_TYPE));
  return 0;
}

/* Pushes a `Socket` that owns nothing yet, with `size` bytes for its
 * name, to be handed what the caller acquires next, so a raise from
 * then on leaves it to the collector. The push may raise; nothing is
 * held yet if so. The metatable is registered only once it is whole, as
 * core/guard.h's is. */
static struct owned *owner_push (lua_State *L, size_t size) {
  struct owned *owned = lua_newuserdatauv(L, sizeof *owned + size, 0);
  owned->fd = -1;
  owned->directory = -1;
  owned->made = false;
  if (luaL_getmetatable(L, SOCKET_TYPE) == LUA_TNIL) {
    lua_pop(L, 1);
    lua_createtable(L, 0, 6);
    lua_pushcfunction(L, socket_fd);
    lua_setfield(L, -2, "fd");
    lua_pushcfunction(L, socket_close);
    lua_setfield(L, -2, "close");
    lua_pushcfunction(L, socket_release);
    lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, socket_release);
    lua_setfield(L, -2, "__gc");
    lua_pushliteral(L, SOCKET_TYPE);
    lua_setfield(L, -2, "__name");
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, SOCKET_TYPE);
  }
  lua_setmetatable(L, -2);
  return owned;
}

/* Makes the `Socket` for a listener at the unix `target`, in `*out`:
 * it holds the directory its file is to be made in and the file's own
 * name there, both read from `target` alone, the bytes the bind is
 * handed. 0, with the socket pushed; or why not: EISDIR, nothing pushed,
 * for a path that ends in "/", as [`address_of`]'s long one fails; or
 * why its directory could not be opened, the socket pushed, holding
 * nothing, and `*out` untouched. */
static int unix_owner_push (lua_State *L, const struct target *target, struct owned **out) {
  const char *path = ((const struct sockaddr_un *)&target->address)->sun_path;
  char split[sizeof ((struct sockaddr_un *)0)->sun_path];
  const char *directory = target->directory;
  const char *name = path;
  if (directory[0] == '\0') {
    size_t size = strlen(path);
    size_t slash = size;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    size_t directory_size = slash > 1 ? slash - 1 : slash;
    memcpy(split, path, directory_size);
    split[directory_size] = '\0';
    directory = slash == 0 ? "." : split;
    name = path + slash;
  }
  if (name[0] == '\0') return EISDIR;
  size_t name_size = strlen(name);
  struct owned *owned = owner_push(L, name_size + 1);
  memcpy(owned->name, name, name_size + 1);
  owned->directory = open(directory, DIRECTORY_FLAGS);
  if (owned->directory < 0) return errno;
  *out = owned;
  return 0;
}

/* The deadline argument `arg`'s timeout in milliseconds makes, on the
 * monotonic clock, or -1 for a timeout of -1, no limit. */
static int64_t deadline_of (lua_State *L, int arg) {
  lua_Integer timeout = luaL_checkinteger(L, arg);
  luaL_argcheck(L, timeout >= -1 && timeout <= INT_MAX, arg, "timeout is out of range");
  return timeout < 0 ? -1 : cosmic_now_ms() + timeout;
}

/* Waits until `fd` has `events`, in slices: 0 once it has, ETIMEDOUT
 * once `deadline` has passed, EINTR once a guard has caught a signal,
 * or why poll failed. */
static int ready (int fd, short events, int64_t deadline) {
  for (;;) {
    if (cosmic_signal_caught()) return EINTR;
    int left = cosmic_wait_slice(deadline);
    struct pollfd watched = { fd, events, 0 };
    int found = poll(&watched, 1, left);
    if (found > 0) return 0;
    if (found < 0 && errno != EINTR) return errno;
    if (found == 0 && left == 0) return ETIMEDOUT;
  }
}

/* What ended the connection `fd` had in progress (SO_ERROR), once it
 * has ended: 0 once made. */
static int pending (int fd) {
  int failure = 0;
  socklen_t size = sizeof failure;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) != 0) return errno;
  return failure;
}

/* Waits for the connection `fd` has in progress to be made or refused,
 * in slices as `cosmic_paused` does: 0 once made, its failure (SO_ERROR) once
 * refused, ETIMEDOUT once `deadline` has passed, EINTR once a guard has
 * caught a signal. */
static int settled (int fd, int64_t deadline) {
  int failure = ready(fd, POLLOUT, deadline);
  if (failure != 0) return failure;
  return pending(fd);
}

COSMIC_SYSCALL(listen, 2) {
  struct target target;
  int failure = address_of(L, 1, &target);
  int backlog = cosmic_checkint(L, 2);
  luaL_argcheck(L, backlog >= 1, 2, "backlog must be at least 1");
  if (failure != 0) return cosmic_fail(L, failure);
  bool unix_socket = target.address.ss_family == AF_UNIX;
  struct owned *owned = NULL;
  if (!unix_socket) {
    owned = owner_push(L, 0);
  } else {
    failure = unix_owner_push(L, &target, &owned);
    if (failure != 0) return cosmic_fail(L, failure);
  }
  owned->fd = new_socket(target.address.ss_family, SOCK_STREAM);
  if (owned->fd < 0) {
    failure = errno;
    released(owned);
    return cosmic_fail(L, failure);
  }
#if defined(__linux__)
  /* A port left in TIME_WAIT by a listener before this one is taken
   * again, as every server does. Linux alone: on macOS the same option
   * also lets a bind to one address take a port another socket holds
   * on every address, and its traffic with it. */
  int on = 1;
  if (!unix_socket && setsockopt(owned->fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on) != 0) {
    failure = errno;
    released(owned);
    return cosmic_fail(L, failure);
  }
#endif
  /* A long path is bound from the directory the socket holds, the one
   * its file is then read back and removed from. A short one is bound
   * whole, so the kernel keeps its whole name for `ss`, `lsof` and a
   * peer's `getpeername`, which a name alone, bound from the
   * directory, would not give them. */
  int stranded = 0;
  failure = unix_socket && target.directory[0] != '\0'
    ? reach_from(owned->fd, owned->directory, &target, true, &stranded)
    : reach(owned->fd, &target, true, &stranded);
  /* The file the bind made, read back at once: a file of another kind
   * has taken its name already, and is not the socket's to remove. A
   * process that replaced it with a socket file in that moment would
   * have its file taken for this one's, and removed at close; that
   * stays, since only one that may remove this file from its directory
   * can put another in its place (none can in a sticky one, /tmp, but
   * its owner), and it could remove it any time. Binding at another name
   * and linking it into place would close the moment, but the kernel
   * keeps the name a socket was bound at: `ss`, `lsof` and a peer's
   * `getpeername` would name the other one. So does a short path whose
   * directory was replaced -- renamed away, a symlink on the way
   * retargeted -- between its open and the bind: the file is read back
   * from the directory opened, finds another file or none there, and the
   * bind's own file is left to whoever moved the directory, as it is
   * left where the read back fails at all: a file whose identity was
   * not read is not told from one that took its name, and removing it
   * could remove another's. A process the bind left in another
   * directory reads it back even so, from the directory the socket
   * holds, before it raises. */
  struct stat st;
  if (failure == 0 && unix_socket) {
    if (fstatat(owned->directory, owned->name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      failure = errno;
    } else if (!S_ISSOCK(st.st_mode)) {
      failure = EEXIST;
    } else {
      owned->made = true;
      owned->device = st.st_dev;
      owned->inode = st.st_ino;
    }
  }
  if (stranded != 0) {
    released(owned);
    return STRANDED_ERROR(L, stranded);
  }
  if (failure == 0 && listen(owned->fd, backlog) != 0) failure = errno;
  if (failure != 0) {
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

/* Whether accept's errno `e` is the failure of one pending connection
 * rather than of the listener, which accept(2) says to answer by taking
 * the next one: ECONNABORTED for a client that reset before it was
 * taken (macOS; Linux hands such a connection over), and on Linux a
 * pending connection's network error. */
#if defined(__linux__)
#define CONNECTION_FAILED(e) \
  ((e) == ECONNABORTED || (e) == EPROTO || (e) == ENETDOWN || \
   (e) == ENOPROTOOPT || (e) == EHOSTDOWN || (e) == ENONET || \
   (e) == EHOSTUNREACH || (e) == ENETUNREACH)
#else
#define CONNECTION_FAILED(e) ((e) == ECONNABORTED || (e) == EPROTO)
#endif

/* How many failed pending connections in a row accept takes before it
 * answers the last failure. It is bounded because the same errno can
 * also be the listener's own and persist: macOS answers ECONNABORTED
 * for every accept on a listener whose receive side is shut down. */
#define ACCEPT_RETRIES 16

COSMIC_SYSCALL(accept, 1) {
  int listener = cosmic_checkfd(L, 1);
  struct owned *owned = owner_push(L, 0);
  /* TODO: test a connection reset before it is taken, once cosmic.net
   * can set SO_LINGER to close with a reset; only macOS reports it. */
  int retries = 0;
  for (;;) {
#if defined(SOCK_CLOEXEC)
    owned->fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
#else
    owned->fd = accept(listener, NULL, NULL);
#endif
    if (owned->fd >= 0) break;
    if (errno == EINTR) continue;
    if (!CONNECTION_FAILED(errno) || ++retries > ACCEPT_RETRIES) break;
  }
  if (owned->fd < 0) return cosmic_fail(L, errno);
  int failure = made(owned->fd);
  if (failure != 0) {
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

/* 0 where the stream socket `fd` is listening, EINVAL where it is not, or
 * why that could not be told. Darwin's getsockopt answers ENOPROTOOPT for
 * SO_ACCEPTCONN, so its socket's own option word is read through libproc. */
static int listening_state (int fd) {
#if defined(__APPLE__)
  struct socket_fdinfo info;
  int got = proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, (int)sizeof info);
  if (got < (int)sizeof info) return got < 0 ? errno : EIO;
  return (info.psi.soi_options & SO_ACCEPTCONN) != 0 ? 0 : EINVAL;
#else
  int listening = 0;
  socklen_t size = sizeof listening;
  if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &size) != 0) return errno;
  return listening ? 0 : EINVAL;
#endif
}

/* 0 where `fd` is a listening TCP stream socket, or why it is not. */
static int adoptable (int fd) {
  int type = 0;
  socklen_t size = sizeof type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) != 0) return errno;
  if (type != SOCK_STREAM) return EPROTOTYPE;
  int state = listening_state(fd);
  if (state != 0) return state;
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return errno;
  if (address.ss_family != AF_INET && address.ss_family != AF_INET6) return EAFNOSUPPORT;
  return 0;
}

COSMIC_SYSCALL(adopt, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct owned *owned = owner_push(L, 0);
  /* The copy is what is checked, so a descriptor changed under the
   * caller after the copy is made cannot be what is adopted. */
  owned->fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  int failure = adoptable(owned->fd);
  if (failure == 0) {
    /* The copy shares the original's open file description, and `accept`
     * must not block a task: the flag is the description's, so the original
     * is nonblocking from here on. */
    int flags = fcntl(owned->fd, F_GETFL);
    if (flags < 0 || fcntl(owned->fd, F_SETFL, flags | O_NONBLOCK) != 0) failure = errno;
  }
  if (failure != 0) {
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

COSMIC_SYSCALL(connect, 2) {
  struct target target;
  int failure = address_of(L, 1, &target);
  int64_t deadline = deadline_of(L, 2);
  if (failure != 0) return cosmic_fail(L, failure);
  struct owned *owned = owner_push(L, 0);
  owned->fd = new_socket(target.address.ss_family, SOCK_STREAM);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  /* A unix socket connects or fails at once -- where its listener's
   * backlog is full, EAGAIN on Linux and ECONNREFUSED on macOS; a TCP
   * one answers EINPROGRESS and connects over time, which `settled`
   * waits out. */
  int stranded = 0;
  failure = reach(owned->fd, &target, false, &stranded);
  if (stranded != 0) {
    released(owned);
    return STRANDED_ERROR(L, stranded);
  }
  if (failure == EINPROGRESS) failure = settled(owned->fd, deadline);
  if (failure != 0) {
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

COSMIC_SYSCALL(start, 1) {
  struct target target;
  int failure = address_of(L, 1, &target);
  if (failure != 0) return cosmic_fail(L, failure);
  struct owned *owned = owner_push(L, 0);
  owned->fd = new_socket(target.address.ss_family, SOCK_STREAM);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  int stranded = 0;
  failure = reach(owned->fd, &target, false, &stranded);
  if (stranded != 0) {
    released(owned);
    return STRANDED_ERROR(L, stranded);
  }
  if (failure != 0 && failure != EINPROGRESS) {
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

COSMIC_SYSCALL(connected, 1) {
  int failure = pending(cosmic_checkfd(L, 1));
  if (failure != 0) return cosmic_fail_effect(L, failure);
  return cosmic_ok(L);
}

/* Pushes the "tcp" address `address` holds: 1, or what `cosmic_fail`
 * pushes for one of another family, EAFNOSUPPORT. */
static int tcp_pushed (lua_State *L, const struct sockaddr_storage *address,
                       const char *kind) {
  char host[INET6_ADDRSTRLEN];
  int port = 0;
  const char *named = NULL;
  if (address->ss_family == AF_INET) {
    const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
    named = inet_ntop(AF_INET, &v4->sin_addr, host, sizeof host);
    port = ntohs(v4->sin_port);
  } else if (address->ss_family == AF_INET6) {
    const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
    named = inet_ntop(AF_INET6, &v6->sin6_addr, host, sizeof host);
    port = ntohs(v6->sin6_port);
  } else {
    return cosmic_fail(L, EAFNOSUPPORT);
  }
  if (named == NULL) return cosmic_fail(L, errno);
  lua_createtable(L, 0, 3);
  lua_pushstring(L, kind);
  lua_setfield(L, -2, "kind");
  lua_pushstring(L, host);
  lua_setfield(L, -2, "host");
  lua_pushinteger(L, port);
  lua_setfield(L, -2, "port");
  return 1;
}

/* Pushes the address `length` bytes of `address` hold, as getsockname
 * or getpeername answered them: 1. Any but a TCP one is a unix one: one
 * bound nowhere may answer no path, and no family either, and a path's
 * length may count its NUL. */
static int address_pushed (lua_State *L, const struct sockaddr_storage *address,
                           socklen_t length) {
  if (address->ss_family == AF_INET || address->ss_family == AF_INET6) {
    return tcp_pushed(L, address, "tcp");
  }
  const struct sockaddr_un *unix_address = (const struct sockaddr_un *)address;
  size_t offset = offsetof(struct sockaddr_un, sun_path);
  size_t size = 0;
  if (length > offset) {
    size_t most = (size_t)length - offset;
    if (most > sizeof unix_address->sun_path) most = sizeof unix_address->sun_path;
    size = strnlen(unix_address->sun_path, most);
  }
  lua_createtable(L, 0, 2);
  lua_pushliteral(L, "unix");
  lua_setfield(L, -2, "kind");
  lua_pushlstring(L, unix_address->sun_path, size);
  lua_setfield(L, -2, "path");
  return 1;
}

COSMIC_SYSCALL(bound, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return cosmic_fail(L, errno);
  if (address.ss_family == AF_INET || address.ss_family == AF_INET6) {
    int type = 0;
    socklen_t size = sizeof type;
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) != 0) return cosmic_fail(L, errno);
    return tcp_pushed(L, &address, type == SOCK_DGRAM ? "udp" : "tcp");
  }
  return address_pushed(L, &address, length);
}

COSMIC_SYSCALL(peer, 1) {
  int fd = cosmic_checkfd(L, 1);
  int type = 0;
  socklen_t size = sizeof type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) != 0) return cosmic_fail(L, errno);
  if (type != SOCK_STREAM) return cosmic_fail(L, EPROTOTYPE);
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getpeername(fd, (struct sockaddr *)&address, &length) != 0) return cosmic_fail(L, errno);
  return tcp_pushed(L, &address, "tcp");
}

COSMIC_SYSCALL(datagram, 1) {
  struct target target;
  int failure = datagram_address_of(L, 1, &target);
  if (failure != 0) return cosmic_fail(L, failure);
  struct owned *owned = owner_push(L, 0);
  owned->fd = new_socket(target.address.ss_family, SOCK_DGRAM);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  if (bind(owned->fd, (const struct sockaddr *)&target.address, target.length) != 0) {
    failure = errno;
    released(owned);
    return cosmic_fail(L, failure);
  }
  return 1;
}

/* Refuses a stream descriptor: its byte stream must never be read or
 * written as if it carried datagram boundaries. */
static int datagram_type (int fd) {
  int type = 0;
  socklen_t size = sizeof type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) != 0) return errno;
  return type == SOCK_DGRAM ? 0 : EPROTOTYPE;
}

COSMIC_SYSCALL(sendto, 3) {
  int fd = cosmic_checkfd(L, 1);
  size_t size = 0;
  const char *data = luaL_checklstring(L, 2, &size);
  luaL_argcheck(L, size <= 65535, 2, "datagram must be at most 65535 bytes");
  struct target target;
  int failure = datagram_address_of(L, 3, &target);
  if (failure == 0) failure = datagram_type(fd);
  if (failure != 0) return cosmic_fail_effect(L, failure);
  ssize_t sent;
  do {
    sent = sendto(fd, data, size, 0, (const struct sockaddr *)&target.address, target.length);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0) return cosmic_fail_effect(L, errno);
  if ((size_t)sent != size) return cosmic_fail_effect(L, EIO);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(recvfrom, 2) {
  int fd = cosmic_checkfd(L, 1);
  int maximum = cosmic_checkint(L, 2);
  luaL_argcheck(L, maximum >= 1 && maximum <= 65535, 2, "max_bytes must be from 1 to 65535");
  int failure = datagram_type(fd);
  if (failure != 0) return cosmic_fail(L, failure);
  /* A fixed bounded stack buffer holds no heap resource across the Lua
   * allocations that build the answer. MSG_TRUNC refuses cut packets. */
  char data[65535];
  struct sockaddr_storage address;
  memset(&address, 0, sizeof address);
  struct iovec part = { data, (size_t)maximum };
  struct msghdr message;
  memset(&message, 0, sizeof message);
  message.msg_name = &address;
  message.msg_namelen = sizeof address;
  message.msg_iov = &part;
  message.msg_iovlen = 1;
  ssize_t received;
  do {
    received = recvmsg(fd, &message, 0);
  } while (received < 0 && errno == EINTR);
  if (received < 0) return cosmic_fail(L, errno);
  if ((message.msg_flags & MSG_TRUNC) != 0 || received > maximum) return cosmic_fail(L, EMSGSIZE);
  lua_createtable(L, 0, 2);
  lua_pushlstring(L, data, (size_t)received);
  lua_setfield(L, -2, "data");
  if (tcp_pushed(L, &address, "udp") != 1) return 3;
  lua_setfield(L, -2, "address");
  return 1;
}

COSMIC_SYSCALL(send, 3) {
  int fd = cosmic_checkfd(L, 1);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
  lua_Integer from = luaL_optinteger(L, 3, 1);
  luaL_argcheck(L, from >= 1 && (lua_Unsigned)from - 1 <= size, 3, "out of range");
  data += from - 1;
  size -= (size_t)(from - 1);
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0;
#endif
  ssize_t sent;
  do {
    sent = send(fd, data, size, flags);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, (lua_Integer)sent);
  return 1;
}

/* Descriptor batches use one marker byte, not a stream framing protocol:
 * callers keep this channel solely for descriptor passing. The bound
 * limits both native ancillary storage and the owners prepared before
 * recvmsg can hand descriptors to the process. */
#define RIGHTS_MAX 16
#if defined(__APPLE__)
/* XNU installs every right before copyout_control truncates the control
 * buffer, so a short receive buffer leaks unseen descriptors. Receive
 * the complete kernel bound, not the caller's expected count. XNU's
 * sockargs limits MT_CONTROL to MCLBYTES (2048); unp_internalize requires
 * exactly one SCM_RIGHTS header spanning that mbuf. Its UIPC_MAX_CMSG_FD
 * is 512 (also statically checked against MCLBYTES / sizeof(int)).
 * sbappendcontrol_internal keeps each send in its own record and
 * soreceive_ctl externalizes only the first record. Neither RLIMIT nor
 * a stream of control-only sends can raise the per-receive bound.
 * See apple-oss-distributions/xnu bsd/kern/uipc_{syscalls,usrreq,socket,
 * socket2}.c and bsd/arm/param.h: xnu-11417.101.15 (macOS 15),
 * xnu-7195.50.7.100.1 (macOS 11), and current XNU. */
#define RIGHTS_RECEIVE_MAX 512
#else
/* Linux closes omitted rights itself; keep truncation exercised there. */
#define RIGHTS_RECEIVE_MAX RIGHTS_MAX
#endif

/* Refuses the runtime's retained artifact even under another descriptor
 * number: SCM_RIGHTS duplicates a descriptor, so checking only the
 * retained number would hand every carried module past a sealed store.
 * Runtime failures, an already closed descriptor included, keep errno's
 * value shape rather than raising. */
static int rights_checked (lua_State *L, int arg, int fd) {
  cosmic_argfd(L, arg, fd);
  struct stat sent;
  if (fstat(fd, &sent) != 0) return errno;
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact != NULL) {
    struct stat retained;
    if (fstat(artifact->fd, &retained) != 0) return errno;
    luaL_argcheck(L, sent.st_dev != retained.st_dev || sent.st_ino != retained.st_ino,
                  arg, "is an alias of this program's retained artifact descriptor");
  }
  return 0;
}

/* An ancillary channel must be a Unix stream socket. Passing rights
 * on other transports is never silently answered as an ordinary send. */
static int rights_channel (int fd) {
  struct sockaddr_storage address = {0};
  socklen_t length = sizeof address;
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return errno;
  if (address.ss_family != AF_UNIX) return EAFNOSUPPORT;
  int kind = 0;
  length = sizeof kind;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) != 0) return errno;
  return kind == SOCK_STREAM ? 0 : EPROTOTYPE;
}

COSMIC_SYSCALL(sendfds, 2) {
  int fd = cosmic_checkfd(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  size_t count = lua_rawlen(L, 2);
  luaL_argcheck(L, count >= 1 && count <= RIGHTS_MAX, 2, "expected 1 to 16 descriptors");
  int descriptors[RIGHTS_MAX];
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i + 1);
    descriptors[i] = cosmic_checkfd(L, -1);
    int failure = rights_checked(L, 2, descriptors[i]);
    lua_pop(L, 1);
    if (failure != 0) return cosmic_fail_effect(L, failure);
  }
  int failure = rights_channel(fd);
  if (failure != 0) return cosmic_fail_effect(L, failure);
  union {
    struct cmsghdr alignment;
    unsigned char bytes[CMSG_SPACE(RIGHTS_MAX * sizeof(int))];
  } control;
  memset(&control, 0, sizeof control);
  char marker = '\0';
  struct iovec payload = { &marker, 1 };
  struct msghdr message;
  memset(&message, 0, sizeof message);
  message.msg_iov = &payload;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = (socklen_t)CMSG_SPACE(count * sizeof(int));
  struct cmsghdr *rights = CMSG_FIRSTHDR(&message);
  rights->cmsg_level = SOL_SOCKET;
  rights->cmsg_type = SCM_RIGHTS;
  rights->cmsg_len = (socklen_t)CMSG_LEN(count * sizeof(int));
  memcpy(CMSG_DATA(rights), descriptors, count * sizeof(int));
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  /* Received or inherited channels need not have been made here, so
   * macOS cannot rely on stream_socket having suppressed SIGPIPE. */
  int on = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) != 0)
    return cosmic_fail_effect(L, errno);
  const int flags = 0;
#endif
  ssize_t sent;
  do {
    sent = sendmsg(fd, &message, flags);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0) return cosmic_fail_effect(L, errno);
  if (sent != 1) return cosmic_fail_effect(L, EPROTO);
  return cosmic_ok(L);
}

/* The guard owns every descriptor recvmsg installs, including extras a
 * rejected frame delivered, until each has been handed to its owner.
 * The block is native heap rather than a C local: a close refused for
 * lack of memory may leave its release to the collector. */
struct received_rights {
  size_t count;
  int descriptors[RIGHTS_RECEIVE_MAX];
};

static void rights_release (void *resource) {
  struct received_rights *received = resource;
  for (size_t i = 0; i < received->count; i++) {
    if (received->descriptors[i] >= 0) close(received->descriptors[i]);
  }
  cosmic_free(received);
}

COSMIC_SYSCALL(recvfds, 2) {
  int fd = cosmic_checkfd(L, 1);
  int count = cosmic_checkint(L, 2);
  luaL_argcheck(L, count >= 1 && count <= RIGHTS_MAX, 2, "expected 1 to 16 descriptors");
  int failure = rights_channel(fd);
  if (failure != 0) return cosmic_fail(L, failure);
  lua_createtable(L, count, 0);
  int answer = lua_gettop(L);
  struct owned *owners[RIGHTS_MAX];
  for (int i = 0; i < count; i++) {
    owners[i] = owner_push(L, 0);
    lua_rawseti(L, answer, i + 1);
  }
  struct cosmic_guard *guard = cosmic_guard_push(L, rights_release);
  struct received_rights *received = cosmic_calloc(1, sizeof *received);
  if (received == NULL) return cosmic_fail(L, ENOMEM);
  guard->resource = received;
  union {
    struct cmsghdr alignment;
    unsigned char bytes[CMSG_SPACE(RIGHTS_RECEIVE_MAX * sizeof(int))];
  } control;
  memset(&control, 0, sizeof control);
  char marker = '\1';
  struct iovec payload = { &marker, 1 };
  struct msghdr message;
  memset(&message, 0, sizeof message);
  message.msg_iov = &payload;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
#if defined(__APPLE__)
  const socklen_t capacity = sizeof control.bytes;
#else
  const socklen_t capacity = (socklen_t)CMSG_SPACE((size_t)count * sizeof(int));
#endif
  message.msg_controllen = capacity;
#if defined(MSG_CMSG_CLOEXEC)
  const int flags = MSG_CMSG_CLOEXEC;
#else
  const int flags = 0;
#endif
  ssize_t got;
  do {
    got = recvmsg(fd, &message, flags);
  } while (got < 0 && errno == EINTR);
  if (got < 0) return cosmic_fail(L, errno);
  bool malformed = message.msg_controllen > capacity;
  if (malformed) message.msg_controllen = capacity;
  size_t offset = 0;
  while ((size_t)message.msg_controllen - offset >= sizeof(struct cmsghdr)) {
    struct cmsghdr *rights = (struct cmsghdr *)(control.bytes + offset);
    size_t remaining = (size_t)message.msg_controllen - offset;
    if (rights->cmsg_len < CMSG_LEN(0) || remaining < CMSG_LEN(0)) {
      malformed = true;
      break;
    }
    size_t bytes = rights->cmsg_len - CMSG_LEN(0);
    if (bytes > remaining - CMSG_LEN(0)) {
      /* Darwin can keep the full cmsg_len when truncating the payload.
       * The delivered prefix still owns descriptors: guard those before
       * rejecting the frame rather than abandon them with the header. */
      bytes = remaining - CMSG_LEN(0);
      malformed = true;
    }
    size_t next = CMSG_SPACE(bytes);
    if (rights->cmsg_level != SOL_SOCKET || rights->cmsg_type != SCM_RIGHTS) {
      malformed = true;
      if (next > remaining) break;
      offset += next;
      continue;
    }
    if (bytes % sizeof(int) != 0) malformed = true;
    for (size_t i = 0; i < bytes / sizeof(int); i++) {
      int descriptor;
      memcpy(&descriptor, CMSG_DATA(rights) + i * sizeof(int), sizeof descriptor);
      if (received->count < RIGHTS_RECEIVE_MAX) {
        received->descriptors[received->count++] = descriptor;
      } else {
        close(descriptor);
        malformed = true;
      }
    }
    if (next > remaining) break;
    offset += next;
  }
  if (got != 1 || marker != '\0' || malformed ||
      (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0 ||
      received->count != (size_t)count) return cosmic_fail(L, EPROTO);
  for (int i = 0; i < count; i++) {
    int descriptor = received->descriptors[i];
    failure = rights_checked(L, 1, descriptor);
    if (failure != 0) return cosmic_fail(L, failure);
    int old = fcntl(descriptor, F_GETFD);
    if (old < 0 || fcntl(descriptor, F_SETFD, old | FD_CLOEXEC) != 0)
      return cosmic_fail(L, errno);
  }
  for (int i = 0; i < count; i++) {
    owners[i]->fd = received->descriptors[i];
    received->descriptors[i] = -1;
  }
  lua_pushvalue(L, answer);
  return 1;
}

COSMIC_SYSCALL(shutdown, 2) {
  int fd = cosmic_checkfd(L, 1);
  static const char *const names[] = {"read", "write", "both", NULL};
  static const int hows[] = {SHUT_RD, SHUT_WR, SHUT_RDWR};
  int how = hows[luaL_checkoption(L, 2, NULL, names)];
  if (shutdown(fd, how) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(wait, 3) {
  int fd = cosmic_checkfd(L, 1);
  int writable = lua_toboolean(L, 2);
  int64_t deadline = deadline_of(L, 3);
  int failure = ready(fd, writable ? POLLOUT : POLLIN, deadline);
  if (failure != 0) return cosmic_fail_effect(L, failure);
  return cosmic_ok(L);
}

/* What `resolve` answers where the resolver, not the system, refused:
 * negative, so none is an errno's number, and fixed, so every OS reads
 * the same (they are glibc's EAI_NONAME, EAI_FAIL and EAI_NODATA). */
#define RESOLVE_NOTFOUND (-2)
#define RESOLVE_FAILED (-4)
#define RESOLVE_NODATA (-5)

/* The longest a host name may be, with its trailing dot (RFC 1035). */
#define RESOLVE_NAME_MAX 254

/* Sockets c-ares may have open at once that a wait watches: a UDP and a
 * TCP socket for each of a few servers. One past it is not watched, and
 * its query ends by the retry timer or the call's deadline instead. */
#define RESOLVE_WATCHED_MAX 64

struct watched_socket {
  ares_socket_t fd;
  short events;
};

/* The most name servers a lookup through a connector asks: no more than
 * a connector's table holds. */
#define RESOLVE_SERVERS_MAX 128
/* "[" an IPv6 address "]:" a port and a comma, with room to spare. */
#define RESOLVE_SERVER_TEXT (INET6_ADDRSTRLEN + 10)

/* One name server a lookup through a connector asks: its address and
 * port, as c-ares hands them to connect, and the 1-based index of the
 * connector's table entry that reaches it. */
struct resolve_server {
  struct sockaddr_storage address;
  uint32_t index;
};

/* The connects a lookup through a connector has asked c-ares for and not
 * yet been handed a socket for, at most. One past it is refused. */
#define RESOLVE_PARKED_MAX 8

/* A connect c-ares asked for that is waiting for its socket: `id` names
 * it to the caller (0 for a free slot), `fd` is the stand-in c-ares
 * holds, `server` the server it is for, and `asked` whether the caller
 * has been told of it. */
struct parked_connect {
  uint32_t id;
  ares_socket_t fd;
  const struct resolve_server *server;
  bool asked;
};

/* One lookup: the channel, what it answered and the sockets it has
 * open. A `Lookup` userdata owns it, so a raise while the answer is
 * built leaves it to the collector; the channel goes first at release,
 * as destroying it ends a query still pending, which calls `resolved`
 * once more, with ARES_EDESTRUCTION, while this struct is still whole. */
struct resolution {
  ares_channel_t *channel;
  struct ares_addrinfo *found;
  int status;
  bool done;
  size_t watching;
  struct watched_socket sockets[RESOLVE_WATCHED_MAX];
  /* A lookup through a connector (`lookup`'s `through`): c-ares's sockets
   * are the caller's to supply, one for each connect it asks. */
  bool through;
  /* The call's deadline, on the monotonic clock in milliseconds, -1 for
   * none: past it a connect is refused unasked. */
  int64_t deadline;
  /* Whether a server went unanswered for want of time: the caller
   * supplied that its connect timed out, or the deadline had passed when
   * c-ares asked for another connection, which is then refused. */
  bool late;
  uint32_t last_id;
  struct parked_connect parked[RESOLVE_PARKED_MAX];
  size_t servers;
  struct resolve_server *server;
  /* A numeric address answers itself: its family (0 for a name) and
   * bytes. */
  int literal_family;
  unsigned char literal[sizeof(struct in6_addr)];
};

static void resolution_release (void *resource) {
  struct resolution *resolution = resource;
  if (resolution->channel != NULL) ares_destroy(resolution->channel);
  if (resolution->found != NULL) ares_freeaddrinfo(resolution->found);
  free(resolution->server);
  free(resolution);
}

static void resolved (void *arg, int status, int timeouts, struct ares_addrinfo *found) {
  struct resolution *resolution = arg;
  (void)timeouts;
  if (resolution->done) {
    ares_freeaddrinfo(found);
    return;
  }
  resolution->done = true;
  resolution->status = status;
  resolution->found = found;
}

/* c-ares's report that it opened, wants or closed a socket, kept as the
 * poll set the wait reads. */
static void socket_state (void *arg, ares_socket_t fd, int readable, int writable) {
  struct resolution *resolution = arg;
  short events = (short)((readable ? POLLIN : 0) | (writable ? POLLOUT : 0));
  for (size_t at = 0; at < resolution->watching; at++) {
    if (resolution->sockets[at].fd != fd) continue;
    if (events != 0) {
      resolution->sockets[at].events = events;
    } else {
      resolution->sockets[at] = resolution->sockets[--resolution->watching];
    }
    return;
  }
  if (events != 0 && resolution->watching < RESOLVE_WATCHED_MAX) {
    resolution->sockets[resolution->watching].fd = fd;
    resolution->sockets[resolution->watching].events = events;
    resolution->watching++;
  }
}

/* The parked connect whose stand-in is `fd`, or NULL. */
static struct parked_connect *parked_for_fd (struct resolution *resolution, ares_socket_t fd) {
  for (size_t i = 0; i < RESOLVE_PARKED_MAX; i++) {
    if (resolution->parked[i].id != 0 && resolution->parked[i].fd == fd) return &resolution->parked[i];
  }
  return NULL;
}

/* Hands c-ares what happened to `fd`: it is readable, writable, or
 * neither (ARES_SOCKET_BAD), which runs its timers. */
static void resolution_process (struct resolution *resolution, ares_socket_t fd, bool readable, bool writable) {
  ares_process_fd(resolution->channel, readable ? fd : ARES_SOCKET_BAD, writable ? fd : ARES_SOCKET_BAD);
}

/* The failure a lookup c-ares ended with `status` answers. */
static int resolve_failed (lua_State *L, int status) {
  int code;
  const char *why;
  switch (status) {
    case ARES_ENOTFOUND:
    code = RESOLVE_NOTFOUND;
    why = "name not found";
    break;
    case ARES_ENODATA:
    code = RESOLVE_NODATA;
    why = "name has no address";
    break;
    case ARES_ETIMEOUT:
    return cosmic_fail(L, ETIMEDOUT);
    case ARES_ECONNREFUSED:
    return cosmic_fail(L, ECONNREFUSED);
    case ARES_ENOMEM:
    return cosmic_fail(L, ENOMEM);
    case ARES_EBADNAME:
    case ARES_EBADQUERY:
    case ARES_EBADFAMILY:
    return cosmic_fail(L, EINVAL);
    default:
    code = RESOLVE_FAILED;
    why = "name server failed";
    break;
  }
  lua_pushnil(L);
  lua_pushstring(L, why);
  lua_pushinteger(L, code);
  return 3;
}

/* Appends `{ address = ..., family = ... }` for the raw address at
 * `address` of `family` to the table on top, as its element `index`. */
static void resolved_pushed (lua_State *L, int family, const void *address, lua_Integer index) {
  char text[INET6_ADDRSTRLEN];
  if (inet_ntop(family, address, text, sizeof text) == NULL) text[0] = '\0';
  lua_createtable(L, 0, 2);
  lua_pushstring(L, text);
  lua_setfield(L, -2, "address");
  lua_pushstring(L, family == AF_INET ? "ipv4" : "ipv6");
  lua_setfield(L, -2, "family");
  lua_rawseti(L, -2, index);
}

/* Whether `name` is a numeric address as a "tcp" address's host is,
 * written to `out` as raw bytes of the `*family` it names. */
static bool numeric_literal (const char *name, size_t size, int *family, unsigned char *out) {
  if (!cosmic_numeric_host(name, size)) return false;
  if (strchr(name, ':') == NULL && inet_pton(AF_INET, name, out) == 1) {
    *family = AF_INET;
    return true;
  }
  if (inet_pton(AF_INET6, name, out) == 1) {
    *family = AF_INET6;
    return true;
  }
  return false;
}

/* Whether `name`, `size` bytes, is one `lookup` refuses before asking:
 * empty, past RESOLVE_NAME_MAX, or holding a NUL or a "%". */
static bool resolve_refused (const char *name, size_t size) {
  return size == 0 || size > RESOLVE_NAME_MAX || memchr(name, '\0', size) != NULL ||
    memchr(name, '%', size) != NULL;
}

#if defined(__linux__)
/* A lookup through a connector reaches the network only through sockets
 * its caller supplies: c-ares's sockets are made by these functions,
 * which refuse every datagram socket, and a connect to one of the
 * lookup's servers is parked, answered "in progress", until the caller
 * (who asks the connector, as cosmic.net does) supplies the connected
 * socket, which then takes the stand-in's place, or that none came,
 * which leaves the stand-in a dead end that c-ares takes for the server
 * failing. */

/* A stream socket's stand-in until a connect is supplied: the read end
 * of a pipe whose write end is closed, so it is a descriptor of its own,
 * not a socket of the host's network. c-ares neither reads nor writes it
 * before it connects. A pipe reads as hung up, and c-ares's `recv` on it
 * fails ENOTSOCK, which it takes for the server's connection failing. */
static ares_socket_t through_socket (int domain, int type, int protocol, void *data) {
  (void)data;
  (void)protocol;
  if (type != SOCK_STREAM || (domain != AF_INET && domain != AF_INET6)) {
    errno = EPROTONOSUPPORT;
    return ARES_SOCKET_BAD;
  }
  int ends[2];
  if (pipe2(ends, O_CLOEXEC | O_NONBLOCK) != 0) return ARES_SOCKET_BAD;
  close(ends[1]);
  return ends[0];
}

static int through_close (ares_socket_t sock, void *data) {
  int closed = close(sock);
  struct parked_connect *parked = parked_for_fd(data, sock);
  if (parked != NULL) parked->id = 0;
  return closed;
}

/* No option is set on the connector's sockets: ENOSYS, which c-ares
 * takes for a choice, and so makes no TCP Fast Open attempt. */
static int through_setsockopt (ares_socket_t sock, ares_socket_opt_t opt, const void *value,
                               ares_socklen_t size, void *data) {
  (void)sock; (void)opt; (void)value; (void)size; (void)data;
  errno = ENOSYS;
  return -1;
}

/* Whether `a` and `b` are one IPv4 or IPv6 address and port. */
static bool through_same (const struct sockaddr_storage *a, const struct sockaddr_storage *b) {
  if (a->ss_family != b->ss_family) return false;
  if (a->ss_family == AF_INET) {
    const struct sockaddr_in *x = (const struct sockaddr_in *)a, *y = (const struct sockaddr_in *)b;
    return x->sin_port == y->sin_port && x->sin_addr.s_addr == y->sin_addr.s_addr;
  }
  if (a->ss_family == AF_INET6) {
    const struct sockaddr_in6 *x = (const struct sockaddr_in6 *)a, *y = (const struct sockaddr_in6 *)b;
    return x->sin6_port == y->sin6_port && memcmp(&x->sin6_addr, &y->sin6_addr, sizeof x->sin6_addr) == 0;
  }
  return false;
}

/* Connects `sock` to `address`, one of the lookup's servers, by parking
 * it for the caller to supply. Every refusal is ECONNREFUSED, which
 * c-ares takes for this server failing: a "wait" or "interrupted" from
 * here would have it poll or call again on the stand-in. */
static int through_connect (ares_socket_t sock, const struct sockaddr *address, ares_socklen_t length,
                            unsigned int flags, void *data) {
  struct resolution *resolution = data;
  (void)flags;
  struct sockaddr_storage asked;
  memset(&asked, 0, sizeof asked);
  const struct resolve_server *server = NULL;
  if (length > 0 && (size_t)length <= sizeof asked) {
    memcpy(&asked, address, (size_t)length);
    for (size_t i = 0; i < resolution->servers && server == NULL; i++) {
      if (through_same(&asked, &resolution->server[i].address)) server = &resolution->server[i];
    }
  }
  /* Past the deadline nothing more is asked. */
  if (resolution->deadline >= 0 && cosmic_now_ms() >= resolution->deadline) {
    resolution->late = true;
    server = NULL;
  }
  struct parked_connect *slot = NULL;
  for (size_t i = 0; i < RESOLVE_PARKED_MAX && slot == NULL; i++) {
    if (resolution->parked[i].id == 0) slot = &resolution->parked[i];
  }
  if (server == NULL || slot == NULL) {
    errno = ECONNREFUSED;
    return -1;
  }
  if (++resolution->last_id == 0) resolution->last_id = 1;
  slot->id = resolution->last_id;
  slot->fd = sock;
  slot->server = server;
  slot->asked = false;
  errno = EINPROGRESS;
  return -1;
}

static ares_ssize_t through_recvfrom (ares_socket_t sock, void *buffer, size_t length, int flags,
                                      struct sockaddr *address, ares_socklen_t *address_length, void *data) {
  (void)data;
  if (address != NULL || address_length != NULL) {
    errno = EINVAL;
    return -1;
  }
  /* On a stand-in this fails ENOTSOCK: the server failing. */
  return recv(sock, buffer, length, flags);
}

static ares_ssize_t through_sendto (ares_socket_t sock, const void *buffer, size_t length, int flags,
                                    const struct sockaddr *address, ares_socklen_t address_length,
                                    void *data) {
  (void)data;
  if (address != NULL || address_length != 0) {
    errno = EINVAL;
    return -1;
  }
  return send(sock, buffer, length, flags | MSG_NOSIGNAL);
}

static const struct ares_socket_functions_ex through_functions = {
  .version = 1,
  .flags = ARES_SOCKFUNC_FLAG_NONBLOCKING,
  .asocket = through_socket,
  .aclose = through_close,
  .asetsockopt = through_setsockopt,
  .aconnect = through_connect,
  .arecvfrom = through_recvfrom,
  .asendto = through_sendto,
};
#endif

#define LOOKUP_TYPE "cosmic.socket.lookup"

/* What a `Lookup` userdata holds: its lookup, NULL once closed. */
struct lookup {
  struct resolution *resolution;
};

static struct resolution *lookup_open (lua_State *L) {
  struct lookup *lookup = luaL_checkudata(L, 1, LOOKUP_TYPE);
  luaL_argcheck(L, lookup->resolution != NULL, 1, "the lookup is closed");
  return lookup->resolution;
}

/* The integer at element `index` of the table at `table`, which must
 * fit an int. */
static int lookup_element (lua_State *L, int table, lua_Integer index) {
  lua_rawgeti(L, table, index);
  int value = cosmic_checkint(L, lua_gettop(L));
  lua_pop(L, 1);
  return value;
}

/* Hands c-ares the readiness the caller found: `fds` and `events` are
 * parallel lists of descriptors and what each had (poll's bits). A
 * parked connect's stand-in is not c-ares's to read yet and is skipped. */
static void lookup_ready (lua_State *L, struct resolution *resolution, int fds, int events) {
  lua_Integer count = (lua_Integer)lua_rawlen(L, fds);
  luaL_argcheck(L, (lua_Integer)lua_rawlen(L, events) == count, events, "events must pair with fds");
  for (lua_Integer i = 1; i <= count; i++) {
    int fd = lookup_element(L, fds, i);
    int had = lookup_element(L, events, i);
    if (parked_for_fd(resolution, fd) != NULL) continue;
    bool readable = (had & (POLLIN | POLLHUP | POLLERR)) != 0;
    bool writable = (had & POLLOUT) != 0;
    if (readable || writable) resolution_process(resolution, fd, readable, writable);
  }
}

/* How long c-ares may sleep before its timers need a call, in
 * milliseconds rounded up, -1 for no timer. */
static int lookup_timer (struct resolution *resolution) {
  struct timeval retry;
  struct timeval *soonest = ares_timeout(resolution->channel, NULL, &retry);
  if (soonest == NULL) return -1;
  int64_t ms = (int64_t)soonest->tv_sec * 1000 + (soonest->tv_usec + 999) / 1000;
  return ms > INT_MAX ? INT_MAX : (int)ms;
}

static int lookup_step (lua_State *L) {
  struct resolution *resolution = lookup_open(L);
  if (!lua_isnoneornil(L, 2) || !lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    luaL_checktype(L, 3, LUA_TTABLE);
    lookup_ready(L, resolution, 2, 3);
  }
  resolution_process(resolution, ARES_SOCKET_BAD, false, false);
  lua_settop(L, 1);
  lua_pushboolean(L, resolution->done);
  lua_createtable(L, (int)resolution->watching, 0);
  lua_createtable(L, (int)resolution->watching, 0);
  lua_Integer watched = 0;
  for (size_t at = 0; at < resolution->watching; at++) {
    if (parked_for_fd(resolution, resolution->sockets[at].fd) != NULL) continue;
    lua_pushinteger(L, resolution->sockets[at].fd);
    lua_rawseti(L, -3, ++watched);
    lua_pushinteger(L, resolution->sockets[at].events);
    lua_rawseti(L, -2, watched);
  }
  lua_pushinteger(L, resolution->done ? -1 : lookup_timer(resolution));
  lua_createtable(L, 1, 0);
  lua_Integer wants = 0;
  for (size_t i = 0; i < RESOLVE_PARKED_MAX; i++) {
    struct parked_connect *parked = &resolution->parked[i];
    if (parked->id == 0 || parked->asked) continue;
    const struct sockaddr_storage *address = &parked->server->address;
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, parked->id);
    lua_setfield(L, -2, "id");
    lua_pushinteger(L, parked->server->index);
    lua_setfield(L, -2, "index");
    lua_pushinteger(L, ntohs(address->ss_family == AF_INET ? ((const struct sockaddr_in *)address)->sin_port :
      ((const struct sockaddr_in6 *)address)->sin6_port));
    lua_setfield(L, -2, "port");
    lua_rawseti(L, -2, ++wants);
    /* Told only once it is in the table, so a refused allocation above
     * loses no connect. */
    parked->asked = true;
  }
  return 5;
}

static int lookup_wait (lua_State *L) {
  struct resolution *resolution = lookup_open(L);
  int timeout = cosmic_checkint(L, 2);
  luaL_argcheck(L, timeout >= -1, 2, "timeout is out of range");
  int64_t deadline = timeout < 0 ? -1 : cosmic_now_ms() + timeout;
  if (resolution->done) return cosmic_ok(L);
  if (cosmic_signal_caught()) return cosmic_fail_effect(L, EINTR);
  int left = cosmic_wait_slice(deadline);
  int timer = lookup_timer(resolution);
  if (timer >= 0 && timer < left) left = timer;
  struct pollfd polled[RESOLVE_WATCHED_MAX];
  size_t count = 0;
  for (size_t at = 0; at < resolution->watching; at++) {
    if (parked_for_fd(resolution, resolution->sockets[at].fd) != NULL) continue;
    polled[count].fd = resolution->sockets[at].fd;
    polled[count].events = resolution->sockets[at].events;
    polled[count].revents = 0;
    count++;
  }
  int found = poll(polled, (nfds_t)count, left);
  if (found < 0 && errno != EINTR) return cosmic_fail_effect(L, errno);
  if (found <= 0) {
    resolution_process(resolution, ARES_SOCKET_BAD, false, false);
    return cosmic_ok(L);
  }
  for (size_t at = 0; at < count; at++) {
    if (polled[at].revents == 0) continue;
    bool readable = (polled[at].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    bool writable = (polled[at].revents & POLLOUT) != 0;
    resolution_process(resolution, polled[at].fd, readable, writable);
  }
  return cosmic_ok(L);
}

static int lookup_supply (lua_State *L) {
  struct resolution *resolution = lookup_open(L);
  int id = cosmic_checkint(L, 2);
  int failure = cosmic_optint(L, 4, 0);
  int fd = -1;
  if (!lua_isnoneornil(L, 3)) {
    fd = cosmic_checkfd(L, 3);
    luaL_argcheck(L, fd >= 0, 3, "descriptor is negative");
  }
  struct parked_connect *parked = NULL;
  for (size_t i = 0; i < RESOLVE_PARKED_MAX && id > 0; i++) {
    if (resolution->parked[i].id == (uint32_t)id) parked = &resolution->parked[i];
  }
  if (parked == NULL) return cosmic_fail_effect(L, ENOENT);
  if (fd < 0 && failure == ETIMEDOUT) resolution->late = true;
  int refused = 0;
  if (fd >= 0) {
    /* c-ares reads and writes the socket from `step`, which must never
     * block: a blocking one is refused, the stand-in left to fail. */
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) {
      refused = errno;
    } else if ((flags & O_NONBLOCK) == 0) {
      refused = EINVAL;
#if defined(__linux__)
    } else if (dup3(fd, parked->fd, O_CLOEXEC) < 0) {
      refused = errno;
    }
#else
  } else if (dup2(fd, parked->fd) < 0 || fcntl(parked->fd, F_SETFD, FD_CLOEXEC) != 0) {
    refused = errno;
  }
#endif
}
parked->id = 0;
if (refused != 0) return cosmic_fail_effect (L, refused);
return cosmic_ok (L);
}

static int lookup_result (lua_State *L) {
  struct resolution *resolution = lookup_open(L);
  if (resolution->literal_family != 0) {
    lua_createtable(L, 1, 0);
    resolved_pushed(L, resolution->literal_family, resolution->literal, 1);
    return 1;
  }
  if (!resolution->done) return cosmic_fail (L, ETIMEDOUT);
  /* Where no server answered, one left for want of time makes the lookup
   * a timeout; a server's answer (no such name, a failure) still stands. */
  if (resolution->late && (resolution->status == ARES_ECONNREFUSED || resolution->status == ARES_ETIMEOUT)) {
    return cosmic_fail(L, ETIMEDOUT);
  }
  if (resolution->status != ARES_SUCCESS) return resolve_failed (L, resolution->status);
  lua_createtable(L, 4, 0);
  lua_Integer count = 0;
  struct ares_addrinfo_node *node = resolution->found == NULL ? NULL : resolution->found->nodes;
  for (; node != NULL; node = node->ai_next) {
    if (node->ai_family == AF_INET) {
      resolved_pushed(L, AF_INET, &((struct sockaddr_in *)node->ai_addr)->sin_addr, ++count);
    } else if (node->ai_family == AF_INET6) {
      resolved_pushed(L, AF_INET6, &((struct sockaddr_in6 *)node->ai_addr)->sin6_addr, ++count);
    }
  }
  if (count == 0) {
    lua_pop(L, 1);
    return resolve_failed(L, ARES_ENODATA);
  }
  return 1;
}

static void lookup_released (struct lookup *lookup) {
  struct resolution *resolution = lookup->resolution;
  lookup->resolution = NULL;
  if (resolution != NULL) resolution_release(resolution);
}

/* close, __close and __gc: ends the lookup, once. */
static int lookup_release (lua_State *L) {
  lookup_released(luaL_checkudata(L, 1, LOOKUP_TYPE));
  return 0;
}

/* Pushes a `Lookup` that owns nothing yet, to be handed what the caller
 * acquires next, so a raise from then on leaves it to the collector. The
 * push may raise; nothing is held yet if so. The metatable is registered
 * only once it is whole. */
static struct lookup *lookup_push (lua_State *L) {
  struct lookup *lookup = lua_newuserdatauv(L, sizeof *lookup, 0);
  lookup->resolution = NULL;
  if (luaL_getmetatable(L, LOOKUP_TYPE) == LUA_TNIL) {
    lua_pop(L, 1);
    lua_createtable(L, 0, 10);
    static const luaL_Reg methods[] = {
      { "step", lookup_step }, { "wait", lookup_wait }, { "supply", lookup_supply },
      { "result", lookup_result }, { "close", lookup_release }, { "__close", lookup_release },
      { "__gc", lookup_release }, { NULL, NULL },
    };
    luaL_setfuncs(L, methods, 0);
    lua_pushliteral(L, LOOKUP_TYPE);
    lua_setfield(L, -2, "__name");
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, LOOKUP_TYPE);
  }
  lua_setmetatable(L, -2);
  return lookup;
}

/* Reads the server on top of the stack, an entry of argument `arg`'s
 * list, into `out`, raising for one that is malformed, and appends it to
 * `listed` (`room` bytes, NULL for none) as c-ares takes a server list:
 * how many bytes it appended. */
static size_t through_server_read (lua_State *L, int arg, bool first, struct resolve_server *out,
                                   char *listed, size_t room) {
  int item = lua_gettop(L);
  if (!lua_istable(L, item)) luaL_argerror(L, arg, "a server must be a table");
  memset(out, 0, sizeof *out);
  lua_getfield(L, item, "index");
  lua_Integer index = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : 0;
  if (index < 1 || index > RESOLVE_SERVERS_MAX) luaL_argerror(L, arg, "a server's index must be 1 through 128");
  lua_getfield(L, item, "port");
  lua_Integer port = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : 0;
  if (port < 1 || port > 65535) luaL_argerror(L, arg, "a server's port must be 1 through 65535");
  lua_getfield(L, item, "host");
  size_t length = 0;
  const char *host = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : NULL;
  struct sockaddr_in *v4 = (struct sockaddr_in *)&out->address;
  struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&out->address;
  bool numeric = host != NULL && strlen(host) == length && cosmic_numeric_host(host, length);
  int written = 0;
  if (numeric && strchr(host, ':') == NULL && inet_pton(AF_INET, host, &v4->sin_addr) == 1) {
    v4->sin_family = AF_INET;
    v4->sin_port = htons((uint16_t)port);
    if (listed != NULL) written = snprintf(listed, room, "%s%s:%u", first ? "" : ",", host, (unsigned)port);
  } else if (numeric && inet_pton(AF_INET6, host, &v6->sin6_addr) == 1) {
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons((uint16_t)port);
    if (listed != NULL) written = snprintf(listed, room, "%s[%s]:%u", first ? "" : ",", host, (unsigned)port);
  } else {
    luaL_argerror(L, arg, "a server's host must be a numeric IPv4 or IPv6 address");
  }
  out->index = (uint32_t)index;
  lua_pop(L, 3);
  return written < 0 ? 0 : (size_t)written;
}


/* Starts the lookup `resolution` holds, which the caller has filled for
 * a lookup through a connector or not: the channel and the query.
 * `servers` is c-ares's server list, NULL for the system's. 0 or the
 * failure the lookup ends with, as [`resolve_failed`] reads it: a c-ares
 * status, or an errno negated. */
static int lookup_begin (const char *name, int timeout, const char *servers, const char *hosts,
                         struct resolution *resolution) {
  /* c-ares needs no library initialization off Windows
   * (ares_library_initialized answers success). */
  struct ares_options options;
  memset(&options, 0, sizeof options);
  int mask = ARES_OPT_FLAGS | ARES_OPT_TRIES | ARES_OPT_SOCK_STATE_CB;
  options.flags = ARES_FLAG_NOALIASES;
  if (resolution->through) options.flags |= ARES_FLAG_USEVC;
  options.tries = 2;
  options.sock_state_cb = socket_state;
  options.sock_state_cb_data = resolution;
  if (timeout >= 0) {
    mask |= ARES_OPT_TIMEOUTMS;
    options.timeout = timeout < 2 ? 1 : timeout / 2;
  }
  /* Through a connector each server is tried once, with the whole time:
   * a connect waits while its per-try clock, started before it, runs on,
   * so a second try or a shorter one would expire the query a slow
   * server's successor could still answer. */
  if (resolution->through) {
    options.tries = 1;
    if (timeout >= 0) options.timeout = timeout < 1 ? 1 : timeout;
  }
  if (hosts != NULL) {
    mask |= ARES_OPT_HOSTS_FILE;
    options.hosts_path = (char *)hosts;
  }
  int status = ares_init_options(&resolution->channel, &options, mask);
  if (status != ARES_SUCCESS) {
    resolution->channel = NULL;
    return status;
  }
#if defined(__linux__)
  if (resolution->through) {
    status = (int)ares_set_socket_functions_ex(resolution->channel, &through_functions, resolution);
    if (status != ARES_SUCCESS) return status;
  }
#endif
  if (servers != NULL && ares_set_servers_ports_csv(resolution->channel, servers) != ARES_SUCCESS) return -EINVAL;
  struct ares_addrinfo_hints hints;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = ARES_AI_NOSORT;
  ares_getaddrinfo(resolution->channel, name, NULL, &hints, resolved, resolution);
  return 0;
}

/* TODO: report which family's lookup failed, so a caller that must see
 * every address can fail closed: ares_getaddrinfo folds one family's
 * failure into the other's success, so this waits on asking for A and
 * AAAA separately (ares_search or ares_send, with the answers parsed
 * here) or on c-ares reporting it.
 * TODO: exercise the system's own configuration on macOS (resolv.conf
 * through dnsinfo): no CI leg runs a lookup that reads it, as the tests
 * name their servers and hosts file, so ares_sysconfig_mac.c's path is
 * untested there until a leg can resolve a name through the system. */
COSMIC_SYSCALL(lookup, 5) {
  size_t size = 0;
  const char *name = luaL_checklstring(L, 1, &size);
  int timeout = cosmic_checkint(L, 2);
  luaL_argcheck(L, timeout >= -1, 2, "timeout is out of range");
  const char *servers = lua_isnoneornil(L, 3) ? NULL : luaL_checkstring(L, 3);
  /* Read before anything is pushed: past the arguments, the top of the
   * stack is the lookup's. */
  bool hosts_given = !lua_isnoneornil(L, 4);
  const char *hosts = hosts_given ? cosmic_path(L, 4) : NULL;
  bool through = !lua_isnoneornil(L, 5);
  size_t count = 0;
  if (through) {
    luaL_checktype(L, 5, LUA_TTABLE);
    count = lua_rawlen(L, 5);
    luaL_argcheck(L, count >= 1 && count <= RESOLVE_SERVERS_MAX, 5, "through must hold 1 through 128 servers");
    luaL_argcheck(L, servers == NULL, 3, "servers and through are exclusive");
  }
#if defined(__linux__)
  struct lookup *lookup = lookup_push(L);
  int owner = lua_gettop(L);
  struct resolution *resolution = calloc(1, sizeof *resolution);
  if (resolution == NULL) return cosmic_fail (L, ENOMEM);
  lookup->resolution = resolution;
  resolution->deadline = timeout < 0 ? -1 : cosmic_now_ms() + timeout;
  char *listed = NULL;
  if (through) {
    resolution->through = true;
    resolution->server = calloc(count, sizeof *resolution->server);
    size_t room = count * RESOLVE_SERVER_TEXT;
    listed = lua_newuserdatauv(L, room, 0);
    if (resolution->server == NULL) return cosmic_fail(L, ENOMEM);
    size_t used = 0;
    for (size_t i = 0; i < count; i++) {
      lua_rawgeti(L, 5, (lua_Integer)i + 1);
      used += through_server_read(L, 5, i == 0, &resolution->server[i], listed + used, room - used);
      lua_pop(L, 1);
      resolution->servers++;
    }
    servers = listed;
  }
  if (resolve_refused(name, size) || (hosts_given && hosts == NULL)) return cosmic_fail (L, EINVAL);
  if (numeric_literal(name, size, &resolution->literal_family, resolution->literal)) {
    resolution->done = true;
    lua_pushvalue(L, owner);
    return 1;
  }
  int failure = lookup_begin(name, timeout, servers, hosts, resolution);
  if (failure > 0) return resolve_failed (L, failure);
  if (failure < 0) return cosmic_fail (L, -failure);
  lua_pushvalue(L, owner);
  return 1;
#else
  /* The servers are held to their form here too, though no lookup runs. */
  for (size_t i = 0; i < count; i++) {
    struct resolve_server server;
    lua_rawgeti(L, 5, (lua_Integer)i + 1);
    (void)through_server_read(L, 5, i == 0, &server, NULL, 0);
    lua_pop(L, 1);
  }
  if (resolve_refused(name, size) || (hosts_given && hosts == NULL)) return cosmic_fail (L, EINVAL);
  if (through) return cosmic_fail (L, ENOSYS);
  struct lookup *lookup = lookup_push(L);
  int owner = lua_gettop(L);
  struct resolution *resolution = calloc(1, sizeof *resolution);
  if (resolution == NULL) return cosmic_fail (L, ENOMEM);
  lookup->resolution = resolution;
  resolution->deadline = timeout < 0 ? -1 : cosmic_now_ms() + timeout;
  if (numeric_literal(name, size, &resolution->literal_family, resolution->literal)) {
    resolution->done = true;
    lua_pushvalue(L, owner);
    return 1;
  }
  int failure = lookup_begin(name, timeout, servers, hosts, resolution);
  if (failure > 0) return resolve_failed (L, failure);
  if (failure < 0) return cosmic_fail (L, -failure);
  lua_pushvalue(L, owner);
  return 1;
#endif
}


/* What a `nameservers` call holds, released on every way out. */
struct listing {
  ares_channel_t *channel;
  char *listed;
};

static void listing_release (void *resource) {
  struct listing *listing = resource;
  if (listing->listed != NULL) ares_free_string(listing->listed);
  if (listing->channel != NULL) ares_destroy(listing->channel);
  free(listing);
}

COSMIC_SYSCALL(nameservers, 1) {
  const char *path = lua_isnoneornil(L, 1) ? NULL : cosmic_path(L, 1);
  if (!lua_isnoneornil(L, 1) && path == NULL) return cosmic_fail (L, EINVAL);
  struct cosmic_guard *guard = cosmic_guard_push(L, listing_release);
  struct listing *listing = calloc(1, sizeof *listing);
  if (listing == NULL) return cosmic_fail (L, ENOMEM);
  guard->resource = listing;
  struct ares_options options;
  memset(&options, 0, sizeof options);
  int mask = 0;
  if (path != NULL) {
    mask |= ARES_OPT_RESOLVCONF;
    options.resolvconf_path = (char *)path;
  }
  int status = ares_init_options(&listing->channel, &options, mask);
  if (status != ARES_SUCCESS) {
    listing->channel = NULL;
    return cosmic_fail(L, status == ARES_ENOMEM ? ENOMEM : status == ARES_EFILE ? EACCES : EIO);
  }
  listing->listed = ares_get_servers_csv(listing->channel);
  if (listing->listed == NULL) return cosmic_fail (L, ENOMEM);
  lua_pushstring(L, listing->listed);
  return 1;
}

/* The table is filled from the header's own entries, as core/syscalls.c
 * fills its own. */
#undef COSMIC_SYSCALL
#undef COSMIC_CONSTANT
#define COSMIC_SYSCALL(name, arity)                                      \
  lua_pushcfunction(L, cosmic_sys_##name);                               \
  lua_setfield(L, -2, #name)
#define COSMIC_CONSTANT(name)                                            \
  lua_pushinteger(L, name);                                              \
  lua_setfield(L, -2, #name);

int cosmic_open_socket (lua_State *L) {
  lua_newtable(L);
#include "socket.h"
  return 1;
}
