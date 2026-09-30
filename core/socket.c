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
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

#include "check.h"
#include "fail.h"
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
  if (strlen(host) != size) {
    failure = EINVAL;
  } else if (inet_pton(AF_INET, host, &v4->sin_addr) == 1) {
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
  if (size == 0) return luaL_argerror(L, index, "path must not be empty");
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
 * (FreeBSD's) to name the directory by its descriptor instead. */
static int reach_from (int fd, int there, const struct target *target, bool binding) {
  const struct sockaddr *address = (const struct sockaddr *)&target->address;
  int here = open(".", DIRECTORY_FLAGS);
  if (here < 0) return errno;
  int failure = 0;
  if (fchdir(there) != 0) {
    failure = errno;
  } else {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    if (done != 0) failure = errno;
    if (fchdir(here) != 0 && failure == 0) failure = errno;
  }
  close(here);
  return failure;
}

/* Binds `fd` to `target`, or connects it there: 0, or why not. A
 * target reached from its directory is reached as [`reach_from`] says. */
static int reach (int fd, const struct target *target, bool binding) {
  const struct sockaddr *address = (const struct sockaddr *)&target->address;
  if (target->directory[0] == '\0') {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    return done == 0 ? 0 : errno;
  }
  int there = open(target->directory, DIRECTORY_FLAGS);
  if (there < 0) return errno;
  int failure = reach_from(fd, there, target, binding);
  close(there);
  return failure;
}

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

/* A new stream socket of `family`, made as `made` says, or -1 with
 * errno set. */
static int stream_socket (int family) {
#if defined(SOCK_CLOEXEC)
  int fd = socket(family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
  int fd = socket(family, SOCK_STREAM, 0);
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
  owned->fd = stream_socket(target.address.ss_family);
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
  failure = unix_socket && target.directory[0] != '\0'
    ? reach_from(owned->fd, owned->directory, &target, true)
    : reach(owned->fd, &target, true);
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
   * left where the read back fails at all, or the bind's return to the
   * working directory does: a file whose identity was not read is not
   * told from one that took its name, and removing it could remove
   * another's. */
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

COSMIC_SYSCALL(connect, 2) {
  struct target target;
  int failure = address_of(L, 1, &target);
  int64_t deadline = deadline_of(L, 2);
  if (failure != 0) return cosmic_fail(L, failure);
  struct owned *owned = owner_push(L, 0);
  owned->fd = stream_socket(target.address.ss_family);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  /* A unix socket connects at once or answers EAGAIN, its listener's
   * backlog full, where a blocking one would wait: this waits in
   * slices, asking again, as `wait` does. A TCP one answers EINPROGRESS
   * and connects over time, which `settled` waits out. */
  int64_t pause = 1;
  for (;;) {
    failure = reach(owned->fd, &target, false);
    if (failure == EAGAIN) {
      failure = cosmic_paused(deadline, &pause);
      if (failure == 0) continue;
    } else if (failure == EINPROGRESS) {
      failure = settled(owned->fd, deadline);
    }
    break;
  }
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
  owned->fd = stream_socket(target.address.ss_family);
  if (owned->fd < 0) return cosmic_fail(L, errno);
  failure = reach(owned->fd, &target, false);
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

COSMIC_SYSCALL(pair, 0) {
  lua_createtable(L, 0, 2);
  struct owned *first = owner_push(L, 0);
  struct owned *second = owner_push(L, 0);
  int ends[2];
#if defined(SOCK_CLOEXEC)
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, ends) != 0) {
    return cosmic_fail(L, errno);
  }
#else
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, ends) != 0) return cosmic_fail(L, errno);
#endif
  first->fd = ends[0];
  second->fd = ends[1];
  int failure = made(first->fd);
  if (failure == 0) failure = made(second->fd);
  if (failure != 0) {
    released(first);
    released(second);
    return cosmic_fail(L, failure);
  }
  lua_setfield(L, -3, "second");
  lua_setfield(L, -2, "first");
  return 1;
}

/* Pushes the "tcp" address `address` holds: 1, or what `cosmic_fail`
 * pushes for one of another family, EAFNOSUPPORT. */
static int tcp_pushed (lua_State *L, const struct sockaddr_storage *address) {
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
  lua_pushliteral(L, "tcp");
  lua_setfield(L, -2, "kind");
  lua_pushstring(L, host);
  lua_setfield(L, -2, "host");
  lua_pushinteger(L, port);
  lua_setfield(L, -2, "port");
  return 1;
}

COSMIC_SYSCALL(bound, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return cosmic_fail(L, errno);
  return tcp_pushed(L, &address);
}

COSMIC_SYSCALL(peer, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getpeername(fd, (struct sockaddr *)&address, &length) != 0) return cosmic_fail(L, errno);
  if (address.ss_family == AF_INET || address.ss_family == AF_INET6) {
    return tcp_pushed(L, &address);
  }
  /* Any other peer is a unix one: one bound nowhere may answer no path,
   * and no family either, and a path's length may count its NUL. */
  const struct sockaddr_un *unix_address = (const struct sockaddr_un *)&address;
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

COSMIC_SYSCALL(send, 2) {
  int fd = cosmic_checkfd(L, 1);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
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
