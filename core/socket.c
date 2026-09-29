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

#if defined(O_PATH)
#define DIRECTORY_FLAGS (O_PATH | O_DIRECTORY | O_CLOEXEC)
#else
#define DIRECTORY_FLAGS (O_RDONLY | O_DIRECTORY | O_CLOEXEC)
#endif

/* Binds `fd` to `target`, or connects it there: 0, or why not. A
 * target reached from its directory is bound or connected with the
 * process in that directory, and back where it was before this
 * returns -- no Lua runs between, and the Lua state is this process's
 * one thread, so nothing else meets the directory changed. Neither
 * macOS nor Linux has bindat and connectat (FreeBSD's) to name the
 * directory by its descriptor instead. */
static int reach (int fd, const struct target *target, bool binding) {
  const struct sockaddr *address = (const struct sockaddr *)&target->address;
  if (target->directory[0] == '\0') {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    return done == 0 ? 0 : errno;
  }
  int here = open(".", DIRECTORY_FLAGS);
  if (here < 0) return errno;
  int there = open(target->directory, DIRECTORY_FLAGS);
  if (there < 0) {
    int failure = errno;
    close(here);
    return failure;
  }
  int failure = 0;
  if (fchdir(there) != 0) {
    failure = errno;
  } else {
    int done = binding ? bind(fd, address, target->length) : connect(fd, address, target->length);
    if (done != 0) failure = errno;
    if (fchdir(here) != 0 && failure == 0) failure = errno;
  }
  close(there);
  close(here);
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

/* Milliseconds on the monotonic clock. */
static int64_t now_ms (void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The longest a wait sleeps before it asks again whether a guard caught
 * a signal. A signal that lands between that question and the sleep
 * only sets the guard's flag, so a sleep with no bound could outlast
 * it forever; each slice bounds how late it is seen, as core/http.c's
 * one-second polls and cosmic.child's do. */
#define SLICE_MS 100

/* The deadline argument `arg`'s timeout in milliseconds makes, on the
 * monotonic clock, or -1 for a timeout of -1, no limit. */
static int64_t deadline_of (lua_State *L, int arg) {
  lua_Integer timeout = luaL_checkinteger(L, arg);
  luaL_argcheck(L, timeout >= -1 && timeout <= INT_MAX, arg, "timeout is out of range");
  return timeout < 0 ? -1 : now_ms() + timeout;
}

/* How long a wait for `deadline` may sleep now: a slice at most, 0 once
 * it has passed. */
static int slice (int64_t deadline) {
  if (deadline < 0) return SLICE_MS;
  int64_t remaining = deadline - now_ms();
  if (remaining <= 0) return 0;
  return remaining < SLICE_MS ? (int)remaining : SLICE_MS;
}

/* Sleeps `*pause` milliseconds, doubling it up to a slice for the next
 * time, before a call that answered EAGAIN is asked again: 0 to ask
 * again, ETIMEDOUT once `deadline` has passed, EINTR once a guard has
 * caught a signal. */
static int paused (int64_t deadline, int64_t *pause) {
  if (cosmic_signal_caught()) return EINTR;
  int most = slice(deadline);
  if (most == 0) return ETIMEDOUT;
  int64_t ms = *pause < most ? *pause : most;
  *pause = *pause * 2 < SLICE_MS ? *pause * 2 : SLICE_MS;
  struct timespec ts = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000L };
  nanosleep(&ts, NULL);
  return cosmic_signal_caught() ? EINTR : 0;
}

/* Waits until `fd` has `events`, in slices: 0 once it has, ETIMEDOUT
 * once `deadline` has passed, EINTR once a guard has caught a signal,
 * or why poll failed. */
static int ready (int fd, short events, int64_t deadline) {
  for (;;) {
    if (cosmic_signal_caught()) return EINTR;
    int left = slice(deadline);
    struct pollfd watched = { fd, events, 0 };
    int found = poll(&watched, 1, left);
    if (found > 0) return 0;
    if (found < 0 && errno != EINTR) return errno;
    if (found == 0 && left == 0) return ETIMEDOUT;
  }
}

/* Waits for the connection `fd` has in progress to be made or refused,
 * in slices as `paused` does: 0 once made, its failure (SO_ERROR) once
 * refused, ETIMEDOUT once `deadline` has passed, EINTR once a guard has
 * caught a signal. */
static int settled (int fd, int64_t deadline) {
  int failure = ready(fd, POLLOUT, deadline);
  if (failure != 0) return failure;
  socklen_t size = sizeof failure;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) != 0) return errno;
  return failure;
}

COSMIC_SYSCALL(listen, 2) {
  struct target target;
  int failure = address_of(L, 1, &target);
  int backlog = cosmic_checkint(L, 2);
  luaL_argcheck(L, backlog >= 1, 2, "backlog must be at least 1");
  if (failure != 0) return cosmic_fail(L, failure);
  int fd = stream_socket(target.address.ss_family);
  if (fd < 0) return cosmic_fail(L, errno);
#if defined(__linux__)
  /* A port left in TIME_WAIT by a listener before this one is taken
   * again, as every server does. Linux alone: on macOS the same option
   * also lets a bind to one address take a port another socket holds
   * on every address, and its traffic with it. */
  int on = 1;
  if (target.address.ss_family != AF_UNIX &&
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on) != 0) {
    failure = errno;
    close(fd);
    return cosmic_fail(L, failure);
  }
#endif
  failure = reach(fd, &target, true);
  if (failure == 0 && listen(fd, backlog) != 0) failure = errno;
  if (failure != 0) {
    close(fd);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(accept, 1) {
  int listener = cosmic_checkfd(L, 1);
  int fd;
  do {
#if defined(SOCK_CLOEXEC)
    fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
#else
    fd = accept(listener, NULL, NULL);
#endif
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) return cosmic_fail(L, errno);
  int failure = made(fd);
  if (failure != 0) {
    close(fd);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(connect, 2) {
  struct target target;
  int failure = address_of(L, 1, &target);
  int64_t deadline = deadline_of(L, 2);
  if (failure != 0) return cosmic_fail(L, failure);
  int fd = stream_socket(target.address.ss_family);
  if (fd < 0) return cosmic_fail(L, errno);
  /* A unix socket connects at once or answers EAGAIN, its listener's
   * backlog full, where a blocking one would wait: this waits in
   * slices, asking again, as `wait` does. A TCP one answers EINPROGRESS
   * and connects over time, which `settled` waits out. */
  int64_t pause = 1;
  for (;;) {
    failure = reach(fd, &target, false);
    if (failure == EAGAIN) {
      failure = paused(deadline, &pause);
      if (failure == 0) continue;
    } else if (failure == EINPROGRESS) {
      failure = settled(fd, deadline);
    }
    break;
  }
  if (failure != 0) {
    close(fd);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(bound, 1) {
  int fd = cosmic_checkfd(L, 1);
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  memset(&address, 0, sizeof address);
  if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return cosmic_fail(L, errno);
  char host[INET6_ADDRSTRLEN];
  int port = 0;
  const char *named = NULL;
  if (address.ss_family == AF_INET) {
    struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
    named = inet_ntop(AF_INET, &v4->sin_addr, host, sizeof host);
    port = ntohs(v4->sin_port);
  } else if (address.ss_family == AF_INET6) {
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
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
